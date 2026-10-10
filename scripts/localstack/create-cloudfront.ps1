$ErrorActionPreference = 'Stop'
& node (Join-Path $PSScriptRoot 'cloudfront-localstack.mjs') create
if ($LASTEXITCODE -ne 0) { throw 'CloudFront local create falhou; conferir a evidencia privada do runtime.' }
