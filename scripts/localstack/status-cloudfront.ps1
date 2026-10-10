$ErrorActionPreference = 'Stop'
& node (Join-Path $PSScriptRoot 'cloudfront-localstack.mjs') status
if ($LASTEXITCODE -ne 0) { throw 'CloudFront local status falhou.' }
