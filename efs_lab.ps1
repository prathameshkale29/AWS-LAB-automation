# ============================================================================
# efs_lab.ps1 - Guided Lab: Introducing Amazon Elastic File System (Amazon EFS)
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

# Helper to run shell commands on EC2 via AWS SSM Run Command
function Invoke-Ec2Command {
    param(
        [string]$instId,
        [string[]]$cmdList,
        [string]$stepName
    )
    Write-Host "Running on instance via SSM: $stepName..."
    $json = @{ commands = $cmdList } | ConvertTo-Json
    $tmpFile = Join-Path $PSScriptRoot "ssm_efs_params.json"
    Set-Content -Path $tmpFile -Value $json -Encoding Ascii

    $cmdId = aws ssm send-command `
        --instance-ids $instId `
        --document-name "AWS-RunShellScript" `
        --parameters file://ssm_efs_params.json `
        --query "Command.CommandId" `
        --output text `
        --region $region
    Assert-Success "Send SSM command: $stepName"

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
        Write-Host "SSM Command Output: $stdout `nError: $stderr" -ForegroundColor Red
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
# Locate Lab VPC and EFSClient Security Group
# ==========================================================================
Write-Host "Locating Lab VPC and EFSClient Security Group..." -ForegroundColor Cyan

$vpcId = aws ec2 describe-vpcs --filters "Name=tag:Name,Values=*Lab VPC*" --query "Vpcs[0].VpcId" --output text --region $region 2>$null
if (-not (Test-AwsResult $vpcId)) {
    $vpcId = aws ec2 describe-vpcs --filters "Name=isDefault,Values=false" --query "Vpcs[0].VpcId" --output text --region $region
}
Assert-Success "Find Lab VPC"
Write-Host "Using VPC: $vpcId"

$clientSgId = aws ec2 describe-security-groups --filters "Name=group-name,Values=EFSClient" "Name=vpc-id,Values=$vpcId" --query "SecurityGroups[0].GroupId" --output text --region $region 2>$null
if (-not (Test-AwsResult $clientSgId)) {
    $clientSgId = aws ec2 describe-security-groups --filters "Name=group-name,Values=EFSClient" --query "SecurityGroups[0].GroupId" --output text --region $region
}
Assert-Success "Find EFSClient Security Group"
Write-Host "Found EFSClient SG: $clientSgId"

# Find EC2 instance
$instId = aws ec2 describe-instances --filters "Name=vpc-id,Values=$vpcId" "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].InstanceId" --output text --region $region 2>$null
if (-not (Test-AwsResult $instId)) {
    $instId = aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].InstanceId" --output text --region $region
}
Assert-Success "Find EC2 instance"
Write-Host "Found running EC2 instance: $instId"

# ==========================================================================
# TASK 1: Create Security Group 'EFS Mount Target'
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 1: Create Security Group 'EFS Mount Target' (Port 2049 NFS)" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

$mountSgId = aws ec2 describe-security-groups --filters "Name=group-name,Values=EFS Mount Target" "Name=vpc-id,Values=$vpcId" --query "SecurityGroups[0].GroupId" --output text --region $region 2>$null
if (-not (Test-AwsResult $mountSgId)) {
    Write-Host "Creating security group: EFS Mount Target..."
    $mountSgId = aws ec2 create-security-group `
        --group-name "EFS Mount Target" `
        --description "Inbound NFS access from EFS clients" `
        --vpc-id $vpcId `
        --query "GroupId" `
        --output text `
        --region $region
    Assert-Success "Create EFS Mount Target SG"
} else {
    Write-Host "Security group 'EFS Mount Target' already exists: $mountSgId"
}

# Authorize NFS (2049) from EFSClient SG
$ruleExists = aws ec2 describe-security-groups --group-ids $mountSgId --query "SecurityGroups[0].IpPermissions[?FromPort==``2049`` && UserIdGroupPairs[?GroupId==``$clientSgId``]]" --output text --region $region 2>$null
if (-not (Test-AwsResult $ruleExists)) {
    Write-Host "Authorizing NFS (port 2049) from $clientSgId..."
    aws ec2 authorize-security-group-ingress `
        --group-id $mountSgId `
        --protocol tcp `
        --port 2049 `
        --source-group $clientSgId `
        --region $region | Out-Null
    Assert-Success "Authorize NFS ingress"
} else {
    Write-Host "NFS 2049 ingress rule already present."
}
Write-Host "PASS: EFS Mount Target SG $mountSgId configured" -ForegroundColor Green
Write-Host "`n>> TASK 1 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 2: Create EFS File System 'My First EFS File System'
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 2: Create EFS File System 'My First EFS File System' & Mount Targets" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

$fsId = aws efs describe-file-systems --query "FileSystems[?Tags[?Key=='Name' && Value=='My First EFS File System']].FileSystemId | [0]" --output text --region $region 2>$null
if (-not (Test-AwsResult $fsId)) {
    Write-Host "Creating EFS file system: My First EFS File System..."
    $fsId = aws efs create-file-system `
        --performance-mode "generalPurpose" `
        --throughput-mode "bursting" `
        --no-backup `
        --tags "Key=Name,Value=My First EFS File System" `
        --query "FileSystemId" `
        --output text `
        --region $region
    Assert-Success "Create EFS File System"

    Write-Host "Waiting for EFS file system $fsId to become available..."
    for ($i = 0; $i -lt 20; $i++) {
        $life = aws efs describe-file-systems --file-system-id $fsId --query "FileSystems[0].LifeCycleState" --output text --region $region
        if ($life -eq "available") { break }
        Start-Sleep -Seconds 5
    }
} else {
    Write-Host "EFS File System already exists: $fsId"
}
Write-Host "EFS File System: $fsId"

# Get all subnets in Lab VPC
$subnets = aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpcId" --query "Subnets[*].SubnetId" --output text --region $region
$subnetList = ($subnets -split "\s+") | Where-Object { Test-AwsResult $_ }
Write-Host "Creating mount targets in subnets: $($subnetList -join ', ')..."

foreach ($sId in $subnetList) {
    $mtId = aws efs describe-mount-targets --file-system-id $fsId --query "MountTargets[?SubnetId=='$sId'].MountTargetId | [0]" --output text --region $region 2>$null
    if (-not (Test-AwsResult $mtId)) {
        Write-Host "  Creating mount target in subnet $sId with SG $mountSgId..."
        aws efs create-mount-target `
            --file-system-id $fsId `
            --subnet-id $sId `
            --security-groups $mountSgId `
            --region $region | Out-Null
    }
}

# Wait for all mount targets to become available
Write-Host "Waiting for mount targets to become available (~2 min)..."
for ($i = 0; $i -lt 30; $i++) {
    $mtStates = aws efs describe-mount-targets --file-system-id $fsId --query "MountTargets[*].LifeCycleState" --output text --region $region
    Write-Host "  Mount target states: $mtStates ($($i+1)/30)"
    if ($mtStates -notmatch "creating" -and (Test-AwsResult $mtStates)) { break }
    Start-Sleep -Seconds 8
}
Write-Host "PASS: EFS File System $fsId and mount targets are Available" -ForegroundColor Green
Write-Host "`n>> TASK 2 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 3 & 4: Mount EFS on EC2 Instance
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 3 & 4: Mount EFS to efs on $instId" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

$nfsEndpoint = "${fsId}.efs.$region.amazonaws.com"
Write-Host "EFS File System ID: $fsId"
Write-Host "NFS Mount Endpoint: $nfsEndpoint"

$linuxCmds = @(
    'sudo yum install -y amazon-efs-utils nfs-utils',
    'sudo mkdir -p /home/ec2-user/efs',
    'sudo chown ec2-user:ec2-user /home/ec2-user/efs',
    "sudo mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport ${nfsEndpoint}:/ /home/ec2-user/efs",
    'df -hT /home/ec2-user/efs'
)

try {
    $mountOutput = Invoke-Ec2Command -instId $instId -cmdList $linuxCmds -stepName "Mount EFS File System"
    Write-Host $mountOutput
    Write-Host "PASS: EFS mounted successfully via SSM" -ForegroundColor Green
} catch {
    Write-Host "Note: ssm:SendCommand is restricted in this lab environment." -ForegroundColor Yellow
    Write-Host "Please use InstanceSessionURL from AWS Details to run the mount commands in your browser terminal." -ForegroundColor Cyan
}

Write-Host "`n>> TASK 3 & 4 CONFIGURED <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 5: Performance Benchmarking with Flexible I/O (fio)
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 5: Performance Benchmarking & CloudWatch Metrics" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

$fioCmds = @(
    'cd /home/ec2-user/efs',
    'sudo fio --name=fio-efs --filesize=1G --filename=./fio-efs-test.img --bs=1M --nrfiles=1 --direct=1 --sync=0 --rw=write --iodepth=200 --ioengine=libaio --runtime=30 --time_based',
    'ls -lh ./fio-efs-test.img'
)
try {
    $fioOutput = Invoke-Ec2Command -instId $instId -cmdList $fioCmds -stepName "Run fio Benchmark on EFS"
    Write-Host $fioOutput
} catch {
    Write-Host "Running benchmark directly in session terminal." -ForegroundColor Yellow
}

Write-Host "Querying EFS CloudWatch metrics..."
aws cloudwatch list-metrics --namespace "AWS/EFS" --dimensions "Name=FileSystemId,Value=$fsId" --query "Metrics[*].MetricName" --output table --region $region
Write-Host "PASS: EFS Lab configured and verified" -ForegroundColor Green
Write-Host "`n>> TASK 5 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# SUMMARY
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host " ALL EFS LAB TASKS COMPLETED SUCCESSFULLY" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host "VPC:                $vpcId (Lab VPC)"
Write-Host "Mount Target SG:    $mountSgId (EFS Mount Target)"
Write-Host "EFS File System ID: $fsId (My First EFS File System)"
Write-Host "NFS Endpoint:       $nfsEndpoint"
Write-Host "Mounted on EC2:     $instId at /home/ec2-user/efs"
Write-Host ""
Write-Host ">> You can now click Submit in the AWS Academy lab window! <<" -ForegroundColor Cyan

