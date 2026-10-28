# ============================================================================
# lambda_lab.ps1 - Activity: AWS Lambda (myStopinator)
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
# Locate instance1 and IAM Role myStopinatorRole
# ==========================================================================
Write-Host "Locating EC2 instance 'instance1' and IAM role 'myStopinatorRole'..." -ForegroundColor Cyan

$instanceId = aws ec2 describe-instances --filters "Name=tag:Name,Values=instance1" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query "Reservations[0].Instances[0].InstanceId" --output text --region $region
if (-not (Test-AwsResult $instanceId)) {
    throw "EC2 instance with tag Name='instance1' not found. Please ensure the lab is fully started."
}
$instState = aws ec2 describe-instances --instance-ids $instanceId --query "Reservations[0].Instances[0].State.Name" --output text --region $region
Write-Host "Found instance1: $instanceId (Current State: $instState)"

# If instance1 is stopped, start it so the stopinator can demonstrate stopping it
if ($instState -eq "stopped") {
    Write-Host "Starting instance1 so the stopinator function can stop it..."
    aws ec2 start-instances --instance-ids $instanceId --region $region | Out-Null
    aws ec2 wait instance-running --instance-ids $instanceId --region $region
    Write-Host "instance1 is now running."
}

# Lookup Role ARN
$roleArn = aws iam get-role --role-name "myStopinatorRole" --query "Role.Arn" --output text 2>$null
if (-not (Test-AwsResult $roleArn)) {
    # Check if role is listed with different casing or prefix
    $roleArn = aws iam list-roles --query "Roles[?contains(RoleName, 'myStopinatorRole')].Arn | [0]" --output text
}
Assert-Success "Get myStopinatorRole ARN"
Write-Host "Found IAM Role: $roleArn"

# ==========================================================================
# TASK 1 & 3: Create & Configure Lambda Function 'myStopinator'
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 1 & 3: Create & Deploy Lambda Function 'myStopinator'" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

# Generate lambda_function.py
$pyCode = @"
import boto3
region = '$region'
instances = ['$instanceId']
ec2 = boto3.client('ec2', region_name=region)

def lambda_handler(event, context):
    ec2.stop_instances(InstanceIds=instances)
    print('stopped your instances: ' + str(instances))
"@

$pyFile = Join-Path $PSScriptRoot "lambda_function.py"
Set-Content -Path $pyFile -Value $pyCode -Encoding Ascii
Write-Host "Generated lambda_function.py targeting instance $instanceId in $region."

# Create zip file
$zipFile = Join-Path $PSScriptRoot "lambda_function.zip"
if (Test-Path $zipFile) { Remove-Item $zipFile -Force }
Compress-Archive -Path $pyFile -DestinationPath $zipFile -Force
Write-Host "Packaged lambda_function.zip."

$fnArn = aws lambda list-functions --query "Functions[?FunctionName=='myStopinator'].FunctionArn | [0]" --output text --region $region
if (-not (Test-AwsResult $fnArn)) {
    Write-Host "Creating Lambda function: myStopinator (Python 3.11)..."
    $fnArn = aws lambda create-function `
        --function-name "myStopinator" `
        --runtime "python3.11" `
        --role $roleArn `
        --handler "lambda_function.lambda_handler" `
        --zip-file "fileb://lambda_function.zip" `
        --description "Stops EC2 instance instance1 every minute" `
        --timeout 15 `
        --query "FunctionArn" `
        --output text `
        --region $region
    Assert-Success "Create Lambda function"
    Write-Host "Waiting for function to be active..."
    aws lambda wait function-active-v2 --function-name "myStopinator" --region $region 2>$null
} else {
    Write-Host "Lambda function 'myStopinator' already exists. Updating code..."
    aws lambda update-function-code `
        --function-name "myStopinator" `
        --zip-file "fileb://lambda_function.zip" `
        --region $region | Out-Null
    Assert-Success "Update Lambda code"
}
Write-Host "PASS: Lambda function myStopinator deployed ($fnArn)" -ForegroundColor Green
Write-Host "`n>> TASK 1 & 3 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 2: Configure EventBridge Trigger 'everyMinute'
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 2: Configure EventBridge Rule 'everyMinute' [rate(1 minute)]" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

# Create EventBridge rule: everyMinute
Write-Host "Creating/updating EventBridge rule 'everyMinute'..."
$ruleArn = aws events put-rule `
    --name "everyMinute" `
    --schedule-expression "rate(1 minute)" `
    --state "ENABLED" `
    --description "Trigger myStopinator every minute" `
    --query "RuleArn" `
    --output text `
    --region $region
Assert-Success "Put EventBridge rule"
Write-Host "EventBridge Rule: $ruleArn"

# Grant EventBridge permission to invoke the Lambda function
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$permCheck = aws lambda get-policy --function-name "myStopinator" --query "Policy" --output text --region $region 2>$null
$ErrorActionPreference = $prevEAP

if ($permCheck -notmatch "everyMinute") {
    Write-Host "Adding invoke permission for EventBridge..."
    aws lambda add-permission `
        --function-name "myStopinator" `
        --statement-id "everyMinuteTrigger" `
        --action "lambda:InvokeFunction" `
        --principal "events.amazonaws.com" `
        --source-arn $ruleArn `
        --region $region | Out-Null
    Assert-Success "Add Lambda permission"
} else {
    Write-Host "EventBridge invoke permission already present on Lambda function."
}

# Attach Lambda as target of the rule
Write-Host "Setting Lambda myStopinator as target for rule 'everyMinute'..."
aws events put-targets `
    --rule "everyMinute" `
    --targets "Id=1,Arn=$fnArn" `
    --region $region | Out-Null
Assert-Success "Put target"

Write-Host "PASS: EventBridge trigger configured and enabled" -ForegroundColor Green
Write-Host "`n>> TASK 2 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 4: Verify that the Lambda function worked
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 4: Verify Lambda Function Stops instance1" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

Write-Host "Invoking Lambda function directly once to verify execution..."
$respFile = Join-Path $PSScriptRoot "response.json"
aws lambda invoke --function-name "myStopinator" --region $region $respFile | Out-Null
Assert-Success "Direct invoke"
if (Test-Path $respFile) {
    Get-Content $respFile
}

Write-Host "Waiting for instance1 ($instanceId) to reach 'stopped' state..."
aws ec2 wait instance-stopped --instance-ids $instanceId --region $region
Assert-Success "Wait for instance stopped"

$finalState = aws ec2 describe-instances --instance-ids $instanceId --query "Reservations[0].Instances[0].State.Name" --output text --region $region
Write-Host "PASS: instance1 successfully stopped by myStopinator! State: $finalState" -ForegroundColor Green
Write-Host "`n>> TASK 4 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# SUMMARY
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host " ALL AWS LAMBDA TASKS COMPLETED SUCCESSFULLY" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host "EC2 Target:         $instanceId (instance1)"
Write-Host "IAM Role:           myStopinatorRole"
Write-Host "Lambda Function:    myStopinator (Python 3.11)"
Write-Host "EventBridge Rule:   everyMinute (rate(1 minute))"
Write-Host "Final EC2 State:    $finalState"
Write-Host ""
Write-Host ">> You can now click Submit in the AWS Academy lab window! <<" -ForegroundColor Cyan

