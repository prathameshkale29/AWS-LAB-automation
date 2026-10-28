# ============================================================================
# cleanup3.ps1 - Clean up Lab 3 resources
# ============================================================================
$ErrorActionPreference = "Stop"
$region = "us-east-1"

function Test-AwsResult {
    param([string]$r)
    return (-not [string]::IsNullOrWhiteSpace($r)) -and ($r -ne "None") -and ($r -ne "null")
}

Write-Host "`n=== CLEANUP: Lab 3 Resources ===" -ForegroundColor Red

# 1. Disable termination protection and terminate instance
$instanceId = aws ec2 describe-instances --filters "Name=tag:Name,Values=Web Server" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query "Reservations[0].Instances[0].InstanceId" --output text --region $region 2>$null
if (Test-AwsResult $instanceId) {
    Write-Host "Disabling termination protection for $instanceId..."
    aws ec2 modify-instance-attribute --instance-id $instanceId --disable-api-termination "{\"Value\": false}" --region $region 2>$null
    aws ec2 modify-instance-attribute --instance-id $instanceId --disable-api-stop "{\"Value\": false}" --region $region 2>$null

    Write-Host "Terminating instance $instanceId..."
    aws ec2 terminate-instances --instance-ids $instanceId --region $region | Out-Null
    Write-Host "Waiting for termination..."
    aws ec2 wait instance-terminated --instance-ids $instanceId --region $region
    Write-Host "DONE: Instance terminated" -ForegroundColor Green
} else {
    Write-Host "No instance named 'Web Server' found."
}

# 2. Delete Security Group
$sgId = aws ec2 describe-security-groups --filters "Name=group-name,Values=Web Server security group" --query "SecurityGroups[0].GroupId" --output text --region $region 2>$null
if (Test-AwsResult $sgId) {
    Write-Host "Deleting security group $sgId..."
    aws ec2 delete-security-group --group-id $sgId --region $region
    Write-Host "DONE: Security group deleted" -ForegroundColor Green
} else {
    Write-Host "No security group named 'Web Server security group' found."
}

Write-Host "`n=== CLEANUP 3 COMPLETE ===" -ForegroundColor Green

