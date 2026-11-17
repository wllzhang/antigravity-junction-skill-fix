<#
.SYNOPSIS
    Installs antigravity-junction-skill-fix plugin into Antigravity.

.DESCRIPTION
    Deploys the plugin to ~/.gemini/config/plugins/antigravity-junction-skill-fix (or workspace)
    and immediately executes an initial bridge scan.
#>

[CmdletBinding()]
param(
    [switch]$Workspace,
    [string]$CustomTargetDir
)

$ErrorActionPreference = 'Stop'

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Installing antigravity-junction-skill-fix Plugin" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$scriptRoot = $PSScriptRoot

$installDest = if ($CustomTargetDir) {
    $CustomTargetDir
} elseif ($Workspace) {
    Join-Path (Get-Location) ".agents\plugins\antigravity-junction-skill-fix"
} else {
    $userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
    Join-Path $userHome ".gemini\config\plugins\antigravity-junction-skill-fix"
}

Write-Host "Target install directory: $installDest" -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $installDest)) {
    New-Item -ItemType Directory -Path $installDest -Force | Out-Null
}

# Files to copy
$filesToCopy = @('plugin.json', 'hooks.json', 'LICENSE')
foreach ($f in $filesToCopy) {
    $src = Join-Path $scriptRoot $f
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination $installDest -Force
    }
}

# Copy scripts directory
$scriptsSrc = Join-Path $scriptRoot 'scripts'
$scriptsDest = Join-Path $installDest 'scripts'
if (-not (Test-Path -LiteralPath $scriptsDest)) {
    New-Item -ItemType Directory -Path $scriptsDest -Force | Out-Null
}
Copy-Item -Path (Join-Path $scriptsSrc '*') -Destination $scriptsDest -Recurse -Force

Write-Host "Plugin files deployed successfully." -ForegroundColor Green

# Run initial bridge scan
Write-Host "Running initial skill junction scan & bridge..." -ForegroundColor Cyan
$bridgeScript = Join-Path $scriptsDest 'bridge.ps1'
if (Test-Path -LiteralPath $bridgeScript) {
    & $bridgeScript -Action Bridge
}

Write-Host "----------------------------------------------------------" -ForegroundColor Green
Write-Host " Installation completed successfully!" -ForegroundColor Green
Write-Host " Antigravity will now automatically bridge junctions on SessionStart." -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
