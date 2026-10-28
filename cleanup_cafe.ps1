# ============================================================================
# cleanup_cafe.ps1 - Clean up Challenge Lab S3 Buckets
# ============================================================================
$ErrorActionPreference = "Stop"
$region = "us-east-1"
$drRegion = "us-west-2"

function Test-AwsResult {
    param([string]$r)
    return (-not [string]::IsNullOrWhiteSpace($r)) -and ($r -ne "None") -and ($r -ne "null")
}

Write-Host "`n=== CLEANUP: Café Challenge Lab Resources ===" -ForegroundColor Red

$identity = aws sts get-caller-identity --output json | ConvertFrom-Json
$accountId = $identity.Account

$sourceBucket = "cafe-website-$accountId"
$destBucket   = "cafe-website-dr-$accountId"

# 1. Empty and delete source bucket
$b1 = aws s3api list-buckets --query "Buckets[?Name=='$sourceBucket'].Name | [0]" --output text
if (Test-AwsResult $b1) {
    Write-Host "Emptying and deleting $sourceBucket..."
    aws s3 rb "s3://$sourceBucket" --force 2>$null | Out-Null
    Write-Host "DONE: Source bucket deleted" -ForegroundColor Green
}

# 2. Empty and delete destination bucket
$b2 = aws s3api list-buckets --query "Buckets[?Name=='$destBucket'].Name | [0]" --output text
if (Test-AwsResult $b2) {
    Write-Host "Emptying and deleting $destBucket..."
    aws s3 rb "s3://$destBucket" --force 2>$null | Out-Null
    Write-Host "DONE: Destination bucket deleted" -ForegroundColor Green
}

Write-Host "`n=== CLEANUP COMPLETE ===" -ForegroundColor Green

