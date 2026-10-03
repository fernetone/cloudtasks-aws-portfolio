$ErrorActionPreference = "Stop"

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
Set-Location $projectRoot
$tokenFile = Join-Path $projectRoot ".env.localstack"

Write-Host "Cole o NOVO Personal Auth Token do LocalStack." -ForegroundColor Yellow
Write-Host "O valor sera salvo somente em .env.localstack e nao sera enviado ao Git." -ForegroundColor DarkGray

$secureToken = Read-Host "LOCALSTACK_AUTH_TOKEN" -AsSecureString
$tokenPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
try {
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($tokenPtr)
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($tokenPtr)
}

if ([string]::IsNullOrWhiteSpace($plainToken)) {
    throw "Token vazio. Nenhuma alteracao foi feita."
}

[IO.File]::WriteAllText($tokenFile, "LOCALSTACK_AUTH_TOKEN=$plainToken", (New-Object Text.UTF8Encoding($false)))
$plainToken = $null
Write-Host "Token LocalStack atualizado com sucesso." -ForegroundColor Green
Write-Host "Reinicie o LocalStack para aplicar: .\scripts\localstack\stop-localstack.ps1 ; .\scripts\localstack\start-localstack.ps1" -ForegroundColor Cyan
