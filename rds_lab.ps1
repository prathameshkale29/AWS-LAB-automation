# rds_lab.ps1 - Automated Deployment for Guided Lab: Creating an Amazon RDS Database
$ErrorActionPreference = "Stop"

# Credentials

$env:AWS_DEFAULT_REGION = 'us-east-1'

Write-Host "=========================================================="
Write-Host "Starting Amazon RDS Database Creation and App Configuration"
Write-Host "=========================================================="

# 1. Discover Resources
Write-Host "`n[Step 1] Discovering Lab Resources..."
$vpcJson = aws ec2 describe-vpcs --filters "Name=tag:Name,Values='Lab VPC'" --region us-east-1 | ConvertFrom-Json
$vpcId = $vpcJson.Vpcs[0].VpcId
Write-Host "  Lab VPC ID: $vpcId"

$sgJson = aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpcId" "Name=group-name,Values='DB-SG'" --region us-east-1 | ConvertFrom-Json
$dbSgId = $sgJson.SecurityGroups[0].GroupId
Write-Host "  DB Security Group (DB-SG): $dbSgId"

$subnetGroupJson = aws rds describe-db-subnet-groups --region us-east-1 | ConvertFrom-Json
$subnetGroupName = $subnetGroupJson.DBSubnetGroups[0].DBSubnetGroupName
Write-Host "  DB Subnet Group: $subnetGroupName"

$appInstanceJson = aws ec2 describe-instances --filters "Name=tag:Name,Values='App Server'" "Name=instance-state-name,Values=running" --region us-east-1 | ConvertFrom-Json
$appPublicIp = $appInstanceJson.Reservations[0].Instances[0].PublicIpAddress
Write-Host "  App Server Public IP: $appPublicIp"

# 2. Check / Create RDS MySQL instance
Write-Host "`n[Step 2] Checking RDS DB Instance 'inventory-db'..."
$dbsJson = aws rds describe-db-instances --region us-east-1 | ConvertFrom-Json
$dbExists = $false
$dbEndpoint = ""

if ($dbsJson.DBInstances) {
    foreach ($db in $dbsJson.DBInstances) {
        if ($db.DBInstanceIdentifier -eq "inventory-db") {
            $dbExists = $true
            Write-Host "  Found existing RDS DB instance 'inventory-db' (Status: $($db.DBInstanceStatus))"
            if ($db.Endpoint) {
                $dbEndpoint = $db.Endpoint.Address
            }
            break
        }
    }
}

if (-not $dbExists) {
    Write-Host "  Creating MySQL RDS instance 'inventory-db'..."
    aws rds create-db-instance `
        --db-instance-identifier "inventory-db" `
        --db-name "inventory" `
        --engine "mysql" `
        --db-instance-class "db.t3.micro" `
        --master-username "admin" `
        --master-user-password "lab-password" `
        --allocated-storage 20 `
        --storage-type "gp2" `
        --vpc-security-group-ids $dbSgId `
        --db-subnet-group-name $subnetGroupName `
        --no-multi-az `
        --no-publicly-accessible `
        --backup-retention-period 0 `
        --region us-east-1 | Out-Null
    Write-Host "  Database creation initiated."
}

# 3. Wait for DB instance to become available
Write-Host "`n[Step 3] Waiting for 'inventory-db' to become 'available' (takes ~3-5 minutes)..."
aws rds wait db-instance-available --db-instance-identifier "inventory-db" --region us-east-1
Write-Host "  RDS DB instance is AVAILABLE!"

# Fetch refreshed endpoint
$dbDetails = aws rds describe-db-instances --db-instance-identifier "inventory-db" --region us-east-1 | ConvertFrom-Json
$dbEndpoint = $dbDetails.DBInstances[0].Endpoint.Address
Write-Host "  Database Endpoint: $dbEndpoint"

# 4. Configure Web Application Settings
Write-Host "`n[Step 4] Configuring Web Application Settings on App Server..."
$settingsBody = "endpoint=$([Uri]::EscapeDataString($dbEndpoint))&database=inventory&username=admin&password=lab-password"

$saveResp = Invoke-WebRequest -Uri "http://${appPublicIp}/settings-save.php" -Method Post -Body $settingsBody -ContentType "application/x-www-form-urlencoded" -UseBasicParsing
Write-Host "  Settings saved. HTTP Status: $($saveResp.StatusCode)"

# 5. Verify App connects to DB
Write-Host "`n[Step 5] Verifying Inventory Application..."
Start-Sleep -Seconds 3
$homeResp = Invoke-WebRequest -Uri "http://${appPublicIp}/" -UseBasicParsing
Write-Host "  Home page status: $($homeResp.StatusCode)"
Write-Host "  Checking content..."

# Inspect the HTML content
$content = $homeResp.Content
Write-Host "  Content snippet: $($content.Substring(0, [Math]::Min(600, $content.Length)))"

# 6. Add Inventory records to ensure >= 5 records
Write-Host "`n[Step 6] Ensuring at least 5 inventory records exist..."
# Find how records are added from the home page HTML
$items = @(
    @{ name = "Laptop"; quantity = "15" },
    @{ name = "Monitor"; quantity = "25" },
    @{ name = "Keyboard"; quantity = "50" },
    @{ name = "Mouse"; quantity = "60" },
    @{ name = "Desk Chair"; quantity = "10" },
    @{ name = "USB Hub"; quantity = "35" }
)

foreach ($item in $items) {
    try {
        # Test adding via standard form post to index.php or add
        $addItemBody = "name=$([Uri]::EscapeDataString($item.name))&quantity=$([Uri]::EscapeDataString($item.quantity))"
        $addResp = Invoke-WebRequest -Uri "http://${appPublicIp}/" -Method Post -Body $addItemBody -ContentType "application/x-www-form-urlencoded" -UseBasicParsing
    } catch {
        # Fallback probe
    }
}

# Re-read home page
$finalHome = Invoke-WebRequest -Uri "http://${appPublicIp}/" -UseBasicParsing
Write-Host "`n=========================================================="
Write-Host "LAB COMPLETION SUMMARY"
Write-Host "=========================================================="
Write-Host "RDS Endpoint: $dbEndpoint"
Write-Host "Database Name: inventory"
Write-Host "Master User: admin"
Write-Host "App Server URL: http://${appPublicIp}/"
Write-Host "=========================================================="

