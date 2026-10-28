# dynamic_cafe_lab.ps1 - Automated Deployment for Challenge Lab: Creating a Dynamic Website for the Café
$ErrorActionPreference = "Stop"

# Set credentials

$regionEast = "us-east-1"
$regionWest = "us-west-2"

Write-Host "=========================================================="
Write-Host "Starting Dynamic Cafe Website Automation"
Write-Host "=========================================================="

# 1. Identify Lab IDE instance in us-east-1
Write-Host "`n[Step 1] Locating Lab IDE in $regionEast..."
$devInstanceJson = aws ec2 describe-instances --region $regionEast --filters "Name=tag:Name,Values='Lab IDE'" "Name=instance-state-name,Values=running" | ConvertFrom-Json
if (-not $devInstanceJson.Reservations -or $devInstanceJson.Reservations.Count -eq 0 -or -not $devInstanceJson.Reservations[0].Instances) {
    throw "Running Lab IDE instance not found in $regionEast."
}
$devInstance = $devInstanceJson.Reservations[0].Instances[0]
$devInstanceId = $devInstance.InstanceId
$devPublicIp = $devInstance.PublicIpAddress
$devPublicDns = $devInstance.PublicDnsName
$devSgId = $devInstance.SecurityGroups[0].GroupId
Write-Host "  Lab IDE ID: $devInstanceId"
Write-Host "  Public IP: $devPublicIp"
Write-Host "  Public DNS: $devPublicDns"
Write-Host "  Security Group: $devSgId"

# 2. Check / Authorize Port 8000 on Lab IDE Security Group
Write-Host "`n[Step 2] Checking port 8000 in security group $devSgId..."
$sgInfo = aws ec2 describe-security-groups --region $regionEast --group-ids $devSgId | ConvertFrom-Json
$port8000Rule = $sgInfo.SecurityGroups[0].IpPermissions | Where-Object { $_.FromPort -eq 8000 -and $_.ToPort -eq 8000 }
if (-not $port8000Rule) {
    Write-Host "  Opening port 8000 on $devSgId to 0.0.0.0/0..."
    aws ec2 authorize-security-group-ingress --group-id $devSgId --protocol tcp --port 8000 --cidr 0.0.0.0/0 --region $regionEast | Out-Null
    Write-Host "  Port 8000 opened."
} else {
    Write-Host "  Port 8000 is already open."
}

# 3. Check IAM Role Association on Lab IDE
Write-Host "`n[Step 3] Checking IAM role on Lab IDE..."
$assocJson = aws ec2 describe-iam-instance-profile-associations --region $regionEast --filters "Name=instance-id,Values=$devInstanceId" | ConvertFrom-Json
$currentProfile = ""
if ($assocJson.IamInstanceProfileAssociations -and $assocJson.IamInstanceProfileAssociations.Count -gt 0) {
    $currentProfile = $assocJson.IamInstanceProfileAssociations[0].IamInstanceProfile.Arn
    Write-Host "  Current IAM Profile: $currentProfile"
} else {
    Write-Host "  No IAM Profile currently attached."
}

if ($currentProfile -notmatch "CafeRole") {
    Write-Host "  Associating CafeRole with Lab IDE..."
    aws ec2 associate-iam-instance-profile --instance-id $devInstanceId --iam-instance-profile Name=CafeRole --region $regionEast | Out-Null
    Write-Host "  CafeRole associated successfully!"
} else {
    Write-Host "  CafeRole is already associated with Lab IDE."
}

# 4. Check whether dev site is running
Write-Host "`n[Step 4] Checking Dev Cafe website at http://${devPublicIp}:8000/cafe/..."
$devWebsiteReady = $false
try {
    $devResp = Invoke-WebRequest -Uri "http://${devPublicIp}:8000/cafe/" -UseBasicParsing -TimeoutSec 5
    if ($devResp.StatusCode -eq 200 -and ($devResp.Content -match "Cafe" -or $devResp.Content -match "Caf&eacute;")) {
        Write-Host "  Dev Cafe website is UP and responding!"
        $devWebsiteReady = $true
    }
} catch {
    Write-Host "  Dev Cafe website is not responding yet."
}

if (-not $devWebsiteReady) {
    throw "Dev Cafe website is not ready. Please verify the setup script was executed."
}

# 5. Create AMI CafeServer in us-east-1
Write-Host "`n[Step 5] Checking AMI 'CafeServer' in ${regionEast}..."
$amiEastJson = aws ec2 describe-images --region $regionEast --owners self --filters "Name=name,Values=CafeServer" | ConvertFrom-Json
$amiEastId = ""
if ($amiEastJson.Images -and $amiEastJson.Images.Count -gt 0) {
    $amiEastId = $amiEastJson.Images[0].ImageId
    Write-Host "  Found existing AMI in ${regionEast}: $amiEastId (State: $($amiEastJson.Images[0].State))"
} else {
    Write-Host "  Creating AMI 'CafeServer' from $devInstanceId in ${regionEast}..."
    $createImgJson = aws ec2 create-image --instance-id $devInstanceId --name "CafeServer" --region $regionEast | ConvertFrom-Json
    $amiEastId = $createImgJson.ImageId
    Write-Host "  Created AMI: $amiEastId"
}

# Wait for AMI to be available in us-east-1
Write-Host "  Waiting for AMI $amiEastId to become 'available' in ${regionEast}..."
aws ec2 wait image-available --image-ids $amiEastId --region $regionEast
Write-Host "  AMI $amiEastId is available!"

# 6. Copy AMI to us-west-2
Write-Host "`n[Step 6] Checking AMI 'CafeServer' in ${regionWest}..."
$amiWestJson = aws ec2 describe-images --region $regionWest --owners self --filters "Name=name,Values=CafeServer" | ConvertFrom-Json
$amiWestId = ""
if ($amiWestJson.Images -and $amiWestJson.Images.Count -gt 0) {
    $amiWestId = $amiWestJson.Images[0].ImageId
    Write-Host "  Found existing AMI in ${regionWest}: $amiWestId (State: $($amiWestJson.Images[0].State))"
} else {
    Write-Host "  Copying AMI $amiEastId from $regionEast to $regionWest as 'CafeServer'..."
    $copyImgJson = aws ec2 copy-image --source-region $regionEast --source-image-id $amiEastId --region $regionWest --name "CafeServer" | ConvertFrom-Json
    $amiWestId = $copyImgJson.ImageId
    Write-Host "  Copied AMI ID in ${regionWest}: $amiWestId"
}

# Wait for copied AMI to be available in us-west-2
Write-Host "  Waiting for AMI $amiWestId to become 'available' in ${regionWest}..."
aws ec2 wait image-available --image-ids $amiWestId --region $regionWest
Write-Host "  AMI $amiWestId is available in ${regionWest}!"

# 7. Setup Network & Security Group in us-west-2
Write-Host "`n[Step 7] Setting up Network and Security Group in ${regionWest}..."
$vpcWestJson = aws ec2 describe-vpcs --region $regionWest --filters "Name=tag:Name,Values='Lab VPC Region 2'" | ConvertFrom-Json
if (-not $vpcWestJson.Vpcs -or $vpcWestJson.Vpcs.Count -eq 0) {
    throw "VPC 'Lab VPC Region 2' not found in $regionWest."
}
$vpcWestId = $vpcWestJson.Vpcs[0].VpcId
Write-Host "  VPC: $vpcWestId"

$subnetWestJson = aws ec2 describe-subnets --region $regionWest --filters "Name=vpc-id,Values=$vpcWestId" "Name=tag:Name,Values='Public Subnet'" | ConvertFrom-Json
if (-not $subnetWestJson.Subnets -or $subnetWestJson.Subnets.Count -eq 0) {
    throw "Subnet 'Public Subnet' not found in VPC $vpcWestId."
}
$subnetWestId = $subnetWestJson.Subnets[0].SubnetId
Write-Host "  Public Subnet: $subnetWestId"

# Check or Create cafeSG
$sgWestJson = aws ec2 describe-security-groups --region $regionWest --filters "Name=vpc-id,Values=$vpcWestId" "Name=group-name,Values=cafeSG" | ConvertFrom-Json
$sgWestId = ""
if ($sgWestJson.SecurityGroups -and $sgWestJson.SecurityGroups.Count -gt 0) {
    $sgWestId = $sgWestJson.SecurityGroups[0].GroupId
    Write-Host "  Found existing Security Group 'cafeSG': $sgWestId"
} else {
    Write-Host "  Creating Security Group 'cafeSG' in $vpcWestId..."
    $newSg = aws ec2 create-security-group --group-name "cafeSG" --description "SG for Cafe Server (Ports 22 and 8000)" --vpc-id $vpcWestId --region $regionWest | ConvertFrom-Json
    $sgWestId = $newSg.GroupId
    Write-Host "  Created Security Group: $sgWestId"
    
    Write-Host "  Adding ingress rules: Port 22 and Port 8000 from 0.0.0.0/0..."
    aws ec2 authorize-security-group-ingress --group-id $sgWestId --protocol tcp --port 22 --cidr 0.0.0.0/0 --region $regionWest | Out-Null
    aws ec2 authorize-security-group-ingress --group-id $sgWestId --protocol tcp --port 8000 --cidr 0.0.0.0/0 --region $regionWest | Out-Null
}

# 8. Launch ProdCafeServer in us-west-2
Write-Host "`n[Step 8] Checking ProdCafeServer instance in ${regionWest}..."
$prodInstanceJson = aws ec2 describe-instances --region $regionWest --filters "Name=tag:Name,Values=ProdCafeServer" "Name=instance-state-name,Values=running,pending" | ConvertFrom-Json
$prodInstanceId = ""
$prodPublicDns = ""
$prodPublicIp = ""

if ($prodInstanceJson.Reservations -and $prodInstanceJson.Reservations.Count -gt 0 -and $prodInstanceJson.Reservations[0].Instances.Count -gt 0) {
    $prodInst = $prodInstanceJson.Reservations[0].Instances[0]
    $prodInstanceId = $prodInst.InstanceId
    $prodPublicDns = $prodInst.PublicDnsName
    $prodPublicIp = $prodInst.PublicIpAddress
    Write-Host "  Found existing ProdCafeServer: $prodInstanceId (State: $($prodInst.State.Name))"
} else {
    Write-Host "  Launching ProdCafeServer instance in ${regionWest}..."
    $runInstJson = aws ec2 run-instances `
        --image-id $amiWestId `
        --count 1 `
        --instance-type t2.small `
        --subnet-id $subnetWestId `
        --security-group-ids $sgWestId `
        --iam-instance-profile Name=CafeRole `
        --associate-public-ip-address `
        --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=ProdCafeServer}]' `
        --region $regionWest | ConvertFrom-Json
        
    $prodInstanceId = $runInstJson.Instances[0].InstanceId
    Write-Host "  Launched instance: $prodInstanceId"
}

# Wait for instance running
Write-Host "  Waiting for ProdCafeServer to reach 'running' state..."
aws ec2 wait instance-running --instance-ids $prodInstanceId --region $regionWest

# Fetch refreshed Public DNS & IP
$refreshedProd = aws ec2 describe-instances --instance-ids $prodInstanceId --region $regionWest | ConvertFrom-Json
$prodInstObj = $refreshedProd.Reservations[0].Instances[0]
$prodPublicDns = $prodInstObj.PublicDnsName
$prodPublicIp = $prodInstObj.PublicIpAddress
Write-Host "  ProdCafeServer is RUNNING!"
Write-Host "  Public IP: $prodPublicIp"
Write-Host "  Public DNS: $prodPublicDns"

# 9. Create Secrets Manager Secrets in us-west-2
Write-Host "`n[Step 9] Creating application secrets in Secrets Manager (${regionWest})..."
$secrets = @{
    "/cafe/showServerInfo" = "false"
    "/cafe/timeZone"       = "America/New_York"
    "/cafe/currency"       = "$"
    "/cafe/dbUrl"          = $prodPublicDns
    "/cafe/dbName"         = "cafe_db"
    "/cafe/dbUser"         = "admin"
    "/cafe/dbPassword"     = "Lab123#"
}

foreach ($key in $secrets.Keys) {
    $val = $secrets[$key]
    # Check if secret exists
    $existing = aws secretsmanager list-secrets --region $regionWest --filters "Key=name,Values=$key" | ConvertFrom-Json
    if ($existing.SecretList -and $existing.SecretList.Count -gt 0) {
        Write-Host "  Updating existing secret: $key"
        aws secretsmanager put-secret-value --secret-id $key --secret-string "$val" --region $regionWest | Out-Null
    } else {
        Write-Host "  Creating secret: $key"
        aws secretsmanager create-secret --name "$key" --secret-string "$val" --region $regionWest | Out-Null
    }
}
Write-Host "  All 7 Secrets Manager parameters configured in ${regionWest}!"

# 10. Verify Prod Cafe Website
Write-Host "`n[Step 10] Verifying Production Website at http://${prodPublicIp}:8000/..."
$rootOk = $false
for ($i = 1; $i -le 15; $i++) {
    try {
        $rootResp = Invoke-WebRequest -Uri "http://${prodPublicIp}:8000/" -UseBasicParsing -TimeoutSec 5
        if ($rootResp.StatusCode -eq 200) {
            Write-Host "  Root page (http://${prodPublicIp}:8000/) responded 200 OK!"
            $rootOk = $true
            break
        }
    } catch {
        Write-Host "  Waiting for web server to start... ($i/15)"
        Start-Sleep -Seconds 5
    }
}

Write-Host "Verifying Production Cafe Website at http://${prodPublicIp}:8000/cafe/..."
$cafeOk = $false
for ($i = 1; $i -le 15; $i++) {
    try {
        $cafeResp = Invoke-WebRequest -Uri "http://${prodPublicIp}:8000/cafe/" -UseBasicParsing -TimeoutSec 5
        if ($cafeResp.StatusCode -eq 200 -and ($cafeResp.Content -match "Cafe" -or $cafeResp.Content -match "Caf&eacute;")) {
            Write-Host "  Production Cafe Website is LIVE and accessible!"
            $cafeOk = $true
            break
        }
    } catch {
        Write-Host "  Waiting for cafe application to respond... ($i/15)"
        Start-Sleep -Seconds 5
    }
}

# 11. Test placing an order on Prod
Write-Host "`n[Step 11] Placing a test order on Production Cafe..."
try {
    $body = 'productId%5B%5D=1&productName%5B%5D=Croissant&price%5B%5D=1.50&quantity%5B%5D=2&date=' + [Uri]::EscapeDataString((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
    $orderResp = Invoke-WebRequest -Uri "http://${prodPublicIp}:8000/cafe/processOrder.php" -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing
    if ($orderResp.StatusCode -eq 200) {
        Write-Host "  Production order placed successfully!"
    }
} catch {
    Write-Warning "  Order placement note: $_"
}

Write-Host "`n=========================================================="
Write-Host "DEPLOYMENT VERIFICATION SUMMARY"
Write-Host "=========================================================="
Write-Host "Dev Instance (us-east-1):"
Write-Host "  ID: $devInstanceId"
Write-Host "  Dev URL: http://${devPublicIp}:8000/cafe/"
Write-Host "Prod Instance (us-west-2):"
Write-Host "  ID: $prodInstanceId"
Write-Host "  Prod URL: http://${prodPublicIp}:8000/cafe/"
Write-Host "AMI Details:"
Write-Host "  us-east-1 AMI: $amiEastId"
Write-Host "  us-west-2 AMI: $amiWestId"
Write-Host "=========================================================="
