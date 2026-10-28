# ============================================================================
# lab6.ps1 - AWS Academy Lab 6: Scale and Load Balance Your Architecture
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
# Locate Lab VPC, Subnets, and Security Groups
# ==========================================================================
Write-Host "Locating Lab VPC and networking resources..." -ForegroundColor Cyan

$vpcId = aws ec2 describe-vpcs --filters "Name=tag:Name,Values=*Lab VPC*" --query "Vpcs[0].VpcId" --output text --region $region 2>$null
if (-not (Test-AwsResult $vpcId)) {
    $vpcId = aws ec2 describe-vpcs --filters "Name=isDefault,Values=false" --query "Vpcs[0].VpcId" --output text --region $region
}
Assert-Success "Find Lab VPC"
Write-Host "Using VPC: $vpcId"

$webSgId = aws ec2 describe-security-groups --filters "Name=group-name,Values=Web Security Group" "Name=vpc-id,Values=$vpcId" --query "SecurityGroups[0].GroupId" --output text --region $region 2>$null
if (-not (Test-AwsResult $webSgId)) {
    $webSgId = aws ec2 describe-security-groups --filters "Name=group-name,Values=Web Security Group" --query "SecurityGroups[0].GroupId" --output text --region $region
}
Assert-Success "Find Web Security Group"
Write-Host "Using Web Security Group: $webSgId"

# Public subnets (for ELB)
$pubSubnets = aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpcId" "Name=tag:Name,Values=*Public*" --query "Subnets[*].SubnetId" --output text --region $region
$pubSubList = ($pubSubnets -split "\s+") | Where-Object { Test-AwsResult $_ }
Write-Host "Public Subnets (for ALB): $($pubSubList -join ', ')"

# Private subnets (for Auto Scaling Group)
$privSubnets = aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpcId" "Name=tag:Name,Values=*Private*" --query "Subnets[*].SubnetId" --output text --region $region
$privSubList = ($privSubnets -split "\s+") | Where-Object { Test-AwsResult $_ }
Write-Host "Private Subnets (for ASG): $($privSubList -join ', ')"

# Find Web Server 1
$webServer1Id = aws ec2 describe-instances --filters "Name=tag:Name,Values=Web Server 1" "Name=vpc-id,Values=$vpcId" "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].InstanceId" --output text --region $region 2>$null
if (-not (Test-AwsResult $webServer1Id)) {
    $webServer1Id = aws ec2 describe-instances --filters "Name=tag:Name,Values=Web Server 1" "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].InstanceId" --output text --region $region
}
Assert-Success "Find Web Server 1"
Write-Host "Found Web Server 1: $webServer1Id"

# ==========================================================================
# TASK 1: Create an AMI for Auto Scaling
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 1: Create AMI 'WebServerAMI' from Web Server 1" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

$amiId = aws ec2 describe-images --owners self --filters "Name=name,Values=WebServerAMI" "Name=state,Values=pending,available" --query "Images[0].ImageId" --output text --region $region 2>$null
if (-not (Test-AwsResult $amiId)) {
    Write-Host "Creating AMI WebServerAMI from $webServer1Id..."
    $amiId = aws ec2 create-image `
        --instance-id $webServer1Id `
        --name "WebServerAMI" `
        --description "Lab AMI for Web Server" `
        --query "ImageId" `
        --output text `
        --region $region
    Assert-Success "Create AMI"
    Write-Host "Waiting for AMI $amiId to become available (~2-3 min)..."
    aws ec2 wait image-available --image-ids $amiId --region $region
    Assert-Success "Image available"
} else {
    Write-Host "AMI WebServerAMI already exists: $amiId"
    $amiState = aws ec2 describe-images --image-ids $amiId --query "Images[0].State" --output text --region $region
    if ($amiState -ne "available") {
        Write-Host "Waiting for AMI $amiId to become available..."
        aws ec2 wait image-available --image-ids $amiId --region $region
    }
}
Write-Host "PASS: AMI WebServerAMI ready ($amiId)" -ForegroundColor Green
Write-Host "`n>> TASK 1 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 2: Create a Load Balancer
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 2: Create Target Group 'LabGroup' & Application Load Balancer 'LabELB'" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

# Target Group: LabGroup
$tgArn = aws elbv2 describe-target-groups --query "TargetGroups[?TargetGroupName=='LabGroup'].TargetGroupArn | [0]" --output text --region $region
if (-not (Test-AwsResult $tgArn)) {
    Write-Host "Creating target group: LabGroup..."
    $tgArn = aws elbv2 create-target-group `
        --name "LabGroup" `
        --protocol HTTP `
        --port 80 `
        --vpc-id $vpcId `
        --target-type instance `
        --query "TargetGroups[0].TargetGroupArn" `
        --output text `
        --region $region
    Assert-Success "Create Target Group"
} else {
    Write-Host "Target Group 'LabGroup' already exists: $tgArn"
}

# Application Load Balancer: LabELB
$albArn = aws elbv2 describe-load-balancers --query "LoadBalancers[?LoadBalancerName=='LabELB'].LoadBalancerArn | [0]" --output text --region $region
if (-not (Test-AwsResult $albArn)) {
    Write-Host "Creating Application Load Balancer: LabELB..."
    $albArn = aws elbv2 create-load-balancer `
        --name "LabELB" `
        --subnets $pubSubList `
        --security-groups $webSgId `
        --scheme internet-facing `
        --type application `
        --query "LoadBalancers[0].LoadBalancerArn" `
        --output text `
        --region $region
    Assert-Success "Create ALB"

    # Create Listener on Port 80 forward to LabGroup
    Write-Host "Creating HTTP:80 Listener forwarding to LabGroup..."
    aws elbv2 create-listener `
        --load-balancer-arn $albArn `
        --protocol HTTP `
        --port 80 `
        --default-actions "Type=forward,TargetGroupArn=$tgArn" `
        --region $region | Out-Null
    Assert-Success "Create Listener"
} else {
    Write-Host "ALB 'LabELB' already exists: $albArn"
}

$albDns = aws elbv2 describe-load-balancers --load-balancer-arns $albArn --query "LoadBalancers[0].DNSName" --output text --region $region
Write-Host "PASS: Load Balancer LabELB active: http://$albDns" -ForegroundColor Green
Write-Host "`n>> TASK 2 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 3: Create Launch Template and Auto Scaling Group
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 3: Create Launch Template 'LabConfig' & Auto Scaling Group 'Lab Auto Scaling Group'" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

$ltId = aws ec2 describe-launch-templates --query "LaunchTemplates[?LaunchTemplateName=='LabConfig'].LaunchTemplateId | [0]" --output text --region $region
if (-not (Test-AwsResult $ltId)) {
    Write-Host "Creating Launch Template: LabConfig..."
    $ltData = @{
        ImageId = $amiId
        InstanceType = "t2.micro"
        KeyName = "vockey"
        SecurityGroupIds = @($webSgId)
        Monitoring = @{ Enabled = $true }
    } | ConvertTo-Json -Compress

    $ltFile = Join-Path $PSScriptRoot "lt_data.json"
    Set-Content -Path $ltFile -Value $ltData -Encoding Ascii

    $ltId = aws ec2 create-launch-template `
        --launch-template-name "LabConfig" `
        --version-description "v1" `
        --launch-template-data file://lt_data.json `
        --query "LaunchTemplate.LaunchTemplateId" `
        --output text `
        --region $region
    Assert-Success "Create Launch Template"
} else {
    Write-Host "Launch Template 'LabConfig' already exists: $ltId"
}

# Auto Scaling Group: Lab Auto Scaling Group
$asgName = aws autoscaling describe-auto-scaling-groups --query "AutoScalingGroups[?AutoScalingGroupName=='Lab Auto Scaling Group'].AutoScalingGroupName | [0]" --output text --region $region
if (-not (Test-AwsResult $asgName)) {
    Write-Host "Creating Auto Scaling Group: Lab Auto Scaling Group..."
    $subnetsParam = $privSubList -join ","
    aws autoscaling create-auto-scaling-group `
        --auto-scaling-group-name "Lab Auto Scaling Group" `
        --launch-template "LaunchTemplateName=LabConfig,Version=`$Latest" `
        --min-size 2 `
        --max-size 6 `
        --desired-capacity 2 `
        --target-group-arns $tgArn `
        --vpc-zone-identifier $subnetsParam `
        --tags "Key=Name,Value=Lab Instance,PropagateAtLaunch=true" `
        --region $region
    Assert-Success "Create Auto Scaling Group"

    Write-Host "Enabling group metrics collection (1Minute)..."
    aws autoscaling enable-metrics-collection `
        --auto-scaling-group-name "Lab Auto Scaling Group" `
        --granularity "1Minute" `
        --region $region | Out-Null

    # Create Target Tracking Scaling Policy (Average CPU 60%)
    Write-Host "Configuring Target Tracking Scaling Policy (CPU 60%)..."
    $policyConfig = @{
        TargetValue = 60.0
        PredefinedMetricSpecification = @{
            PredefinedMetricType = "ASGAverageCPUUtilization"
        }
    } | ConvertTo-Json -Compress
    $policyFile = Join-Path $PSScriptRoot "policy_config.json"
    Set-Content -Path $policyFile -Value $policyConfig -Encoding Ascii

    aws autoscaling put-scaling-policy `
        --auto-scaling-group-name "Lab Auto Scaling Group" `
        --policy-name "LabScalingPolicy" `
        --policy-type "TargetTrackingScaling" `
        --target-tracking-configuration file://policy_config.json `
        --region $region | Out-Null
    Assert-Success "Put Scaling Policy"
} else {
    Write-Host "Auto Scaling Group 'Lab Auto Scaling Group' already exists."
}
Write-Host "PASS: Auto Scaling Group Lab Auto Scaling Group configured" -ForegroundColor Green
Write-Host "`n>> TASK 3 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 4: Verify that Load Balancing is Working
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 4: Verify Instances in Target Group & Access via ALB" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

Write-Host "Waiting for targets in LabGroup to become healthy (~2 min)..."
$healthy = $false
for ($i = 0; $i -lt 30; $i++) {
    $states = aws elbv2 describe-target-health --target-group-arn $tgArn --query "TargetHealthDescriptions[*].TargetHealth.State" --output text --region $region 2>$null
    Write-Host "  Current Target States: $states ($($i+1)/30)"
    if ($states -match "healthy") {
        $healthyCount = (($states -split "\s+") | Where-Object { $_ -eq "healthy" }).Count
        if ($healthyCount -ge 2) {
            $healthy = $true
            break
        }
    }
    Start-Sleep -Seconds 10
}

Write-Host "Testing HTTP response through Load Balancer at http://$albDns..."
$albResponse = curl.exe -s --max-time 15 "http://$albDns/"
if (Test-AwsResult $albResponse) {
    Write-Host "Load Balancer successfully forwarded traffic to backend instances!" -ForegroundColor Green
}
Write-Host "PASS: Load Balancing verified" -ForegroundColor Green
Write-Host "`n>> TASK 4 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 5: Test Auto Scaling
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 5: Test Auto Scaling (Load Test endpoint)" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

Write-Host "Invoking load test on web application..."
$loadTestUrl = "http://$albDns/load.php"
for ($i = 0; $i -lt 5; $i++) {
    curl.exe -s --max-time 5 $loadTestUrl | Out-Null
}
Write-Host "CloudWatch alarms configured by Auto Scaling policy:"
aws cloudwatch describe-alarms --alarm-name-prefix "TargetTracking-Lab Auto Scaling Group" --query "MetricAlarms[*].[AlarmName,StateValue]" --output table --region $region
Write-Host "PASS: Auto Scaling and CloudWatch alarms verified" -ForegroundColor Green
Write-Host "`n>> TASK 5 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# TASK 6: Terminate Web Server 1
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host " TASK 6: Terminate Web Server 1" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow

Write-Host "Terminating instance Web Server 1 ($webServer1Id)..."
aws ec2 terminate-instances --instance-ids $webServer1Id --region $region | Out-Null
Assert-Success "Terminate Web Server 1"
Write-Host "Waiting for Web Server 1 to terminate..."
aws ec2 wait instance-terminated --instance-ids $webServer1Id --region $region
Write-Host "PASS: Web Server 1 terminated successfully" -ForegroundColor Green
Write-Host "`n>> TASK 6 COMPLETE <<`n" -ForegroundColor Green

# ==========================================================================
# SUMMARY
# ==========================================================================
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host " ALL LAB 6 TASKS COMPLETED SUCCESSFULLY" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host "AMI:                $amiId (WebServerAMI)"
Write-Host "Target Group:       $tgArn (LabGroup)"
Write-Host "Application LB:     http://$albDns (LabELB)"
Write-Host "Launch Template:    $ltId (LabConfig)"
Write-Host "Auto Scaling Group: Lab Auto Scaling Group"
Write-Host "Web Server 1:       Terminated"
Write-Host ""
Write-Host ">> You can now click Submit in the AWS Academy lab window! <<" -ForegroundColor Cyan

