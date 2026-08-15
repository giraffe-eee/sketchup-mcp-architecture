[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$SketchUpVersion = '2026',
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

if ([string]::IsNullOrWhiteSpace($PluginsRoot)) {
    $PluginsRoot = Join-Path $env:APPDATA "SketchUp\SketchUp $SketchUpVersion\SketchUp\Plugins"
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
if (-not (Test-Path -LiteralPath $PluginsRoot -PathType Container)) {
    throw "SketchUp plugin folder is missing: $PluginsRoot"
}
if (Get-Process -Name SketchUp -ErrorAction SilentlyContinue) {
    throw 'SketchUp is running. Save work and close SketchUp before installing or updating this plugin.'
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
        (Join-Path $ExtensionPath 'action_catalog.json')
    )
    foreach ($requiredFile in $requiredFiles) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            return $false
        }
    }
    return $true
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
            Write-Host 'Restart SketchUp, then use check-bridge.ps1 to verify the localhost bridge.'
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
        Write-Host 'Restart SketchUp, then use check-bridge.ps1 to verify the localhost bridge.'
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
