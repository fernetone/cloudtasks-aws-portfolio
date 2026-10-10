$ErrorActionPreference = 'Stop'
& node (Join-Path $PSScriptRoot 'mcp-localstack.mjs') create
if ($LASTEXITCODE -ne 0) { throw 'MCP local nao foi configurado.' }
