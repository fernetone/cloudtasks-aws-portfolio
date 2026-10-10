$ErrorActionPreference = 'Stop'
& node (Join-Path $PSScriptRoot 'mcp-localstack.mjs') test
if ($LASTEXITCODE -ne 0) { throw 'Consultas reais pelo MCP reprovadas.' }
