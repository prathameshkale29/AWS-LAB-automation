# cleanup_rds.ps1 - Automated Cleanup for Guided Lab: Creating an Amazon RDS Database
$ErrorActionPreference = "Continue"

# Credentials

$env:AWS_DEFAULT_REGION = 'us-east-1'

Write-Host "=========================================================="
Write-Host "Starting RDS Database Cleanup"
Write-Host "=========================================================="

Write-Host "Deleting RDS DB Instance 'inventory-db'..."
aws rds delete-db-instance --db-instance-identifier "inventory-db" --skip-final-snapshot --delete-automated-backups --region us-east-1 2>$null | Out-Null
Write-Host "Waiting for DB instance to be deleted..."
aws rds wait db-instance-deleted --db-instance-identifier "inventory-db" --region us-east-1 2>$null

Write-Host "`nCleanup Complete!"

