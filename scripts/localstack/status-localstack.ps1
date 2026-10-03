$ErrorActionPreference = "Stop"

Write-Host "Container:" -ForegroundColor Cyan
docker ps --filter "name=cloudtasks-localstack" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

if ($LASTEXITCODE -ne 0) {
    throw "Nao foi possivel consultar o Docker."
}

try {
    $info = Invoke-RestMethod -Uri "http://localhost:4566/_localstack/info" -TimeoutSec 5
    Write-Host ""
    Write-Host "LocalStack info endpoint respondeu com sucesso." -ForegroundColor Green
    $info | ConvertTo-Json -Depth 8
}
catch {
    Write-Host ""
    Write-Host "O endpoint http://localhost:4566/_localstack/info nao respondeu." -ForegroundColor Red
    exit 1
}
