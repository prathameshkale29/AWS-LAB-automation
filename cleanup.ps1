# ============================================================================
# cleanup.ps1 - Delete all resources created by lab.ps1
# ============================================================================
$ErrorActionPreference = "Stop"
$region = "us-east-1"

function Test-AwsResult {
    param([string]$r)
    return (-not [string]::IsNullOrWhiteSpace($r)) -and ($r -ne "None") -and ($r -ne "null")
}

Write-Host "`n=== CLEANUP: Deleting Lab 2 Resources ===" -ForegroundColor Red

# 1. Terminate EC2 instance
Write-Host "`n--- EC2 Instance ---"
$instanceId = aws ec2 describe-instances --filters "Name=tag:Name,Values=Web Server 1" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query "Reservations[0].Instances[0].InstanceId" --output text --region $region 2>$null
if (Test-AwsResult $instanceId) {
    Write-Host "Terminating instance $instanceId..."
    aws ec2 terminate-instances --instance-ids $instanceId --region $region | Out-Null
    Write-Host "Waiting for termination..."
    aws ec2 wait instance-terminated --instance-ids $instanceId --region $region
    Write-Host "DONE: Instance terminated" -ForegroundColor Green
} else { Write-Host "No running instance found." }

# 2. Find VPC
$vpcId = aws ec2 describe-vpcs --filters "Name=tag:Name,Values=lab-vpc" --query "Vpcs[0].VpcId" --output text --region $region 2>$null
if (-not (Test-AwsResult $vpcId)) {
    Write-Host "`nVPC lab-vpc not found. Nothing more to clean up." -ForegroundColor Yellow
    exit 0
}
Write-Host "Found VPC: $vpcId"

# 3. Delete Security Group
Write-Host "`n--- Security Group ---"
$sgId = aws ec2 describe-security-groups --filters "Name=group-name,Values=Web Security Group" "Name=vpc-id,Values=$vpcId" --query "SecurityGroups[0].GroupId" --output text --region $region 2>$null
if (Test-AwsResult $sgId) {
    Write-Host "Deleting security group $sgId..."
    aws ec2 delete-security-group --group-id $sgId --region $region
    Write-Host "DONE" -ForegroundColor Green
} else { Write-Host "Not found." }

# 4. Delete NAT Gateway and release EIP
Write-Host "`n--- NAT Gateway ---"
$natGwId = aws ec2 describe-nat-gateways --filter "Name=tag:Name,Values=lab-nat-public1-us-east-1a" "Name=state,Values=pending,available" --query "NatGateways[0].NatGatewayId" --output text --region $region 2>$null
if (Test-AwsResult $natGwId) {
    # Grab the EIP allocation ID before deleting
    $eipAllocId = aws ec2 describe-nat-gateways --nat-gateway-ids $natGwId --query "NatGateways[0].NatGatewayAddresses[0].AllocationId" --output text --region $region
    Write-Host "Deleting NAT Gateway $natGwId..."
    aws ec2 delete-nat-gateway --nat-gateway-id $natGwId --region $region | Out-Null
    Write-Host "Waiting for NAT Gateway deletion (~2 min)..."
    do {
        Start-Sleep -Seconds 15
        $s = aws ec2 describe-nat-gateways --nat-gateway-ids $natGwId --query "NatGateways[0].State" --output text --region $region
        Write-Host "  State: $s"
    } while ($s -ne "deleted")
    # Release EIP
    if (Test-AwsResult $eipAllocId) {
        Write-Host "Releasing Elastic IP $eipAllocId..."
        aws ec2 release-address --allocation-id $eipAllocId --region $region
    }
    Write-Host "DONE" -ForegroundColor Green
} else { Write-Host "Not found (or already deleted)." }

# Also release any tagged EIPs that might be orphaned
$orphanEips = aws ec2 describe-addresses --filters "Name=tag:Name,Values=lab-nat-eip" --query "Addresses[*].AllocationId" --output text --region $region 2>$null
if (Test-AwsResult $orphanEips) {
    foreach ($a in ($orphanEips -split "\s+")) {
        if (Test-AwsResult $a) {
            Write-Host "Releasing orphan EIP $a..."
            aws ec2 release-address --allocation-id $a --region $region 2>$null
        }
    }
}

# 5. Disassociate & delete route tables
Write-Host "`n--- Route Tables ---"
foreach ($rtName in @("lab-rtb-public", "lab-rtb-private1-us-east-1a")) {
    $rtId = aws ec2 describe-route-tables --filters "Name=tag:Name,Values=$rtName" "Name=vpc-id,Values=$vpcId" --query "RouteTables[0].RouteTableId" --output text --region $region 2>$null
    if (Test-AwsResult $rtId) {
        # Disassociate explicit (non-main) associations
        $assocIds = aws ec2 describe-route-tables --route-table-ids $rtId --query "RouteTables[0].Associations[?Main==``false``].RouteTableAssociationId" --output text --region $region 2>$null
        if (Test-AwsResult $assocIds) {
            foreach ($aid in ($assocIds -split "\s+")) {
                if (Test-AwsResult $aid) {
                    Write-Host "  Disassociating $aid from $rtName..."
                    aws ec2 disassociate-route-table --association-id $aid --region $region
                }
            }
        }
        Write-Host "Deleting route table $rtId ($rtName)..."
        aws ec2 delete-route-table --route-table-id $rtId --region $region
        Write-Host "DONE" -ForegroundColor Green
    } else { Write-Host "$rtName not found." }
}

# 6. Delete subnets
Write-Host "`n--- Subnets ---"
foreach ($sn in @("lab-subnet-public1-us-east-1a","lab-subnet-private1-us-east-1a","lab-subnet-public2","lab-subnet-private2")) {
    $sid = aws ec2 describe-subnets --filters "Name=tag:Name,Values=$sn" "Name=vpc-id,Values=$vpcId" --query "Subnets[0].SubnetId" --output text --region $region 2>$null
    if (Test-AwsResult $sid) {
        Write-Host "Deleting subnet $sid ($sn)..."
        aws ec2 delete-subnet --subnet-id $sid --region $region
        Write-Host "DONE" -ForegroundColor Green
    } else { Write-Host "$sn not found." }
}

# 7. Detach & delete Internet Gateway
Write-Host "`n--- Internet Gateway ---"
$igwId = aws ec2 describe-internet-gateways --filters "Name=tag:Name,Values=lab-igw" --query "InternetGateways[0].InternetGatewayId" --output text --region $region 2>$null
if (Test-AwsResult $igwId) {
    Write-Host "Detaching IGW $igwId..."
    aws ec2 detach-internet-gateway --internet-gateway-id $igwId --vpc-id $vpcId --region $region
    Write-Host "Deleting IGW $igwId..."
    aws ec2 delete-internet-gateway --internet-gateway-id $igwId --region $region
    Write-Host "DONE" -ForegroundColor Green
} else { Write-Host "Not found." }

# 8. Delete VPC
Write-Host "`n--- VPC ---"
Write-Host "Deleting VPC $vpcId (lab-vpc)..."
aws ec2 delete-vpc --vpc-id $vpcId --region $region
Write-Host "DONE" -ForegroundColor Green

Write-Host "`n=== CLEANUP COMPLETE ===" -ForegroundColor Green

