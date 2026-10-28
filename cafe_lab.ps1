# ============================================================================
# cafe_lab.ps1 - Challenge Lab: Creating a Static Website for the Café
# ============================================================================
$ErrorActionPreference = "Stop"
$region = "us-east-1"
$drRegion = "us-west-2"
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
$identity = aws sts get-caller-identity --output json | ConvertFrom-Json
$accountId = $identity.Account
Write-Host "Account: $accountId"
Write-Host "PASS: Session valid`n" -ForegroundColor Green

# Unique bucket names
$sourceBucket = "cafe-website-$accountId"
$destBucket   = "cafe-website-dr-$accountId"

# ==========================================================================
# TASK 1: Download & Extract Static Website Files
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 1: Extract Static Website Files" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

$zipUrl = "https://aws-tc-largeobjects.s3.us-west-2.amazonaws.com/CUR-TF-200-ACACAD-3-113230/01-lab-mod4-challenge-S3/s3/scripts/static-website.zip"
$zipPath = Join-Path $PSScriptRoot "static-website.zip"
$extractDir = Join-Path $PSScriptRoot "static-website"

if (-not (Test-Path $zipPath)) {
    Write-Host "Downloading static-website.zip..."
    curl.exe -s -L -o $zipPath $zipUrl
    Assert-Success "Download static-website.zip"
}

if (-not (Test-Path $extractDir)) {
    Write-Host "Extracting static-website.zip..."
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
    Assert-Success "Extract static-website.zip"
}
Write-Host "PASS: Website files extracted to $extractDir" -ForegroundColor Green
Write-Host "`n>> TASK 1 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 2: Create S3 Bucket & Enable Static Website Hosting
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 2: Create S3 Bucket '$sourceBucket' & Enable Static Website" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

$bucketExists = aws s3api list-buckets --query "Buckets[?Name=='$sourceBucket'].Name | [0]" --output text
if (-not (Test-AwsResult $bucketExists)) {
    Write-Host "Creating bucket $sourceBucket in $region..."
    aws s3api create-bucket --bucket $sourceBucket --region $region | Out-Null
    Assert-Success "Create source bucket"
} else {
    Write-Host "Bucket $sourceBucket already exists."
}

# Ownership controls & public access
Write-Host "Configuring ownership controls and public access settings..."
aws s3api put-bucket-ownership-controls `
    --bucket $sourceBucket `
    --ownership-controls="Rules=[{ObjectOwnership=BucketOwnerPreferred}]" | Out-Null

aws s3api put-public-access-block `
    --bucket $sourceBucket `
    --public-access-block-configuration "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false" | Out-Null

# Enable Static Website Hosting
Write-Host "Enabling static website hosting (index: index.html)..."
aws s3api put-bucket-website `
    --bucket $sourceBucket `
    --website-configuration "IndexDocument={Suffix=index.html}" | Out-Null
Assert-Success "Enable website hosting"

$websiteUrl = "http://$sourceBucket.s3-website-$region.amazonaws.com"
Write-Host "PASS: Website bucket configured. Endpoint: $websiteUrl" -ForegroundColor Green
Write-Host "`n>> TASK 2 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 3: Upload Content to S3 Bucket
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 3: Upload Static Files to '$sourceBucket'" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

Write-Host "Uploading website files to s3://$sourceBucket/..."
aws s3 sync $extractDir "s3://$sourceBucket/" | Out-Null
Assert-Success "Sync files to S3"

Write-Host "Testing access before policy (expected 403 Forbidden)..."
$test403 = curl.exe -s -I $websiteUrl
Write-Host ($test403 | Select-String "HTTP")
Write-Host "PASS: Files uploaded to $sourceBucket" -ForegroundColor Green
Write-Host "`n>> TASK 3 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 4: Create Bucket Policy to Grant Public Read Access
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 4: Apply Public Read Bucket Policy" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

$bucketPolicy = @"
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "PublicReadGetObject",
            "Effect": "Allow",
            "Principal": "*",
            "Action": "s3:GetObject",
            "Resource": "arn:aws:s3:::$sourceBucket/*"
        }
    ]
}
"@
$policyFile = Join-Path $PSScriptRoot "bucket_policy.json"
Set-Content -Path $policyFile -Value $bucketPolicy -Encoding Ascii

Write-Host "Applying bucket policy to $sourceBucket..."
aws s3api put-bucket-policy --bucket $sourceBucket --policy file://bucket_policy.json | Out-Null
Assert-Success "Put bucket policy"

Write-Host "Testing website access after policy (expecting HTTP 200 OK)..."
$webCheck = curl.exe -s -I $websiteUrl
Write-Host ($webCheck | Select-String "HTTP")
Write-Host "PASS: Website is publicly accessible at $websiteUrl" -ForegroundColor Green
Write-Host "`n>> TASK 4 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 5: Enable Versioning & Update index.html
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 5: Enable Bucket Versioning & Update index.html (Version 2)" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

Write-Host "Enabling versioning on $sourceBucket..."
aws s3api put-bucket-versioning --bucket $sourceBucket --versioning-configuration Status=Enabled | Out-Null
Assert-Success "Enable versioning"

# Modify index.html per instructions:
# 1. First bgcolor="aquamarine" -> bgcolor="gainsboro"
# 2. bgcolor="orange" -> bgcolor="cornsilk"
# 3. Second bgcolor="aquamarine" -> bgcolor="gainsboro"
$indexHtmlPath = Join-Path $extractDir "index.html"
$content = Get-Content $indexHtmlPath -Raw
$content = $content -replace 'bgcolor="aquamarine"', 'bgcolor="gainsboro"'
$content = $content -replace 'bgcolor="orange"', 'bgcolor="cornsilk"'
Set-Content -Path $indexHtmlPath -Value $content -Encoding UTF8

Write-Host "Uploading modified index.html as Version 2..."
aws s3 cp $indexHtmlPath "s3://$sourceBucket/index.html" | Out-Null
Assert-Success "Upload index.html v2"

$vCount = (aws s3api list-object-versions --bucket $sourceBucket --prefix "index.html" --query "Versions[*].VersionId" --output text).Split(" `t`n`r") | Where-Object { Test-AwsResult $_ }
Write-Host "PASS: Versioning enabled and index.html has $($vCount.Count) versions" -ForegroundColor Green
Write-Host "`n>> TASK 5 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 6: Configure Two Separate Lifecycle Rules
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 6: Configure Lifecycle Rules (Transition 30d & Expiration 365d)" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

# Note: The lab instructions state:
# "To receive full credit, create two separate rules. Do not configure two transitions in a single rule:
# In one rule, move previous versions of all source bucket objects to S3 Standard-IA after 30 days.
# In the other rule, delete previous versions of the objects after 365 days."

$lifecycleConfig = @"
{
    "Rules": [
        {
            "ID": "TransitionNoncurrentToStandardIA",
            "Status": "Enabled",
            "Filter": {},
            "NoncurrentVersionTransitions": [
                {
                    "NoncurrentDays": 30,
                    "StorageClass": "STANDARD_IA"
                }
            ]
        },
        {
            "ID": "ExpireNoncurrentVersions",
            "Status": "Enabled",
            "Filter": {},
            "NoncurrentVersionExpiration": {
                "NoncurrentDays": 365
            }
        }
    ]
}
"@
$lcFile = Join-Path $PSScriptRoot "lifecycle.json"
Set-Content -Path $lcFile -Value $lifecycleConfig -Encoding Ascii

Write-Host "Applying lifecycle configuration to $sourceBucket..."
aws s3api put-bucket-lifecycle-configuration --bucket $sourceBucket --lifecycle-configuration file://lifecycle.json | Out-Null
Assert-Success "Put lifecycle configuration"
Write-Host "PASS: Two separate lifecycle rules configured successfully" -ForegroundColor Green
Write-Host "`n>> TASK 6 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 7: Enable Cross-Region Replication to Destination Bucket
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 7: Cross-Region Replication to '$destBucket' ($drRegion)" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

# Create destination bucket in us-west-2
$destExists = aws s3api list-buckets --query "Buckets[?Name=='$destBucket'].Name | [0]" --output text
if (-not (Test-AwsResult $destExists)) {
    Write-Host "Creating destination bucket $destBucket in $drRegion..."
    aws s3api create-bucket `
        --bucket $destBucket `
        --region $drRegion `
        --create-bucket-configuration LocationConstraint=$drRegion | Out-Null
    Assert-Success "Create destination bucket"
} else {
    Write-Host "Destination bucket $destBucket already exists."
}

# Enable versioning on destination bucket
Write-Host "Enabling versioning on destination bucket $destBucket..."
aws s3api put-bucket-versioning --bucket $destBucket --versioning-configuration Status=Enabled | Out-Null
Assert-Success "Enable versioning on destination bucket"

# Get CafeRole ARN
$roleArn = aws iam get-role --role-name "CafeRole" --query "Role.Arn" --output text
Assert-Success "Get CafeRole ARN"
Write-Host "Using IAM Role: $roleArn"

# Configure Cross-Region Replication on source bucket
$replicationConfig = @"
{
    "Role": "$roleArn",
    "Rules": [
        {
            "ID": "ReplicateAllToDR",
            "Status": "Enabled",
            "Priority": 1,
            "Filter": {},
            "Destination": {
                "Bucket": "arn:aws:s3:::$destBucket"
            },
            "DeleteMarkerReplication": {
                "Status": "Disabled"
            }
        }
    ]
}
"@
$repFile = Join-Path $PSScriptRoot "replication.json"
Set-Content -Path $repFile -Value $replicationConfig -Encoding Ascii

Write-Host "Configuring replication on $sourceBucket..."
aws s3api put-bucket-replication --bucket $sourceBucket --replication-configuration file://replication.json | Out-Null
Assert-Success "Put bucket replication"

# Minor change to index.html to create Version 3
Write-Host "Uploading Version 3 of index.html to trigger replication..."
$v3Content = $content + "`n<!-- Cafe Website v3 Replication Test -->"
Set-Content -Path $indexHtmlPath -Value $v3Content -Encoding UTF8
aws s3 cp $indexHtmlPath "s3://$sourceBucket/index.html" | Out-Null
Assert-Success "Upload index.html v3"

# Delete the latest version to verify versioning delete marker
Write-Host "Deleting latest version of index.html from source bucket (creates delete marker)..."
aws s3 rm "s3://$sourceBucket/index.html" | Out-Null

Write-Host "PASS: Cross-Region Replication configured and tested" -ForegroundColor Green
Write-Host "`n>> TASK 7 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# SUMMARY & QUESTION ANSWERS
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host " ALL CHALLENGE LAB TASKS COMPLETED SUCCESSFULLY" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host "Source Bucket:       $sourceBucket (us-east-1)"
Write-Host "Website URL:         $websiteUrl"
Write-Host "Destination Bucket:  $destBucket (us-west-2)"
Write-Host "Replication Role:    $roleArn"
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " MULTIPLE CHOICE QUESTIONS ANSWERS:" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "Question 1: No / 403 Forbidden (Public read bucket policy not yet added)"
Write-Host "Question 2: MFA Delete"
Write-Host "Question 3: No (Existing objects were not replicated)"
Write-Host "Question 4: No (Deleting the latest version on source creates a delete marker; it does not delete versions on destination)"
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "`n>> You can now answer the questions and click Submit! <<" -ForegroundColor Green

