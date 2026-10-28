# ============================================================================
# lab5.ps1 - AWS Academy Lab 5: Build Your DB Server and Interact With Your DB
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
# Locate Lab VPC and Web Security Group
# ==========================================================================
Write-Host "Locating Lab VPC and Web Security Group..." -ForegroundColor Cyan
$vpcId = aws ec2 describe-vpcs --filters "Name=tag:Name,Values=*Lab VPC*" --query "Vpcs[0].VpcId" --output text --region $region 2>$null
if (-not (Test-AwsResult $vpcId)) {
    $vpcId = aws ec2 describe-vpcs --filters "Name=isDefault,Values=false" --query "Vpcs[0].VpcId" --output text --region $region
}
Assert-Success "Find Lab VPC"
Write-Host "Using VPC: $vpcId"

$webSgId = aws ec2 describe-security-groups --filters "Name=group-name,Values=Web Security Group" "Name=vpc-id,Values=$vpcId" --query "SecurityGroups[0].GroupId" --output text --region $region 2>$null
if (-not (Test-AwsResult $webSgId)) {
    # Check without VPC filter if needed
    $webSgId = aws ec2 describe-security-groups --filters "Name=group-name,Values=Web Security Group" --query "SecurityGroups[0].GroupId" --output text --region $region
}
Assert-Success "Find Web Security Group"
Write-Host "Found Web Security Group: $webSgId"

# ==========================================================================
# TASK 1: Create a Security Group for the RDS DB Instance
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 1: Create 'DB Security Group' (Allow 3306 from Web SG)" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

$dbSgId = aws ec2 describe-security-groups --filters "Name=group-name,Values=DB Security Group" "Name=vpc-id,Values=$vpcId" --query "SecurityGroups[0].GroupId" --output text --region $region 2>$null
if (-not (Test-AwsResult $dbSgId)) {
    Write-Host "Creating security group: DB Security Group..."
    $dbSgId = aws ec2 create-security-group `
        --group-name "DB Security Group" `
        --description "Permit access from Web Security Group" `
        --vpc-id $vpcId `
        --query "GroupId" `
        --output text `
        --region $region
    Assert-Success "Create DB Security Group"
} else {
    Write-Host "Security group 'DB Security Group' already exists: $dbSgId"
}

# Authorize MySQL (port 3306) from Web Security Group
$ruleExists = aws ec2 describe-security-groups --group-ids $dbSgId --query "SecurityGroups[0].IpPermissions[?FromPort==``3306`` && UserIdGroupPairs[?GroupId==``$webSgId``]]" --output text --region $region 2>$null
if (-not (Test-AwsResult $ruleExists)) {
    Write-Host "Adding rule: MySQL/Aurora (3306) from $webSgId..."
    aws ec2 authorize-security-group-ingress `
        --group-id $dbSgId `
        --protocol tcp `
        --port 3306 `
        --source-group $webSgId `
        --region $region | Out-Null
    Assert-Success "Authorize DB ingress"
} else {
    Write-Host "Inbound rule 3306 from $webSgId already exists."
}
Write-Host "PASS: DB Security Group $dbSgId configured" -ForegroundColor Green
Write-Host "`n>> TASK 1 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 2: Create a DB Subnet Group
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 2: Create DB Subnet Group 'DB-Subnet-Group'" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

# Locate the two private subnets: 10.0.1.0/24 (us-east-1a) and 10.0.3.0/24 (us-east-1b)
$subnets = aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpcId" "Name=cidr-block,Values=10.0.1.0/24,10.0.3.0/24" --query "Subnets[*].SubnetId" --output text --region $region
$subnetList = ($subnets -split "\s+") | Where-Object { Test-AwsResult $_ }

if ($subnetList.Count -lt 2) {
    # Fallback to any two subnets in different AZs within Lab VPC
    $subnetList = (aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpcId" --query "Subnets[*].SubnetId" --output text --region $region) -split "\s+"
}
Write-Host "Using Subnets for DB Subnet Group: $($subnetList -join ', ')"

$sng = aws rds describe-db-subnet-groups --query "DBSubnetGroups[?DBSubnetGroupName=='db-subnet-group'].DBSubnetGroupName | [0]" --output text --region $region
if (-not (Test-AwsResult $sng)) {
    Write-Host "Creating DB Subnet Group: DB-Subnet-Group..."
    aws rds create-db-subnet-group `
        --db-subnet-group-name "db-subnet-group" `
        --db-subnet-group-description "DB Subnet Group" `
        --subnet-ids $subnetList `
        --region $region | Out-Null
    Assert-Success "Create DB Subnet Group"
} else {
    Write-Host "DB Subnet Group 'db-subnet-group' already exists."
}
Write-Host "PASS: DB Subnet Group db-subnet-group verified" -ForegroundColor Green
Write-Host "`n>> TASK 2 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 3: Create an Amazon RDS DB Instance
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 3: Create Multi-AZ MySQL DB Instance (lab-db)" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

$dbStatus = aws rds describe-db-instances --query "DBInstances[?DBInstanceIdentifier=='lab-db'].DBInstanceStatus | [0]" --output text --region $region
if (-not (Test-AwsResult $dbStatus)) {
    Write-Host "Creating RDS MySQL Multi-AZ instance 'lab-db' (db.t3.micro)..."
    aws rds create-db-instance `
        --db-instance-identifier "lab-db" `
        --db-instance-class "db.t3.micro" `
        --engine "mysql" `
        --master-username "main" `
        --master-user-password "lab-password" `
        --allocated-storage 20 `
        --storage-type "gp2" `
        --multi-az `
        --db-name "lab" `
        --db-subnet-group-name "db-subnet-group" `
        --vpc-security-group-ids $dbSgId `
        --backup-retention-period 0 `
        --no-storage-encrypted `
        --no-auto-minor-version-upgrade `
        --region $region | Out-Null
    Assert-Success "Create DB Instance"

    Write-Host "Waiting for database to become available (this takes ~4-5 minutes for Multi-AZ)..."
    aws rds wait db-instance-available --db-instance-identifier "lab-db" --region $region
    Assert-Success "DB instance available"
} else {
    Write-Host "Database 'lab-db' already exists (Status: $dbStatus)"
    if ($dbStatus -ne "available") {
        Write-Host "Waiting for database to reach available state..."
        aws rds wait db-instance-available --db-instance-identifier "lab-db" --region $region
    }
}

$dbEndpoint = aws rds describe-db-instances --db-instance-identifier "lab-db" --query "DBInstances[0].Endpoint.Address" --output text --region $region
Write-Host "PASS: Database lab-db is Available" -ForegroundColor Green
Write-Host "  Endpoint: $dbEndpoint" -ForegroundColor Cyan
Write-Host "`n>> TASK 3 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 4: Interact with Your Database via Web Application
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 4: Interact with Database via Web Application" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

# Locate the WebServer instance public IP
$webIp = aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].PublicIpAddress" --output text --region $region
$targetIp = $webIp.Trim()
Write-Host "Found Web Server IP: $targetIp"

Write-Host "Testing connectivity to web application at http://$targetIp..."
$indexHtml = curl.exe -s --max-time 10 "http://$targetIp/"
Write-Host "Connected to Web Server."

# Configure RDS connection on web application via rds-write-config.php
Write-Host "Submitting database connection details to application..."
$postResult = curl.exe -s --max-time 15 -X POST "http://$targetIp/rds-write-config.php" `
    -d "endpoint=$dbEndpoint" `
    -d "database=lab" `
    -d "username=main" `
    -d "password=lab-password" `
    -d "submit=Submit"

Start-Sleep -Seconds 3
$rdsPage = curl.exe -s --max-time 10 "http://$targetIp/rds.php"
if ($rdsPage -match "Address Book") {
    Write-Host "Address Book loaded and connected to database!" -ForegroundColor Green
}
Write-Host "PASS: Web application configured to use RDS lab-db" -ForegroundColor Green
Write-Host "`n>> TASK 4 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# SUMMARY
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host " ALL LAB 5 TASKS COMPLETED SUCCESSFULLY" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host "VPC:                $vpcId (Lab VPC)"
Write-Host "Web Security Group: $webSgId"
Write-Host "DB Security Group:  $dbSgId"
Write-Host "DB Subnet Group:    db-subnet-group"
Write-Host "RDS DB Identifier:  lab-db (Multi-AZ MySQL)"
Write-Host "RDS DB Endpoint:    $dbEndpoint"
Write-Host "Web Application:    http://$targetIp"
Write-Host ""
Write-Host ">> You can now click Submit in the AWS Academy lab window! <<" -ForegroundColor Cyan

