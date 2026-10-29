# cafe_ha_lab.ps1 - Automated Deployment for Challenge Lab: Creating a Scalable and Highly Available Environment for the Café
$ErrorActionPreference = "Continue"

Write-Host "========================================================================" -ForegroundColor Cyan
Write-Host " Deploying Scalable and Highly Available Café Architecture " -ForegroundColor Cyan
Write-Host "========================================================================" -ForegroundColor Cyan

$region = "us-east-1"
$env:AWS_DEFAULT_REGION = $region

# 1. Discover Resources
Write-Host "`n[Task 1] Discovering Lab Resources..." -ForegroundColor Yellow
$vpcs = aws ec2 describe-vpcs --region $region | ConvertFrom-Json
$labVpc = ($vpcs.Vpcs | Where-Object { $_.IsDefault -eq $false }).VpcId
Write-Host "  Lab VPC ID: $labVpc"

$subnetsJson = aws ec2 describe-subnets --filters "Name=vpc-id,Values=$labVpc" --region $region | ConvertFrom-Json
$pubSubnet1 = ($subnetsJson.Subnets | Where-Object { $_.CidrBlock -eq "10.0.0.0/24" }).SubnetId
$pubSubnet2 = ($subnetsJson.Subnets | Where-Object { $_.CidrBlock -eq "10.0.1.0/24" }).SubnetId
$privSubnet1 = ($subnetsJson.Subnets | Where-Object { $_.CidrBlock -eq "10.0.2.0/24" }).SubnetId
$privSubnet2 = ($subnetsJson.Subnets | Where-Object { $_.CidrBlock -eq "10.0.3.0/24" }).SubnetId

Write-Host "  Public Subnet 1:  $pubSubnet1"
Write-Host "  Public Subnet 2:  $pubSubnet2"
Write-Host "  Private Subnet 1: $privSubnet1"
Write-Host "  Private Subnet 2: $privSubnet2"

# Security Groups
$sgList = aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$labVpc" --region $region | ConvertFrom-Json
$cafeSg = ($sgList.SecurityGroups | Where-Object { ($_.GroupName -like "*CafeSG*") -or ($_.Tags.Value -contains "CafeSG") }).GroupId | Select-Object -First 1
Write-Host "  CafeSG: $cafeSg"

# AMI ID
$amiId = (aws ec2 describe-images --owners self --region $region --query "Images[?Name=='Cafe WebServer Image'].ImageId | [0]" --output text)
Write-Host "  AMI ID: $amiId"

# 2. Task 2: Create NAT Gateway in Public Subnet 2 and update Route Table
Write-Host "`n[Task 2] Setting up NAT Gateway in AZ 2 and route table..." -ForegroundColor Yellow
$existingNat2 = (aws ec2 describe-nat-gateways --filter "Name=subnet-id,Values=$pubSubnet2" "Name=state,Values=available,pending" --region $region --query "NatGateways[0].NatGatewayId" --output text 2>$null)
if (-not $existingNat2 -or $existingNat2 -eq "None") {
    Write-Host "  Allocating Elastic IP..."
    $eip = (aws ec2 allocate-address --domain vpc --region $region | ConvertFrom-Json).AllocationId

    Write-Host "  Creating NAT Gateway 2 in Public Subnet 2 ($pubSubnet2)..."
    $natJson = (aws ec2 create-nat-gateway `
        --subnet-id $pubSubnet2 `
        --allocation-id $eip `
        --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=Cafe-NatGateway2}]" `
        --region $region | ConvertFrom-Json)
    $nat2Id = $natJson.NatGateway.NatGatewayId
    Write-Host "  Created NAT Gateway 2: $nat2Id. Waiting for available status..."
    aws ec2 wait nat-gateway-available --nat-gateway-ids $nat2Id --region $region
    Write-Host "  NAT Gateway 2 is available!" -ForegroundColor Green
} else {
    $nat2Id = $existingNat2
    Write-Host "  NAT Gateway 2 already exists: $nat2Id"
}

# Update route in Private Route Table 2
$rt2Id = (aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$privSubnet2" --region $region --query "RouteTables[0].RouteTableId" --output text)
Write-Host "  Private Subnet 2 Route Table ID: $rt2Id"

$hasRoute = (aws ec2 describe-route-tables --route-table-ids $rt2Id --region $region --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].State | [0]" --output text 2>$null)
if (-not $hasRoute -or $hasRoute -eq "None") {
    Write-Host "  Adding 0.0.0.0/0 route to NAT Gateway 2..."
    aws ec2 create-route --route-table-id $rt2Id --destination-cidr-block "0.0.0.0/0" --nat-gateway-id $nat2Id --region $region | Out-Null
    Write-Host "  Route added successfully!" -ForegroundColor Green
} else {
    Write-Host "  Route already exists in route table."
}

# 3. Task 3: Key Pair & Launch Template
Write-Host "`n[Task 3] Creating Key Pair and Launch Template..." -ForegroundColor Yellow
$keyCheck = (aws ec2 describe-key-pairs --region $region --query "KeyPairs[?KeyName=='CafeKey'].KeyName | [0]" --output text 2>$null)
if (-not $keyCheck -or $keyCheck -eq "None") {
    Write-Host "  Creating key pair CafeKey..."
    aws ec2 create-key-pair --key-name "CafeKey" --region $region | Out-Null
}

$ltData = @{
    ImageId = $amiId
    InstanceType = "t2.micro"
    KeyName = "CafeKey"
    SecurityGroupIds = @($cafeSg)
    IamInstanceProfile = @{ Name = "CafeRole" }
    TagSpecifications = @(
        @{
            ResourceType = "instance"
            Tags = @(
                @{ Key = "Name"; Value = "webserver" }
            )
        }
    )
}
$ltDataJson = $ltData | ConvertTo-Json -Depth 5 -Compress
$ltDataPath = Join-Path $PSScriptRoot "lt_cafe.json"
Set-Content -Path $ltDataPath -Value $ltDataJson

$ltId = (aws ec2 describe-launch-templates --region $region --query "LaunchTemplates[?LaunchTemplateName=='Cafe-LT'].LaunchTemplateId | [0]" --output text 2>$null)
if (-not $ltId -or $ltId -eq "None") {
    Write-Host "  Creating Launch Template: Cafe-LT..."
    $ltId = (aws ec2 create-launch-template `
        --launch-template-name "Cafe-LT" `
        --version-description "v1" `
        --launch-template-data file://$ltDataPath `
        --region $region `
        --query "LaunchTemplate.LaunchTemplateId" --output text)
    Write-Host "  Created Launch Template: $ltId" -ForegroundColor Green
} else {
    Write-Host "  Launch Template Cafe-LT already exists: $ltId"
}
Remove-Item $ltDataPath -Force -ErrorAction SilentlyContinue

# 4. Task 5: Load Balancer & Target Group
Write-Host "`n[Task 5] Creating Application Load Balancer..." -ForegroundColor Yellow
$albSg = (aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$labVpc" "Name=group-name,Values=Cafe-ALB-SG" --region $region --query "SecurityGroups[0].GroupId" --output text 2>$null)
if (-not $albSg -or $albSg -eq "None") {
    Write-Host "  Creating Security Group Cafe-ALB-SG..."
    $albSg = (aws ec2 create-security-group `
        --group-name "Cafe-ALB-SG" `
        --description "Allow HTTP traffic from anywhere" `
        --vpc-id $labVpc `
        --region $region `
        --query "GroupId" --output text)
    
    aws ec2 authorize-security-group-ingress `
        --group-id $albSg `
        --protocol tcp --port 80 --cidr 0.0.0.0/0 `
        --region $region | Out-Null
    Write-Host "  Created Cafe-ALB-SG: $albSg"
}

# Allow HTTP from anywhere on CafeSG
aws ec2 authorize-security-group-ingress `
    --group-id $cafeSg `
    --protocol tcp --port 80 --cidr 0.0.0.0/0 `
    --region $region 2>$null | Out-Null

$tgArn = (aws elbv2 describe-target-groups --region $region --query "TargetGroups[?TargetGroupName=='Cafe-TG'].TargetGroupArn | [0]" --output text 2>$null)
if (-not $tgArn -or $tgArn -eq "None") {
    Write-Host "  Creating Target Group Cafe-TG..."
    $tgArn = (aws elbv2 create-target-group `
        --name "Cafe-TG" `
        --protocol HTTP `
        --port 80 `
        --target-type instance `
        --vpc-id $labVpc `
        --health-check-path "/" `
        --healthy-threshold-count 2 `
        --health-check-interval-seconds 15 `
        --region $region `
        --query "TargetGroups[0].TargetGroupArn" --output text)
    Write-Host "  Created Target Group: $tgArn"
}

$albArn = (aws elbv2 describe-load-balancers --region $region --query "LoadBalancers[?LoadBalancerName=='Cafe-ALB'].LoadBalancerArn | [0]" --output text 2>$null)
if (-not $albArn -or $albArn -eq "None") {
    Write-Host "  Creating Application Load Balancer Cafe-ALB..."
    $albJson = (aws elbv2 create-load-balancer `
        --name "Cafe-ALB" `
        --subnets $pubSubnet1 $pubSubnet2 `
        --security-groups $albSg `
        --scheme internet-facing `
        --type application `
        --region $region | ConvertFrom-Json)
    $albArn = $albJson.LoadBalancers[0].LoadBalancerArn
    $albDns = $albJson.LoadBalancers[0].DNSName
    Write-Host "  Created ALB: $albDns"

    Write-Host "  Creating ALB Listener on Port 80..."
    aws elbv2 create-listener `
        --load-balancer-arn $albArn `
        --protocol HTTP `
        --port 80 `
        --default-actions Type=forward,TargetGroupArn=$tgArn `
        --region $region | Out-Null
} else {
    $albDns = (aws elbv2 describe-load-balancers --load-balancer-arns $albArn --region $region --query "LoadBalancers[0].DNSName" --output text)
    Write-Host "  ALB already exists: $albDns"
}

# 5. Task 4: Auto Scaling Group with Target Tracking Policy
Write-Host "`n[Task 4] Creating Auto Scaling Group: Cafe-ASG..." -ForegroundColor Yellow
$asgCheck = (aws autoscaling describe-auto-scaling-groups --region $region --query "AutoScalingGroups[?AutoScalingGroupName=='Cafe-ASG'].AutoScalingGroupName | [0]" --output text 2>$null)
if (-not $asgCheck -or $asgCheck -eq "None") {
    Write-Host "  Creating Auto Scaling Group Cafe-ASG with Desired=2, Min=2, Max=6..."
    aws autoscaling create-auto-scaling-group `
        --auto-scaling-group-name "Cafe-ASG" `
        --launch-template "LaunchTemplateName=Cafe-LT,Version=`$Latest" `
        --min-size 2 `
        --max-size 6 `
        --desired-capacity 2 `
        --vpc-zone-identifier "$privSubnet1,$privSubnet2" `
        --target-group-arns $tgArn `
        --health-check-type "ELB" `
        --health-check-grace-period 90 `
        --region $region

    Write-Host "  Attaching Target Tracking CPU Scaling Policy (25%)..."
    aws autoscaling put-scaling-policy `
        --auto-scaling-group-name "Cafe-ASG" `
        --policy-name "Cafe-CPU-Scaling-Policy" `
        --policy-type "TargetTrackingScaling" `
        --target-tracking-configuration "{\`"PredefinedMetricSpecification\`":{\`"PredefinedMetricType\`":\`"ASGAverageCPUUtilization\`"}, \`"TargetValue\`":25.0}" `
        --estimated-instance-warmup 60 `
        --region $region | Out-Null
    Write-Host "  Auto Scaling Group and Policy configured successfully!" -ForegroundColor Green
} else {
    Write-Host "  Auto Scaling Group Cafe-ASG already exists."
}

# 6. Task 6: Testing Application
Write-Host "`n[Task 6] Waiting for instances to become healthy..." -ForegroundColor Yellow
for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep -Seconds 15
    $targetHealth = aws elbv2 describe-target-health --target-group-arn $tgArn --region $region 2>$null | ConvertFrom-Json
    $healthyCount = ($targetHealth.TargetHealthDescriptions | Where-Object { $_.TargetHealth.State -eq "healthy" }).Count
    Write-Host "  Healthy targets: $healthyCount / 2 (attempt $($i+1))"
    if ($healthyCount -ge 2) {
        Write-Host "  All instances are healthy!" -ForegroundColor Green
        break
    }
}

Write-Host "`n========================================================================" -ForegroundColor Cyan
Write-Host " Lab Setup Completed Successfully!" -ForegroundColor Green
Write-Host " Application URL: http://$albDns/cafe" -ForegroundColor Yellow
Write-Host " ALB DNS Name:    http://$albDns" -ForegroundColor Yellow
Write-Host " Target Group:    $tgArn"
Write-Host " Auto Scaling Group: Cafe-ASG"
Write-Host "========================================================================" -ForegroundColor Cyan
