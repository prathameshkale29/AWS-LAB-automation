# ============================================================================
# cleanup5.ps1 - Clean up Lab 5 created RDS resources
# ============================================================================
$ErrorActionPreference = "Stop"
$region = "us-east-1"

function Test-AwsResult {
    param([string]$r)
    return (-not [string]::IsNullOrWhiteSpace($r)) -and ($r -ne "None") -and ($r -ne "null")
}

Write-Host "`n=== CLEANUP: Lab 5 Resources ===" -ForegroundColor Red

# 1. Delete RDS Database instance
$db = aws rds describe-db-instances --db-instance-identifier "lab-db" --query "DBInstances[0].DBInstanceIdentifier" --output text --region $region 2>$null
if (Test-AwsResult $db) {
    Write-Host "Deleting RDS instance lab-db (skip final snapshot)..."
    aws rds delete-db-instance --db-instance-identifier "lab-db" --skip-final-snapshot --delete-automated-backups --region $region | Out-Null
    Write-Host "Waiting for database deletion (~3-5 min)..."
    aws rds wait db-instance-deleted --db-instance-identifier "lab-db" --region $region
    Write-Host "DONE: Deleted lab-db" -ForegroundColor Green
}

# 2. Delete DB Subnet Group
$sng = aws rds describe-db-subnet-groups --db-subnet-group-name "db-subnet-group" --query "DBSubnetGroups[0].DBSubnetGroupName" --output text --region $region 2>$null
if (Test-AwsResult $sng) {
    Write-Host "Deleting DB Subnet Group db-subnet-group..."
    aws rds delete-db-subnet-group --db-subnet-group-name "db-subnet-group" --region $region
    Write-Host "DONE: Deleted db-subnet-group" -ForegroundColor Green
}

# 3. Delete DB Security Group
$sgId = aws ec2 describe-security-groups --filters "Name=group-name,Values=DB Security Group" --query "SecurityGroups[0].GroupId" --output text --region $region 2>$null
if (Test-AwsResult $sgId) {
    Write-Host "Deleting DB Security Group $sgId..."
    aws ec2 delete-security-group --group-id $sgId --region $region
    Write-Host "DONE: Deleted DB Security Group" -ForegroundColor Green
}

Write-Host "`n=== CLEANUP 5 COMPLETE ===" -ForegroundColor Green

