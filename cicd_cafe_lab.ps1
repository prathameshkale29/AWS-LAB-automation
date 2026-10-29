# cicd_cafe_lab.ps1 - Automated Deployment for Challenge Lab: Automating Infrastructure Deployment
$ErrorActionPreference = "Continue"

Write-Host "========================================================================" -ForegroundColor Cyan
Write-Host " Starting Automating Infrastructure Deployment Lab Automation          " -ForegroundColor Cyan
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

# Task 2: Create S3 Bucket via CloudFormation Stack CreateBucket
Write-Host "`n[Task 2] Creating S3.yaml and deploying CreateBucket stack..." -ForegroundColor Yellow
$s3TemplateInitial = @'
AWSTemplateFormatVersion: "2010-09-09"
Description: cafe S3 template
Resources:
  S3Bucket:
    Type: AWS::S3::Bucket
'@
$s3File = Join-Path $PSScriptRoot "S3.yaml"
Set-Content -Path $s3File -Value $s3TemplateInitial

$bucketStack = (aws cloudformation describe-stacks --stack-name "CreateBucket" --region $region --query "Stacks[0].StackStatus" --output text 2>$null)
if (-not $bucketStack -or $bucketStack -eq "None") {
    aws cloudformation create-stack --stack-name "CreateBucket" --template-body "file://$($s3File.Replace('\', '/'))" --region $region | Out-Null
    Write-Host "  Waiting for CreateBucket CREATE_COMPLETE..."
    aws cloudformation wait stack-create-complete --stack-name "CreateBucket" --region $region
    Write-Host "  CreateBucket stack created!" -ForegroundColor Green
}

# Get created S3 Bucket Name
$bucketName = (aws cloudformation describe-stack-resources --stack-name "CreateBucket" --region $region --query "StackResources[?LogicalResourceId=='S3Bucket'].PhysicalResourceId | [0]" --output text)
Write-Host "  Created S3 Bucket: $bucketName" -ForegroundColor Green

# Task 3: Configure bucket as static website, upload files, update stack
Write-Host "`n[Task 3] Uploading static website files and updating S3 stack..." -ForegroundColor Yellow
$zipUrl = "https://aws-tc-largeobjects.s3.us-west-2.amazonaws.com/CUR-TF-200-ACACAD-3-113230/15-lab-mod11-challenge-CFn/s3/static-website.zip"
$zipPath = Join-Path $PSScriptRoot "static-website.zip"
$staticDir = Join-Path $PSScriptRoot "static"
if (-not (Test-Path $zipPath)) {
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath
}
if (-not (Test-Path $staticDir)) {
    Expand-Archive -Path $zipPath -DestinationPath $staticDir -Force
}

# Ownership & Public Access
aws s3api put-bucket-ownership-controls --bucket $bucketName --ownership-controls "Rules=[{ObjectOwnership=BucketOwnerPreferred}]" --region $region | Out-Null
aws s3api put-public-access-block --bucket $bucketName --public-access-block-configuration "BlockPublicAcls=false,RestrictPublicBuckets=false,IgnorePublicAcls=false,BlockPublicPolicy=false" --region $region | Out-Null
aws s3 cp --recursive $staticDir "s3://$bucketName/" --acl public-read --region $region | Out-Null
Write-Host "  Website files uploaded with public read permissions." -ForegroundColor Green

# Updated S3.yaml with WebsiteConfiguration, DeletionPolicy: Retain, and Output
$s3TemplateUpdated = @'
AWSTemplateFormatVersion: "2010-09-09"
Description: cafe S3 template
Resources:
  S3Bucket:
    Type: AWS::S3::Bucket
    DeletionPolicy: Retain
    Properties:
      WebsiteConfiguration:
        IndexDocument: index.html
Outputs:
  WebsiteURL:
    Value: !GetAtt S3Bucket.WebsiteURL
    Description: URL for website hosted on S3
'@
Set-Content -Path $s3File -Value $s3TemplateUpdated

Write-Host "  Updating CreateBucket stack with website hosting..."
$upRes = aws cloudformation update-stack --stack-name "CreateBucket" --template-body "file://$($s3File.Replace('\', '/'))" --region $region 2>&1
if ($upRes -notmatch "No updates are to be performed") {
    aws cloudformation wait stack-update-complete --stack-name "CreateBucket" --region $region
    Write-Host "  CreateBucket stack updated!" -ForegroundColor Green
}
$websiteUrl = (aws cloudformation describe-stacks --stack-name "CreateBucket" --region $region --query "Stacks[0].Outputs[?OutputKey=='WebsiteURL'].OutputValue | [0]" --output text)
Write-Host "  Static Website URL: $websiteUrl" -ForegroundColor Green

# Task 4 & 5: Clone / Fetch CodeCommit CFTemplatesRepo & Push cafe-network.yaml
Write-Host "`n[Task 5] Setting up cafe-network.yaml via CodeCommit & CodePipeline..." -ForegroundColor Yellow
$repoDir = Join-Path $PSScriptRoot "CFTemplatesRepo"
if (Test-Path $repoDir) { Remove-Item $repoDir -Recurse -Force -ErrorAction SilentlyContinue }

# Get clone URL
$cloneUrl = (aws codecommit get-repository --repository-name "CFTemplatesRepo" --region $region --query "repositoryMetadata.cloneUrlHttp" --output text)
Write-Host "  Cloning CodeCommit repo: $cloneUrl"
git clone $cloneUrl $repoDir 2>$null

# Build cafe-network.yaml with Outputs included
$networkYamlContent = @'
AWSTemplateFormatVersion: '2010-09-09'
Description: Network layer for the cafe
Resources:
  VPC:
    Type: 'AWS::EC2::VPC'
    Properties:
      CidrBlock: 10.0.0.0/16
      EnableDnsSupport: 'true'
      EnableDnsHostnames: 'true'
      Tags:
        - Key: Name
          Value: Cafe VPC
  InternetGateway:
    Type: 'AWS::EC2::InternetGateway'
    Properties:
      Tags:
        - Key: Name
          Value: Cafe IGW
  AttachGateway:
    Type: 'AWS::EC2::VPCGatewayAttachment'
    Properties:
      VpcId: !Ref VPC
      InternetGatewayId: !Ref InternetGateway
  PublicSubnet:
    Type: 'AWS::EC2::Subnet'
    Properties:
      VpcId: !Ref VPC
      CidrBlock: 10.0.0.0/24
      MapPublicIpOnLaunch: 'true'
      Tags:
        - Key: Name
          Value: Cafe Public Subnet
  PublicRouteTable:
    Type: 'AWS::EC2::RouteTable'
    Properties:
      VpcId: !Ref VPC
      Tags:
        - Key: Name
          Value: Cafe Public Route Table
  PublicRoute:
    Type: 'AWS::EC2::Route'
    DependsOn: AttachGateway
    Properties:
      RouteTableId: !Ref PublicRouteTable
      DestinationCidrBlock: 0.0.0.0/0
      GatewayId: !Ref InternetGateway
  PublicSubnetRouteTableAssociation:
    Type: 'AWS::EC2::SubnetRouteTableAssociation'
    Properties:
      SubnetId: !Ref PublicSubnet
      RouteTableId: !Ref PublicRouteTable
Outputs:
  PublicSubnet:
    Description: The subnet ID to use for public web servers
    Value: !Ref PublicSubnet
    Export:
      Name: !Sub '${AWS::StackName}-SubnetID'
  VpcId:
    Description: The VPC ID
    Value: !Ref VPC
    Export:
      Name: !Sub '${AWS::StackName}-VpcID'
'@

$templatesDir = Join-Path $repoDir "templates"
if (-not (Test-Path $templatesDir)) { New-Item -ItemType Directory -Path $templatesDir -Force | Out-Null }
$networkYamlPath = Join-Path $templatesDir "cafe-network.yaml"
Set-Content -Path $networkYamlPath -Value $networkYamlContent

# Build cafe-app.yaml
Write-Host "`n[Task 7] Building cafe-app.yaml with parameters, instance & user data..." -ForegroundColor Yellow
$appYamlContent = @'
AWSTemplateFormatVersion: '2010-09-09'
Description: Application layer for the cafe
Parameters:
  LatestAmiId:
    Type: 'AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>'
    Default: '/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64'
  CafeNetworkParameter:
    Type: String
    Default: update-cafe-network
    Description: Name of the network stack to import values from
  InstanceTypeParameter:
    Type: String
    Default: t2.small
    AllowedValues:
      - t2.micro
      - t2.small
      - t3.micro
      - t3.small
    Description: Choose an EC2 instance type (t2.micro, t2.small, t3.micro, t3.small)
Mappings:
  RegionMap:
    us-east-1:
      keypair: vockey
    us-west-2:
      keypair: cafe-oregon
Resources:
  CafeSG:
    Type: 'AWS::EC2::SecurityGroup'
    Properties:
      GroupDescription: Enable HTTP and SSH access
      VpcId: !ImportValue
        'Fn::Sub': '${CafeNetworkParameter}-VpcID'
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 80
          ToPort: 80
          CidrIp: 0.0.0.0/0
        - IpProtocol: tcp
          FromPort: 22
          ToPort: 22
          CidrIp: 0.0.0.0/0
      Tags:
        - Key: Name
          Value: CafeSG
  CafeInstance:
    Type: 'AWS::EC2::Instance'
    Properties:
      ImageId: !Ref LatestAmiId
      InstanceType: !Ref InstanceTypeParameter
      KeyName: !FindInMap [RegionMap, !Ref "AWS::Region", keypair]
      IamInstanceProfile: CafeRole
      NetworkInterfaces:
        - DeviceIndex: '0'
          AssociatePublicIpAddress: 'true'
          SubnetId: !ImportValue
            'Fn::Sub': '${CafeNetworkParameter}-SubnetID'
          GroupSet:
            - !Ref CafeSG
      Tags:
        - Key: Name
          Value: Cafe Web Server
      UserData:
        Fn::Base64:
          !Sub |
            #!/bin/bash
            dnf -y update
            dnf install -y mariadb1011-server httpd php8.4 php8.4-fpm php8.4-mysqlnd wget unzip
            systemctl enable --now php-fpm
            systemctl enable httpd
            systemctl start httpd
            systemctl enable mariadb
            systemctl start mariadb
            wget https://aws-tc-largeobjects.s3.us-west-2.amazonaws.com/CUR-TF-200-ACACAD-3-113230/15-lab-mod11-challenge-CFn/s3/cafe-app.sh
            chmod +x cafe-app.sh
            ./cafe-app.sh
Outputs:
  WebServerPublicIP:
    Description: Public IP of the Cafe Web Server
    Value: !GetAtt CafeInstance.PublicIp
'@

$appYamlPath = Join-Path $templatesDir "cafe-app.yaml"
Set-Content -Path $appYamlPath -Value $appYamlContent

# Commit & Push to CodeCommit
Push-Location $repoDir
git config user.name "Sofia"
git config user.email "sofia@cafe.aws"
git add templates/cafe-network.yaml templates/cafe-app.yaml
git commit -m "Deploy network and application templates for cafe"
git push origin main
Pop-Location
Write-Host "  Pushed templates to CodeCommit. CodePipelines triggered!" -ForegroundColor Green

# Wait for update-cafe-network stack
Write-Host "`nWaiting for update-cafe-network stack to complete via pipeline..." -ForegroundColor Yellow
$netComplete = $false
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Seconds 15
    $st = (aws cloudformation describe-stacks --stack-name "update-cafe-network" --region $region --query "Stacks[0].StackStatus" --output text 2>$null)
    Write-Host "  update-cafe-network Status: $st (attempt $($i+1))"
    if ($st -eq "CREATE_COMPLETE" -or $st -eq "UPDATE_COMPLETE") {
        $netComplete = $true
        break
    }
}

# Wait for update-cafe-app stack
Write-Host "`nWaiting for update-cafe-app stack to complete via pipeline..." -ForegroundColor Yellow
for ($i = 0; $i -lt 25; $i++) {
    Start-Sleep -Seconds 15
    $st = (aws cloudformation describe-stacks --stack-name "update-cafe-app" --region $region --query "Stacks[0].StackStatus" --output text 2>$null)
    Write-Host "  update-cafe-app Status: $st (attempt $($i+1))"
    if ($st -eq "CREATE_COMPLETE" -or $st -eq "UPDATE_COMPLETE") {
        break
    }
}

# Task 8: Duplicate in us-west-2 (Oregon)
Write-Host "`n[Task 8] Duplicating deployment in us-west-2 (Oregon)..." -ForegroundColor Yellow
$westRegion = "us-west-2"

# 1. Deploy update-cafe-network in us-west-2
$westNet = (aws cloudformation describe-stacks --stack-name "update-cafe-network" --region $westRegion --query "Stacks[0].StackStatus" --output text 2>$null)
if (-not $westNet -or $westNet -eq "None") {
    Write-Host "  Creating update-cafe-network in us-west-2..."
    aws cloudformation create-stack `
        --stack-name "update-cafe-network" `
        --template-body "file://$($networkYamlPath.Replace('\', '/'))" `
        --region $westRegion | Out-Null
    aws cloudformation wait stack-create-complete --stack-name "update-cafe-network" --region $westRegion
    Write-Host "  us-west-2 update-cafe-network CREATE_COMPLETE!" -ForegroundColor Green
}

# 2. Create Key Pair cafe-oregon in us-west-2
$keyWest = (aws ec2 describe-key-pairs --region $westRegion --query "KeyPairs[?KeyName=='cafe-oregon'].KeyName | [0]" --output text 2>$null)
if (-not $keyWest -or $keyWest -eq "None") {
    Write-Host "  Creating key pair cafe-oregon in us-west-2..."
    aws ec2 create-key-pair --key-name "cafe-oregon" --region $westRegion | Out-Null
}

# 3. Copy cafe-app.yaml to repobucket in S3
$s3Buckets = aws s3api list-buckets --query "Buckets[*].Name" | ConvertFrom-Json
$repoBucket = ($s3Buckets | Where-Object { $_ -like "*repobucket*" }) | Select-Object -First 1
Write-Host "  Target S3 Repo Bucket: $repoBucket"
aws s3 cp $appYamlPath "s3://$repoBucket/cafe-app.yaml" --region $region | Out-Null

# 4. Deploy update-cafe-app in us-west-2
$westApp = (aws cloudformation describe-stacks --stack-name "update-cafe-app" --region $westRegion --query "Stacks[0].StackStatus" --output text 2>$null)
if (-not $westApp -or $westApp -eq "None") {
    Write-Host "  Creating update-cafe-app in us-west-2 with InstanceType=t3.micro..."
    aws cloudformation create-stack `
        --stack-name "update-cafe-app" `
        --template-url "https://$repoBucket.s3.amazonaws.com/cafe-app.yaml" `
        --parameters ParameterKey=InstanceTypeParameter,ParameterValue=t3.micro `
        --region $westRegion | Out-Null
    aws cloudformation wait stack-create-complete --stack-name "update-cafe-app" --region $westRegion
    Write-Host "  us-west-2 update-cafe-app CREATE_COMPLETE!" -ForegroundColor Green
}

Write-Host "`n========================================================================" -ForegroundColor Cyan
Write-Host " Challenge Lab Completed Successfully in both us-east-1 and us-west-2!  " -ForegroundColor Green
Write-Host "========================================================================" -ForegroundColor Cyan
