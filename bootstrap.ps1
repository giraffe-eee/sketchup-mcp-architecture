[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-CheckedPython {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    & $venvPython @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Python command failed: $venvPython $($Arguments -join ' ')"
    }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$venvPython = Join-Path $projectRoot '.venv\Scripts\python.exe'

if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
    $pythonCommand = Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pythonCommand) {
        $python = $pythonCommand.Source
    } else {
        $python = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Programs\Python') -Filter python.exe -Recurse -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName -First 1
    }
    if ([string]::IsNullOrWhiteSpace($python)) {
        throw 'Python 3.10 or later is required. Install Python, then run this script again.'
    }
    & $python -m venv (Join-Path $projectRoot '.venv')
}

Invoke-CheckedPython -Arguments @('-m', 'pip', 'install', '--upgrade', 'pip')
Invoke-CheckedPython -Arguments @('-m', 'pip', 'install', '-r', (Join-Path $projectRoot 'mcp-server\requirements.txt'))
Write-Host 'MCP Python environment is ready.'
