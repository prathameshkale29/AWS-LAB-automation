# ============================================================================
# lab4.ps1 - AWS Academy Lab 4: Working with EBS
# ============================================================================
$ErrorActionPreference = "Stop"
$region = "us-east-1"
Set-Location $PSScriptRoot

function Test-AwsResult {
    param([string]$r)
    return (-not [string]::IsNullOrWhiteSpace($r)) -and ($r -ne "None") -and ($r -ne "null")
}
function Assert-Success {
    param([string]$step)
    if ($LASTEXITCODE -ne 0) { throw "FAIL: $step (exit code $LASTEXITCODE)" }
}

# Helper to run shell commands on the EC2 instance via AWS SSM Run Command
function Invoke-Ec2Command {
    param(
        [string]$instId,
        [string[]]$cmdList,
        [string]$stepName
    )
    Write-Host "Running on instance via SSM: $stepName..."
    $json = @{ commands = $cmdList } | ConvertTo-Json
    $tmpFile = Join-Path $PSScriptRoot "ssm_params.json"
    Set-Content -Path $tmpFile -Value $json -Encoding Ascii
    $cmdId = aws ssm send-command `
        --instance-ids $instId `
        --document-name "AWS-RunShellScript" `
        --parameters file://ssm_params.json `
        --query "Command.CommandId" `
        --output text `
        --region $region
    Assert-Success "Send SSM command: $stepName"

    # Wait for command completion
    $status = "Pending"
    do {
        Start-Sleep -Seconds 3
        $status = aws ssm get-command-invocation `
            --command-id $cmdId `
            --instance-id $instId `
            --query "Status" `
            --output text `
            --region $region 2>$null
    } while ($status -in @("Pending", "InProgress", "Delayed"))

    $stdout = aws ssm get-command-invocation `
        --command-id $cmdId `
        --instance-id $instId `
        --query "StandardOutputContent" `
        --output text `
        --region $region 2>$null

    if ($status -ne "Success") {
        $stderr = aws ssm get-command-invocation `
            --command-id $cmdId `
            --instance-id $instId `
            --query "StandardErrorContent" `
            --output text `
            --region $region 2>$null
        Write-Host "SSM Command Failed. Output: $stdout `nError: $stderr" -ForegroundColor Red
        throw "FAIL: SSM command '$stepName' exited with status $status"
    }
    return $stdout
}

# === Verify AWS session ===
Write-Host "`n=== Verifying AWS Session ===" -ForegroundColor Cyan
aws sts get-caller-identity --region $region --output table
Assert-Success "Session verification"
Write-Host "PASS: Session valid`n" -ForegroundColor Green

# ==========================================================================
# Locate pre-existing EC2 instance named 'Lab'
# ==========================================================================
Write-Host "Locating EC2 instance 'Lab'..." -ForegroundColor Cyan
$instanceId = aws ec2 describe-instances --filters "Name=tag:Name,Values=Lab" "Name=instance-state-name,Values=pending,running" --query "Reservations[0].Instances[0].InstanceId" --output text --region $region
if (-not (Test-AwsResult $instanceId)) {
    throw "EC2 instance with tag Name='Lab' not found. Please ensure Lab 4 is fully started."
}
$az = aws ec2 describe-instances --instance-ids $instanceId --query "Reservations[0].Instances[0].Placement.AvailabilityZone" --output text --region $region
Write-Host "Found Lab instance: $instanceId in Availability Zone: $az"

# Wait for SSM agent to be online
Write-Host "Checking SSM connectivity to instance $instanceId..."
$ssmOnline = $false
for ($i = 0; $i -lt 20; $i++) {
    $ping = aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$instanceId" --query "InstanceInformationList[0].PingStatus" --output text --region $region 2>$null
    if ($ping -eq "Online") {
        $ssmOnline = $true
        break
    }
    Write-Host "  Waiting for SSM agent to report Online (attempt $($i+1)/20)..."
    Start-Sleep -Seconds 6
}
if (-not $ssmOnline) {
    Write-Host "Warning: SSM agent not yet reported Online. Will attempt commands directly." -ForegroundColor Yellow
}

# ==========================================================================
# TASK 1: Create a New EBS Volume
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 1: Create a New EBS Volume (1 GiB gp2 in $az)" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

$vol1Id = aws ec2 describe-volumes --filters "Name=tag:Name,Values=My Volume" "Name=availability-zone,Values=$az" "Name=status,Values=creating,available,in-use" --query "Volumes[0].VolumeId" --output text --region $region 2>$null
if (-not (Test-AwsResult $vol1Id)) {
    Write-Host "Creating volume: My Volume (1 GiB, gp2, $az)..."
    $vol1Id = aws ec2 create-volume `
        --volume-type gp2 `
        --size 1 `
        --availability-zone $az `
        --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=My Volume}]" `
        --query "VolumeId" `
        --output text `
        --region $region
    Assert-Success "Create volume My Volume"
    Write-Host "Waiting for volume $vol1Id to become available..."
    aws ec2 wait volume-available --volume-ids $vol1Id --region $region
} else {
    Write-Host "Volume 'My Volume' already exists: $vol1Id"
}
$vState = aws ec2 describe-volumes --volume-ids $vol1Id --query "Volumes[0].State" --output text --region $region
Write-Host "PASS: Volume $vol1Id (State: $vState)" -ForegroundColor Green
Write-Host "`n>> TASK 1 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 2: Attach the Volume to the Instance
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 2: Attach Volume to Instance Lab as /dev/sdb" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

$attachState = aws ec2 describe-volumes --volume-ids $vol1Id --query "Volumes[0].Attachments[0].State" --output text --region $region 2>$null
if ($attachState -ne "attached" -and $attachState -ne "attaching") {
    Write-Host "Attaching $vol1Id to $instanceId as /dev/sdb..."
    aws ec2 attach-volume --volume-id $vol1Id --instance-id $instanceId --device /dev/sdb --region $region | Out-Null
    Assert-Success "Attach volume"
    Write-Host "Waiting for volume to be in-use..."
    aws ec2 wait volume-in-use --volume-ids $vol1Id --region $region
} else {
    Write-Host "Volume is already attached (State: $attachState)"
}
Write-Host "PASS: Volume $vol1Id attached as /dev/sdb" -ForegroundColor Green
Write-Host "`n>> TASK 2 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 3 & 4: Create and Configure File System on /dev/sdb
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 3 & 4: Format ext3 & Mount to /mnt/data-store" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

# Script to format, mount, add to fstab, and create test file
$linuxCmds1 = @(
    'DEVICE=/dev/sdb',
    'if [ ! -b $DEVICE ] && [ -b /dev/xvdb ]; then DEVICE=/dev/xvdb; fi',
    'if [ ! -b $DEVICE ] && [ -b /dev/nvme1n1 ]; then DEVICE=/dev/nvme1n1; fi',
    'echo Using device: $DEVICE',
    'file -s $DEVICE | grep ext3 || sudo mkfs -t ext3 $DEVICE',
    'sudo mkdir -p /mnt/data-store',
    'mountpoint -q /mnt/data-store || sudo mount $DEVICE /mnt/data-store',
    'grep -q "/mnt/data-store" /etc/fstab || echo "$DEVICE /mnt/data-store ext3 defaults,noatime 1 2" | sudo tee -a /etc/fstab',
    'sudo sh -c "echo some text has been written > /mnt/data-store/file.txt"',
    'cat /mnt/data-store/file.txt',
    'df -h /mnt/data-store'
)
$output1 = Invoke-Ec2Command -instId $instanceId -cmdList $linuxCmds1 -stepName "Format and Mount My Volume"
Write-Host $output1
Write-Host "PASS: ext3 filesystem formatted, mounted at /mnt/data-store, and file.txt created" -ForegroundColor Green
Write-Host "`n>> TASK 3 & 4 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 5: Create an Amazon EBS Snapshot
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 5: Create Snapshot of My Volume" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

$snapId = aws ec2 describe-snapshots --owner-ids self --filters "Name=tag:Name,Values=My Snapshot" "Name=volume-id,Values=$vol1Id" --query "Snapshots[0].SnapshotId" --output text --region $region 2>$null
if (-not (Test-AwsResult $snapId)) {
    Write-Host "Creating snapshot of volume $vol1Id..."
    $snapId = aws ec2 create-snapshot `
        --volume-id $vol1Id `
        --description "Snapshot of My Volume" `
        --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=My Snapshot}]" `
        --query "SnapshotId" `
        --output text `
        --region $region
    Assert-Success "Create snapshot"
    Write-Host "Waiting for snapshot $snapId to complete (~1-2 min)..."
    aws ec2 wait snapshot-completed --snapshot-ids $snapId --region $region
} else {
    Write-Host "Snapshot already exists: $snapId"
    $s = aws ec2 describe-snapshots --snapshot-ids $snapId --query "Snapshots[0].State" --output text --region $region
    if ($s -ne "completed") {
        Write-Host "Waiting for snapshot to complete..."
        aws ec2 wait snapshot-completed --snapshot-ids $snapId --region $region
    }
}
Write-Host "PASS: Snapshot $snapId completed" -ForegroundColor Green

# Delete file.txt on the instance as required by Task 5
$linuxCmds2 = @(
    "sudo rm -f /mnt/data-store/file.txt",
    "ls -la /mnt/data-store/"
)
$output2 = Invoke-Ec2Command -instId $instanceId -cmdList $linuxCmds2 -stepName "Delete file.txt from /mnt/data-store"
Write-Host $output2
Write-Host "PASS: Verified file.txt deleted from original volume" -ForegroundColor Green
Write-Host "`n>> TASK 5 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 6: Restore the Snapshot to a New EBS Volume and Mount It
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 6: Restore Snapshot to 'Restored Volume' & Mount to /mnt/data-store2" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

$vol2Id = aws ec2 describe-volumes --filters "Name=tag:Name,Values=Restored Volume" "Name=availability-zone,Values=$az" "Name=status,Values=creating,available,in-use" --query "Volumes[0].VolumeId" --output text --region $region 2>$null
if (-not (Test-AwsResult $vol2Id)) {
    Write-Host "Creating volume from snapshot $snapId..."
    $vol2Id = aws ec2 create-volume `
        --snapshot-id $snapId `
        --availability-zone $az `
        --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=Restored Volume}]" `
        --query "VolumeId" `
        --output text `
        --region $region
    Assert-Success "Create restored volume"
    Write-Host "Waiting for volume $vol2Id to become available..."
    aws ec2 wait volume-available --volume-ids $vol2Id --region $region
} else {
    Write-Host "Restored Volume already exists: $vol2Id"
}

# Attach Restored Volume as /dev/sdc
$attachState2 = aws ec2 describe-volumes --volume-ids $vol2Id --query "Volumes[0].Attachments[0].State" --output text --region $region 2>$null
if ($attachState2 -ne "attached" -and $attachState2 -ne "attaching") {
    Write-Host "Attaching $vol2Id to $instanceId as /dev/sdc..."
    aws ec2 attach-volume --volume-id $vol2Id --instance-id $instanceId --device /dev/sdc --region $region | Out-Null
    Assert-Success "Attach restored volume"
    Write-Host "Waiting for volume to be in-use..."
    aws ec2 wait volume-in-use --volume-ids $vol2Id --region $region
} else {
    Write-Host "Restored volume already attached: $attachState2"
}

# Mount Restored Volume to /mnt/data-store2 and verify file.txt exists
$linuxCmds3 = @(
    'DEVICE=/dev/sdc',
    'if [ ! -b $DEVICE ] && [ -b /dev/xvdc ]; then DEVICE=/dev/xvdc; fi',
    'if [ ! -b $DEVICE ] && [ -b /dev/nvme2n1 ]; then DEVICE=/dev/nvme2n1; fi',
    'echo Using device: $DEVICE',
    'sudo mkdir -p /mnt/data-store2',
    'mountpoint -q /mnt/data-store2 || sudo mount $DEVICE /mnt/data-store2',
    'ls -l /mnt/data-store2/file.txt',
    'cat /mnt/data-store2/file.txt'
)
$output3 = Invoke-Ec2Command -instId $instanceId -cmdList $linuxCmds3 -stepName "Mount Restored Volume & Verify file.txt"
Write-Host $output3
Write-Host "PASS: Restored volume mounted at /mnt/data-store2 and file.txt verified restored!" -ForegroundColor Green
Write-Host "`n>> TASK 6 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# SUMMARY
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host " ALL LAB 4 TASKS COMPLETED SUCCESSFULLY" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host "EC2 Instance:       $instanceId (Lab)"
Write-Host "Availability Zone:  $az"
Write-Host "Original Volume:    $vol1Id (My Volume, 1 GiB, gp2)"
Write-Host "Snapshot:           $snapId (My Snapshot)"
Write-Host "Restored Volume:    $vol2Id (Restored Volume)"
Write-Host ""
Write-Host ">> You can now click Submit in the AWS Academy lab window! <<" -ForegroundColor Cyan

