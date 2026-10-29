# cafe_ha_lab.ps1 - Automated Deployment for Challenge Lab: Creating a Scalable and Highly Available Environment for the Café
$ErrorActionPreference = "Continue"

Write-Host "========================================================================" -ForegroundColor Cyan
Write-Host " Starting Challenge Lab: Scalable and Highly Available Café Environment " -ForegroundColor Cyan
Write-Host "========================================================================" -ForegroundColor Cyan

# 0. Check AWS Session
Write-Host "`n[Step 0] Verifying AWS Identity..." -ForegroundColor Yellow
$identity = aws sts get-caller-identity 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: AWS credentials not found or invalid." -ForegroundColor Red
    Write-Host "Please set `$env:AWS_ACCESS_KEY_ID, `$env:AWS_SECRET_ACCESS_KEY, and `$env:AWS_SESSION_TOKEN." -ForegroundColor Red
    exit 1
}
Write-Host "AWS Identity verified successfully." -ForegroundColor Green

# Determine Region
$region = $env:AWS_DEFAULT_REGION
if (-not $region) { $region = "us-east-1" }

$vpcCheck = aws ec2 describe-vpcs --filters "Name=tag:Name,Values=*Cafe*,*Lab*" --region $region 2>$null | ConvertFrom-Json
if (-not $vpcCheck.Vpcs -or $vpcCheck.Vpcs.Count -eq 0) {
    if ($region -eq "us-east-1") { $altRegion = "us-west-2" } else { $altRegion = "us-east-1" }
    $altCheck = aws ec2 describe-vpcs --filters "Name=tag:Name,Values=*Cafe*,*Lab*" --region $altRegion 2>$null | ConvertFrom-Json
    if ($altCheck.Vpcs -and $altCheck.Vpcs.Count -gt 0) {
        $region = $altRegion
        $env:AWS_DEFAULT_REGION = $altRegion
    }
}
Write-Host "Operating Region: $region" -ForegroundColor Green

# 1. Discover Lab Resources
Write-Host "`n[Task 1] Discovering Lab VPC, Subnets, and Security Groups..." -ForegroundColor Yellow
$vpcs = aws ec2 describe-vpcs --region $region | ConvertFrom-Json
$labVpc = $vpcs.Vpcs | Where-Object { $_.IsDefault -eq $false } | Select-Object -First 1
$vpcId = $labVpc.VpcId
Write-Host "  Lab VPC ID: $vpcId"

$subnetsJson = aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpcId" --region $region | ConvertFrom-Json
$pubSubnet1 = ($subnetsJson.Subnets | Where-Object { ($_.Tags.Value -like "*Public Subnet 1*") -or ($_.Tags.Value -like "*Public*1*") }).SubnetId | Select-Object -First 1
$pubSubnet2 = ($subnetsJson.Subnets | Where-Object { ($_.Tags.Value -like "*Public Subnet 2*") -or ($_.Tags.Value -like "*Public*2*") }).SubnetId | Select-Object -First 1
$privSubnet1 = ($subnetsJson.Subnets | Where-Object { ($_.Tags.Value -like "*Private Subnet 1*") -or ($_.Tags.Value -like "*Private*1*") }).SubnetId | Select-Object -First 1
$privSubnet2 = ($subnetsJson.Subnets | Where-Object { ($_.Tags.Value -like "*Private Subnet 2*") -or ($_.Tags.Value -like "*Private*2*") }).SubnetId | Select-Object -First 1

if (-not $pubSubnet1 -or -not $pubSubnet2) {
    # Fallback to AZ-based sorting if name tags differ
    $sortedSubs = $subnetsJson.Subnets | Sort-Object CidrBlock
    $pubSubnet1 = $sortedSubs[0].SubnetId
    $pubSubnet2 = $sortedSubs[1].SubnetId
    $privSubnet1 = $sortedSubs[2].SubnetId
    $privSubnet2 = $sortedSubs[3].SubnetId
}

Write-Host "  Public Subnet 1:  $pubSubnet1"
Write-Host "  Public Subnet 2:  $pubSubnet2"
Write-Host "  Private Subnet 1: $privSubnet1"
Write-Host "  Private Subnet 2: $privSubnet2"

# Security Groups
$sgList = aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpcId" --region $region | ConvertFrom-Json
$cafeSg = ($sgList.SecurityGroups | Where-Object { $_.GroupName -like "*CafeSG*" }).GroupId | Select-Object -First 1
Write-Host "  CafeSG: $cafeSg"

# Inspect CafeSG Open Ports
$cafeSgDetails = $sgList.SecurityGroups | Where-Object { $_.GroupId -eq $cafeSg }
Write-Host "  CafeSG Inbound Rules:"
foreach ($perm in $cafeSgDetails.IpPermissions) {
    Write-Host "    Protocol: $($perm.IpProtocol), FromPort: $($perm.FromPort), ToPort: $($perm.ToPort)"
}

# 2. Task 2: Create NAT Gateway in Public Subnet 2 and Route Table
Write-Host "`n[Task 2] Setting up NAT Gateway in AZ 2 and routing for Private Subnet 2..." -ForegroundColor Yellow
$nat2Check = aws ec2 describe-nat-gateways --filter "Name=subnet-id,Values=$pubSubnet2" "Name=state,Values=pending,available" --region $region | ConvertFrom-Json
if (-not $nat2Check.NatGateways -or $nat2Check.NatGateways.Count -eq 0) {
    Write-Host "  Allocating Elastic IP for NAT Gateway 2..."
    $eip = (aws ec2 allocate-address --domain vpc --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=Cafe-NatGateway2-EIP}]" --region $region | ConvertFrom-Json).AllocationId
    
    Write-Host "  Creating NAT Gateway 2 in Public Subnet 2 ($pubSubnet2)..."
    $nat2Json = (aws ec2 create-nat-gateway `
        --subnet-id $pubSubnet2 `
        --allocation-id $eip `
        --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=Cafe-NatGateway2}]" `
        --region $region | ConvertFrom-Json)
    $nat2Id = $nat2Json.NatGateway.NatGatewayId
    Write-Host "  Created NAT Gateway 2: $nat2Id. Waiting for available status..."
    aws ec2 wait nat-gateway-available --nat-gateway-ids $nat2Id --region $region
    Write-Host "  NAT Gateway 2 is now available!" -ForegroundColor Green

    # Route Table for Private Subnet 2
    Write-Host "  Configuring route table for Private Subnet 2..."
    $rt2Json = (aws ec2 create-route-table `
        --vpc-id $vpcId `
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value='Private Route Table 2'}]" `
        --region $region | ConvertFrom-Json)
    $rt2Id = $rt2Json.RouteTable.RouteTableId

    aws ec2 create-route `
        --route-table-id $rt2Id `
        --destination-cidr-block 0.0.0.0/0 `
        --nat-gateway-id $nat2Id `
        --region $region | Out-Null

    # Reassociate Private Subnet 2
    $existingAssoc = (aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$privSubnet2" --region $region --query "RouteTables[0].Associations[?SubnetId=='$privSubnet2'].RouteTableAssociationId" --output text 2>$null)
    if ($existingAssoc -and $existingAssoc -ne "None") {
        aws ec2 replace-route-table-association `
            --association-id $existingAssoc `
            --route-table-id $rt2Id `
            --region $region | Out-Null
    } else {
        aws ec2 associate-route-table `
            --route-table-id $rt2Id `
            --subnet-id $privSubnet2 `
            --region $region | Out-Null
    }
    Write-Host "  Routing for Private Subnet 2 configured through NAT Gateway 2!" -ForegroundColor Green
} else {
    Write-Host "  NAT Gateway 2 already exists."
}

# 3. Task 3: Create Launch Template
Write-Host "`n[Task 3] Creating Launch Template..." -ForegroundColor Yellow
$amiId = (aws ec2 describe-images --filters "Name=name,Values=*Cafe WebServer Image*" --region $region --query "Images[0].ImageId" --output text 2>$null)
if (-not $amiId -or $amiId -eq "None") {
    $amiId = (aws ec2 describe-images --owners self --region $region --query "Images[0].ImageId" --output text 2>$null)
}
Write-Host "  Using AMI ID: $amiId"

$keyPair = (aws ec2 describe-key-pairs --region $region --query "KeyPairs[0].KeyName" --output text 2>$null)
if (-not $keyPair -or $keyPair -eq "None") {
    Write-Host "  Creating key pair CafeKey..."
    aws ec2 create-key-pair --key-name "CafeKey" --region $region --query "KeyMaterial" --output text > "$PSScriptRoot\CafeKey.pem"
    $keyPair = "CafeKey"
}
Write-Host "  Using Key Pair: $keyPair"

$ltData = @{
    ImageId = $amiId
    InstanceType = "t2.micro"
    KeyName = $keyPair
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
    Write-Host "  Created Launch Template: $ltId"
} else {
    Write-Host "  Launch Template Cafe-LT already exists: $ltId"
}
Remove-Item $ltDataPath -Force -ErrorAction SilentlyContinue

# 4. Task 5: Create Load Balancer and Target Group
Write-Host "`n[Task 5] Creating Application Load Balancer and Target Group..." -ForegroundColor Yellow

# Create ALB Security Group
$albSg = ($sgList.SecurityGroups | Where-Object { $_.GroupName -eq "Cafe-ALB-SG" }).GroupId
if (-not $albSg) {
    Write-Host "  Creating Security Group: Cafe-ALB-SG..."
    $albSg = (aws ec2 create-security-group `
        --group-name "Cafe-ALB-SG" `
        --description "Allow HTTP traffic from anywhere to Cafe ALB" `
        --vpc-id $vpcId `
        --region $region `
        --query "GroupId" --output text)
    
    aws ec2 authorize-security-group-ingress `
        --group-id $albSg `
        --protocol tcp --port 80 --cidr 0.0.0.0/0 `
        --region $region | Out-Null
    Write-Host "  Created Cafe-ALB-SG: $albSg"
} else {
    Write-Host "  Cafe-ALB-SG already exists: $albSg"
}

# Allow CafeSG to accept HTTP from Cafe-ALB-SG (or 0.0.0.0/0)
aws ec2 authorize-security-group-ingress `
    --group-id $cafeSg `
    --protocol tcp --port 80 --cidr 0.0.0.0/0 `
    --region $region 2>$null | Out-Null

# Create Target Group
$tgArn = (aws elbv2 describe-target-groups --region $region --query "TargetGroups[?TargetGroupName=='Cafe-TG'].TargetGroupArn | [0]" --output text 2>$null)
if (-not $tgArn -or $tgArn -eq "None") {
    Write-Host "  Creating Target Group: Cafe-TG..."
    $tgArn = (aws elbv2 create-target-group `
        --name "Cafe-TG" `
        --protocol HTTP `
        --port 80 `
        --target-type instance `
        --vpc-id $vpcId `
        --health-check-path "/cafe/" `
        --healthy-threshold-count 2 `
        --health-check-interval-seconds 15 `
        --region $region `
        --query "TargetGroups[0].TargetGroupArn" --output text)
    Write-Host "  Created Target Group: $tgArn"
} else {
    Write-Host "  Target Group already exists: $tgArn"
}

# Create Application Load Balancer
$albArn = (aws elbv2 describe-load-balancers --region $region --query "LoadBalancers[?LoadBalancerName=='Cafe-ALB'].LoadBalancerArn | [0]" --output text 2>$null)
if (-not $albArn -or $albArn -eq "None") {
    Write-Host "  Creating Application Load Balancer: Cafe-ALB..."
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

    Write-Host "  Creating ALB Listener for Port 80..."
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

# 5. Task 4: Create Auto Scaling Group with Target Tracking Policy
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

    # Target Tracking Scaling Policy: Average CPU 25%, Warmup 60s
    Write-Host "  Configuring Target Tracking Scaling Policy (Average CPU 25%)..."
    aws autoscaling put-scaling-policy `
        --auto-scaling-group-name "Cafe-ASG" `
        --policy-name "Cafe-CPU-Scaling-Policy" `
        --policy-type "TargetTrackingScaling" `
        --target-tracking-configuration "{\`"PredefinedMetricSpecification\`":{\`"PredefinedMetricType\`":\`"ASGAverageCPUUtilization\`"}, \`"TargetValue\`":25.0, \`"EstimatedInstanceWarmup\`":60}" `
        --region $region | Out-Null
    Write-Host "  Scaling Policy attached successfully." -ForegroundColor Green
} else {
    Write-Host "  Auto Scaling Group Cafe-ASG already exists."
    # Ensure Target Group is attached
    aws autoscaling attach-load-balancer-target-groups `
        --auto-scaling-group-name "Cafe-ASG" `
        --target-group-arns $tgArn `
        --region $region 2>$null | Out-Null
}

# 6. Task 6: Testing Web Application
Write-Host "`n[Task 6] Testing Web Application..." -ForegroundColor Yellow
Write-Host "  Waiting for instances to become healthy in Target Group..."
for ($i = 0; $i -lt 12; $i++) {
    Start-Sleep -Seconds 15
    $targetHealth = aws elbv2 describe-target-health --target-group-arn $tgArn --region $region | ConvertFrom-Json
    $healthyCount = ($targetHealth.TargetHealthDescriptions | Where-Object { $_.TargetHealth.State -eq "healthy" }).Count
    Write-Host "  Healthy targets: $healthyCount / 2"
    if ($healthyCount -ge 2) {
        Write-Host "  Instances are healthy!" -ForegroundColor Green
        break
    }
}

Write-Host "`n========================================================================" -ForegroundColor Cyan
Write-Host " Lab Setup Completed Successfully!" -ForegroundColor Green
Write-Host " Application URL: http://$albDns/cafe" -ForegroundColor Yellow
Write-Host " Target Group: $tgArn"
Write-Host " Auto Scaling Group: Cafe-ASG (Desired: 2, Min: 2, Max: 6)"
Write-Host "========================================================================" -ForegroundColor Cyan

