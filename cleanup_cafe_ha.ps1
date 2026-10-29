# cleanup_cafe_ha.ps1 - Tear down resources created for Scalable & HA Cafe Lab
$ErrorActionPreference = "Continue"

$region = $env:AWS_DEFAULT_REGION
if (-not $region) { $region = "us-east-1" }

Write-Host "Cleaning up Café Scalable & Highly Available resources in $region..." -ForegroundColor Yellow

# Delete Auto Scaling Group
Write-Host "Deleting Auto Scaling Group Cafe-ASG..."
aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "Cafe-ASG" --force-delete --region $region

# Delete Launch Template
Write-Host "Deleting Launch Template Cafe-LT..."
aws ec2 delete-launch-template --launch-template-name "Cafe-LT" --region $region

# Delete ALB
$albArn = (aws elbv2 describe-load-balancers --region $region --query "LoadBalancers[?LoadBalancerName=='Cafe-ALB'].LoadBalancerArn | [0]" --output text 2>$null)
if ($albArn -and $albArn -ne "None") {
    Write-Host "Deleting ALB Cafe-ALB..."
    aws elbv2 delete-load-balancer --load-balancer-arn $albArn --region $region
    Start-Sleep -Seconds 10
}

# Delete Target Group
$tgArn = (aws elbv2 describe-target-groups --region $region --query "TargetGroups[?TargetGroupName=='Cafe-TG'].TargetGroupArn | [0]" --output text 2>$null)
if ($tgArn -and $tgArn -ne "None") {
    Write-Host "Deleting Target Group Cafe-TG..."
    aws elbv2 delete-target-group --target-group-arn $tgArn --region $region
}

# Delete Security Group Cafe-ALB-SG
Start-Sleep -Seconds 15
$albSg = (aws ec2 describe-security-groups --filters "Name=group-name,Values=Cafe-ALB-SG" --region $region --query "SecurityGroups[0].GroupId" --output text 2>$null)
if ($albSg -and $albSg -ne "None") {
    Write-Host "Deleting Security Group Cafe-ALB-SG..."
    aws ec2 delete-security-group --group-id $albSg --region $region
}

# Delete NAT Gateway 2
$nat2 = (aws ec2 describe-nat-gateways --filter "Name=tag:Name,Values=Cafe-NatGateway2" "Name=state,Values=available,pending" --region $region --query "NatGateways[0].NatGatewayId" --output text 2>$null)
if ($nat2 -and $nat2 -ne "None") {
    Write-Host "Deleting NAT Gateway 2..."
    aws ec2 delete-nat-gateway --nat-gateway-id $nat2 --region $region
}

# Delete Route Table
$rt2 = (aws ec2 describe-route-tables --filters "Name=tag:Name,Values='Private Route Table 2'" --region $region --query "RouteTables[0].RouteTableId" --output text 2>$null)
if ($rt2 -and $rt2 -ne "None") {
    Write-Host "Deleting Private Route Table 2..."
    aws ec2 delete-route-table --route-table-id $rt2 --region $region
}

Write-Host "Cleanup completed." -ForegroundColor Green
