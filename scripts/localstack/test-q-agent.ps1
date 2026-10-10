$ErrorActionPreference = 'Stop'
& node (Join-Path $PSScriptRoot 'q-agent-localstack.mjs') validate
if ($LASTEXITCODE -ne 0) { throw 'Agente bia nao foi validado pelo Amazon Q.' }
