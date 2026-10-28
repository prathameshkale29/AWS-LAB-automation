# cleanup_dynamic_cafe.ps1 - Automated Cleanup for Challenge Lab: Creating a Dynamic Website for the Café
$ErrorActionPreference = "Continue"

# Set credentials

$regionEast = "us-east-1"
$regionWest = "us-west-2"

Write-Host "=========================================================="
Write-Host "Starting Dynamic Cafe Website Cleanup"
Write-Host "=========================================================="

# 1. Terminate ProdCafeServer in us-west-2
Write-Host "`n[Step 1] Terminating ProdCafeServer in $regionWest..."
$prodInstances = aws ec2 describe-instances --region $regionWest --filters "Name=tag:Name,Values=ProdCafeServer" "Name=instance-state-name,Values=running,pending,stopped" | ConvertFrom-Json
if ($prodInstances.Reservations -and $prodInstances.Reservations.Count -gt 0) {
    foreach ($res in $prodInstances.Reservations) {
        foreach ($inst in $res.Instances) {
            Write-Host "  Terminating instance $($inst.InstanceId)..."
            aws ec2 terminate-instances --instance-ids $inst.InstanceId --region $regionWest | Out-Null
            aws ec2 wait instance-terminated --instance-ids $inst.InstanceId --region $regionWest
            Write-Host "  Terminated $($inst.InstanceId)."
        }
    }
} else {
    Write-Host "  No ProdCafeServer instances found."
}

# 2. Delete Secrets Manager secrets in us-west-2
Write-Host "`n[Step 2] Deleting secrets in Secrets Manager ($regionWest)..."
$secretNames = @(
    "/cafe/showServerInfo",
    "/cafe/timeZone",
    "/cafe/currency",
    "/cafe/dbUrl",
    "/cafe/dbName",
    "/cafe/dbUser",
    "/cafe/dbPassword"
)
foreach ($s in $secretNames) {
    Write-Host "  Deleting secret: $s..."
    aws secretsmanager delete-secret --secret-id $s --force-delete-without-recovery --region $regionWest 2>$null | Out-Null
}

# 3. Deregistered AMIs and Delete Snapshots in us-west-2
Write-Host "`n[Step 3] Deregistering AMIs in $regionWest..."
$amisWest = aws ec2 describe-images --region $regionWest --owners self --filters "Name=name,Values=CafeServer" | ConvertFrom-Json
if ($amisWest.Images) {
    foreach ($img in $amisWest.Images) {
        Write-Host "  Deregistering AMI $($img.ImageId)..."
        aws ec2 deregister-image --image-id $img.ImageId --region $regionWest | Out-Null
        foreach ($bdm in $img.BlockDeviceMappings) {
            if ($bdm.Ebs.SnapshotId) {
                Write-Host "  Deleting Snapshot $($bdm.Ebs.SnapshotId)..."
                aws ec2 delete-snapshot --snapshot-id $bdm.Ebs.SnapshotId --region $regionWest 2>$null | Out-Null
            }
        }
    }
}

# 4. Delete cafeSG in us-west-2
Write-Host "`n[Step 4] Deleting Security Group 'cafeSG' in $regionWest..."
$sgs = aws ec2 describe-security-groups --region $regionWest --filters "Name=group-name,Values=cafeSG" | ConvertFrom-Json
if ($sgs.SecurityGroups) {
    foreach ($sg in $sgs.SecurityGroups) {
        Write-Host "  Deleting SG $($sg.GroupId)..."
        aws ec2 delete-security-group --group-id $sg.GroupId --region $regionWest 2>$null | Out-Null
    }
}

# 5. Deregister AMI in us-east-1
Write-Host "`n[Step 5] Deregistering AMI in $regionEast..."
$amisEast = aws ec2 describe-images --region $regionEast --owners self --filters "Name=name,Values=CafeServer" | ConvertFrom-Json
if ($amisEast.Images) {
    foreach ($img in $amisEast.Images) {
        Write-Host "  Deregistering AMI $($img.ImageId)..."
        aws ec2 deregister-image --image-id $img.ImageId --region $regionEast | Out-Null
        foreach ($bdm in $img.BlockDeviceMappings) {
            if ($bdm.Ebs.SnapshotId) {
                Write-Host "  Deleting Snapshot $($bdm.Ebs.SnapshotId)..."
                aws ec2 delete-snapshot --snapshot-id $bdm.Ebs.SnapshotId --region $regionEast 2>$null | Out-Null
            }
        }
    }
}

Write-Host "`nCleanup Complete!"

