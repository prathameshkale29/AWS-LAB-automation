# ============================================================================
# cleanup_lambda.ps1 - Clean up Lambda function and EventBridge rule
# ============================================================================
$ErrorActionPreference = "Stop"
$region = "us-east-1"

function Test-AwsResult {
    param([string]$r)
    return (-not [string]::IsNullOrWhiteSpace($r)) -and ($r -ne "None") -and ($r -ne "null")
}

Write-Host "`n=== CLEANUP: Lambda Lab Resources ===" -ForegroundColor Red

# 1. Remove targets and delete EventBridge rule
Write-Host "Removing targets from rule everyMinute..."
aws events remove-targets --rule "everyMinute" --ids 1 --region $region 2>$null | Out-Null
Write-Host "Deleting EventBridge rule everyMinute..."
aws events delete-rule --name "everyMinute" --region $region 2>$null | Out-Null
Write-Host "DONE: Rule deleted" -ForegroundColor Green

# 2. Delete Lambda function
Write-Host "Deleting Lambda function myStopinator..."
aws lambda delete-function --function-name "myStopinator" --region $region 2>$null | Out-Null
Write-Host "DONE: Function deleted" -ForegroundColor Green

Write-Host "`n=== CLEANUP COMPLETE ===" -ForegroundColor Green

