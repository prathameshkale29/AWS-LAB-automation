# migration_lab.ps1 - Automated Migration for Challenge Lab: Migrating a Database to Amazon RDS
$ErrorActionPreference = "Stop"

# Set credentials

$env:AWS_DEFAULT_REGION = 'us-east-1'

Write-Host "=========================================================="
Write-Host "Starting Database Migration to Amazon RDS Automation"
Write-Host "=========================================================="

# 1. Discover Resources
Write-Host "`n[Step 1] Discovering Lab Resources..."
$vpcJson = aws ec2 describe-vpcs --filters "Name=tag:Name,Values='Lab VPC'" --region us-east-1 | ConvertFrom-Json
$vpcId = $vpcJson.Vpcs[0].VpcId
Write-Host "  Lab VPC ID: $vpcId"

$dbSgJson = aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpcId" "Name=group-name,Values=dbSG" --region us-east-1 | ConvertFrom-Json
$dbSgId = $dbSgJson.SecurityGroups[0].GroupId
Write-Host "  DB Security Group (dbSG): $dbSgId"

$cafeInstanceJson = aws ec2 describe-instances --filters "Name=tag:Name,Values=CafeServer" "Name=instance-state-name,Values=running" --region us-east-1 | ConvertFrom-Json
$cafeInst = $cafeInstanceJson.Reservations[0].Instances[0]
$cafeInstanceId = $cafeInst.InstanceId
$cafePublicIp = $cafeInst.PublicIpAddress
$cafeSgId = $cafeInst.SecurityGroups[0].GroupId
Write-Host "  CafeServer ID: $cafeInstanceId"
Write-Host "  CafeServer Public IP: $cafePublicIp"
Write-Host "  CafeServer SG ID: $cafeSgId"

# 2. Configure Ingress on dbSG for Port 3306
Write-Host "`n[Step 2] Authorizing Port 3306 on dbSG from CafeServer SG ($cafeSgId)..."
$existingRules = aws ec2 describe-security-groups --group-ids $dbSgId --region us-east-1 | ConvertFrom-Json
$has3306 = $false
foreach ($perm in $existingRules.SecurityGroups[0].IpPermissions) {
    if ($perm.FromPort -eq 3306 -and $perm.ToPort -eq 3306) {
        $has3306 = $true
        break
    }
}
if (-not $has3306) {
    aws ec2 authorize-security-group-ingress --group-id $dbSgId --protocol tcp --port 3306 --source-group $cafeSgId --region us-east-1 | Out-Null
    Write-Host "  Inbound rule for TCP 3306 from $cafeSgId added to dbSG."
} else {
    Write-Host "  Inbound rule for TCP 3306 already exists on dbSG."
}

# 3. Create RDS MariaDB Instance CafeDatabase
Write-Host "`n[Step 3] Checking RDS instance 'cafedatabase'..."
$dbsJson = aws rds describe-db-instances --region us-east-1 | ConvertFrom-Json
$dbExists = $false
$rdsEndpoint = ""

if ($dbsJson.DBInstances) {
    foreach ($db in $dbsJson.DBInstances) {
        if ($db.DBInstanceIdentifier -ieq "cafedatabase") {
            $dbExists = $true
            Write-Host "  Found existing RDS DB instance 'cafedatabase' (Status: $($db.DBInstanceStatus))"
            if ($db.Endpoint) {
                $rdsEndpoint = $db.Endpoint.Address
            }
            break
        }
    }
}

if (-not $dbExists) {
    Write-Host "  Creating MariaDB 10.6.25 RDS instance 'cafedatabase'..."
    aws rds create-db-instance `
        --db-instance-identifier "cafedatabase" `
        --engine "mariadb" `
        --engine-version "10.6.25" `
        --master-username "admin" `
        --master-user-password "Caf3DbPassw0rd!" `
        --db-instance-class "db.t3.micro" `
        --allocated-storage 20 `
        --storage-type "gp2" `
        --vpc-security-group-ids $dbSgId `
        --db-subnet-group-name "lab-db-subnet-group" `
        --availability-zone "us-east-1a" `
        --no-multi-az `
        --no-publicly-accessible `
        --backup-retention-period 0 `
        --region us-east-1 | Out-Null
    Write-Host "  Database creation initiated."
}

Write-Host "  Waiting for 'cafedatabase' to reach 'available' state..."
aws rds wait db-instance-available --db-instance-identifier "cafedatabase" --region us-east-1
Write-Host "  RDS instance 'cafedatabase' is AVAILABLE!"

$dbDetails = aws rds describe-db-instances --db-instance-identifier "cafedatabase" --region us-east-1 | ConvertFrom-Json
$rdsEndpoint = $dbDetails.DBInstances[0].Endpoint.Address
Write-Host "  RDS Endpoint: $rdsEndpoint"

# 4. Check subnet details for questionnaire verification
$subnets = aws ec2 describe-subnets --subnet-ids $dbDetails.DBInstances[0].DBSubnetGroup.Subnets[0].SubnetIdentifier --region us-east-1 | ConvertFrom-Json
Write-Host "`n[Questionnaire Data Check]"
Write-Host "  Subnet ID: $($subnets.Subnets[0].SubnetId)"
Write-Host "  Subnet Name: $(($subnets.Subnets[0].Tags | Where-Object Key -eq 'Name').Value)"
Write-Host "  Subnet AZ: $($subnets.Subnets[0].AvailabilityZone)"
Write-Host "  Publicly Accessible: $($dbDetails.DBInstances[0].PubliclyAccessible)"
Write-Host "  Security Groups Count: $($dbDetails.DBInstances[0].VpcSecurityGroups.Count)"

Write-Host "`n[Next Phase: Data Migration & Secrets Manager update]"
Write-Host "  Run mysqldump and restore on CafeServer pointing to: $rdsEndpoint"

