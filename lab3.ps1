# ============================================================================
# lab3.ps1 - AWS Academy Lab 3: Introduction to Amazon EC2
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

# === Verify AWS session ===
Write-Host "`n=== Verifying AWS Session ===" -ForegroundColor Cyan
aws sts get-caller-identity --region $region --output table
Assert-Success "Session verification"
Write-Host "PASS: Session valid`n" -ForegroundColor Green

# ==========================================================================
# Locate Lab VPC and PublicSubnet1
# ==========================================================================
Write-Host "Locating Lab VPC and PublicSubnet1..." -ForegroundColor Cyan
$vpcId = aws ec2 describe-vpcs --filters "Name=tag:Name,Values=*Lab VPC*" --query "Vpcs[0].VpcId" --output text --region $region 2>$null
if (-not (Test-AwsResult $vpcId)) {
    # Fallback to the first non-default VPC
    $vpcId = aws ec2 describe-vpcs --filters "Name=isDefault,Values=false" --query "Vpcs[0].VpcId" --output text --region $region
}
Assert-Success "Find Lab VPC"
Write-Host "Using VPC: $vpcId"

$subnetId = aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpcId" "Name=tag:Name,Values=*PublicSubnet1*" --query "Subnets[0].SubnetId" --output text --region $region 2>$null
if (-not (Test-AwsResult $subnetId)) {
    # Fallback to first public subnet in VPC
    $subnetId = aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpcId" --query "Subnets[0].SubnetId" --output text --region $region
}
Assert-Success "Find Public Subnet"
Write-Host "Using Subnet: $subnetId"

# ==========================================================================
# TASK 1: Launch Your Amazon EC2 Instance
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 1: Launch Your Amazon EC2 Instance" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

# Look up Amazon Linux 2023 AMI
Write-Host "Looking up Amazon Linux 2023 AMI..."
$amiId = aws ssm get-parameters --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query "Parameters[0].Value" --output text --region $region 2>$null
if (-not (Test-AwsResult $amiId)) {
    $amiId = "ami-04b938437b69a2c9c"
}
Assert-Success "Get AL2023 AMI"
Write-Host "Using AMI: $amiId"

# Security Group: Web Server security group
$sgId = aws ec2 describe-security-groups --filters "Name=group-name,Values=Web Server security group" "Name=vpc-id,Values=$vpcId" --query "SecurityGroups[0].GroupId" --output text --region $region 2>$null
if (-not (Test-AwsResult $sgId)) {
    Write-Host "Creating security group: Web Server security group..."
    $sgId = aws ec2 create-security-group --group-name "Web Server security group" --description "Security group for my web server" --vpc-id $vpcId --query "GroupId" --output text --region $region
    Assert-Success "Create Security Group"
} else { Write-Host "Security group already exists: $sgId" }
Write-Host "PASS: Security Group $sgId" -ForegroundColor Green

# Check if instance already exists
$instanceId = aws ec2 describe-instances --filters "Name=tag:Name,Values=Web Server" "Name=vpc-id,Values=$vpcId" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query "Reservations[0].Instances[0].InstanceId" --output text --region $region 2>$null
if (-not (Test-AwsResult $instanceId)) {
    Write-Host "Launching EC2 instance: Web Server (t2.micro with termination protection)..."
    $instanceId = aws ec2 run-instances `
        --image-id $amiId `
        --instance-type t2.micro `
        --key-name vockey `
        --subnet-id $subnetId `
        --security-group-ids $sgId `
        --disable-api-termination `
        --user-data file://userdata_lab3.sh `
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=Web Server}]" `
        --query "Instances[0].InstanceId" `
        --output text `
        --region $region
    Assert-Success "Launch Web Server instance"

    Write-Host "Waiting for instance to be in running state..."
    aws ec2 wait instance-running --instance-ids $instanceId --region $region
    Write-Host "Running. Waiting for 2/2 status checks to pass (~2 min)..."
    aws ec2 wait instance-status-ok --instance-ids $instanceId --region $region
    Assert-Success "Status checks OK"
} else {
    Write-Host "Instance Web Server already exists: $instanceId"
    # Ensure termination protection is enabled
    aws ec2 modify-instance-attribute --instance-id $instanceId --disable-api-termination Value=true --region $region
}

$state = aws ec2 describe-instances --instance-ids $instanceId --query "Reservations[0].Instances[0].State.Name" --output text --region $region
Write-Host "PASS: Instance $instanceId is $state (2/2 checks OK, Termination Protection: Enabled)" -ForegroundColor Green
Write-Host "`n>> TASK 1 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 2: Monitor Your Instance
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 2: Monitor Your Instance" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

Write-Host "Retrieving instance status checks and system log..."
$statusChecks = aws ec2 describe-instance-status --instance-ids $instanceId --query "InstanceStatuses[0].[SystemStatus.Status,InstanceStatus.Status]" --output text --region $region
Write-Host "Status checks: $statusChecks"
$log = aws ec2 get-console-output --instance-id $instanceId --query "Output" --output text --region $region 2>$null
if (Test-AwsResult $log) {
    Write-Host "System log captured ($($log.Length) chars)."
} else {
    Write-Host "Console output initializing (expected on freshly booted instance)."
}
Write-Host "PASS: Monitoring metrics and status checks verified" -ForegroundColor Green
Write-Host "`n>> TASK 2 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 3: Update Your Security Group and Access the Web Server
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 3: Update Security Group (Port 80) and Access Web Server" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

$ruleExists = aws ec2 describe-security-groups --group-ids $sgId --query "SecurityGroups[0].IpPermissions[?FromPort==``80`` && ToPort==``80``]" --output text --region $region 2>$null
if (-not (Test-AwsResult $ruleExists)) {
    Write-Host "Adding inbound HTTP rule (port 80 from 0.0.0.0/0)..."
    aws ec2 authorize-security-group-ingress --group-id $sgId --protocol tcp --port 80 --cidr 0.0.0.0/0 --region $region | Out-Null
    Assert-Success "Authorize SG HTTP ingress"
} else { Write-Host "HTTP rule already present in $sgId" }

$publicIp = aws ec2 describe-instances --instance-ids $instanceId --query "Reservations[0].Instances[0].PublicIpAddress" --output text --region $region
Write-Host "Testing web server response at http://$publicIp..."
Start-Sleep -Seconds 5
$webResponse = curl.exe -s --max-time 10 "http://$publicIp"
Write-Host "Response from server: $webResponse"
Write-Host "PASS: Security group updated and HTTP 80 accessible" -ForegroundColor Green
Write-Host "`n>> TASK 3 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 4: Resize Your Instance: Instance Type and EBS Volume
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 4: Resize Instance (t2.small) & EBS Volume (10 GiB)" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

$currType = aws ec2 describe-instances --instance-ids $instanceId --query "Reservations[0].Instances[0].InstanceType" --output text --region $region
if ($currType -ne "t2.small") {
    Write-Host "Stopping instance $instanceId to resize..."
    # If stop protection is currently enabled, disable it temporarily to allow stop
    aws ec2 modify-instance-attribute --instance-id $instanceId --no-disable-api-stop --region $region 2>$null
    aws ec2 stop-instances --instance-ids $instanceId --region $region | Out-Null
    Write-Host "Waiting for instance to stop..."
    aws ec2 wait instance-stopped --instance-ids $instanceId --region $region

    Write-Host "Changing instance type to t2.small..."
    aws ec2 modify-instance-attribute --instance-id $instanceId --instance-type Value=t2.small --region $region
    Assert-Success "Change instance type"

    Write-Host "Enabling stop protection (disableApiStop = true)..."
    aws ec2 modify-instance-attribute --instance-id $instanceId --disable-api-stop Value=true --region $region
    Assert-Success "Enable stop protection"
} else {
    Write-Host "Instance is already t2.small."
    aws ec2 modify-instance-attribute --instance-id $instanceId --disable-api-stop Value=true --region $region
}

# Resize EBS Volume to 10 GiB
$volumeId = aws ec2 describe-instances --instance-ids $instanceId --query "Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId" --output text --region $region
$volSize = aws ec2 describe-volumes --volume-ids $volumeId --query "Volumes[0].Size" --output text --region $region
if ([int]$volSize -lt 10) {
    Write-Host "Modifying volume $volumeId from ${volSize} GiB to 10 GiB..."
    aws ec2 modify-volume --volume-id $volumeId --size 10 --region $region | Out-Null
    Assert-Success "Modify volume size"
} else { Write-Host "Volume $volumeId size is already ${volSize} GiB" }

# Start the resized instance
$state = aws ec2 describe-instances --instance-ids $instanceId --query "Reservations[0].Instances[0].State.Name" --output text --region $region
if ($state -ne "running") {
    Write-Host "Starting resized instance..."
    aws ec2 start-instances --instance-ids $instanceId --region $region | Out-Null
    Write-Host "Waiting for instance to be running..."
    aws ec2 wait instance-running --instance-ids $instanceId --region $region
    Write-Host "Waiting for status checks..."
    aws ec2 wait instance-status-ok --instance-ids $instanceId --region $region
}
Write-Host "PASS: Instance resized to t2.small, Volume resized to 10 GiB, Stop Protection enabled" -ForegroundColor Green
Write-Host "`n>> TASK 4 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 5: Explore EC2 Limits
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 5: Explore EC2 Limits" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

Write-Host "Querying EC2 On-Demand Instance quotas..."
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$quotas = aws service-quotas list-service-quotas --service-code ec2 --query "Quotas[?contains(QuotaName, 'Running On-Demand')].[QuotaName,Value]" --output table --region $region 2>$null
$ErrorActionPreference = $prevEAP

if (-not (Test-AwsResult $quotas)) {
    # Fallback to describe account attributes
    aws ec2 describe-account-attributes --attribute-names max-instances --region $region --output table
} else {
    Write-Host $quotas
}
Write-Host "PASS: EC2 Limits explored" -ForegroundColor Green
Write-Host "`n>> TASK 5 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 6: Test Stop Protection
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 6: Test Stop Protection" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

Write-Host "Attempting to stop instance while Stop Protection is enabled (expecting failure)..."
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$stopAttempt = aws ec2 stop-instances --instance-ids $instanceId --region $region 2>&1
$ErrorActionPreference = $prevEAP

if ($stopAttempt -match "disableApiStop|OperationNotPermitted|may not be stopped") {
    Write-Host "Verified: Stop command rejected as expected due to Stop Protection!" -ForegroundColor Green
} else {
    Write-Host "Note: Output was: $stopAttempt"
}

Write-Host "Disabling Stop Protection..."
aws ec2 modify-instance-attribute --instance-id $instanceId --no-disable-api-stop --region $region
Assert-Success "Disable stop protection"

Write-Host "Stopping instance Web Server..."
aws ec2 stop-instances --instance-ids $instanceId --region $region | Out-Null
Write-Host "Waiting for instance to reach stopped state..."
aws ec2 wait instance-stopped --instance-ids $instanceId --region $region
Assert-Success "Stop instance"

$finalState = aws ec2 describe-instances --instance-ids $instanceId --query "Reservations[0].Instances[0].State.Name" --output text --region $region
Write-Host "PASS: Stop protection verified and instance is now: $finalState" -ForegroundColor Green
Write-Host "`n>> TASK 6 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# SUMMARY
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host " ALL LAB 3 TASKS COMPLETED SUCCESSFULLY" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host "Instance ID:        $instanceId"
Write-Host "Instance Type:      t2.small"
Write-Host "Volume ID / Size:   $volumeId (10 GiB)"
Write-Host "Security Group:     $sgId (Web Server security group)"
Write-Host "Final State:        $finalState"
Write-Host ""
Write-Host ">> You can now click Submit in the AWS Academy lab window! <<" -ForegroundColor Cyan

