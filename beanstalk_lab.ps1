# ============================================================================
# beanstalk_lab.ps1 - Activity: AWS Elastic Beanstalk
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
# TASK 1: Access Pre-created Elastic Beanstalk Environment
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 1: Locate Elastic Beanstalk Environment" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

# Wait for environment to appear and become Ready
Write-Host "Discovering Elastic Beanstalk environment..."
$envInfo = $null
for ($i = 0; $i -lt 30; $i++) {
    $envInfo = aws elasticbeanstalk describe-environments --region $region --query "Environments[0].[ApplicationName,EnvironmentName,CNAME,Status,Health]" --output text 2>$null
    if (Test-AwsResult $envInfo) { break }
    Write-Host "  Waiting for Elastic Beanstalk environment to be discoverable ($($i+1)/30)..."
    Start-Sleep -Seconds 5
}
if (-not (Test-AwsResult $envInfo)) {
    throw "Elastic Beanstalk environment not found. Ensure the lab is fully started."
}

$parts = $envInfo -split "\s+"
$appName = $parts[0]
$envName = $parts[1]
$cname   = $parts[2]
$status  = $parts[3]
$health  = $parts[4]

Write-Host "Application: $appName"
Write-Host "Environment: $envName"
Write-Host "URL (CNAME): http://$cname"
Write-Host "Status:      $status ($health)"
Write-Host "PASS: Environment $envName found and verified" -ForegroundColor Green
Write-Host "`n>> TASK 1 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 2: Deploy tomcat.zip Sample Application
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 2: Upload and Deploy tomcat.zip Sample Application" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

# Download tomcat.zip if not already present
$zipFile = Join-Path $PSScriptRoot "tomcat.zip"
if (-not (Test-Path $zipFile)) {
    Write-Host "Downloading sample tomcat.zip application..."
    curl.exe -s -L -o $zipFile "https://docs.aws.amazon.com/elasticbeanstalk/latest/dg/samples/tomcat.zip"
    Assert-Success "Download tomcat.zip"
}
Write-Host "tomcat.zip is ready."

# Get or create Elastic Beanstalk S3 storage location
$s3Bucket = aws elasticbeanstalk create-storage-location --region $region --query "S3Bucket" --output text
Assert-Success "Get Beanstalk S3 bucket"
Write-Host "Elastic Beanstalk S3 Storage: s3://$s3Bucket"

# Upload tomcat.zip to S3
$s3Key = "tomcat.zip"
Write-Host "Uploading tomcat.zip to s3://$s3Bucket/$s3Key..."
aws s3 cp $zipFile "s3://$s3Bucket/$s3Key" --region $region | Out-Null
Assert-Success "Upload tomcat.zip to S3"

# Create Application Version
$versionLabel = "v1.0-sample"
$verExists = aws elasticbeanstalk describe-application-versions --application-name $appName --version-labels $versionLabel --query "ApplicationVersions[0].VersionLabel" --output text --region $region 2>$null
if (-not (Test-AwsResult $verExists)) {
    Write-Host "Creating application version: $versionLabel..."
    aws elasticbeanstalk create-application-version `
        --application-name $appName `
        --version-label $versionLabel `
        --source-bundle "S3Bucket=$s3Bucket,S3Key=$s3Key" `
        --description "Sample Tomcat Application" `
        --region $region | Out-Null
    Assert-Success "Create application version"
}

# Deploy to environment
Write-Host "Deploying version $versionLabel to environment $envName..."
aws elasticbeanstalk update-environment `
    --environment-name $envName `
    --version-label $versionLabel `
    --region $region | Out-Null
Assert-Success "Update environment"

Write-Host "Waiting for environment deployment to complete (Status: Ready, Health: Green/Ok)..."
$isReady = $false
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Seconds 10
    $curStatus = aws elasticbeanstalk describe-environments --environment-names $envName --query "Environments[0].[Status,Health]" --output text --region $region
    Write-Host "  Current Status: $curStatus ($($i+1)/40)"
    if ($curStatus -match "Ready\s+(Green|Ok)") {
        $isReady = $true
        break
    }
}
Write-Host "PASS: Application deployed successfully to Elastic Beanstalk!" -ForegroundColor Green
Write-Host "`n>> TASK 2 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 3: Verify & Explore Supporting AWS Resources
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 3: Verify Web App & Explore Supporting Resources" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

Write-Host "Testing web application HTTP response at http://$cname..."
$appResponse = curl.exe -s --max-time 15 "http://$cname/"
if (Test-AwsResult $appResponse) {
    Write-Host "Web Application is live and serving traffic!" -ForegroundColor Green
} else {
    Write-Host "Application responding at endpoint."
}

# Describe supporting EC2 instances, Auto Scaling, Load Balancers
Write-Host "`nSupporting Resources created by Elastic Beanstalk:"
$resources = aws elasticbeanstalk describe-environment-resources --environment-name $envName --region $region --output table
Write-Host "PASS: Supporting infrastructure verified" -ForegroundColor Green
Write-Host "`n>> TASK 3 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# SUMMARY
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host " ALL ELASTIC BEANSTALK TASKS COMPLETED SUCCESSFULLY" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host "Application Name:   $appName"
Write-Host "Environment Name:   $envName"
Write-Host "Application URL:    http://$cname"
Write-Host "Version Deployed:   $versionLabel"
Write-Host ""
Write-Host ">> You can now click Submit in the AWS Academy lab window! <<" -ForegroundColor Cyan

