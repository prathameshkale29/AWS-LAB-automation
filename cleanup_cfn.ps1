# cleanup_cfn.ps1 - Tear down all resources created for CloudFormation Lab
$ErrorActionPreference = "Continue"

$region = $env:AWS_DEFAULT_REGION
if (-not $region) { $region = "us-east-1" }

Write-Host "Cleaning up CloudFormation Lab resources in $region..." -ForegroundColor Yellow

# Delete lab-application if still present
$app = aws cloudformation describe-stacks --stack-name "lab-application" --region $region 2>$null
if ($app) {
    Write-Host "Deleting stack lab-application..."
    aws cloudformation delete-stack --stack-name "lab-application" --region $region
    aws cloudformation wait stack-delete-complete --stack-name "lab-application" --region $region
}

# Delete lab-network
$net = aws cloudformation describe-stacks --stack-name "lab-network" --region $region 2>$null
if ($net) {
    Write-Host "Deleting stack lab-network..."
    aws cloudformation delete-stack --stack-name "lab-network" --region $region
    aws cloudformation wait stack-delete-complete --stack-name "lab-network" --region $region
}

# Delete Snapshot Web Data
$snapId = (aws ec2 describe-snapshots --owner-ids self --region $region --filters "Name=tag:Name,Values='Web Data'" --query "Snapshots[0].SnapshotId" --output text 2>$null)
if ($snapId -and $snapId -ne "None") {
    Write-Host "Deleting Snapshot $snapId..."
    aws ec2 delete-snapshot --snapshot-id $snapId --region $region
}

Write-Host "Cleanup completed." -ForegroundColor Green
