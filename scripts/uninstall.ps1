<#
.SYNOPSIS
    Uninstalls antigravity-junction-skill-fix and restores all bridged directories.

.DESCRIPTION
    Rolls back bridged directories back to original NTFS Junctions and removes plugin files.
#>

[CmdletBinding()]
param(
    [switch]$KeepBridges
)

$ErrorActionPreference = 'Stop'

Write-Host "==========================================================" -ForegroundColor Yellow
Write-Host " Uninstalling antigravity-junction-skill-fix" -ForegroundColor Yellow
Write-Host "==========================================================" -ForegroundColor Yellow

$scriptRoot = $PSScriptRoot
$bridgeScript = Join-Path $scriptRoot 'bridge.ps1'

if (-not $KeepBridges -and (Test-Path -LiteralPath $bridgeScript)) {
    Write-Host "Restoring bridged directories back to original Junctions/Symlinks..." -ForegroundColor Cyan
    & $bridgeScript -Action Restore
}

$userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$pluginDir = Join-Path $userHome ".gemini\config\plugins\antigravity-junction-skill-fix"

if (Test-Path -LiteralPath $pluginDir) {
    Write-Host "Removing installed plugin from: $pluginDir" -ForegroundColor Cyan
    Remove-Item -LiteralPath $pluginDir -Recurse -Force
}

Write-Host "Uninstallation complete. System restored to original state." -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Yellow
