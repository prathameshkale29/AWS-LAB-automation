# ============================================================================
# cleanup4.ps1 - Clean up Lab 4 created volumes and snapshots
# ============================================================================
$ErrorActionPreference = "Stop"
$region = "us-east-1"

function Test-AwsResult {
    param([string]$r)
    return (-not [string]::IsNullOrWhiteSpace($r)) -and ($r -ne "None") -and ($r -ne "null")
}

Write-Host "`n=== CLEANUP: Lab 4 Resources ===" -ForegroundColor Red

# 1. Unmount and detach / delete Restored Volume
$vol2Id = aws ec2 describe-volumes --filters "Name=tag:Name,Values=Restored Volume" "Name=status,Values=available,in-use" --query "Volumes[0].VolumeId" --output text --region $region 2>$null
if (Test-AwsResult $vol2Id) {
    Write-Host "Detaching Restored Volume $vol2Id..."
    aws ec2 detach-volume --volume-id $vol2Id --force --region $region 2>$null | Out-Null
    aws ec2 wait volume-available --volume-ids $vol2Id --region $region 2>$null
    Write-Host "Deleting volume $vol2Id..."
    aws ec2 delete-volume --volume-id $vol2Id --region $region
    Write-Host "DONE: Deleted Restored Volume" -ForegroundColor Green
}

# 2. Delete Snapshot
$snapId = aws ec2 describe-snapshots --owner-ids self --filters "Name=tag:Name,Values=My Snapshot" --query "Snapshots[0].SnapshotId" --output text --region $region 2>$null
if (Test-AwsResult $snapId) {
    Write-Host "Deleting Snapshot $snapId..."
    aws ec2 delete-snapshot --snapshot-id $snapId --region $region
    Write-Host "DONE: Deleted Snapshot" -ForegroundColor Green
}

# 3. Detach & delete My Volume
$vol1Id = aws ec2 describe-volumes --filters "Name=tag:Name,Values=My Volume" "Name=status,Values=available,in-use" --query "Volumes[0].VolumeId" --output text --region $region 2>$null
if (Test-AwsResult $vol1Id) {
    Write-Host "Detaching My Volume $vol1Id..."
    aws ec2 detach-volume --volume-id $vol1Id --force --region $region 2>$null | Out-Null
    aws ec2 wait volume-available --volume-ids $vol1Id --region $region 2>$null
    Write-Host "Deleting volume $vol1Id..."
    aws ec2 delete-volume --volume-id $vol1Id --region $region
    Write-Host "DONE: Deleted My Volume" -ForegroundColor Green
}

Write-Host "`n=== CLEANUP 4 COMPLETE ===" -ForegroundColor Green

