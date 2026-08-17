[CmdletBinding()]
param(
    [string]$PythonPath,
    [string]$SketchUpVersion,
    [string]$PluginsRoot,
    [switch]$Update,
    [string]$BackupRoot,
    [switch]$SkipDependencyInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$bootstrapArguments = @{}
if (-not [string]::IsNullOrWhiteSpace($PythonPath)) {
    $bootstrapArguments.PythonPath = $PythonPath
}
if ($SkipDependencyInstall) {
    $bootstrapArguments.SkipDependencyInstall = $true
}

$pluginArguments = @{}
if (-not [string]::IsNullOrWhiteSpace($SketchUpVersion)) {
    $pluginArguments.SketchUpVersion = $SketchUpVersion
}
if (-not [string]::IsNullOrWhiteSpace($PluginsRoot)) {
    $pluginArguments.PluginsRoot = $PluginsRoot
}
if (-not [string]::IsNullOrWhiteSpace($BackupRoot)) {
    $pluginArguments.BackupRoot = $BackupRoot
}
if ($Update) {
    $pluginArguments.Update = $true
}

& (Join-Path $PSScriptRoot 'bootstrap.ps1') @bootstrapArguments
& (Join-Path $PSScriptRoot 'install-plugin.ps1') @pluginArguments

Write-Host 'Installation completed. Restart SketchUp, then run .\scripts\check-bridge.ps1.'
