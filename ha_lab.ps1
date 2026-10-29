# ha_lab.ps1 - Automated Deployment for Guided Lab: Creating a Highly Available Environment
$ErrorActionPreference = "Continue"

Write-Host "========================================================================" -ForegroundColor Cyan
Write-Host " Starting Guided Lab: Creating a Highly Available Environment Automation" -ForegroundColor Cyan
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

# Test if Lab VPC exists in us-east-1 or us-west-2
$vpcCheck = aws ec2 describe-vpcs --filters "Name=tag:Name,Values=*Lab VPC*" --region $region 2>$null | ConvertFrom-Json
if (-not $vpcCheck.Vpcs -or $vpcCheck.Vpcs.Count -eq 0) {
    if ($region -eq "us-east-1") { $altRegion = "us-west-2" } else { $altRegion = "us-east-1" }
    $altCheck = aws ec2 describe-vpcs --filters "Name=tag:Name,Values=*Lab VPC*" --region $altRegion 2>$null | ConvertFrom-Json
    if ($altCheck.Vpcs -and $altCheck.Vpcs.Count -gt 0) {
        $region = $altRegion
        $env:AWS_DEFAULT_REGION = $altRegion
    }
}
Write-Host "Operating Region: $region" -ForegroundColor Green

# 1. Discover Lab Resources
Write-Host "`n[Task 1] Discovering Lab VPC and existing resources..." -ForegroundColor Yellow
$vpcJson = aws ec2 describe-vpcs --filters "Name=tag:Name,Values=*Lab VPC*" --region $region | ConvertFrom-Json
$vpcId = $vpcJson.Vpcs[0].VpcId
Write-Host "  Lab VPC ID: $vpcId"

$subnetsJson = aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpcId" --region $region | ConvertFrom-Json
$pubSubnet1 = ($subnetsJson.Subnets | Where-Object { ($_.Tags.Value -like "*Public Subnet 1*") -or ($_.CidrBlock -eq "10.0.0.0/24") }).SubnetId | Select-Object -First 1
$pubSubnet2 = ($subnetsJson.Subnets | Where-Object { ($_.Tags.Value -like "*Public Subnet 2*") -or ($_.CidrBlock -eq "10.0.1.0/24") }).SubnetId | Select-Object -First 1
$privSubnet1 = ($subnetsJson.Subnets | Where-Object { ($_.Tags.Value -like "*Private Subnet 1*") -or ($_.CidrBlock -eq "10.0.2.0/23") }).SubnetId | Select-Object -First 1
$privSubnet2 = ($subnetsJson.Subnets | Where-Object { ($_.Tags.Value -like "*Private Subnet 2*") -or ($_.CidrBlock -eq "10.0.4.0/23") }).SubnetId | Select-Object -First 1

Write-Host "  Public Subnet 1:  $pubSubnet1"
Write-Host "  Public Subnet 2:  $pubSubnet2"
Write-Host "  Private Subnet 1: $privSubnet1"
Write-Host "  Private Subnet 2: $privSubnet2"

# Security Groups
$sgList = aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpcId" --region $region | ConvertFrom-Json
$appSg = ($sgList.SecurityGroups | Where-Object { $_.GroupName -eq "Inventory-App" }).GroupId
$dbSg  = ($sgList.SecurityGroups | Where-Object { $_.GroupName -eq "Inventory-DB" }).GroupId
Write-Host "  Inventory-App SG: $appSg"
Write-Host "  Inventory-DB SG:  $dbSg"

# 2. Task 2: Create ALB and Target Group
Write-Host "`n[Task 2] Creating Application Load Balancer..." -ForegroundColor Yellow

# Create ALB Security Group (Inventory-LB)
$lbSg = ($sgList.SecurityGroups | Where-Object { $_.GroupName -eq "Inventory-LB" }).GroupId
if (-not $lbSg) {
    Write-Host "  Creating Security Group: Inventory-LB..."
    $lbSg = (aws ec2 create-security-group `
        --group-name "Inventory-LB" `
        --description "Enable web access to load balancer" `
        --vpc-id $vpcId `
        --region $region `
        --query "GroupId" --output text)
    
    aws ec2 authorize-security-group-ingress `
        --group-id $lbSg `
        --protocol tcp --port 80 --cidr 0.0.0.0/0 `
        --region $region | Out-Null
        
    aws ec2 authorize-security-group-ingress `
        --group-id $lbSg `
        --protocol tcp --port 443 --cidr 0.0.0.0/0 `
        --region $region | Out-Null
    Write-Host "  Created Inventory-LB SG: $lbSg"
} else {
    Write-Host "  Inventory-LB SG already exists: $lbSg"
}

# Create Target Group (Inventory-App)
$tgArn = (aws elbv2 describe-target-groups --region $region --query "TargetGroups[?TargetGroupName=='Inventory-App'].TargetGroupArn | [0]" --output text 2>$null)
if (-not $tgArn -or $tgArn -eq "None") {
    Write-Host "  Creating Target Group: Inventory-App..."
    $tgArn = (aws elbv2 create-target-group `
        --name "Inventory-App" `
        --protocol HTTP `
        --port 80 `
        --target-type instance `
        --vpc-id $vpcId `
        --healthy-threshold-count 2 `
        --health-check-interval-seconds 10 `
        --region $region `
        --query "TargetGroups[0].TargetGroupArn" --output text)
    Write-Host "  Created Target Group: $tgArn"
} else {
    Write-Host "  Target Group already exists: $tgArn"
}

# Create Application Load Balancer (Inventory-LB)
$albArn = (aws elbv2 describe-load-balancers --region $region --query "LoadBalancers[?LoadBalancerName=='Inventory-LB'].LoadBalancerArn | [0]" --output text 2>$null)
if (-not $albArn -or $albArn -eq "None") {
    Write-Host "  Creating Application Load Balancer: Inventory-LB..."
    $albJson = (aws elbv2 create-load-balancer `
        --name "Inventory-LB" `
        --subnets $pubSubnet1 $pubSubnet2 `
        --security-groups $lbSg `
        --scheme internet-facing `
        --type application `
        --region $region | ConvertFrom-Json)
    $albArn = $albJson.LoadBalancers[0].LoadBalancerArn
    $albDns = $albJson.LoadBalancers[0].DNSName
    Write-Host "  Created ALB: $albDns"

    # Create Listener on Port 80 forward to Target Group
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

# 3. Task 3.1: Create AMI from Web Server 1
Write-Host "`n[Task 3.1] Creating AMI from Web Server 1..." -ForegroundColor Yellow
$instancesJson = aws ec2 describe-instances --filters "Name=tag:Name,Values='Web Server 1'" "Name=instance-state-name,Values=running,pending" --region $region | ConvertFrom-Json
$webServer1Id = $instancesJson.Reservations[0].Instances[0].InstanceId
Write-Host "  Web Server 1 Instance ID: $webServer1Id"

$amiId = (aws ec2 describe-images --filters "Name=name,Values='Web Server AMI'" --owners self --region $region --query "Images[0].ImageId" --output text 2>$null)
if (-not $amiId -or $amiId -eq "None") {
    Write-Host "  Initiating AMI creation: Web Server AMI..."
    $amiId = (aws ec2 create-image `
        --instance-id $webServer1Id `
        --name "Web Server AMI" `
        --description "Lab AMI for Web Server" `
        --region $region `
        --query "ImageId" --output text)
    Write-Host "  Created AMI: $amiId. Waiting for AMI to be available..."
    aws ec2 wait image-available --image-ids $amiId --region $region
    Write-Host "  AMI $amiId is now available!" -ForegroundColor Green
} else {
    Write-Host "  AMI already exists: $amiId"
}

# 4. Task 3.2: Create Launch Template and Auto Scaling Group
Write-Host "`n[Task 3.2] Creating Launch Template and Auto Scaling Group..." -ForegroundColor Yellow

# User Data script
$userDataScript = @'
#!/bin/bash
# Install Apache Web Server and PHP
dnf install -y httpd php8.4 php8.4-fpm php8.4-mysqlnd mariadb1011 wget unzip
systemctl enable --now php-fpm
# Download Lab files
wget https://aws-tc-largeobjects.s3.us-west-2.amazonaws.com/CUR-TF-200-ACACAD-3-113230/12-lab-mod10-guided-Scaling/s3/scripts/al2023-inventory-app.zip -O inventory-app.zip
unzip inventory-app.zip -d /var/www/html/
# Download and install the AWS SDK for PHP
wget https://docs.aws.amazon.com/aws-sdk-php/v3/download/aws.zip
unzip -o aws.zip -d /var/www/html
# Turn on web server
systemctl enable httpd
service httpd start
'@
$userDataBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($userDataScript))

$ltData = @{
    ImageId = $amiId
    InstanceType = "t2.micro"
    KeyName = "vockey"
    SecurityGroupIds = @($appSg)
    IamInstanceProfile = @{ Name = "Inventory-App-Role" }
    Monitoring = @{ Enabled = $true }
    UserData = $userDataBase64
}
$ltDataJson = $ltData | ConvertTo-Json -Depth 5 -Compress
$ltDataPath = Join-Path $PSScriptRoot "lt_inventory.json"
Set-Content -Path $ltDataPath -Value $ltDataJson

$ltCheck = (aws ec2 describe-launch-templates --region $region --query "LaunchTemplates[?LaunchTemplateName=='Inventory-LT'].LaunchTemplateId | [0]" --output text 2>$null)
if (-not $ltCheck -or $ltCheck -eq "None") {
    Write-Host "  Creating Launch Template: Inventory-LT..."
    $ltId = (aws ec2 create-launch-template `
        --launch-template-name "Inventory-LT" `
        --version-description "v1" `
        --launch-template-data file://$ltDataPath `
        --region $region `
        --query "LaunchTemplate.LaunchTemplateId" --output text)
    Write-Host "  Created Launch Template: $ltId"
} else {
    Write-Host "  Launch Template Inventory-LT already exists: $ltCheck"
    $ltId = $ltCheck
}
Remove-Item $ltDataPath -Force -ErrorAction SilentlyContinue

# Create Auto Scaling Group
$asgCheck = (aws autoscaling describe-auto-scaling-groups --region $region --query "AutoScalingGroups[?AutoScalingGroupName=='Inventory-ASG'].AutoScalingGroupName | [0]" --output text 2>$null)
if (-not $asgCheck -or $asgCheck -eq "None") {
    Write-Host "  Creating Auto Scaling Group: Inventory-ASG..."
    aws autoscaling create-auto-scaling-group `
        --auto-scaling-group-name "Inventory-ASG" `
        --launch-template "LaunchTemplateName=Inventory-LT,Version=`$Latest" `
        --min-size 2 `
        --max-size 2 `
        --desired-capacity 2 `
        --vpc-zone-identifier "$privSubnet1,$privSubnet2" `
        --target-group-arns $tgArn `
        --health-check-type "ELB" `
        --health-check-grace-period 90 `
        --tags "Key=Name,Value=Inventory-App,PropagateAtLaunch=true" `
        --region $region

    aws autoscaling enable-metrics-collection `
        --auto-scaling-group-name "Inventory-ASG" `
        --granularity "1Minute" `
        --region $region
    Write-Host "  Created Auto Scaling Group Inventory-ASG with Desired=2, Min=2, Max=2" -ForegroundColor Green
} else {
    Write-Host "  Auto Scaling Group Inventory-ASG already exists."
}

# 5. Task 4: Update Security Groups
Write-Host "`n[Task 4] Configuring 3-tier Security Groups..." -ForegroundColor Yellow

# 4.2 Application SG (Inventory-App): Inbound HTTP 80 from Inventory-LB SG
Write-Host "  Configuring Inventory-App SG ingress from Inventory-LB SG..."
aws ec2 authorize-security-group-ingress `
    --group-id $appSg `
    --protocol tcp --port 80 `
    --source-group $lbSg `
    --region $region 2>$null | Out-Null
Write-Host "  Inventory-App SG updated."

# 4.3 Database SG (Inventory-DB): Revoke existing ingress, allow 3306 from Inventory-App SG
Write-Host "  Configuring Inventory-DB SG ingress from Inventory-App SG..."
$dbSgDetails = aws ec2 describe-security-groups --group-ids $dbSg --region $region | ConvertFrom-Json
foreach ($rule in $dbSgDetails.SecurityGroups[0].IpPermissions) {
    if ($rule.FromPort -eq 3306) {
        foreach ($ipRange in $rule.IpRanges) {
            aws ec2 revoke-security-group-ingress `
                --group-id $dbSg `
                --protocol tcp --port 3306 --cidr $ipRange.CidrIp `
                --region $region 2>$null | Out-Null
        }
    }
}
aws ec2 authorize-security-group-ingress `
    --group-id $dbSg `
    --protocol tcp --port 3306 `
    --source-group $appSg `
    --region $region 2>$null | Out-Null
Write-Host "  Inventory-DB SG updated (only accepts MySQL traffic from Inventory-App SG)."

# 6. Optional Task 1: Multi-AZ Database
Write-Host "`n[Optional Task 1] Configuring RDS Multi-AZ Deployment & Scaling..." -ForegroundColor Yellow
$dbInstances = aws rds describe-db-instances --region $region | ConvertFrom-Json
$dbInst = $dbInstances.DBInstances | Where-Object { $_.DBInstanceIdentifier -like "*inventory*" }
if ($dbInst) {
    $dbId = $dbInst.DBInstanceIdentifier
    Write-Host "  Modifying database $dbId to Multi-AZ with db.t3.small and 20GB storage..."
    aws rds modify-db-instance `
        --db-instance-identifier $dbId `
        --multi-az `
        --db-instance-class db.t3.small `
        --allocated-storage 20 `
        --apply-immediately `
        --region $region | Out-Null
    Write-Host "  Database modification submitted (Apply Immediately)." -ForegroundColor Green
} else {
    Write-Host "  No inventory database instance found to modify."
}

# 7. Optional Task 2: Highly Available NAT Gateway
Write-Host "`n[Optional Task 2] Configuring Highly Available NAT Gateway in AZ 2..." -ForegroundColor Yellow
$natCheck = aws ec2 describe-nat-gateways --filter "Name=tag:Name,Values=NatGateway2" "Name=state,Values=pending,available" --region $region | ConvertFrom-Json
if (-not $natCheck.NatGateways -or $natCheck.NatGateways.Count -eq 0) {
    Write-Host "  Allocating Elastic IP for NatGateway2..."
    $eip = (aws ec2 allocate-address --domain vpc --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=NatGateway2-EIP}]" --region $region | ConvertFrom-Json).AllocationId
    
    Write-Host "  Creating NatGateway2 in Public Subnet 2 ($pubSubnet2)..."
    $nat2Json = (aws ec2 create-nat-gateway `
        --subnet-id $pubSubnet2 `
        --allocation-id $eip `
        --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=NatGateway2}]" `
        --region $region | ConvertFrom-Json)
    $nat2Id = $nat2Json.NatGateway.NatGatewayId
    Write-Host "  Created NatGateway2: $nat2Id. Waiting for available status..."
    aws ec2 wait nat-gateway-available --nat-gateway-ids $nat2Id --region $region
    Write-Host "  NatGateway2 is now available!" -ForegroundColor Green

    # Create Private Route Table 2
    Write-Host "  Creating Private Route Table 2..."
    $rt2Json = (aws ec2 create-route-table `
        --vpc-id $vpcId `
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value='Private Route Table 2'}]" `
        --region $region | ConvertFrom-Json)
    $rt2Id = $rt2Json.RouteTable.RouteTableId

    # Add Route 0.0.0.0/0 -> NatGateway2
    Write-Host "  Adding 0.0.0.0/0 route to NatGateway2..."
    aws ec2 create-route `
        --route-table-id $rt2Id `
        --destination-cidr-block 0.0.0.0/0 `
        --nat-gateway-id $nat2Id `
        --region $region | Out-Null

    # Associate with Private Subnet 2
    Write-Host "  Associating Private Route Table 2 with Private Subnet 2 ($privSubnet2)..."
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
    Write-Host "  Highly Available NAT Gateway and routing configured!" -ForegroundColor Green
} else {
    Write-Host "  NatGateway2 already exists."
}

# 8. Testing and Validation
Write-Host "`n========================================================================" -ForegroundColor Cyan
Write-Host " Lab Setup Completed Successfully!" -ForegroundColor Green
Write-Host " ALB DNS Name: http://$albDns" -ForegroundColor Yellow
Write-Host " Target Group: $tgArn"
Write-Host " Auto Scaling Group: Inventory-ASG"
Write-Host "========================================================================" -ForegroundColor Cyan
