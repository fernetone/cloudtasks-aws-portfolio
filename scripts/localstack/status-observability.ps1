$ErrorActionPreference = 'Stop'
& node (Join-Path $PSScriptRoot 'observability-localstack.mjs') status
if ($LASTEXITCODE -ne 0) { throw 'Monitor/heartbeat local nao foi verificado.' }
