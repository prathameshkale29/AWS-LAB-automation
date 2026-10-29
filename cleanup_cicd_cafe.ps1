# cleanup_cicd_cafe.ps1 - Tear down all resources created for Challenge Lab: Automating Infrastructure Deployment
$ErrorActionPreference = "Continue"

$region = "us-east-1"
$westRegion = "us-west-2"

Write-Host "Cleaning up in us-west-2..." -ForegroundColor Yellow
aws cloudformation delete-stack --stack-name "update-cafe-app" --region $westRegion
aws cloudformation wait stack-delete-complete --stack-name "update-cafe-app" --region $westRegion 2>$null

aws cloudformation delete-stack --stack-name "update-cafe-network" --region $westRegion
aws cloudformation wait stack-delete-complete --stack-name "update-cafe-network" --region $westRegion 2>$null

aws ec2 delete-key-pair --key-name "cafe-oregon" --region $westRegion 2>$null

Write-Host "Cleaning up in us-east-1..." -ForegroundColor Yellow
aws cloudformation delete-stack --stack-name "update-cafe-app" --region $region
aws cloudformation wait stack-delete-complete --stack-name "update-cafe-app" --region $region 2>$null

aws cloudformation delete-stack --stack-name "update-cafe-network" --region $region
aws cloudformation wait stack-delete-complete --stack-name "update-cafe-network" --region $region 2>$null

# Empty and delete CreateBucket stack
$bucketName = (aws cloudformation describe-stack-resources --stack-name "CreateBucket" --region $region --query "StackResources[?LogicalResourceId=='S3Bucket'].PhysicalResourceId | [0]" --output text 2>$null)
if ($bucketName -and $bucketName -ne "None") {
    aws s3 rm "s3://$bucketName" --recursive --region $region 2>$null
}
aws cloudformation delete-stack --stack-name "CreateBucket" --region $region
aws cloudformation wait stack-delete-complete --stack-name "CreateBucket" --region $region 2>$null

Write-Host "Cleanup completed." -ForegroundColor Green
