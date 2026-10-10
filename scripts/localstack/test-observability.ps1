$ErrorActionPreference = 'Stop'
& node (Join-Path $PSScriptRoot 'observability-localstack.mjs') test
if ($LASTEXITCODE -ne 0) { throw 'Observabilidade reprovada; nao homologar por SetAlarmState.' }
