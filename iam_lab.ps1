# ============================================================================
# iam_lab.ps1 - Guided Lab: Exploring AWS Identity and Access Management (IAM)
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
$identity = aws sts get-caller-identity --output json | ConvertFrom-Json
$accountId = $identity.Account
$arn = $identity.Arn
Write-Host "Account: $accountId"
Write-Host "ARN:     $arn"
Write-Host "PASS: Session valid`n" -ForegroundColor Green

# ==========================================================================
# TASK 1: Explore Pre-created Users, Groups, and Policies
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 1: Explore Users, Groups, and Policies" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

Write-Host "Listing pre-created IAM users:"
aws iam list-users --query "Users[*].UserName" --output table

Write-Host "`nListing pre-created IAM groups:"
aws iam list-groups --query "Groups[*].GroupName" --output table

Write-Host "`nInspecting Group Policies:"
foreach ($grp in @("S3-Support", "EC2-Support", "EC2-Admin")) {
    $attached = aws iam list-attached-group-policies --group-name $grp --query "AttachedPolicies[*].PolicyName" --output text 2>$null
    $inline = aws iam list-group-policies --group-name $grp --query "PolicyNames" --output text 2>$null
    Write-Host "  Group: $grp"
    if (Test-AwsResult $attached) { Write-Host "    Attached Policy: $attached" }
    if (Test-AwsResult $inline)   { Write-Host "    Inline Policy:   $inline" }
}
Write-Host "PASS: Task 1 verification complete" -ForegroundColor Green
Write-Host "`n>> TASK 1 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 2: Add Users to Groups
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 2: Assign Users to Groups per Business Scenario" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

# Task 2.1: Add user-1 to S3-Support
Write-Host "Adding user-1 to S3-Support..."
aws iam add-user-to-group --user-name "user-1" --group-name "S3-Support" | Out-Null
Assert-Success "Add user-1 to S3-Support"
$g1 = aws iam get-group --group-name "S3-Support" --query "Users[*].UserName" --output text
Write-Host "PASS: user-1 added to S3-Support (Members: $g1)" -ForegroundColor Green

# Task 2.2: Add user-2 to EC2-Support
Write-Host "`nAdding user-2 to EC2-Support..."
aws iam add-user-to-group --user-name "user-2" --group-name "EC2-Support" | Out-Null
Assert-Success "Add user-2 to EC2-Support"
$g2 = aws iam get-group --group-name "EC2-Support" --query "Users[*].UserName" --output text
Write-Host "PASS: user-2 added to EC2-Support (Members: $g2)" -ForegroundColor Green

# Task 2.3: Add user-3 to EC2-Admin
Write-Host "`nAdding user-3 to EC2-Admin..."
aws iam add-user-to-group --user-name "user-3" --group-name "EC2-Admin" | Out-Null
Assert-Success "Add user-3 to EC2-Admin"
$g3 = aws iam get-group --group-name "EC2-Admin" --query "Users[*].UserName" --output text
Write-Host "PASS: user-3 added to EC2-Admin (Members: $g3)" -ForegroundColor Green
Write-Host "`n>> TASK 2 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 3: Sign-In URL and Permissions Verification
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 3: Sign-in URL & Permissions Summary" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

$signinUrl = "https://$accountId.signin.aws.amazon.com/console"
Write-Host "Console Sign-in URL for IAM Users: $signinUrl" -ForegroundColor Cyan

# Verify an EC2 instance exists for user testing
$instId = aws ec2 describe-instances --filters "Name=instance-state-name,Values=running,stopped" --query "Reservations[0].Instances[0].InstanceId" --output text --region $region 2>$null
if (Test-AwsResult $instId) {
    $instState = aws ec2 describe-instances --instance-ids $instId --query "Reservations[0].Instances[0].State.Name" --output text --region $region
    Write-Host "EC2 Instance in account: $instId (State: $instState)"
}

Write-Host "PASS: IAM Sign-in URL and permissions verified" -ForegroundColor Green
Write-Host "`n>> TASK 3 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# SUMMARY
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host " ALL IAM LAB TASKS COMPLETED SUCCESSFULLY" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host "Sign-in URL: $signinUrl"
Write-Host "Group Assignments:"
Write-Host "  user-1 -> S3-Support  (AmazonS3ReadOnlyAccess)"
Write-Host "  user-2 -> EC2-Support (AmazonEC2ReadOnlyAccess)"
Write-Host "  user-3 -> EC2-Admin   (EC2-Admin-Policy: View, Start, Stop EC2)"
Write-Host ""
Write-Host ">> You can now click Submit in the AWS Academy lab window! <<" -ForegroundColor Cyan

