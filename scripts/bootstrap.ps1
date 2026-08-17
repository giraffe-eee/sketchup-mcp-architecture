[CmdletBinding()]
param(
    # Use this only when Python is installed in a non-standard location and is
    # not discoverable through the py launcher, PATH, or the normal registry.
    [string]$PythonPath,
    [switch]$SkipDependencyInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$venvRoot = Join-Path $projectRoot '.venv'
$venvPython = Join-Path $venvRoot 'Scripts\python.exe'
$requirementsPath = Join-Path $projectRoot 'mcp-server\requirements.txt'
$minimumPythonVersion = [Version]'3.10'

function Get-PythonVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [string[]]$PrefixArguments = @()
    )

    $probe = 'import sys; print("{0}.{1}.{2}".format(sys.version_info[0], sys.version_info[1], sys.version_info[2]))'
    try {
        $arguments = @($PrefixArguments) + @('-c', $probe)
        $output = & $Executable @arguments 2>$null
        if ($LASTEXITCODE -ne 0) {
            return $null
        }
        $versionText = ($output | Select-Object -Last 1).ToString().Trim()
        return [Version]::Parse($versionText)
    } catch {
        return $null
    }
}

function Resolve-ExecutablePath {
    param([Parameter(Mandatory = $true)][string]$Value)

    if (Test-Path -LiteralPath $Value -PathType Leaf) {
        return [System.IO.Path]::GetFullPath($Value)
    }
    $command = Get-Command $Value -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {
        return $command.Path
    }
    return $null
}

function Add-Candidate {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$List,
        [Parameter(Mandatory = $true)][string]$Executable,
        [string[]]$PrefixArguments = @()
    )

    $resolved = Resolve-ExecutablePath $Executable
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        return
    }
    $key = ($resolved.ToLowerInvariant() + '|' + ($PrefixArguments -join [char]0))
    if ($List | Where-Object { $_.Key -eq $key }) {
        return
    }
    [void]$List.Add([PSCustomObject]@{
        Key = $key
        Path = $resolved
        PrefixArguments = @($PrefixArguments)
    })
}

function Add-PythonDirectoryCandidates {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$List,
        [Parameter(Mandatory = $true)][string]$Root
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return
    }
    Get-ChildItem -LiteralPath $Root -Filter 'python.exe' -File -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object { Add-Candidate -List $List -Executable $_.FullName }
}

function Add-PythonRegistryCandidates {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$List)

    $registryRoots = @(
        'HKCU:\Software\Python\PythonCore',
        'HKLM:\Software\Python\PythonCore',
        'HKLM:\Software\WOW6432Node\Python\PythonCore'
    )
    foreach ($registryRoot in $registryRoots) {
        if (-not (Test-Path -LiteralPath $registryRoot)) {
            continue
        }
        Get-ChildItem -LiteralPath $registryRoot -ErrorAction SilentlyContinue | ForEach-Object {
            $installKeyPath = Join-Path $_.PSPath 'InstallPath'
            $installKey = Get-Item -LiteralPath $installKeyPath -ErrorAction SilentlyContinue
            $installPath = if ($installKey) { $installKey.GetValue('') } else { $null }
            if (-not [string]::IsNullOrWhiteSpace($installPath)) {
                $candidate = Join-Path $installPath 'python.exe'
                Add-Candidate -List $List -Executable $candidate
            }
        }
    }
}

function Find-Python {
    param([string]$ExplicitPath)

    $candidates = [System.Collections.Generic.List[object]]::new()
    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $resolvedExplicit = Resolve-ExecutablePath $ExplicitPath
        if ([string]::IsNullOrWhiteSpace($resolvedExplicit)) {
            throw "The requested Python executable was not found: $ExplicitPath"
        }
        Add-Candidate -List $candidates -Executable $resolvedExplicit
    } else {
        # The launcher also knows registered installations outside the usual
        # folders. Probe the verified version first, then its newest Python 3.
        Add-Candidate -List $candidates -Executable 'py.exe' -PrefixArguments @('-3.12')
        Add-Candidate -List $candidates -Executable 'py.exe' -PrefixArguments @('-3')
        Add-Candidate -List $candidates -Executable 'python.exe'
        Add-Candidate -List $candidates -Executable 'python3.exe'

        if ($env:LOCALAPPDATA) {
            Add-PythonDirectoryCandidates -List $candidates -Root (Join-Path $env:LOCALAPPDATA 'Programs\Python')
        }
        if ($env:ProgramFiles) {
            Add-PythonDirectoryCandidates -List $candidates -Root (Join-Path $env:ProgramFiles 'Python')
        }
        if (${env:ProgramFiles(x86)}) {
            Add-PythonDirectoryCandidates -List $candidates -Root (Join-Path ${env:ProgramFiles(x86)} 'Python')
        }
        Add-PythonRegistryCandidates -List $candidates
    }

    $valid = foreach ($candidate in $candidates) {
        $version = Get-PythonVersion -Executable $candidate.Path -PrefixArguments $candidate.PrefixArguments
        if ($version -and $version -ge $minimumPythonVersion) {
            [PSCustomObject]@{
                Path = $candidate.Path
                PrefixArguments = $candidate.PrefixArguments
                Version = $version
            }
        }
    }
    # Python 3.12 is the project's verified runtime. Fall back to the newest
    # compatible interpreter when it is not installed.
    $selected = $valid |
        Sort-Object @{Expression = { if ($_.Version.Major -eq 3 -and $_.Version.Minor -eq 12) { 1 } else { 0 } }; Descending = $true}, @{Expression = 'Version'; Descending = $true} |
        Select-Object -First 1
    if (-not $selected) {
        throw 'Python 3.10 or later was not found. Install Python 3.12 (recommended), ensure the Python launcher or PATH is available, then run this script again. For a custom location, use -PythonPath C:\path\to\python.exe.'
    }
    return $selected
}

function Invoke-CheckedPython {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    & $venvPython @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Python command failed: $venvPython $($Arguments -join ' ')"
    }
}

if (-not (Test-Path -LiteralPath $requirementsPath -PathType Leaf)) {
    throw "Python requirements file is missing: $requirementsPath"
}

if (Test-Path -LiteralPath $venvPython -PathType Leaf) {
    $existingVersion = Get-PythonVersion -Executable $venvPython
    if (-not $existingVersion -or $existingVersion -lt $minimumPythonVersion) {
        throw "The existing project virtual environment is missing or uses Python older than 3.10: $venvPython. Remove the .venv folder manually, then run this script again."
    }
    Write-Host "Using existing project Python $existingVersion at $venvPython"
    if ($existingVersion.Major -ne 3 -or $existingVersion.Minor -ne 12) {
        Write-Warning 'Python 3.12 is the verified runtime. The existing compatible virtual environment will be preserved; recreate .venv manually with Python 3.12 if a dependency issue occurs.'
    }
} else {
    $selectedPython = Find-Python -ExplicitPath $PythonPath
    Write-Host "Creating the project virtual environment with Python $($selectedPython.Version) at $($selectedPython.Path)"
    $venvArguments = @($selectedPython.PrefixArguments) + @('-m', 'venv', $venvRoot)
    & $selectedPython.Path @venvArguments
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
        throw "Could not create the project virtual environment at $venvRoot"
    }
}

if (-not $SkipDependencyInstall) {
    Invoke-CheckedPython -Arguments @('-m', 'pip', 'install', '--upgrade', 'pip')
    Invoke-CheckedPython -Arguments @('-m', 'pip', 'install', '-r', $requirementsPath)
}

Write-Host "MCP Python environment is ready: $venvPython"
