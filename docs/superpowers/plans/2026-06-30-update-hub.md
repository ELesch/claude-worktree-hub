# Hub self-update (`update-hub.ps1`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add one command (`update-hub.ps1`) that overlays a hub deployment's tracked tooling files from the pristine `ELesch/claude-worktree-hub` source clone — skipping CRLF-only noise, preserving runtime data + `HUB-STATE.md` — plus a `CLAUDE.md` section documenting it durably.

**Architecture:** A single PowerShell script with four pure, unit-tested helpers (`ConvertTo-Crlf`, `Test-HubSourceRemote`, `Get-HubUpdateSkipList`, `Get-OverlayAction`) and one integration `Invoke-UpdateHub` body. The body validates the source clone's remote, refreshes it (`git pull --ff-only`), enumerates `git ls-files`, and copies each tracked file (normalized to CRLF, skipping content-identical and the skip-list) onto `$PSScriptRoot` (the hub you run it from). A dot-source guard lets the tests load the helpers without running `main`.

**Tech Stack:** PowerShell 7, git CLI, Pester v5 (`C:\mydev\pester-modules\Pester\5.7.1`).

**Spec:** `docs/superpowers/specs/2026-06-30-update-hub-design.md`

---

## File structure

- **Create `update-hub.ps1`** (hub root) — the script: param block, four pure helpers, `Invoke-UpdateHub`, dot-source guard.
- **Create `update-hub.Tests.ps1`** (hub root) — Pester v5 unit tests for the four pure helpers.
- **Modify `CLAUDE.md`** — new `## Updating the hub itself` section + one directory-tree line.

Conventions to follow (from `init-hub.ps1` / `hub-lib.Tests.ps1`): `[CmdletBinding()]`, `$ErrorActionPreference` left default (helpers throw explicitly), colored `Write-Host`, native git exit checked via `$LASTEXITCODE`, tests dot-source via `. $PSCommandPath.Replace('.Tests.ps1','.ps1')` and use `$TestDrive`.

---

### Task 1: Script skeleton + `ConvertTo-Crlf` (TDD)

**Files:**
- Create: `update-hub.ps1`
- Test: `update-hub.Tests.ps1`

- [ ] **Step 1: Create the dot-sourceable skeleton** so the tests can load it (main is guarded off; a placeholder `Invoke-UpdateHub` keeps the script coherent if run before Task 4).

```powershell
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

# (helpers added in Tasks 1-3)

# ---------- main (skipped when the script is dot-sourced, e.g. by the tests) ----------

function Invoke-UpdateHub {
    throw 'update-hub.ps1: Invoke-UpdateHub not yet implemented (see plan Task 4).'
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-UpdateHub -Source $Source -Target $PSScriptRoot -DryRun:$DryRun -NoPull:$NoPull
}
```

- [ ] **Step 2: Write the failing test** for `ConvertTo-Crlf`.

```powershell
BeforeAll {
    . $PSCommandPath.Replace('.Tests.ps1', '.ps1')   # dot-source update-hub.ps1 (main is guarded off)
}

Describe 'ConvertTo-Crlf' {
    It 'converts LF to CRLF'                  { ConvertTo-Crlf "a`nb"        | Should -Be "a`r`nb" }
    It 'leaves CRLF unchanged (idempotent)'   { ConvertTo-Crlf "a`r`nb"      | Should -Be "a`r`nb" }
    It 'normalizes mixed CRLF/LF/CR to CRLF'  { ConvertTo-Crlf "a`r`nb`nc`rd"| Should -Be "a`r`nb`r`nc`r`nd" }
    It 'is idempotent on double application'  {
        $once = ConvertTo-Crlf "x`ny`r`nz"
        ConvertTo-Crlf $once | Should -Be $once
    }
    It 'handles the empty string'             { ConvertTo-Crlf '' | Should -Be '' }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `Import-Module C:\mydev\pester-modules\Pester\5.7.1\Pester.psd1 -Force; Invoke-Pester -Path .\update-hub.Tests.ps1 -Output Detailed`
Expected: FAIL — `CommandNotFoundException: The term 'ConvertTo-Crlf' is not recognized`.

- [ ] **Step 4: Implement `ConvertTo-Crlf`** (replace the `# (helpers added in Tasks 1-3)` line).

```powershell
function ConvertTo-Crlf {
    <# Normalize any mix of CRLF/LF/CR line endings to CRLF. Idempotent. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    ($Text -replace "`r`n", "`n" -replace "`r", "`n") -replace "`n", "`r`n"
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `Invoke-Pester -Path .\update-hub.Tests.ps1 -Output Detailed`
Expected: PASS (5 tests in `ConvertTo-Crlf`).

- [ ] **Step 6: Commit**

```bash
git add update-hub.ps1 update-hub.Tests.ps1
git commit -m "feat(hub): update-hub.ps1 skeleton + ConvertTo-Crlf helper"
```

---

### Task 2: `Test-HubSourceRemote` (TDD)

**Files:**
- Modify: `update-hub.ps1` (add helper)
- Test: `update-hub.Tests.ps1` (add Describe)

- [ ] **Step 1: Write the failing test** (append a new `Describe`).

```powershell
Describe 'Test-HubSourceRemote' {
    It 'accepts an https URL with .git'    { Test-HubSourceRemote 'https://github.com/ELesch/claude-worktree-hub.git' | Should -BeTrue }
    It 'accepts an https URL without .git' { Test-HubSourceRemote 'https://github.com/ELesch/claude-worktree-hub'     | Should -BeTrue }
    It 'accepts an ssh URL'                { Test-HubSourceRemote 'git@github.com:ELesch/claude-worktree-hub.git'      | Should -BeTrue }
    It 'is case-insensitive'               { Test-HubSourceRemote 'https://github.com/elesch/Claude-Worktree-Hub'      | Should -BeTrue }
    It 'rejects a different repo'          { Test-HubSourceRemote 'https://github.com/someone/other-repo.git'          | Should -BeFalse }
    It 'rejects an empty string'           { Test-HubSourceRemote '' | Should -BeFalse }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `Invoke-Pester -Path .\update-hub.Tests.ps1 -Output Detailed`
Expected: FAIL — `Test-HubSourceRemote` not recognized.

- [ ] **Step 3: Implement `Test-HubSourceRemote`** (add below `ConvertTo-Crlf`).

```powershell
function Test-HubSourceRemote {
    <# True if a git remote URL points at ELesch/claude-worktree-hub (https or ssh, +/- .git). #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$RemoteUrl)
    $normalized = ($RemoteUrl.Trim() -replace '(?i)\.git/?$', '').TrimEnd('/')
    if ($normalized -match '[:/](?<slug>[^/]+/[^/]+)$') {
        return $Matches['slug'].ToLowerInvariant() -eq 'elesch/claude-worktree-hub'
    }
    return $false
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `Invoke-Pester -Path .\update-hub.Tests.ps1 -Output Detailed`
Expected: PASS (6 tests in `Test-HubSourceRemote`).

- [ ] **Step 5: Commit**

```bash
git add update-hub.ps1 update-hub.Tests.ps1
git commit -m "feat(hub): update-hub source-remote validator"
```

---

### Task 3: `Get-HubUpdateSkipList` + `Get-OverlayAction` (TDD)

**Files:**
- Modify: `update-hub.ps1` (add two helpers)
- Test: `update-hub.Tests.ps1` (add two Describes)

- [ ] **Step 1: Write the failing tests** (append two `Describe` blocks).

```powershell
Describe 'Get-HubUpdateSkipList' {
    It 'excludes HUB-STATE.md'      { Get-HubUpdateSkipList | Should -Contain 'HUB-STATE.md' }
    It 'does not exclude CLAUDE.md' { Get-HubUpdateSkipList | Should -Not -Contain 'CLAUDE.md' }
}

Describe 'Get-OverlayAction' {
    It "returns 'new' when the target is missing" {
        Get-OverlayAction -SourceNorm "a`r`nb" -TargetContent '' -TargetExists:$false | Should -Be 'new'
    }
    It "returns 'unchanged' when only the line endings differ" {
        $src = ConvertTo-Crlf "line1`nline2"
        Get-OverlayAction -SourceNorm $src -TargetContent "line1`nline2" -TargetExists | Should -Be 'unchanged'
    }
    It "returns 'unchanged' when identical (already CRLF)" {
        Get-OverlayAction -SourceNorm "a`r`nb" -TargetContent "a`r`nb" -TargetExists | Should -Be 'unchanged'
    }
    It "returns 'updated' when the content really differs" {
        Get-OverlayAction -SourceNorm "a`r`nb" -TargetContent "a`r`nCHANGED" -TargetExists | Should -Be 'updated'
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `Invoke-Pester -Path .\update-hub.Tests.ps1 -Output Detailed`
Expected: FAIL — `Get-HubUpdateSkipList` / `Get-OverlayAction` not recognized.

- [ ] **Step 3: Implement both helpers** (add below `Test-HubSourceRemote`).

```powershell
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `Invoke-Pester -Path .\update-hub.Tests.ps1 -Output Detailed`
Expected: PASS — all four Describes green (17 tests total).

- [ ] **Step 5: Commit**

```bash
git add update-hub.ps1 update-hub.Tests.ps1
git commit -m "feat(hub): update-hub skip-list + per-file overlay decision"
```

---

### Task 4: `Invoke-UpdateHub` main body (integration)

**Files:**
- Modify: `update-hub.ps1` (replace the placeholder `Invoke-UpdateHub`)

This is orchestration glue over git + file I/O; it is verified by a dry-run smoke test rather than a unit test (the pure logic it relies on is already covered by Tasks 1-3).

- [ ] **Step 1: Replace the placeholder `Invoke-UpdateHub`** with the full body.

```powershell
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
```

- [ ] **Step 2: Verify the unit tests still pass** (dot-source didn't break).

Run: `Invoke-Pester -Path .\update-hub.Tests.ps1 -Output Detailed`
Expected: PASS — all 17 tests still green.

- [ ] **Step 3: Smoke-test the overlay against a throwaway target** (writes nothing; exercises real `ls-files`, skip-list, CRLF, reporting). From the hub root:

```powershell
$tmp = Join-Path $env:TEMP ('uh-smoke-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
. .\update-hub.ps1                       # dot-source (main guarded off) to expose Invoke-UpdateHub
Invoke-UpdateHub -Source (Get-Location).Path -Target $tmp -DryRun -NoPull
Remove-Item $tmp -Recurse -Force
```

Expected: a report listing ~53 files as **new** (every tracked file except `HUB-STATE.md`), summary ends `... | 1 skipped (HUB-STATE.md)`, and the dry-run footer. `$tmp` stays empty (nothing written).

- [ ] **Step 4: Smoke-test the "inside the source" path.** From the hub root:

Run: `.\update-hub.ps1 -DryRun -NoPull`
Expected: prints `Source`/`Target` (both = this repo), then `You are in the source clone itself - nothing to overlay.` (This is the correct no-op when run from the source clone; a real deployment's `$PSScriptRoot` differs from `-Source`, so it overlays.)

- [ ] **Step 5: Commit**

```bash
git add update-hub.ps1
git commit -m "feat(hub): update-hub overlay engine (validate, pull, ls-files, copy, report)"
```

---

### Task 5: Document it in `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md` (new section after the orientation block; one directory-tree line)

- [ ] **Step 1: Add the `## Updating the hub itself` section.** Insert it between the orientation blockquote and `## Repository`. Anchor (near line 14-16):

Replace:
````text
> (`main\`, `agent-*\`, …), each of which has its own project-level `CLAUDE.md`.

## Repository
````

with:
````text
> (`main\`, `agent-*\`, …), each of which has its own project-level `CLAUDE.md`.

## Updating the hub itself

This hub's **tooling** — the `.ps1` scripts, `CLAUDE.md`, `WORKTREE.md`, the `.claude\agents\hub-*` experts,
the docs — is tracked in the upstream repo **`ELesch/claude-worktree-hub`**. To pull the latest tooling into
**this deployment**, run `update-hub.ps1` **from this hub root**:

```powershell
.\update-hub.ps1 -DryRun   # preview exactly which files would change (writes nothing)
.\update-hub.ps1           # pull latest, then overlay the tracked tooling files
```

It reads from a pristine **source clone** (default `C:\mydev\claude-worktree-hub`; override with `-Source
<path>`, validated to be a clone of `ELesch/claude-worktree-hub`), refreshes it (`git pull --ff-only`; skip
with `-NoPull`), then copies only the **tracked** files onto this hub — reporting which changed and treating
files that differ only in line endings (CRLF vs LF) as unchanged. **Your runtime data is never touched:**
`hub.config.json`, the `.review\` ledger, the worktrees, `.env*`, and `PRODUCT.md` are gitignored upstream, so
they aren't part of the overlay — and **`HUB-STATE.md` is preserved** even though it's tracked, because it
holds this deployment's live state. Because this section lives in the tracked `CLAUDE.md`, it ships to every
deployment and survives the next update — so any change to the update process itself belongs **upstream**, not
in a deployment's copy.

## Repository
````

- [ ] **Step 2: Add the directory-tree line.** In the `## Directory structure` code block, insert an `update-hub.ps1` line right after the `setup-hub.ps1` line (keep the `<-` arrows column-aligned — 11 spaces after `update-hub.ps1`):

Replace:
````text
├── setup-hub.ps1            <- interactive first-run wizard (bootstrap + config + ledger + env + prereqs)
├── hub-doctor.ps1           <- non-interactive readiness report (exit 0 ready / 1 blockers)
````

with:
````text
├── setup-hub.ps1            <- interactive first-run wizard (bootstrap + config + ledger + env + prereqs)
├── update-hub.ps1           <- helper: overlay this deployment's tracked tooling files from the source clone (self-update; -DryRun to preview)
├── hub-doctor.ps1           <- non-interactive readiness report (exit 0 ready / 1 blockers)
````

- [ ] **Step 3: Verify** the section reads correctly and the tree line aligns.

Run: `git diff --stat CLAUDE.md`
Expected: `CLAUDE.md` shows additions only (the section + one tree line).

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(hub): document update-hub.ps1 (## Updating the hub itself)"
```

---

### Task 6: Final verification + PR

**Files:** none (verification + integration)

- [ ] **Step 1: Full test run — all green.**

Run: `Import-Module C:\mydev\pester-modules\Pester\5.7.1\Pester.psd1 -Force; Invoke-Pester -Path .\update-hub.Tests.ps1 -Output Detailed`
Expected: 17 passed, 0 failed.

- [ ] **Step 2: Parser check on the script** (no syntax errors).

```powershell
$null = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\update-hub.ps1), [ref]$null, [ref]$errs=$null)
if ($errs) { $errs | ForEach-Object { Write-Host $_ -ForegroundColor Red } } else { 'parse OK' }
```
Expected: `parse OK`.

- [ ] **Step 3: Confirm the whole feature branch** is coherent.

Run: `git log --oneline main..HEAD` and `git diff --stat main..HEAD`
Expected: the spec + 5 feature commits; changed files = `update-hub.ps1`, `update-hub.Tests.ps1`, `CLAUDE.md`, and the two docs.

- [ ] **Step 4: Push + open the PR** (outward-facing — confirm with the user first).

```bash
git push -u origin feat/update-hub
gh pr create --base main --title "feat(hub): update-hub.ps1 — one-command deployment self-update" --body "<summary + test evidence>"
```
Expected: PR opened against `ELesch/claude-worktree-hub:main`. Do NOT merge (the user reviews/merges).

---

## Self-review

**Spec coverage:** source-remote validation (Task 2 + 4) · HUB-STATE.md skip (Task 3 + 4) · run-inside-hub / `Target=$PSScriptRoot` (Task 1 guard + 4) · CRLF-normalize & skip-identical (Tasks 1, 3, 4) · `-DryRun`/`-NoPull`/`-Source` (Task 1 param + 4) · DryRun still refreshes source (Task 4: pull gated only by `-NoPull`) · additive/no-delete (Task 4: no deletion path) · UTF-8 no-BOM write (Task 4) · Target==Source no-op (Task 4) · report counts (Task 4) · CLAUDE.md section + tree line (Task 5) · unit tests (Tasks 1-3) + acceptance (Task 6). All spec sections map to a task.

**Placeholder scan:** none — every step carries the actual code/command.

**Type consistency:** helper names and signatures are identical across the script and the tests — `ConvertTo-Crlf($Text)`, `Test-HubSourceRemote($RemoteUrl)`, `Get-HubUpdateSkipList()`, `Get-OverlayAction(-SourceNorm,-TargetContent,-TargetExists)`, `Invoke-UpdateHub(-Source,-Target,-DryRun,-NoPull)`. The guard calls `Invoke-UpdateHub` with exactly those params.
