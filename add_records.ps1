$itemsToAdd = @(
    @{ store = 'Seattle'; item = 'Kindle Paperwhite'; quantity = '20' },
    @{ store = 'London'; item = 'Fire TV Stick'; quantity = '35' },
    @{ store = 'Tokyo'; item = 'Echo Show'; quantity = '15' }
)

foreach ($it in $itemsToAdd) {
    $body = "mode=added&store=$([Uri]::EscapeDataString($it.store))&item=$([Uri]::EscapeDataString($it.item))&quantity=$([Uri]::EscapeDataString($it.quantity))"
    $postResp = Invoke-WebRequest -Uri 'http://100.27.45.66/index.php' -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing
    Write-Host "Added $($it.item) at $($it.store): $($postResp.StatusCode)"
}

$final = Invoke-WebRequest -Uri 'http://100.27.45.66/' -UseBasicParsing
Write-Host "`n=== Updated Table HTML ==="
$regex = '(?s)<table id=''inventory''.*?</table>'
if ($final.Content -match $regex) {
    Write-Host $matches[0]
}

