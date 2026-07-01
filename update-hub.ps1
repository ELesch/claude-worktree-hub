<#
.SYNOPSIS
  Refresh THIS hub deployment's tracked tooling files from the pristine source clone.
.DESCRIPTION
  Run from inside the hub deployment you want to update. Overlays the TRACKED tooling files
  (git ls-files) from a source clone of ELesch/claude-worktree-hub onto this hub, skipping
  files that are content-identical (ignoring CRLF-only differences) and never touching
  gitignored runtime data or the per-deployment HUB-STATE.md.
.PARAMETER Source
  Path to a normal (non-bare) clone of ELesch/claude-worktree-hub. Default C:\mydev\claude-worktree-hub.
.PARAMETER DryRun
  Preview every action; write nothing to this deployment. Still refreshes the source (ff-only) unless -NoPull.
.PARAMETER NoPull
  Skip the source refresh; overlay the source's current checkout as-is.
.EXAMPLE
  .\update-hub.ps1 -DryRun
  .\update-hub.ps1
  .\update-hub.ps1 -Source D:\src\claude-worktree-hub -NoPull
#>
[CmdletBinding()]
param(
    [string]$Source = 'C:\mydev\claude-worktree-hub',
    [switch]$DryRun,
    [switch]$NoPull
)

# ---------- pure, unit-testable helpers (safe to dot-source) ----------

function ConvertTo-Crlf {
    <# Normalize any mix of CRLF/LF/CR line endings to CRLF. Idempotent. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    ($Text -replace "`r`n", "`n" -replace "`r", "`n") -replace "`n", "`r`n"
}

function Test-HubSourceRemote {
    <# True if a git remote URL points at ELesch/claude-worktree-hub (https or ssh, +/- .git). #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$RemoteUrl)
    $normalized = ($RemoteUrl.Trim() -replace '(?i)\.git/?$', '').TrimEnd('/')
    if ($normalized -match '[:/](?<slug>[^/]+/[^/]+)$') {
        return $Matches['slug'].ToLowerInvariant() -eq 'elesch/claude-worktree-hub'
    }
    return $false
}

function Get-HubUpdateSkipList {
    <# Tracked files that are per-deployment volatile and must NOT be overlaid. #>
    @('HUB-STATE.md')
}

function Get-OverlayAction {
    <# Decide the overlay action for one file: 'new' | 'updated' | 'unchanged'.
       $SourceNorm is the CRLF-normalized SOURCE content; $TargetContent is the raw target
       content (ignored unless -TargetExists). EOL-only differences => 'unchanged'. #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$SourceNorm,
        [AllowNull()][AllowEmptyString()][string]$TargetContent,
        [switch]$TargetExists
    )
    if (-not $TargetExists) { return 'new' }
    if ($SourceNorm -ceq (ConvertTo-Crlf $TargetContent)) { return 'unchanged' }
    return 'updated'
}

# ---------- main (skipped when the script is dot-sourced, e.g. by the tests) ----------

function Invoke-UpdateHub {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target,
        [switch]$DryRun,
        [switch]$NoPull
    )

    # --- resolve + validate the source clone ---
    if (-not (Test-Path $Source)) {
        throw "Source hub clone not found at '$Source'.`n  Clone it:  git clone https://github.com/ELesch/claude-worktree-hub.git '$Source'`n  or pass:   -Source <path to your claude-worktree-hub clone>"
    }
    $Source = (Resolve-Path $Source).Path
    $Target = (Resolve-Path $Target).Path

    $inWorkTree = & git -C $Source rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -ne 0 -or $inWorkTree -ne 'true') {
        throw "Source '$Source' is not a git work-tree. Pass -Source <path to a claude-worktree-hub clone>."
    }
    $remote = & git -C $Source remote get-url origin 2>$null
    if ($LASTEXITCODE -ne 0 -or -not (Test-HubSourceRemote $remote)) {
        throw "Source '$Source' origin is '$remote', not ELesch/claude-worktree-hub. Refusing to overlay from the wrong repo; pass the correct -Source."
    }

    Write-Host "Source : $Source" -ForegroundColor Cyan
    Write-Host "Target : $Target  (this hub)" -ForegroundColor Cyan
    if ($DryRun) { Write-Host "Mode   : DRY RUN - nothing will be written to this hub" -ForegroundColor DarkGray }

    # --- refresh the source (unless -NoPull); a failed pull is a WARNING, not fatal ---
    if ($NoPull) {
        Write-Host "Source refresh skipped (-NoPull); overlaying its current checkout." -ForegroundColor DarkGray
    } else {
        Write-Host "Refreshing source (git fetch + pull --ff-only)..." -ForegroundColor Cyan
        & git -C $Source fetch --quiet 2>&1 | Out-Null
        & git -C $Source pull --ff-only 2>&1 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  WARNING: source did not fast-forward (dirty or diverged); overlaying its CURRENT checkout." -ForegroundColor Yellow
        }
    }

    # --- running inside the source clone itself? nothing to overlay ---
    if ($Source -eq $Target) {
        Write-Host "`nYou are in the source clone itself - nothing to overlay." -ForegroundColor Yellow
        return
    }

    # --- enumerate tracked files and overlay ---
    $tracked = & git -C $Source ls-files
    if ($LASTEXITCODE -ne 0) { throw "git ls-files failed in source '$Source'." }
    $skip = Get-HubUpdateSkipList
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    $new = [System.Collections.Generic.List[string]]::new()
    $updated = [System.Collections.Generic.List[string]]::new()
    $skipped = [System.Collections.Generic.List[string]]::new()
    $unchanged = 0

    foreach ($rel in $tracked) {
        if ($skip -contains $rel) { $skipped.Add($rel); continue }
        $srcPath = Join-Path $Source $rel
        if (-not (Test-Path $srcPath)) { continue }   # tracked but absent on disk; skip defensively
        $dstPath = Join-Path $Target $rel
        $exists = Test-Path $dstPath
        $srcNorm = ConvertTo-Crlf ([System.IO.File]::ReadAllText($srcPath))
        $targetContent = if ($exists) { [System.IO.File]::ReadAllText($dstPath) } else { '' }
        $action = Get-OverlayAction -SourceNorm $srcNorm -TargetContent $targetContent -TargetExists:$exists

        if ($action -eq 'unchanged') { $unchanged++; continue }
        if ($action -eq 'new') { $new.Add($rel) } else { $updated.Add($rel) }
        if (-not $DryRun) {
            $dstDir = Split-Path -Parent $dstPath
            if ($dstDir -and -not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
            [System.IO.File]::WriteAllText($dstPath, $srcNorm, $utf8NoBom)
        }
    }

    # --- report ---
    $verb = if ($DryRun) { 'would ' } else { '' }
    Write-Host ""
    if ($updated.Count) {
        Write-Host "Updated ($($updated.Count)) - $($verb)overwrite:" -ForegroundColor Yellow
        $updated | ForEach-Object { Write-Host "  ~ $_" -ForegroundColor Yellow }
    }
    if ($new.Count) {
        Write-Host "New ($($new.Count)) - $($verb)create:" -ForegroundColor Green
        $new | ForEach-Object { Write-Host "  + $_" -ForegroundColor Green }
    }
    if (-not $updated.Count -and -not $new.Count) {
        Write-Host "Everything is already up to date." -ForegroundColor Green
    }
    Write-Host ""
    Write-Host ("{0} updated | {1} new | {2} unchanged | {3} skipped ({4})" -f `
        $updated.Count, $new.Count, $unchanged, $skipped.Count, ($skipped -join ', ')) -ForegroundColor Cyan
    if ($DryRun) { Write-Host "(dry-run - no files were written; re-run without -DryRun to apply)" -ForegroundColor DarkGray }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-UpdateHub -Source $Source -Target $PSScriptRoot -DryRun:$DryRun -NoPull:$NoPull
}
