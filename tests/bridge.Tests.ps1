<#
.SYNOPSIS
    Automated Test Suite for antigravity-junction-skill-fix.

.DESCRIPTION
    Executes comprehensive unit & integration tests covering:
    - Junction detection and recursive resolution
    - Bridge conversion to real directories
    - NTFS hardlink integrity and zero-redundancy live synchronization
    - Incremental sync when source adds new files
    - 100% reversible restore back to original NTFS Junction
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testDir = Join-Path $PSScriptRoot "temp_test_sandbox"
$bridgeScript = Join-Path (Join-Path $PSScriptRoot "..") "scripts\bridge.ps1"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Running antigravity-junction-skill-fix Test Suite" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# Cleanup existing test sandbox
if (Test-Path -LiteralPath $testDir) {
    Remove-Item -LiteralPath $testDir -Recurse -Force
}
New-Item -ItemType Directory -Path $testDir -Force | Out-Null

$passCount = 0
$failCount = 0

function Assert-Test {
    param([string]$Name, [bool]$Condition, [string]$Details = '')
    if ($Condition) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green
        $script:passCount++
    } else {
        Write-Host "  [FAIL] ${Name} - $Details" -ForegroundColor Red
        $script:failCount++
    }
}

try {
    # --------------------------------------------------------------------------
    # Setup test directory layout
    # --------------------------------------------------------------------------
    $mockSkillsDir = Join-Path $testDir "skills"
    $realAppDir = Join-Path $testDir "app_install\v1\my-skill"
    $hopDir = Join-Path $testDir "intermediate_hop\hop-skill"

    New-Item -ItemType Directory -Path $mockSkillsDir -Force | Out-Null
    New-Item -ItemType Directory -Path $realAppDir -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path $hopDir) -Force | Out-Null

    # Create real skill content
    $skillMdContent = "# Test Skill`nThis is a test skill content."
    Set-Content -LiteralPath (Join-Path $realAppDir "SKILL.md") -Value $skillMdContent -Encoding UTF8
    New-Item -ItemType Directory -Path (Join-Path $realAppDir "scripts") -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $realAppDir "scripts\run.cmd") -Value "@echo test" -Encoding UTF8

    # Create 2-tier junction:
    # 1. Hop junction: $hopDir -> $realAppDir
    cmd /c "mklink /J `"$hopDir`" `"$realAppDir`"" 2>&1 | Out-Null
    # 2. Main junction: $mockSkillsDir\test-skill -> $hopDir
    $junctionSkill = Join-Path $mockSkillsDir "test-skill"
    cmd /c "mklink /J `"$junctionSkill`" `"$hopDir`"" 2>&1 | Out-Null

    Write-Host "`nTest Group 1: Detection & Multi-Hop Resolution" -ForegroundColor Yellow
    $item = Get-Item -LiteralPath $junctionSkill -Force
    $isReparse = (($item.Attributes.value__ -band 1024) -ne 0)
    Assert-Test -Name "Junction identified as ReparsePoint" -Condition $isReparse

    # Run Scan via bridge.ps1
    & $bridgeScript -Action Scan -TargetDir $mockSkillsDir

    # --------------------------------------------------------------------------
    # Test Group 2: Bridge Conversion
    # --------------------------------------------------------------------------
    Write-Host "`nTest Group 2: Bridge Conversion to Real Directory" -ForegroundColor Yellow
    & $bridgeScript -Action Bridge -TargetDir $mockSkillsDir

    $bridgedItem = Get-Item -LiteralPath $junctionSkill -Force
    $isNowReparse = (($bridgedItem.Attributes.value__ -band 1024) -ne 0)
    $hasSkillMd = Test-Path -LiteralPath (Join-Path $junctionSkill "SKILL.md")
    $hasMeta = Test-Path -LiteralPath (Join-Path $junctionSkill ".bridge_meta.json")

    Assert-Test -Name "ReparsePoint converted to real directory (d----)" -Condition (-not $isNowReparse)
    Assert-Test -Name "SKILL.md exists in bridged directory" -Condition $hasSkillMd
    Assert-Test -Name ".bridge_meta.json exists" -Condition $hasMeta

    # Read meta
    $meta = Get-Content -LiteralPath (Join-Path $junctionSkill ".bridge_meta.json") -Raw | ConvertFrom-Json
    Assert-Test -Name "Metadata recorded originalType as Junction" -Condition ($meta.originalType -eq 'Junction')
    Assert-Test -Name "Metadata resolved 2-hop target to realAppDir" -Condition ($meta.resolvedTarget -ieq $realAppDir)
    Assert-Test -Name "Metadata used HardLink bridgeMode" -Condition ($meta.bridgeMode -eq 'HardLink')

    # --------------------------------------------------------------------------
    # Test Group 3: Hardlink Live Synchronization Test
    # --------------------------------------------------------------------------
    Write-Host "`nTest Group 3: Hardlink Live Synchronization" -ForegroundColor Yellow
    # Modify source SKILL.md and verify destination instantly reflects the modification without re-sync
    $newContent = "# Modified Content Live"
    Set-Content -LiteralPath (Join-Path $realAppDir "SKILL.md") -Value $newContent -Encoding UTF8
    $bridgedContent = Get-Content -LiteralPath (Join-Path $junctionSkill "SKILL.md") -Raw
    Assert-Test -Name "Source edit instantly visible in bridged file (NTFS Hardlink confirmation)" -Condition ($bridgedContent.Trim() -eq $newContent)

    # --------------------------------------------------------------------------
    # Test Group 4: Incremental File Sync
    # --------------------------------------------------------------------------
    Write-Host "`nTest Group 4: Incremental Sync for Newly Added Files" -ForegroundColor Yellow
    # Add new file in source
    Set-Content -LiteralPath (Join-Path $realAppDir "extra_file.txt") -Value "extra" -Encoding UTF8
    Assert-Test -Name "New file not yet in bridge before sync" -Condition (-not (Test-Path -LiteralPath (Join-Path $junctionSkill "extra_file.txt")))

    & $bridgeScript -Action Sync -TargetDir $mockSkillsDir
    Assert-Test -Name "New file bridged after Sync" -Condition (Test-Path -LiteralPath (Join-Path $junctionSkill "extra_file.txt"))

    # --------------------------------------------------------------------------
    # Test Group 5: Restore (Reversibility)
    # --------------------------------------------------------------------------
    Write-Host "`nTest Group 5: Restore (Unbridge) Reversibility" -ForegroundColor Yellow
    & $bridgeScript -Action Restore -TargetDir $mockSkillsDir

    $restoredItem = Get-Item -LiteralPath $junctionSkill -Force
    $isRestoredReparse = (($restoredItem.Attributes.value__ -band 1024) -ne 0)
    Assert-Test -Name "Directory restored back to ReparsePoint" -Condition $isRestoredReparse
    Assert-Test -Name "Source files completely intact" -Condition (Test-Path -LiteralPath (Join-Path $realAppDir "SKILL.md"))

} finally {
    # Clean up test sandbox
    if (Test-Path -LiteralPath $testDir) {
        Remove-Item -LiteralPath $testDir -Recurse -Force
    }
}

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host " Test Summary: $passCount Passed, $failCount Failed" -ForegroundColor $(if ($failCount -eq 0) { 'Green' } else { 'Red' })
Write-Host "==========================================================" -ForegroundColor Cyan

if ($failCount -gt 0) {
    exit 1
} else {
    exit 0
}
