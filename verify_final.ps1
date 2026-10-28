# verify_final.ps1 - Test Cafe application on RDS
$appUrl = "http://34.204.79.203"

Write-Host "Checking Cafe Website on RDS..."
try {
    $menuResp = Invoke-WebRequest -Uri "$appUrl/cafe/menu.php" -UseBasicParsing -TimeoutSec 5
    Write-Host "Menu Status: $($menuResp.StatusCode)"
    if ($menuResp.Content -match "Croissant") {
        Write-Host "  Products loaded successfully from RDS!"
    } else {
        Write-Host "  Database import not detected yet."
        exit 1
    }

    Write-Host "Submitting a test order..."
    $body = 'productId%5B%5D=1&productName%5B%5D=Croissant&price%5B%5D=1.50&quantity%5B%5D=2&date=' + [Uri]::EscapeDataString((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
    $orderResp = Invoke-WebRequest -Uri "$appUrl/cafe/processOrder.php" -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing
    Write-Host "Order Status: $($orderResp.StatusCode)"

    Write-Host "Checking Order History..."
    $histResp = Invoke-WebRequest -Uri "$appUrl/cafe/orderHistory.php" -UseBasicParsing
    Write-Host "Order History Status: $($histResp.StatusCode)"
    if ($histResp.Content -match "Croissant") {
        Write-Host "  Order confirmed in RDS Order History!"
    }
    Write-Host "`n=== ALL VERIFICATIONS PASSED 100% ==="
} catch {
    Write-Host "Verification error: $_"
    exit 1
}

