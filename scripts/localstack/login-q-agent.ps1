$ErrorActionPreference = 'Stop'
& node (Join-Path $PSScriptRoot 'q-agent-localstack.mjs') login
if ($LASTEXITCODE -ne 0) { throw 'Login Amazon Q nao concluido.' }
