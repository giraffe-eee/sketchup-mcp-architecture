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
    $python = $null
    foreach ($pythonCommand in (Get-Command python, py -ErrorAction SilentlyContinue)) {
        & $pythonCommand.Source --version *> $null
        if ($LASTEXITCODE -eq 0) {
            $python = $pythonCommand.Source
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($python)) {
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
