# ============================================================================
# lab.ps1 - AWS Academy Lab 2: Build your VPC and Launch a Web Server
# ============================================================================
$ErrorActionPreference = "Stop"
$region = "us-east-1"

Set-Location $PSScriptRoot

function Test-AwsResult {
    param([string]$r)
    return (-not [string]::IsNullOrWhiteSpace($r)) -and ($r -ne "None") -and ($r -ne "null")
}
function Assert-Success {
    param([string]$step)
    if ($LASTEXITCODE -ne 0) { throw "FAIL: $step (exit code $LASTEXITCODE)" }
}

# === Verify AWS session ===
Write-Host "`n=== Verifying AWS Session ===" -ForegroundColor Cyan
aws sts get-caller-identity --region $region --output table
Assert-Success "Session verification"
Write-Host "PASS: Session valid`n" -ForegroundColor Green

# ==========================================================================
# TASK 1: Create Your VPC
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 1: Create Your VPC" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

# --- 1.1 VPC ---
$vpcId = aws ec2 describe-vpcs --filters "Name=tag:Name,Values=lab-vpc" "Name=cidr,Values=10.0.0.0/16" --query "Vpcs[0].VpcId" --output text --region $region 2>$null
if (-not (Test-AwsResult $vpcId)) {
    Write-Host "Creating VPC lab-vpc (10.0.0.0/16)..."
    $vpcId = aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query "Vpc.VpcId" --output text --region $region
    Assert-Success "Create VPC"
    aws ec2 create-tags --resources $vpcId --tags Key=Name,Value=lab-vpc --region $region
    aws ec2 modify-vpc-attribute --vpc-id $vpcId --enable-dns-support Value=true --region $region
    aws ec2 modify-vpc-attribute --vpc-id $vpcId --enable-dns-hostnames Value=true --region $region
} else { Write-Host "VPC lab-vpc already exists: $vpcId" }
$v = aws ec2 describe-vpcs --vpc-ids $vpcId --query "Vpcs[0].State" --output text --region $region
Write-Host "PASS: VPC $vpcId (State: $v)" -ForegroundColor Green

# --- 1.2 Internet Gateway ---
$igwId = aws ec2 describe-internet-gateways --filters "Name=tag:Name,Values=lab-igw" --query "InternetGateways[0].InternetGatewayId" --output text --region $region 2>$null
if (-not (Test-AwsResult $igwId)) {
    Write-Host "Creating Internet Gateway lab-igw..."
    $igwId = aws ec2 create-internet-gateway --query "InternetGateway.InternetGatewayId" --output text --region $region
    Assert-Success "Create IGW"
    aws ec2 create-tags --resources $igwId --tags Key=Name,Value=lab-igw --region $region
    aws ec2 attach-internet-gateway --internet-gateway-id $igwId --vpc-id $vpcId --region $region
    Assert-Success "Attach IGW"
} else { Write-Host "IGW lab-igw already exists: $igwId" }
$v = aws ec2 describe-internet-gateways --internet-gateway-ids $igwId --query "InternetGateways[0].Attachments[0].State" --output text --region $region
Write-Host "PASS: IGW $igwId (Attachment: $v)" -ForegroundColor Green

# --- 1.3 Public Subnet 1 (us-east-1a, 10.0.0.0/24) ---
$pubSub1 = aws ec2 describe-subnets --filters "Name=tag:Name,Values=lab-subnet-public1-us-east-1a" "Name=vpc-id,Values=$vpcId" --query "Subnets[0].SubnetId" --output text --region $region 2>$null
if (-not (Test-AwsResult $pubSub1)) {
    Write-Host "Creating subnet lab-subnet-public1-us-east-1a (10.0.0.0/24)..."
    $pubSub1 = aws ec2 create-subnet --vpc-id $vpcId --cidr-block 10.0.0.0/24 --availability-zone us-east-1a --query "Subnet.SubnetId" --output text --region $region
    Assert-Success "Create public subnet 1"
    aws ec2 create-tags --resources $pubSub1 --tags Key=Name,Value=lab-subnet-public1-us-east-1a --region $region
    aws ec2 modify-subnet-attribute --subnet-id $pubSub1 --map-public-ip-on-launch --region $region
} else { Write-Host "Subnet lab-subnet-public1-us-east-1a already exists: $pubSub1" }
Write-Host "PASS: Public Subnet 1 $pubSub1" -ForegroundColor Green

# --- 1.4 Private Subnet 1 (us-east-1a, 10.0.1.0/24) ---
$privSub1 = aws ec2 describe-subnets --filters "Name=tag:Name,Values=lab-subnet-private1-us-east-1a" "Name=vpc-id,Values=$vpcId" --query "Subnets[0].SubnetId" --output text --region $region 2>$null
if (-not (Test-AwsResult $privSub1)) {
    Write-Host "Creating subnet lab-subnet-private1-us-east-1a (10.0.1.0/24)..."
    $privSub1 = aws ec2 create-subnet --vpc-id $vpcId --cidr-block 10.0.1.0/24 --availability-zone us-east-1a --query "Subnet.SubnetId" --output text --region $region
    Assert-Success "Create private subnet 1"
    aws ec2 create-tags --resources $privSub1 --tags Key=Name,Value=lab-subnet-private1-us-east-1a --region $region
} else { Write-Host "Subnet lab-subnet-private1-us-east-1a already exists: $privSub1" }
Write-Host "PASS: Private Subnet 1 $privSub1" -ForegroundColor Green

# --- 1.5 Public Route Table ---
$pubRtb = aws ec2 describe-route-tables --filters "Name=tag:Name,Values=lab-rtb-public" "Name=vpc-id,Values=$vpcId" --query "RouteTables[0].RouteTableId" --output text --region $region 2>$null
if (-not (Test-AwsResult $pubRtb)) {
    Write-Host "Creating route table lab-rtb-public..."
    $pubRtb = aws ec2 create-route-table --vpc-id $vpcId --query "RouteTable.RouteTableId" --output text --region $region
    Assert-Success "Create public RT"
    aws ec2 create-tags --resources $pubRtb --tags Key=Name,Value=lab-rtb-public --region $region
    aws ec2 create-route --route-table-id $pubRtb --destination-cidr-block 0.0.0.0/0 --gateway-id $igwId --region $region | Out-Null
    Assert-Success "Add IGW route"
} else { Write-Host "Route table lab-rtb-public already exists: $pubRtb" }
# Associate public subnet 1
$assoc = aws ec2 describe-route-tables --route-table-ids $pubRtb --query "RouteTables[0].Associations[?SubnetId=='$pubSub1'] | [0].RouteTableAssociationId" --output text --region $region 2>$null
if (-not (Test-AwsResult $assoc)) {
    aws ec2 associate-route-table --route-table-id $pubRtb --subnet-id $pubSub1 --region $region | Out-Null
    Write-Host "  Associated public subnet 1 with lab-rtb-public"
}
Write-Host "PASS: Public RT $pubRtb" -ForegroundColor Green

# --- 1.6 NAT Gateway ---
$natGwId = aws ec2 describe-nat-gateways --filter "Name=tag:Name,Values=lab-nat-public1-us-east-1a" "Name=state,Values=pending,available" --query "NatGateways[0].NatGatewayId" --output text --region $region 2>$null
if (-not (Test-AwsResult $natGwId)) {
    Write-Host "Allocating Elastic IP for NAT Gateway..."
    $eipAllocId = aws ec2 allocate-address --domain vpc --query "AllocationId" --output text --region $region
    Assert-Success "Allocate EIP"
    aws ec2 create-tags --resources $eipAllocId --tags Key=Name,Value=lab-nat-eip --region $region
    Write-Host "Creating NAT Gateway lab-nat-public1-us-east-1a..."
    $natGwId = aws ec2 create-nat-gateway --subnet-id $pubSub1 --allocation-id $eipAllocId --query "NatGateway.NatGatewayId" --output text --region $region
    Assert-Success "Create NAT GW"
    aws ec2 create-tags --resources $natGwId --tags Key=Name,Value=lab-nat-public1-us-east-1a --region $region
    Write-Host "Waiting for NAT Gateway to become available (~2 min)..."
    aws ec2 wait nat-gateway-available --nat-gateway-ids $natGwId --region $region
    Assert-Success "NAT GW available"
} else {
    Write-Host "NAT Gateway already exists: $natGwId"
    $s = aws ec2 describe-nat-gateways --nat-gateway-ids $natGwId --query "NatGateways[0].State" --output text --region $region
    if ($s -eq "pending") {
        Write-Host "Waiting for NAT Gateway to become available..."
        aws ec2 wait nat-gateway-available --nat-gateway-ids $natGwId --region $region
    }
}
$s = aws ec2 describe-nat-gateways --nat-gateway-ids $natGwId --query "NatGateways[0].State" --output text --region $region
Write-Host "PASS: NAT Gateway $natGwId (State: $s)" -ForegroundColor Green

# --- 1.7 Private Route Table ---
$privRtb = aws ec2 describe-route-tables --filters "Name=tag:Name,Values=lab-rtb-private1-us-east-1a" "Name=vpc-id,Values=$vpcId" --query "RouteTables[0].RouteTableId" --output text --region $region 2>$null
if (-not (Test-AwsResult $privRtb)) {
    Write-Host "Creating route table lab-rtb-private1-us-east-1a..."
    $privRtb = aws ec2 create-route-table --vpc-id $vpcId --query "RouteTable.RouteTableId" --output text --region $region
    Assert-Success "Create private RT"
    aws ec2 create-tags --resources $privRtb --tags Key=Name,Value=lab-rtb-private1-us-east-1a --region $region
    aws ec2 create-route --route-table-id $privRtb --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $natGwId --region $region | Out-Null
    Assert-Success "Add NAT route"
} else { Write-Host "Route table lab-rtb-private1-us-east-1a already exists: $privRtb" }
# Associate private subnet 1
$assoc = aws ec2 describe-route-tables --route-table-ids $privRtb --query "RouteTables[0].Associations[?SubnetId=='$privSub1'] | [0].RouteTableAssociationId" --output text --region $region 2>$null
if (-not (Test-AwsResult $assoc)) {
    aws ec2 associate-route-table --route-table-id $privRtb --subnet-id $privSub1 --region $region | Out-Null
    Write-Host "  Associated private subnet 1 with lab-rtb-private1-us-east-1a"
}
Write-Host "PASS: Private RT $privRtb" -ForegroundColor Green
Write-Host "`n>> TASK 1 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 2: Create Additional Subnets
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 2: Create Additional Subnets" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

# --- 2.1 Public Subnet 2 (us-east-1b, 10.0.2.0/24) ---
$pubSub2 = aws ec2 describe-subnets --filters "Name=tag:Name,Values=lab-subnet-public2" "Name=vpc-id,Values=$vpcId" --query "Subnets[0].SubnetId" --output text --region $region 2>$null
if (-not (Test-AwsResult $pubSub2)) {
    Write-Host "Creating subnet lab-subnet-public2 (10.0.2.0/24 in us-east-1b)..."
    $pubSub2 = aws ec2 create-subnet --vpc-id $vpcId --cidr-block 10.0.2.0/24 --availability-zone us-east-1b --query "Subnet.SubnetId" --output text --region $region
    Assert-Success "Create public subnet 2"
    aws ec2 create-tags --resources $pubSub2 --tags Key=Name,Value=lab-subnet-public2 --region $region
    aws ec2 modify-subnet-attribute --subnet-id $pubSub2 --map-public-ip-on-launch --region $region
} else { Write-Host "Subnet lab-subnet-public2 already exists: $pubSub2" }
# Associate with public route table
$assoc = aws ec2 describe-route-tables --route-table-ids $pubRtb --query "RouteTables[0].Associations[?SubnetId=='$pubSub2'] | [0].RouteTableAssociationId" --output text --region $region 2>$null
if (-not (Test-AwsResult $assoc)) {
    aws ec2 associate-route-table --route-table-id $pubRtb --subnet-id $pubSub2 --region $region | Out-Null
    Write-Host "  Associated lab-subnet-public2 with lab-rtb-public"
}
Write-Host "PASS: Public Subnet 2 $pubSub2" -ForegroundColor Green

# --- 2.2 Private Subnet 2 (us-east-1b, 10.0.3.0/24) ---
$privSub2 = aws ec2 describe-subnets --filters "Name=tag:Name,Values=lab-subnet-private2" "Name=vpc-id,Values=$vpcId" --query "Subnets[0].SubnetId" --output text --region $region 2>$null
if (-not (Test-AwsResult $privSub2)) {
    Write-Host "Creating subnet lab-subnet-private2 (10.0.3.0/24 in us-east-1b)..."
    $privSub2 = aws ec2 create-subnet --vpc-id $vpcId --cidr-block 10.0.3.0/24 --availability-zone us-east-1b --query "Subnet.SubnetId" --output text --region $region
    Assert-Success "Create private subnet 2"
    aws ec2 create-tags --resources $privSub2 --tags Key=Name,Value=lab-subnet-private2 --region $region
} else { Write-Host "Subnet lab-subnet-private2 already exists: $privSub2" }
# Associate with private route table
$assoc = aws ec2 describe-route-tables --route-table-ids $privRtb --query "RouteTables[0].Associations[?SubnetId=='$privSub2'] | [0].RouteTableAssociationId" --output text --region $region 2>$null
if (-not (Test-AwsResult $assoc)) {
    aws ec2 associate-route-table --route-table-id $privRtb --subnet-id $privSub2 --region $region | Out-Null
    Write-Host "  Associated lab-subnet-private2 with lab-rtb-private1-us-east-1a"
}
Write-Host "PASS: Private Subnet 2 $privSub2" -ForegroundColor Green
Write-Host "`n>> TASK 2 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 3: Create a VPC Security Group
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 3: Create VPC Security Group" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

$sgId = aws ec2 describe-security-groups --filters "Name=group-name,Values=Web Security Group" "Name=vpc-id,Values=$vpcId" --query "SecurityGroups[0].GroupId" --output text --region $region 2>$null
if (-not (Test-AwsResult $sgId)) {
    Write-Host "Creating security group: Web Security Group..."
    $sgId = aws ec2 create-security-group --group-name "Web Security Group" --description "Enable HTTP access" --vpc-id $vpcId --query "GroupId" --output text --region $region
    Assert-Success "Create SG"
    Write-Host "Adding inbound rule: HTTP (port 80) from 0.0.0.0/0..."
    aws ec2 authorize-security-group-ingress --group-id $sgId --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description=Permit web requests}]" --region $region | Out-Null
    Assert-Success "Add HTTP rule"
} else { Write-Host "Security group 'Web Security Group' already exists: $sgId" }
$v = aws ec2 describe-security-groups --group-ids $sgId --query "SecurityGroups[0].IpPermissions[0].IpRanges[0].CidrIp" --output text --region $region
Write-Host "PASS: Security Group $sgId (HTTP from: $v)" -ForegroundColor Green
Write-Host "`n>> TASK 3 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 4: Launch a Web Server Instance
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 4: Launch Web Server Instance" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

# Get latest Amazon Linux 2023 AMI
Write-Host "Looking up Amazon Linux 2023 AMI..."
$amiId = aws ec2 describe-images --owners amazon --filters "Name=name,Values=al2023-ami-2023*-kernel-default-x86_64" "Name=state,Values=available" --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text --region $region
if (-not (Test-AwsResult $amiId)) {
    $amiId = aws ssm get-parameters --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query "Parameters[0].Value" --output text --region $region 2>$null
}
Assert-Success "Get AMI ID"
Write-Host "Using AMI: $amiId"

# Check if instance already exists
$instanceId = aws ec2 describe-instances --filters "Name=tag:Name,Values=Web Server 1" "Name=instance-state-name,Values=pending,running" --query "Reservations[0].Instances[0].InstanceId" --output text --region $region 2>$null
if (-not (Test-AwsResult $instanceId)) {
    Write-Host "Launching EC2 instance: Web Server 1 (t2.micro in lab-subnet-public2)..."
    $instanceId = aws ec2 run-instances `
        --image-id $amiId `
        --instance-type t2.micro `
        --key-name vockey `
        --subnet-id $pubSub2 `
        --security-group-ids $sgId `
        --user-data file://userdata.sh `
        --query "Instances[0].InstanceId" `
        --output text `
        --region $region
    Assert-Success "Launch instance"
    aws ec2 create-tags --resources $instanceId --tags "Key=Name,Value=Web Server 1" --region $region
    Assert-Success "Tag instance"

    Write-Host "Instance $instanceId launched. Waiting for running state..."
    aws ec2 wait instance-running --instance-ids $instanceId --region $region
    Write-Host "Running. Waiting for 2/2 status checks (~2-3 min)..."
    aws ec2 wait instance-status-ok --instance-ids $instanceId --region $region
    Assert-Success "Instance status OK"
} else { Write-Host "Instance 'Web Server 1' already exists: $instanceId" }

# Verify
$publicDns = aws ec2 describe-instances --instance-ids $instanceId --query "Reservations[0].Instances[0].PublicDnsName" --output text --region $region
$publicIp  = aws ec2 describe-instances --instance-ids $instanceId --query "Reservations[0].Instances[0].PublicIpAddress" --output text --region $region
$state     = aws ec2 describe-instances --instance-ids $instanceId --query "Reservations[0].Instances[0].State.Name" --output text --region $region
Write-Host "PASS: Instance $instanceId (State: $state)" -ForegroundColor Green
Write-Host "  Public IP:  $publicIp"
Write-Host "  Public DNS: $publicDns"
Write-Host "`n>> TASK 4 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# SUMMARY
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host " ALL TASKS COMPLETE" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host "VPC:              $vpcId  (lab-vpc)"
Write-Host "IGW:              $igwId  (lab-igw)"
Write-Host "NAT Gateway:      $natGwId  (lab-nat-public1-us-east-1a)"
Write-Host "Public Subnet 1:  $pubSub1  (10.0.0.0/24 us-east-1a)"
Write-Host "Private Subnet 1: $privSub1  (10.0.1.0/24 us-east-1a)"
Write-Host "Public Subnet 2:  $pubSub2  (10.0.2.0/24 us-east-1b)"
Write-Host "Private Subnet 2: $privSub2  (10.0.3.0/24 us-east-1b)"
Write-Host "Public RT:        $pubRtb  (lab-rtb-public)"
Write-Host "Private RT:       $privRtb  (lab-rtb-private1-us-east-1a)"
Write-Host "Security Group:   $sgId  (Web Security Group)"
Write-Host "EC2 Instance:     $instanceId  (Web Server 1)"
Write-Host ""
Write-Host ">> Open in browser: http://$publicDns" -ForegroundColor Cyan
Write-Host ""

