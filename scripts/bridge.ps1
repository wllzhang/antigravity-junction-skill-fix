<#
.SYNOPSIS
    antigravity-junction-skill-fix - Core Bridge Engine
    Seamlessly bridges NTFS Directory Junctions and Symlinks into real directories with hardlinks for Antigravity.

.DESCRIPTION
    Scans Antigravity skill directories (global ~/.gemini/config/skills and active workspaces),
    detects NTFS Directory Junctions (mklink /J) and Directory Symlinks (mklink /D),
    and transforms them into real directories with zero-copy NTFS hardlinks so that Antigravity's
    Go-based Language Server can discover SKILL.md.

.PARAMETER Action
    Operation to perform: 'Scan', 'Bridge', 'Sync', 'Restore', or 'Status'. Default is 'Bridge'.

.PARAMETER TargetDir
    Explicit directory or directories to inspect. Defaults to global and workspace skills directories.

.PARAMETER Force
    Force re-bridging even if up-to-date.

.PARAMETER HookMode
    Runs in Antigravity lifecycle hook mode (reads stdin context, outputs JSON {} to stdout).
#>

[CmdletBinding(DefaultParameterSetName = 'Cli')]
param(
    [Parameter(ParameterSetName = 'Cli', Position = 0)]
    [ValidateSet('Scan', 'Bridge', 'Sync', 'Restore', 'Status')]
    [string]$Action = 'Bridge',

    [Parameter(ParameterSetName = 'Cli')]
    [string[]]$TargetDir,

    [Parameter(ParameterSetName = 'Cli')]
    [switch]$Force,

    [Parameter(ParameterSetName = 'Hook')]
    [switch]$HookMode
)

# ------------------------------------------------------------------------------
# 1. Cross-Platform Guard
# ------------------------------------------------------------------------------
$isWindowsOS = if ($PSVersionTable.Platform) {
    $PSVersionTable.Platform -eq 'Win32NT'
} else {
    [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
}

if (-not $isWindowsOS) {
    if ($HookMode) {
        Write-Output '{}'
    } else {
        Write-Host "antigravity-junction-skill-fix: Running on non-Windows OS ($([System.Environment]::OSVersion.Platform)). Symlinks are natively supported. No bridge required." -ForegroundColor Cyan
    }
    exit 0
}

# ------------------------------------------------------------------------------
# 2. Helper Functions
# ------------------------------------------------------------------------------

function Write-Log {
    param([string]$Message, [string]$Level = 'Info')
    if ($HookMode) {
        # Antigravity hooks require clean JSON on stdout; send diagnostic logs to stderr or debug stream
        [System.Console]::Error.WriteLine("[bridge-fix][$Level] $Message")
    } else {
        $color = switch ($Level) {
            'Warn'  { 'Yellow' }
            'Error' { 'Red' }
            'Success' { 'Green' }
            default { 'Cyan' }
        }
        Write-Host "[bridge-fix][$Level] $Message" -ForegroundColor $color
    }
}

function Test-IsReparsePoint {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        # ReparsePoint attribute value is 1024 (0x400)
        return (($item.Attributes.value__ -band 1024) -ne 0)
    } catch {
        return $false
    }
}

function Get-LinkTypeAndRawTarget {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    $linkType = if ($item.LinkType) { $item.LinkType } else { 'Junction' }
    
    $rawTarget = $null
    if ($item.PSObject.Properties['LinkTarget'] -and $item.LinkTarget) {
        $rawTarget = $item.LinkTarget
    } elseif ($item.PSObject.Properties['Target'] -and $item.Target) {
        $rawTarget = if ($item.Target -is [array]) { $item.Target[0] } else { $item.Target }
    }
    
    if (-not $rawTarget) {
        # Fallback using cmd dir /al to parse target if PowerShell property is empty
        $dirOutput = cmd /c "dir /a:l `"$Path`" 2>nul"
        if ($dirOutput -match '\[(.*?)\]') {
            $rawTarget = $Matches[1]
        }
    }

    return @{
        LinkType = $linkType
        RawTarget = $rawTarget
    }
}

function Resolve-TargetRecursive {
    param([string]$Path)
    $current = $Path
    $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    while ($true) {
        if (-not (Test-Path -LiteralPath $current)) { break }
        $item = Get-Item -LiteralPath $current -Force
        
        # Check if reparse point
        if (($item.Attributes.value__ -band 1024) -eq 0) {
            return $current
        }

        if ($visited.Contains($current)) {
            Write-Log "Circular junction detected at: $current" 'Warn'
            return $current
        }
        $visited.Add($current) | Out-Null

        $nextTarget = $null
        if ($item.PSObject.Properties['ResolvedTarget'] -and $item.ResolvedTarget) {
            $nextTarget = $item.ResolvedTarget
        } else {
            $linkInfo = Get-LinkTypeAndRawTarget -Path $current
            $nextTarget = $linkInfo.RawTarget
        }

        if (-not $nextTarget -or (-not (Test-Path -LiteralPath $nextTarget))) {
            return $current
        }
        $current = $nextTarget
    }
    return $current
}

function Test-IsBridgedFolder {
    param([string]$Path)
    $metaFile = Join-Path $Path '.bridge_meta.json'
    return (Test-Path -LiteralPath $metaFile)
}

function Read-BridgeMeta {
    param([string]$Path)
    $metaFile = Join-Path $Path '.bridge_meta.json'
    if (Test-Path -LiteralPath $metaFile) {
        try {
            return (Get-Content -LiteralPath $metaFile -Raw -Encoding UTF8 | ConvertFrom-Json)
        } catch {
            return $null
        }
    }
    return $null
}

function Save-BridgeMeta {
    param([string]$Path, [psobject]$Meta)
    $metaFile = Join-Path $Path '.bridge_meta.json'
    $json = $Meta | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath $metaFile -Value $json -Encoding UTF8 -Force
    # Set hidden attribute to keep it unobtrusive
    try {
        (Get-Item -LiteralPath $metaFile -Force).Attributes = 'Hidden, Archive'
    } catch {}
}

function Create-HardLinkOrCopy {
    param([string]$SourceFile, [string]$DestFile)
    
    $destDir = [System.IO.Path]::GetDirectoryName($DestFile)
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    if (Test-Path -LiteralPath $DestFile) {
        Remove-Item -LiteralPath $DestFile -Force
    }

    $srcRoot = [System.IO.Path]::GetPathRoot($SourceFile)
    $destRoot = [System.IO.Path]::GetPathRoot($DestFile)

    # If same volume, use NTFS HardLink (zero copy, instant synchronization)
    if ($srcRoot -and $destRoot -and ($srcRoot.TrimEnd('\') -ieq $destRoot.TrimEnd('\'))) {
        try {
            New-Item -ItemType HardLink -Path $DestFile -Target $SourceFile -Force -ErrorAction Stop | Out-Null
            return 'HardLink'
        } catch {
            # Fallback to copy if HardLink creation fails
            Copy-Item -LiteralPath $SourceFile -Destination $DestFile -Force
            return 'Copy'
        }
    } else {
        # Cross-volume boundary: Hardlinks cannot cross volumes, fallback to copy
        Copy-Item -LiteralPath $SourceFile -Destination $DestFile -Force
        return 'Copy'
    }
}

# ------------------------------------------------------------------------------
# 3. Core Engine Operations: Bridge, Sync, Restore, Scan
# ------------------------------------------------------------------------------

function Invoke-BridgeDirectory {
    param(
        [string]$DirectoryPath,
        [switch]$ForceBridge
    )

    if (-not (Test-Path -LiteralPath $DirectoryPath)) { return }

    $isReparse = Test-IsReparsePoint -Path $DirectoryPath
    $isBridged = Test-IsBridgedFolder -Path $DirectoryPath

    if (-not $isReparse -and -not $isBridged) {
        return # Regular directory, nothing to do
    }

    if ($isBridged -and -not $ForceBridge) {
        Invoke-SyncDirectory -DirectoryPath $DirectoryPath
        return
    }

    if ($isBridged -and $ForceBridge) {
        $existingMeta = Read-BridgeMeta -Path $DirectoryPath
        if (-not $existingMeta) { return }
        $rawTarget = $existingMeta.linkTarget
        $linkType = $existingMeta.originalType
        $targetToCheck = if ($rawTarget) { $rawTarget } else { $existingMeta.resolvedTarget }
        $resolvedTarget = Resolve-TargetRecursive -Path $targetToCheck

        if (-not $resolvedTarget -or (-not (Test-Path -LiteralPath $resolvedTarget))) {
            Write-Log "Cannot force re-bridge '$DirectoryPath': Target '$resolvedTarget' does not exist." 'Warn'
            return
        }

        Write-Log "Force re-bridging: $DirectoryPath -> $resolvedTarget (Type: $linkType)" 'Info'
        Get-ChildItem -LiteralPath $DirectoryPath -Force | Remove-Item -Recurse -Force -ErrorAction Stop
    } else {
        # Extract link information from raw reparse point
        $linkInfo = Get-LinkTypeAndRawTarget -Path $DirectoryPath
        $rawTarget = $linkInfo.RawTarget
        $linkType = $linkInfo.LinkType
        $resolvedTarget = Resolve-TargetRecursive -Path $DirectoryPath

        if (-not $resolvedTarget -or (-not (Test-Path -LiteralPath $resolvedTarget))) {
            Write-Log "Cannot bridge '$DirectoryPath': Target '$resolvedTarget' does not exist." 'Warn'
            return
        }

        Write-Log "Bridging: $DirectoryPath -> $resolvedTarget (Type: $linkType)" 'Info'

        # Safely remove the junction/symlink reparse point (leaving target directory untouched)
        cmd /c "rmdir `"$DirectoryPath`"" 2>&1 | Out-Null

        if (Test-Path -LiteralPath $DirectoryPath) {
            Write-Log "Failed to unmount junction at $DirectoryPath" 'Error'
            return
        }

        # Create real directory
        New-Item -ItemType Directory -Path $DirectoryPath -Force | Out-Null
    }

    # Prepare metadata
    $meta = @{
        version = '1.0.0'
        originalType = $linkType
        linkTarget = $rawTarget
        resolvedTarget = $resolvedTarget
        bridgedAt = (Get-Date).ToString('o')
        lastSyncAt = (Get-Date).ToString('o')
        bridgeMode = 'Pending'
    }

    # Mirror files
    $modeUsed = 'HardLink'
    $srcFiles = Get-ChildItem -LiteralPath $resolvedTarget -Recurse -File -Force
    foreach ($file in $srcFiles) {
        $relativePath = $file.FullName.Substring($resolvedTarget.Length).TrimStart('\', '/')
        $destFile = Join-Path $DirectoryPath $relativePath
        $res = Create-HardLinkOrCopy -SourceFile $file.FullName -DestFile $destFile
        if ($res -eq 'Copy') { $modeUsed = 'Copy' }
    }

    $meta['bridgeMode'] = $modeUsed
    Save-BridgeMeta -Path $DirectoryPath -Meta $meta
    Write-Log "Bridge created successfully: $DirectoryPath ($modeUsed mode)" 'Success'
}

function Invoke-SyncDirectory {
    param([string]$DirectoryPath)

    $meta = Read-BridgeMeta -Path $DirectoryPath
    if (-not $meta) { return }

    $targetToCheck = if ($meta.linkTarget) { $meta.linkTarget } else { $meta.resolvedTarget }
    $currentResolved = Resolve-TargetRecursive -Path $targetToCheck

    if (-not $currentResolved -or (-not (Test-Path -LiteralPath $currentResolved))) {
        Write-Log "Cannot sync '$DirectoryPath': Source target '$currentResolved' no longer exists." 'Warn'
        return
    }

    $targetChanged = ($currentResolved -ine $meta.resolvedTarget)
    if ($targetChanged) {
        Write-Log "Upstream target updated: '$($meta.resolvedTarget)' -> '$currentResolved'" 'Info'
        $meta.resolvedTarget = $currentResolved
    }

    $srcFiles = Get-ChildItem -LiteralPath $currentResolved -Recurse -File -Force
    $destFiles = Get-ChildItem -LiteralPath $DirectoryPath -Recurse -File -Force | Where-Object { $_.Name -ne '.bridge_meta.json' }

    $srcRelMap = @{}
    foreach ($f in $srcFiles) {
        $rel = $f.FullName.Substring($currentResolved.Length).TrimStart('\', '/')
        $srcRelMap[$rel] = $f
    }

    $destRelMap = @{}
    foreach ($df in $destFiles) {
        $rel = $df.FullName.Substring($DirectoryPath.Length).TrimStart('\', '/')
        $destRelMap[$rel] = $df
    }

    # 1. Remove deleted files and orphaned empty subdirectories
    $hasUpdated = $targetChanged
    foreach ($rel in $destRelMap.Keys) {
        if (-not $srcRelMap.ContainsKey($rel)) {
            Remove-Item -LiteralPath $destRelMap[$rel].FullName -Force -ErrorAction SilentlyContinue
            $hasUpdated = $true
        }
    }

    $destDirs = @(Get-ChildItem -LiteralPath $DirectoryPath -Recurse -Directory -Force -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending)
    foreach ($dd in $destDirs) {
        $relDir = $dd.FullName.Substring($DirectoryPath.Length).TrimStart('\', '/')
        $srcDir = Join-Path $currentResolved $relDir
        if (-not (Test-Path -LiteralPath $srcDir)) {
            $remaining = @(Get-ChildItem -LiteralPath $dd.FullName -Force -ErrorAction SilentlyContinue)
            if ($remaining.Count -eq 0) {
                Remove-Item -LiteralPath $dd.FullName -Force -ErrorAction SilentlyContinue
                $hasUpdated = $true
            }
        }
    }

    # 2. Add new files or update modified files in Copy mode or when target changed
    foreach ($rel in $srcRelMap.Keys) {
        $srcFile = $srcRelMap[$rel]
        $destFile = Join-Path $DirectoryPath $rel

        $needsUpdate = $false
        if (-not $destRelMap.ContainsKey($rel)) {
            $needsUpdate = $true
        } elseif ($meta.bridgeMode -eq 'Copy' -or $targetChanged) {
            $destFileItem = $destRelMap[$rel]
            if ($srcFile.Length -ne $destFileItem.Length -or $srcFile.LastWriteTimeUtc -ne $destFileItem.LastWriteTimeUtc) {
                $needsUpdate = $true
            }
        }

        if ($needsUpdate) {
            $res = Create-HardLinkOrCopy -SourceFile $srcFile.FullName -DestFile $destFile
            if ($res -eq 'Copy') { $meta.bridgeMode = 'Copy' }
            $hasUpdated = $true
        }
    }

    $meta.lastSyncAt = (Get-Date).ToString('o')
    Save-BridgeMeta -Path $DirectoryPath -Meta $meta
    if ($hasUpdated) {
        Write-Log "Bridge synced with updates: $DirectoryPath" 'Info'
    }
}

function Invoke-RestoreDirectory {
    param([string]$DirectoryPath)

    $meta = Read-BridgeMeta -Path $DirectoryPath
    if (-not $meta) {
        Write-Log "Cannot restore '$DirectoryPath': No .bridge_meta.json found." 'Warn'
        return
    }

    $originalType = $meta.originalType
    $linkTarget = $meta.linkTarget

    Write-Log "Restoring '$DirectoryPath' to original $originalType -> '$linkTarget'..." 'Info'

    # Remove the bridged real directory and all hardlinks/copies
    Remove-Item -LiteralPath $DirectoryPath -Recurse -Force

    # Recreate the original link
    if ($originalType -ieq 'SymbolicLink') {
        cmd /c "mklink /D `"$DirectoryPath`" `"$linkTarget`"" 2>&1 | Out-Null
    } else {
        # Default to NTFS Junction
        cmd /c "mklink /J `"$DirectoryPath`" `"$linkTarget`"" 2>&1 | Out-Null
    }

    if (Test-IsReparsePoint -Path $DirectoryPath) {
        Write-Log "Restored successfully: $DirectoryPath" 'Success'
    } else {
        Write-Log "Failed to recreate link at: $DirectoryPath" 'Error'
    }
}

function Get-SkillSearchDirectories {
    param([string[]]$WorkspaceRoots)

    $dirs = [System.Collections.Generic.List[string]]::new()

    # 1. User Global Skills: ~/.gemini/config/skills
    $userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
    if ($userHome) {
        $globalSkills = Join-Path $userHome ".gemini\config\skills"
        if (Test-Path -LiteralPath $globalSkills) {
            $dirs.Add($globalSkills)
        }
    }

    # 2. Workspace Skills: <workspace>/.agents/skills & <workspace>/.gemini/skills
    if ($WorkspaceRoots) {
        foreach ($ws in $WorkspaceRoots) {
            if ($ws -and (Test-Path -LiteralPath $ws)) {
                $wsAgentSkills = Join-Path $ws ".agents\skills"
                if (Test-Path -LiteralPath $wsAgentSkills) { $dirs.Add($wsAgentSkills) }
                $wsGeminiSkills = Join-Path $ws ".gemini\skills"
                if (Test-Path -LiteralPath $wsGeminiSkills) { $dirs.Add($wsGeminiSkills) }
            }
        }
    }

    return $dirs
}

# ------------------------------------------------------------------------------
# 4. Main Execution Controller
# ------------------------------------------------------------------------------

$workspacesFromHook = @()

if ($HookMode) {
    # Read hook context from stdin if available
    try {
        if ([System.Console]::IsInputRedirected) {
            $rawInput = [System.Console]::In.ReadToEnd()
            if ($rawInput -and $rawInput.Trim().Length -gt 0) {
                $hookData = $rawInput | ConvertFrom-Json
                if ($hookData.workspacePaths) {
                    $workspacesFromHook = @($hookData.workspacePaths)
                }
            }
        }
    } catch {
        # Non-critical parsing failure, continue with defaults
    }
    # Force action to Bridge in hook mode
    $Action = 'Bridge'
}

# Determine candidate directories
$searchDirs = [System.Collections.Generic.List[string]]::new()

if ($TargetDir -and $TargetDir.Length -gt 0) {
    foreach ($td in $TargetDir) {
        if (Test-Path -LiteralPath $td) { $searchDirs.Add($td) }
    }
} else {
    $foundDirs = Get-SkillSearchDirectories -WorkspaceRoots $workspacesFromHook
    foreach ($fd in $foundDirs) { $searchDirs.Add($fd) }
}

# Scan and execute action
$statusList = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($parentDir in $searchDirs) {
    if (-not (Test-Path -LiteralPath $parentDir)) { continue }

    $entries = Get-ChildItem -LiteralPath $parentDir -Force
    foreach ($entry in $entries) {
        $itemPath = $entry.FullName
        $isReparse = Test-IsReparsePoint -Path $itemPath
        $isBridged = Test-IsBridgedFolder -Path $itemPath

        if ($Action -eq 'Status' -or $Action -eq 'Scan') {
            if ($isReparse -or $isBridged) {
                $meta = Read-BridgeMeta -Path $itemPath
                $linkInfo = if ($isReparse) { Get-LinkTypeAndRawTarget -Path $itemPath } else { @{ LinkType = $meta.originalType; RawTarget = $meta.linkTarget } }
                $statusList.Add([PSCustomObject]@{
                    Path = $itemPath
                    Name = $entry.Name
                    Status = if ($isBridged) { 'Bridged' } elseif ($isReparse) { 'RawReparsePoint' } else { 'Regular' }
                    LinkType = $linkInfo.LinkType
                    Target = $linkInfo.RawTarget
                    ResolvedTarget = if ($meta) { $meta.resolvedTarget } else { Resolve-TargetRecursive -Path $itemPath }
                })
            }
        } elseif ($Action -eq 'Bridge') {
            if ($isReparse) {
                Invoke-BridgeDirectory -DirectoryPath $itemPath
            } elseif ($isBridged -and $Force) {
                Invoke-BridgeDirectory -DirectoryPath $itemPath -ForceBridge
            } elseif ($isBridged) {
                Invoke-SyncDirectory -DirectoryPath $itemPath
            }
        } elseif ($Action -eq 'Sync') {
            if ($isBridged) {
                Invoke-SyncDirectory -DirectoryPath $itemPath
            }
        } elseif ($Action -eq 'Restore') {
            if ($isBridged) {
                Invoke-RestoreDirectory -DirectoryPath $itemPath
            }
        }
    }
}

if ($HookMode) {
    # Antigravity SessionStart hook contract requires clean JSON on stdout
    Write-Output '{}'
} elseif ($Action -eq 'Status' -or $Action -eq 'Scan') {
    if ($statusList.Count -eq 0) {
        Write-Host "No directory junctions or bridged skills found in scanned paths." -ForegroundColor DarkGray
    } else {
        $statusList | Format-Table -AutoSize
    }
}
