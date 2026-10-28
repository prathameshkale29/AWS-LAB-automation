# ============================================================================
# cleanup_efs.ps1 - Clean up EFS File System and Mount Target SG
# ============================================================================
$ErrorActionPreference = "Stop"
$region = "us-east-1"

function Test-AwsResult {
    param([string]$r)
    return (-not [string]::IsNullOrWhiteSpace($r)) -and ($r -ne "None") -and ($r -ne "null")
}

Write-Host "`n=== CLEANUP: EFS Lab Resources ===" -ForegroundColor Red

# 1. Delete mount targets and EFS file system
$fsId = aws efs describe-file-systems --query "FileSystems[?Tags[?Key=='Name' && Value=='My First EFS File System']].FileSystemId | [0]" --output text --region $region 2>$null
if (Test-AwsResult $fsId) {
    # Delete mount targets first
    $mtIds = aws efs describe-mount-targets --file-system-id $fsId --query "MountTargets[*].MountTargetId" --output text --region $region 2>$null
    if (Test-AwsResult $mtIds) {
        foreach ($m in ($mtIds -split "\s+")) {
            if (Test-AwsResult $m) {
                Write-Host "Deleting mount target $m..."
                aws efs delete-mount-target --mount-target-id $m --region $region | Out-Null
            }
        }
        Write-Host "Waiting for mount targets to delete..."
        Start-Sleep -Seconds 20
    }
    Write-Host "Deleting EFS file system $fsId..."
    aws efs delete-file-system --file-system-id $fsId --region $region | Out-Null
    Write-Host "DONE: EFS file system deleted" -ForegroundColor Green
}

# 2. Delete EFS Mount Target Security Group
$sgId = aws ec2 describe-security-groups --filters "Name=group-name,Values=EFS Mount Target" --query "SecurityGroups[0].GroupId" --output text --region $region 2>$null
if (Test-AwsResult $sgId) {
    Write-Host "Deleting security group $sgId..."
    aws ec2 delete-security-group --group-id $sgId --region $region
    Write-Host "DONE: Security group deleted" -ForegroundColor Green
}

Write-Host "`n=== CLEANUP COMPLETE ===" -ForegroundColor Green

