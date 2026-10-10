$ErrorActionPreference = 'Stop'
# Temporarily enables only the owned Disabled distribution, then restores it by ETag.
& node (Join-Path $PSScriptRoot 'cloudfront-localstack.mjs') test
if ($LASTEXITCODE -ne 0) { throw 'CloudFront local test falhou; nao converter configuracao em homologacao.' }
