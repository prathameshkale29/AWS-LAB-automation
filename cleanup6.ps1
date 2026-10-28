# ============================================================================
# cleanup6.ps1 - Clean up Lab 6 resources
# ============================================================================
$ErrorActionPreference = "Stop"
$region = "us-east-1"

function Test-AwsResult {
    param([string]$r)
    return (-not [string]::IsNullOrWhiteSpace($r)) -and ($r -ne "None") -and ($r -ne "null")
}

Write-Host "`n=== CLEANUP: Lab 6 Resources ===" -ForegroundColor Red

# 1. Delete Auto Scaling Group
$asg = aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "Lab Auto Scaling Group" --query "AutoScalingGroups[0].AutoScalingGroupName" --output text --region $region 2>$null
if (Test-AwsResult $asg) {
    Write-Host "Setting ASG capacities to 0..."
    aws autoscaling update-auto-scaling-group --auto-scaling-group-name "Lab Auto Scaling Group" --min-size 0 --max-size 0 --desired-capacity 0 --region $region
    Write-Host "Deleting Auto Scaling Group..."
    aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "Lab Auto Scaling Group" --force-delete --region $region
    Write-Host "DONE: ASG deleted" -ForegroundColor Green
}

# 2. Delete Load Balancer & Target Group
$albArn = aws elbv2 describe-load-balancers --names "LabELB" --query "LoadBalancers[0].LoadBalancerArn" --output text --region $region 2>$null
if (Test-AwsResult $albArn) {
    Write-Host "Deleting Load Balancer LabELB..."
    aws elbv2 delete-load-balancer --load-balancer-arn $albArn --region $region
    Start-Sleep -Seconds 10
}

$tgArn = aws elbv2 describe-target-groups --names "LabGroup" --query "TargetGroups[0].TargetGroupArn" --output text --region $region 2>$null
if (Test-AwsResult $tgArn) {
    Write-Host "Deleting Target Group LabGroup..."
    aws elbv2 delete-target-group --target-group-arn $tgArn --region $region
    Write-Host "DONE: Target group deleted" -ForegroundColor Green
}

# 3. Delete Launch Template
$ltId = aws ec2 describe-launch-templates --launch-template-names "LabConfig" --query "LaunchTemplates[0].LaunchTemplateId" --output text --region $region 2>$null
if (Test-AwsResult $ltId) {
    Write-Host "Deleting Launch Template LabConfig..."
    aws ec2 delete-launch-template --launch-template-name "LabConfig" --region $region | Out-Null
    Write-Host "DONE: Launch template deleted" -ForegroundColor Green
}

# 4. Deregister AMI
$amiId = aws ec2 describe-images --owners self --filters "Name=name,Values=WebServerAMI" --query "Images[0].ImageId" --output text --region $region 2>$null
if (Test-AwsResult $amiId) {
    Write-Host "Deregistering AMI $amiId..."
    aws ec2 deregister-image --image-id $amiId --region $region
    Write-Host "DONE: AMI deregistered" -ForegroundColor Green
}

Write-Host "`n=== CLEANUP 6 COMPLETE ===" -ForegroundColor Green

