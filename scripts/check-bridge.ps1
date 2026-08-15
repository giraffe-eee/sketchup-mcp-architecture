[CmdletBinding()]
param(
    [ValidateRange(1, 120)]
    [int]$TimeoutSeconds = 35
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$venvPython = Join-Path $projectRoot '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
    throw 'MCP Python environment is missing. Run .\scripts\bootstrap.ps1 first.'
}

$env:SKETCHUP_MCP_TIMEOUT_SEC = $TimeoutSeconds.ToString()
$checkCommand = @'
import json
import sys

sys.path.insert(0, "mcp-server")
import sketchup_mcp_server as server

print(json.dumps(server.bridge_status(), ensure_ascii=False, indent=2))
'@

& $venvPython -c $checkCommand
if ($LASTEXITCODE -ne 0) {
    throw 'SketchUp bridge verification failed. Confirm SketchUp is open and the extension is enabled.'
}
