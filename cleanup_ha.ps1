# cleanup_ha.ps1 - Tear down resources created for Highly Available Environment Lab
$ErrorActionPreference = "Continue"

$region = $env:AWS_DEFAULT_REGION
if (-not $region) { $region = "us-east-1" }

Write-Host "Cleaning up Highly Available Environment resources in $region..." -ForegroundColor Yellow

# Delete Auto Scaling Group
Write-Host "Deleting Auto Scaling Group Inventory-ASG..."
aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "Inventory-ASG" --force-delete --region $region

# Delete Launch Template
Write-Host "Deleting Launch Template Inventory-LT..."
aws ec2 delete-launch-template --launch-template-name "Inventory-LT" --region $region

# Delete Listener & ALB
$albArn = (aws elbv2 describe-load-balancers --names "Inventory-LB" --region $region --query "LoadBalancers[0].LoadBalancerArn" --output text 2>$null)
if ($albArn -and $albArn -ne "None") {
    Write-Host "Deleting ALB Inventory-LB..."
    aws elbv2 delete-load-balancer --load-balancer-arn $albArn --region $region
    Start-Sleep -Seconds 10
}

# Delete Target Group
$tgArn = (aws elbv2 describe-target-groups --names "Inventory-App" --region $region --query "TargetGroups[0].TargetGroupArn" --output text 2>$null)
if ($tgArn -and $tgArn -ne "None") {
    Write-Host "Deleting Target Group Inventory-App..."
    aws elbv2 delete-target-group --target-group-arn $tgArn --region $region
}

# Delete Security Group Inventory-LB
Start-Sleep -Seconds 15
$lbSg = (aws ec2 describe-security-groups --filters "Name=group-name,Values=Inventory-LB" --region $region --query "SecurityGroups[0].GroupId" --output text 2>$null)
if ($lbSg -and $lbSg -ne "None") {
    Write-Host "Deleting Security Group Inventory-LB..."
    aws ec2 delete-security-group --group-id $lbSg --region $region
}

# Delete NatGateway2 & EIP
$nat2 = (aws ec2 describe-nat-gateways --filter "Name=tag:Name,Values=NatGateway2" "Name=state,Values=available,pending" --region $region --query "NatGateways[0].NatGatewayId" --output text 2>$null)
if ($nat2 -and $nat2 -ne "None") {
    Write-Host "Deleting NatGateway2..."
    aws ec2 delete-nat-gateway --nat-gateway-id $nat2 --region $region
}

# Delete Route Table Private Route Table 2
$rt2 = (aws ec2 describe-route-tables --filters "Name=tag:Name,Values='Private Route Table 2'" --region $region --query "RouteTables[0].RouteTableId" --output text 2>$null)
if ($rt2 -and $rt2 -ne "None") {
    Write-Host "Deleting Private Route Table 2..."
    aws ec2 delete-route-table --route-table-id $rt2 --region $region
}

# Deregister AMI
$amiId = (aws ec2 describe-images --filters "Name=name,Values='Web Server AMI'" --owners self --region $region --query "Images[0].ImageId" --output text 2>$null)
if ($amiId -and $amiId -ne "None") {
    Write-Host "Deregistering AMI $amiId..."
    aws ec2 deregister-image --image-id $amiId --region $region
}

Write-Host "Cleanup completed." -ForegroundColor Green
