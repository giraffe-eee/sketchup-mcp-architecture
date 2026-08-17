[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$SketchUpVersion,
    [string]$PluginsRoot,
    [switch]$Update,
    [string]$BackupRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$sourceRoot = Join-Path $projectRoot 'sketchup-plugin-source'
$sourceExtension = Join-Path $sourceRoot 'codex_sketchup_mcp'
$sourceLoader = Join-Path $sourceRoot 'sketchup_mcp_port_bridge.rb'
$resolvedProjectRoot = [System.IO.Path]::GetFullPath($projectRoot)
$projectPrefix = $resolvedProjectRoot.TrimEnd([char[]]@('\', '/')) + [System.IO.Path]::DirectorySeparatorChar

function Add-SketchUpPluginCandidate {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Candidates,
        [Parameter(Mandatory = $true)][hashtable]$Seen,
        [Parameter(Mandatory = $true)][string]$VersionName,
        [Parameter(Mandatory = $true)][string]$Root
    )

    if ($VersionName -notmatch '^SketchUp\s+(\d{4})$') {
        return
    }
    $resolvedRoot = [System.IO.Path]::GetFullPath($Root)
    $key = $resolvedRoot.ToLowerInvariant()
    if ($Seen.ContainsKey($key)) {
        return
    }
    $Seen[$key] = $true
    [void]$Candidates.Add([PSCustomObject]@{
        Version = [int]$Matches[1]
        VersionName = $VersionName
        Root = $resolvedRoot
        Exists = (Test-Path -LiteralPath $resolvedRoot -PathType Container)
    })
}

function Get-SketchUpPluginCandidates {
    $candidates = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    $profileRoots = @()
    if ($env:APPDATA) {
        $profileRoots += Join-Path $env:APPDATA 'SketchUp'
    }
    if ($env:LOCALAPPDATA) {
        $profileRoots += Join-Path $env:LOCALAPPDATA 'SketchUp'
    }

    # First use the folders SketchUp has already created for this Windows user.
    foreach ($profileRoot in ($profileRoots | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $profileRoot -PathType Container)) {
            continue
        }
        Get-ChildItem -LiteralPath $profileRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                $plugins = Join-Path $_.FullName 'SketchUp\Plugins'
                Add-SketchUpPluginCandidate -Candidates $candidates -Seen $seen -VersionName $_.Name -Root $plugins
            }
    }

    # A freshly installed SketchUp might not have created its Plugins folder
    # yet. Registry entries identify its version so the normal per-user folder
    # can be created without relying on the SketchUp executable's location.
    $registryRoots = @(
        'HKCU:\Software\SketchUp',
        'HKLM:\Software\SketchUp',
        'HKLM:\Software\WOW6432Node\SketchUp'
    )
    foreach ($registryRoot in $registryRoots) {
        if (-not (Test-Path -LiteralPath $registryRoot)) {
            continue
        }
        Get-ChildItem -LiteralPath $registryRoot -ErrorAction SilentlyContinue |
            ForEach-Object {
                foreach ($profileRoot in ($profileRoots | Select-Object -Unique)) {
                    $plugins = Join-Path (Join-Path $_.PSChildName 'SketchUp') 'Plugins'
                    $plugins = Join-Path $profileRoot $plugins
                    Add-SketchUpPluginCandidate -Candidates $candidates -Seen $seen -VersionName $_.PSChildName -Root $plugins
                }
            }
    }

    return $candidates
}

function Resolve-SketchUpPluginRoot {
    if (-not [string]::IsNullOrWhiteSpace($PluginsRoot)) {
        return [System.IO.Path]::GetFullPath($PluginsRoot)
    }

    $candidates = @(Get-SketchUpPluginCandidates)
    if (-not [string]::IsNullOrWhiteSpace($SketchUpVersion)) {
        $requestedVersion = ($SketchUpVersion -replace '^SketchUp\s+', '').Trim()
        $candidates = @($candidates | Where-Object { $_.VersionName -eq "SketchUp $requestedVersion" })
    }
    if ($candidates.Count -eq 0) {
        $versionHint = if ([string]::IsNullOrWhiteSpace($SketchUpVersion)) { 'any supported version' } else { "SketchUp $SketchUpVersion" }
        throw "Could not find a SketchUp Plugins folder for $versionHint. Use -SketchUpVersion 2026 or pass the exact folder with -PluginsRoot. Expected pattern: %APPDATA%\SketchUp\SketchUp <year>\SketchUp\Plugins"
    }

    # Use the newest installed SketchUp. Its Plugins folder can be created when
    # SketchUp has not populated it yet.
    $selected = $candidates |
        Sort-Object @{Expression = 'Version'; Descending = $true}, @{Expression = { if ($_.Exists) { 1 } else { 0 } }; Descending = $true} |
        Select-Object -First 1
    $detectedVersionCount = @($candidates | Select-Object -ExpandProperty Version -Unique).Count
    if ($detectedVersionCount -gt 1 -and [string]::IsNullOrWhiteSpace($SketchUpVersion)) {
        Write-Warning "Multiple SketchUp versions were found. Using $($selected.VersionName). Use -SketchUpVersion <year> to select another version."
    }
    Write-Host "Using SketchUp plugin folder: $($selected.Root)"
    return [System.IO.Path]::GetFullPath($selected.Root)
}

if ([string]::IsNullOrWhiteSpace($PluginsRoot)) {
    $PluginsRoot = Resolve-SketchUpPluginRoot
}
if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
    $BackupRoot = Join-Path $projectRoot 'plugin-backups'
}

$resolvedBackupRoot = [System.IO.Path]::GetFullPath($BackupRoot)
if ($resolvedBackupRoot -ne $resolvedProjectRoot -and -not $resolvedBackupRoot.StartsWith($projectPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "BackupRoot must stay inside the project folder: $resolvedProjectRoot"
}
if (-not (Test-Path -LiteralPath $sourceExtension -PathType Container) -or -not (Test-Path -LiteralPath $sourceLoader -PathType Leaf)) {
    throw "Plugin source is missing: $sourceRoot"
}
if (Test-Path -LiteralPath $PluginsRoot -PathType Leaf) {
    throw "The requested SketchUp plugin path is a file, not a folder: $PluginsRoot"
}
if (Get-Process -Name SketchUp -ErrorAction SilentlyContinue) {
    throw 'SketchUp is running. Save work and close SketchUp before installing or updating this plugin.'
}
if (-not (Test-Path -LiteralPath $PluginsRoot -PathType Container)) {
    if ($PSCmdlet.ShouldProcess($PluginsRoot, 'Create SketchUp plugin folder')) {
        New-Item -ItemType Directory -Path $PluginsRoot -Force | Out-Null
    }
}

$resolvedPluginsRoot = [System.IO.Path]::GetFullPath($PluginsRoot)
$pluginsPrefix = $resolvedPluginsRoot.TrimEnd([char[]]@('\', '/')) + [System.IO.Path]::DirectorySeparatorChar
$destinationExtension = Join-Path $resolvedPluginsRoot 'codex_sketchup_mcp'
$destinationLoader = Join-Path $resolvedPluginsRoot 'sketchup_mcp_port_bridge.rb'

function Assert-PluginsChildPath {
    param([Parameter(Mandatory = $true)][string]$CandidatePath)

    $resolvedCandidate = [System.IO.Path]::GetFullPath($CandidatePath)
    if (-not $resolvedCandidate.StartsWith($pluginsPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to change a path outside the SketchUp plugin folder: $resolvedCandidate"
    }
    return $resolvedCandidate
}

function Test-PluginPayload {
    param(
        [Parameter(Mandatory = $true)][string]$ExtensionPath,
        [Parameter(Mandatory = $true)][string]$LoaderPath
    )

    if (-not (Test-Path -LiteralPath $ExtensionPath -PathType Container)) {
        return $false
    }
    $requiredFiles = @(
        $LoaderPath,
        (Join-Path $ExtensionPath 'main.rb'),
        (Join-Path $ExtensionPath 'version.rb'),
        (Join-Path $ExtensionPath 'core.rb'),
        (Join-Path $ExtensionPath 'runtime_config.rb'),
        (Join-Path $ExtensionPath 'runtime_config.json'),
        (Join-Path $ExtensionPath 'action_catalog.json')
    )
    foreach ($requiredFile in $requiredFiles) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            return $false
        }
    }
    return $true
}

function Write-RuntimeConfig {
    param([Parameter(Mandatory = $true)][string]$ExtensionPath)

    $runtimeDirectory = Join-Path $resolvedProjectRoot '.runtime'
    $config = [ordered]@{
        runtime_dir = $runtimeDirectory
        file_bridge_dir = (Join-Path $runtimeDirectory 'file-queue')
    } | ConvertTo-Json -Compress
    $configPath = Join-Path $ExtensionPath 'runtime_config.json'
    [System.IO.File]::WriteAllText($configPath, $config, [System.Text.UTF8Encoding]::new($false))
}

function New-StagedPluginPayload {
    param([Parameter(Mandatory = $true)][string]$StageRoot)

    $resolvedStageRoot = Assert-PluginsChildPath $StageRoot
    if (Test-Path -LiteralPath $resolvedStageRoot) {
        throw "Plugin staging folder already exists: $resolvedStageRoot"
    }
    New-Item -ItemType Directory -Path $resolvedStageRoot | Out-Null

    $stageExtension = Join-Path $resolvedStageRoot 'codex_sketchup_mcp'
    $stageLoader = Join-Path $resolvedStageRoot 'sketchup_mcp_port_bridge.rb'
    Copy-Item -LiteralPath $sourceExtension -Destination $stageExtension -Recurse | Out-Null
    Copy-Item -LiteralPath $sourceLoader -Destination $stageLoader | Out-Null
    Write-RuntimeConfig -ExtensionPath $stageExtension
    if (-not (Test-PluginPayload -ExtensionPath $stageExtension -LoaderPath $stageLoader)) {
        throw "Staged plugin payload is incomplete: $resolvedStageRoot"
    }

    return [PSCustomObject]@{
        Root = $resolvedStageRoot
        Extension = $stageExtension
        Loader = $stageLoader
        RollbackRoot = (Join-Path $resolvedStageRoot 'previous')
    }
}

function Remove-PluginItem {
    param(
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [switch]$Directory
    )

    $resolvedTarget = Assert-PluginsChildPath $TargetPath
    if (-not (Test-Path -LiteralPath $resolvedTarget)) {
        return
    }
    if ($Directory) {
        Remove-Item -LiteralPath $resolvedTarget -Recurse -Force
    } else {
        Remove-Item -LiteralPath $resolvedTarget -Force
    }
}

[void](Assert-PluginsChildPath $destinationExtension)
[void](Assert-PluginsChildPath $destinationLoader)
if ((Test-Path -LiteralPath $destinationExtension) -and -not (Test-Path -LiteralPath $destinationExtension -PathType Container)) {
    throw "Expected plugin extension directory but found a different item: $destinationExtension"
}
if ((Test-Path -LiteralPath $destinationLoader) -and -not (Test-Path -LiteralPath $destinationLoader -PathType Leaf)) {
    throw "Expected plugin loader file but found a different item: $destinationLoader"
}

$extensionExists = Test-Path -LiteralPath $destinationExtension -PathType Container
$loaderExists = Test-Path -LiteralPath $destinationLoader -PathType Leaf
$pluginExists = $extensionExists -or $loaderExists
if ($pluginExists -and -not $Update) {
    throw 'A Codex SketchUp MCP plugin is already installed. Run this script with -Update to create a project-local backup and replace it.'
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$stageRoot = Join-Path $resolvedPluginsRoot ".codex-sketchup-mcp-stage-$timestamp-$PID"
[void](Assert-PluginsChildPath $stageRoot)

if ($pluginExists -and $Update) {
    $backupDestination = Join-Path $resolvedBackupRoot "sketchup-plugin-$timestamp"
    if ($PSCmdlet.ShouldProcess($resolvedPluginsRoot, "Back up, stage, and update Codex SketchUp MCP plugin to $backupDestination")) {
        $stagePayload = $null
        $previousExtensionMoved = $false
        $previousLoaderMoved = $false
        try {
            $stagePayload = New-StagedPluginPayload -StageRoot $stageRoot
            if (Test-Path -LiteralPath $backupDestination) {
                throw "Plugin backup folder already exists: $backupDestination"
            }
            if (-not (Test-Path -LiteralPath $resolvedBackupRoot -PathType Container)) {
                New-Item -ItemType Directory -Path $resolvedBackupRoot -Force | Out-Null
            }
            New-Item -ItemType Directory -Path $backupDestination | Out-Null
            if ($extensionExists) {
                Copy-Item -LiteralPath $destinationExtension -Destination (Join-Path $backupDestination 'codex_sketchup_mcp') -Recurse | Out-Null
            }
            if ($loaderExists) {
                Copy-Item -LiteralPath $destinationLoader -Destination (Join-Path $backupDestination 'sketchup_mcp_port_bridge.rb') | Out-Null
            }

            New-Item -ItemType Directory -Path $stagePayload.RollbackRoot | Out-Null
            $rollbackExtension = Join-Path $stagePayload.RollbackRoot 'codex_sketchup_mcp'
            $rollbackLoader = Join-Path $stagePayload.RollbackRoot 'sketchup_mcp_port_bridge.rb'
            if ($extensionExists) {
                Move-Item -LiteralPath $destinationExtension -Destination $rollbackExtension
                $previousExtensionMoved = $true
            }
            if ($loaderExists) {
                Move-Item -LiteralPath $destinationLoader -Destination $rollbackLoader
                $previousLoaderMoved = $true
            }

            Move-Item -LiteralPath $stagePayload.Extension -Destination $destinationExtension
            Move-Item -LiteralPath $stagePayload.Loader -Destination $destinationLoader
            if (-not (Test-PluginPayload -ExtensionPath $destinationExtension -LoaderPath $destinationLoader)) {
                throw 'The replacement plugin payload failed validation after installation'
            }
            Remove-PluginItem -TargetPath $stagePayload.Root -Directory

            Write-Host "Backed up the previous plugin to $backupDestination"
            Write-Host "Updated plugin files in $resolvedPluginsRoot"
            Write-Host 'Restart SketchUp, then run .\scripts\check-bridge.ps1 to verify the bridge.'
        } catch {
            $originalError = $_.Exception.Message
            $rollbackErrors = [System.Collections.Generic.List[string]]::new()
            $rollbackExtension = if ($stagePayload) { Join-Path $stagePayload.RollbackRoot 'codex_sketchup_mcp' } else { $null }
            $rollbackLoader = if ($stagePayload) { Join-Path $stagePayload.RollbackRoot 'sketchup_mcp_port_bridge.rb' } else { $null }

            if ($previousExtensionMoved -or -not $extensionExists) {
                try { Remove-PluginItem -TargetPath $destinationExtension -Directory } catch { [void]$rollbackErrors.Add("Could not remove replacement extension: $($_.Exception.Message)") }
            }
            if ($previousLoaderMoved -or -not $loaderExists) {
                try { Remove-PluginItem -TargetPath $destinationLoader } catch { [void]$rollbackErrors.Add("Could not remove replacement loader: $($_.Exception.Message)") }
            }
            if ($previousExtensionMoved) {
                try {
                    if (-not (Test-Path -LiteralPath $rollbackExtension -PathType Container)) { throw 'Previous extension payload is missing from the rollback folder' }
                    Move-Item -LiteralPath $rollbackExtension -Destination $destinationExtension
                } catch { [void]$rollbackErrors.Add("Could not restore previous extension: $($_.Exception.Message)") }
            }
            if ($previousLoaderMoved) {
                try {
                    if (-not (Test-Path -LiteralPath $rollbackLoader -PathType Leaf)) { throw 'Previous loader file is missing from the rollback folder' }
                    Move-Item -LiteralPath $rollbackLoader -Destination $destinationLoader
                } catch { [void]$rollbackErrors.Add("Could not restore previous loader: $($_.Exception.Message)") }
            }

            if ($rollbackErrors.Count -eq 0 -and $stagePayload) {
                try { Remove-PluginItem -TargetPath $stagePayload.Root -Directory } catch { [void]$rollbackErrors.Add("Could not clean the staging folder: $($_.Exception.Message)") }
            }
            if ($rollbackErrors.Count -gt 0) {
                $stageLocation = if ($stagePayload) { $stagePayload.Root } else { $stageRoot }
                throw "Plugin update failed. Original error: $originalError. Automatic recovery also failed: $($rollbackErrors -join '; '). The staging folder was preserved at $stageLocation."
            }
            throw "Plugin update failed; the previous plugin was restored. Original error: $originalError"
        }
    }
    return
}

if ($PSCmdlet.ShouldProcess($resolvedPluginsRoot, 'Install Codex SketchUp MCP plugin')) {
    $stagePayload = $null
    try {
        $stagePayload = New-StagedPluginPayload -StageRoot $stageRoot
        Move-Item -LiteralPath $stagePayload.Extension -Destination $destinationExtension
        Move-Item -LiteralPath $stagePayload.Loader -Destination $destinationLoader
        if (-not (Test-PluginPayload -ExtensionPath $destinationExtension -LoaderPath $destinationLoader)) {
            throw 'The installed plugin payload failed validation'
        }
        Remove-PluginItem -TargetPath $stagePayload.Root -Directory

        Write-Host "Installed plugin files in $resolvedPluginsRoot"
        Write-Host 'Restart SketchUp, then run .\scripts\check-bridge.ps1 to verify the bridge.'
    } catch {
        $originalError = $_.Exception.Message
        $cleanupErrors = [System.Collections.Generic.List[string]]::new()
        try { Remove-PluginItem -TargetPath $destinationExtension -Directory } catch { [void]$cleanupErrors.Add("Could not remove partial extension: $($_.Exception.Message)") }
        try { Remove-PluginItem -TargetPath $destinationLoader } catch { [void]$cleanupErrors.Add("Could not remove partial loader: $($_.Exception.Message)") }
        if ($stagePayload) {
            try { Remove-PluginItem -TargetPath $stagePayload.Root -Directory } catch { [void]$cleanupErrors.Add("Could not clean the staging folder: $($_.Exception.Message)") }
        }
        if ($cleanupErrors.Count -gt 0) {
            throw "Plugin installation failed. Original error: $originalError. Cleanup also failed: $($cleanupErrors -join '; ')"
        }
        throw "Plugin installation failed and partial files were removed. Original error: $originalError"
    }
}
