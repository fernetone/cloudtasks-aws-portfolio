$ErrorActionPreference = 'Stop'
& node (Join-Path $PSScriptRoot 'observability-localstack.mjs') create
if ($LASTEXITCODE -ne 0) { throw 'Observabilidade local nao foi criada/verificada.' }
