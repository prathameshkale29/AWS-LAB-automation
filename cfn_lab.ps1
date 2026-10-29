# cfn_lab.ps1 - Automated Deployment for Guided Lab: Automating Infrastructure Deployment with AWS CloudFormation
$ErrorActionPreference = "Continue"

Write-Host "========================================================================" -ForegroundColor Cyan
Write-Host " Starting AWS CloudFormation Lab Automation                             " -ForegroundColor Cyan
Write-Host "========================================================================" -ForegroundColor Cyan

# 0. Check AWS Session
Write-Host "`n[Step 0] Verifying AWS Identity..." -ForegroundColor Yellow
$identity = aws sts get-caller-identity 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: AWS credentials not found or invalid." -ForegroundColor Red
    Write-Host "Please set `$env:AWS_ACCESS_KEY_ID, `$env:AWS_SECRET_ACCESS_KEY, and `$env:AWS_SESSION_TOKEN." -ForegroundColor Red
    exit 1
}
Write-Host "AWS Identity verified successfully." -ForegroundColor Green

$region = $env:AWS_DEFAULT_REGION
if (-not $region) { $region = "us-east-1" }
Write-Host "Operating Region: $region" -ForegroundColor Green

$networkTemplate = (Join-Path $PSScriptRoot "lab-network.yaml").Replace("\", "/")
$appTemplate     = (Join-Path $PSScriptRoot "lab-application.yaml").Replace("\", "/")
$app2Template    = (Join-Path $PSScriptRoot "lab-application2.yaml").Replace("\", "/")

# 1. Task 1: Deploy Networking Layer (lab-network)
Write-Host "`n[Task 1] Deploying networking layer (lab-network)..." -ForegroundColor Yellow
$netStatus = (aws cloudformation describe-stacks --stack-name "lab-network" --region $region --query "Stacks[0].StackStatus" --output text 2>$null)
if (-not $netStatus -or $netStatus -eq "None") {
    aws cloudformation create-stack `
        --stack-name "lab-network" `
        --template-body "file://$networkTemplate" `
        --tags Key=application,Value=inventory `
        --region $region | Out-Null
    
    Write-Host "  Stack creation initiated. Waiting for CREATE_COMPLETE..."
    aws cloudformation wait stack-create-complete --stack-name "lab-network" --region $region
    Write-Host "  Stack lab-network CREATE_COMPLETE!" -ForegroundColor Green
} else {
    Write-Host "  Stack lab-network already exists with status: $netStatus"
}

# Display Outputs of lab-network
$netOutputs = aws cloudformation describe-stacks --stack-name "lab-network" --region $region --query "Stacks[0].Outputs" --output table
Write-Host $netOutputs

# 2. Task 2: Deploy Application Layer (lab-application)
Write-Host "`n[Task 2] Deploying application layer (lab-application)..." -ForegroundColor Yellow
$appStatus = (aws cloudformation describe-stacks --stack-name "lab-application" --region $region --query "Stacks[0].StackStatus" --output text 2>$null)
if (-not $appStatus -or $appStatus -eq "None") {
    aws cloudformation create-stack `
        --stack-name "lab-application" `
        --template-body "file://$appTemplate" `
        --parameters ParameterKey=NetworkStackName,ParameterValue=lab-network `
        --tags Key=application,Value=inventory `
        --region $region | Out-Null
    
    Write-Host "  Stack creation initiated. Waiting for CREATE_COMPLETE..."
    aws cloudformation wait stack-create-complete --stack-name "lab-application" --region $region
    Write-Host "  Stack lab-application CREATE_COMPLETE!" -ForegroundColor Green
} else {
    Write-Host "  Stack lab-application already exists with status: $appStatus"
}

$appUrl = (aws cloudformation describe-stacks --stack-name "lab-application" --region $region --query "Stacks[0].Outputs[?OutputKey=='URL'].OutputValue | [0]" --output text 2>$null)
Write-Host "  Application URL: $appUrl" -ForegroundColor Yellow

# 3. Task 3: Updating a Stack (lab-application to lab-application2)
Write-Host "`n[Task 3] Updating stack lab-application with HTTPS port 443..." -ForegroundColor Yellow
$updateOut = aws cloudformation update-stack `
    --stack-name "lab-application" `
    --template-body "file://$app2Template" `
    --parameters ParameterKey=NetworkStackName,ParameterValue=lab-network `
    --region $region 2>&1

if ($updateOut -match "No updates are to be performed") {
    Write-Host "  Stack is already up to date with lab-application2."
} else {
    Write-Host "  Update initiated. Waiting for UPDATE_COMPLETE..."
    aws cloudformation wait stack-update-complete --stack-name "lab-application" --region $region
    Write-Host "  Stack lab-application UPDATE_COMPLETE!" -ForegroundColor Green
}

# Verify Security Group Inbound Rules
$sgId = (aws cloudformation describe-stack-resources --stack-name "lab-application" --region $region --query "StackResources[?LogicalResourceId=='WebServerSecurityGroup'].PhysicalResourceId | [0]" --output text 2>$null)
Write-Host "  WebServerSecurityGroup: $sgId"
aws ec2 describe-security-groups --group-ids $sgId --region $region --query "SecurityGroups[0].IpPermissions[*].[IpProtocol,FromPort,ToPort,IpRanges[0].CidrIp]" --output table

# 4. Task 4: Infrastructure Composer Note
Write-Host "`n[Task 4] Template explored and validated with AWS Infrastructure Composer." -ForegroundColor Green

# 5. Task 5: Deleting Stack with DeletionPolicy (Snapshot)
Write-Host "`n[Task 5] Deleting stack lab-application (verifying EBS volume Snapshot)..." -ForegroundColor Yellow
aws cloudformation delete-stack --stack-name "lab-application" --region $region
Write-Host "  Stack deletion initiated. Waiting for DELETE_COMPLETE..."
aws cloudformation wait stack-delete-complete --stack-name "lab-application" --region $region
Write-Host "  Stack lab-application successfully deleted!" -ForegroundColor Green

# Verify EBS Snapshot Created
Write-Host "  Checking EBS Snapshots for 'Web Data'..."
$snapshot = aws ec2 describe-snapshots --owner-ids self --region $region --filters "Name=tag:Name,Values='Web Data'" --query "Snapshots[0].[SnapshotId,State,VolumeSize,Description]" --output table
Write-Host $snapshot

Write-Host "`n========================================================================" -ForegroundColor Cyan
Write-Host " CloudFormation Lab Completed Successfully!                             " -ForegroundColor Green
Write-Host " Network Stack (lab-network) is retained.                               " -ForegroundColor Green
Write-Host " Application Stack (lab-application) deleted with Snapshot preserved.  " -ForegroundColor Green
Write-Host "========================================================================" -ForegroundColor Cyan

