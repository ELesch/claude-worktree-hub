# First-Run Setup Wizard + Doctor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the hub a single idempotent first-run command (`setup-hub.ps1`) that initializes and verifies every capability, plus a re-runnable readiness report (`hub-doctor.ps1`), both backed by one shared check library (`hub-checks.ps1`).

**Architecture:** A pure-ish check library (`hub-checks.ps1`) exposes `Get-HubReadiness`, the single source of truth for "what a complete hub requires" (21 checks). `hub-doctor.ps1` renders those checks non-interactively with an exit code; `setup-hub.ps1` is the interactive wizard that runs the checks and does/offers each fix. `init-hub.ps1` stays the mechanical bare-repo core the wizard calls.

**Tech Stack:** PowerShell 7, Pester v5 (unit tests for the pure logic), `git`/`gh`/`sqlite3` CLIs, the existing hub scripts (`hub-config.ps1`, `hub-lib.ps1`, `review-coverage.ps1`, `init-hub.ps1`).

**Design doc:** `docs/superpowers/specs/2026-06-28-hub-first-run-setup-design.md`

**Conventions for every task:**
- Run all commands from the hub root (`C:\mydev\claude-worktree-hub`) in **PowerShell 7 (`pwsh`)**.
- This repo is the hub's own source repo (normal working tree), so commit normally on the current feature branch `feature/first-run-setup-wizard`.
- **Every commit message ends with the trailer:** `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- Do **not** push or open a PR unless the user asks.

---

## File Structure

| File | New/Changed | Responsibility |
|---|---|---|
| `hub-checks.ps1` | new | Readiness check library: pure helpers, thin probe wrappers, `Get-HubReadiness`, `Get-ReadinessVerdict`, `New-CheckResult`. No prompts, no mutations. |
| `hub-checks.Tests.ps1` | new | Pester v5 unit tests for the pure logic + a mock-based `Get-HubReadiness` test. |
| `hub-doctor.ps1` | new | Non-interactive readiness report; grouped/colored output; exit 0 (ready) / 1 (blockers). |
| `setup-hub.ps1` | new | Interactive wizard: 6 idempotent phases + final doctor call. Params `-CloneUrl`, `-DryRun`, `-Yes`. |
| `init-hub.ps1` | changed (minimal) | "Next:" output points at `setup-hub.ps1` / `hub-doctor.ps1`. |
| `README.md` | changed | Quickstart → one command; file map; Pester note. |
| `CLAUDE.md` | changed | Setup narrative + directory-structure listing. |

**Data contract (used across all tasks):** every check returns a `[pscustomobject]` with exactly these properties:
`Name` (string), `Category` (one of `prereq|hub|config|ledger|env|rules|info`), `Status` (one of `ok|warn|fail`), `Detail` (string), `Fix` (string). `fail` = blocker.

---

## Task 1: Pester setup + check-result primitives (`New-CheckResult`, `Get-ReadinessVerdict`)

**Files:**
- Create: `hub-checks.ps1`
- Test: `hub-checks.Tests.ps1`

- [ ] **Step 1: Ensure Pester v5 is installed**

Run:
```powershell
Get-Module -ListAvailable Pester | Select-Object Version | Sort-Object Version -Descending | Select-Object -First 1
```
If no version `5.x` is listed, install it:
```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck
```
Expected: a Pester `5.x` version is available.

- [ ] **Step 2: Write the failing test**

Create `hub-checks.Tests.ps1`:
```powershell
BeforeAll {
    . $PSCommandPath.Replace('.Tests.ps1', '.ps1')
}

Describe 'New-CheckResult' {
    It 'builds an object with the five contract properties' {
        $r = New-CheckResult -Name 'x' -Category prereq -Status ok -Detail 'd' -Fix 'f'
        $r.Name     | Should -Be 'x'
        $r.Category | Should -Be 'prereq'
        $r.Status   | Should -Be 'ok'
        $r.Detail   | Should -Be 'd'
        $r.Fix      | Should -Be 'f'
    }
    It 'rejects an invalid status' {
        { New-CheckResult -Name 'x' -Category prereq -Status nope } | Should -Throw
    }
}

Describe 'Get-ReadinessVerdict' {
    It 'is ready when there are no fail results' {
        $results = @(
            (New-CheckResult -Name 'a' -Category prereq -Status ok),
            (New-CheckResult -Name 'b' -Category env    -Status warn)
        )
        $v = Get-ReadinessVerdict -Results $results
        $v.Ready        | Should -BeTrue
        $v.Blockers     | Should -BeNullOrEmpty
        $v.Warnings     | Should -Be @('b')
    }
    It 'is not ready and lists blockers when a fail is present' {
        $results = @(
            (New-CheckResult -Name 'a' -Category prereq -Status fail),
            (New-CheckResult -Name 'b' -Category prereq -Status ok)
        )
        $v = Get-ReadinessVerdict -Results $results
        $v.Ready    | Should -BeFalse
        $v.Blockers | Should -Be @('a')
    }
    It 'treats an empty result set as ready' {
        (Get-ReadinessVerdict -Results @()).Ready | Should -BeTrue
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run:
```powershell
Invoke-Pester -Path .\hub-checks.Tests.ps1 -Output Detailed
```
Expected: FAIL — the file `hub-checks.ps1` doesn't exist yet / commands not found.

- [ ] **Step 4: Write the minimal implementation**

Create `hub-checks.ps1`:
```powershell
<#
  hub-checks.ps1 - readiness check library for the claude-worktree-hub.
  The SINGLE source of truth for "what a complete hub requires".
  Pure-ish: no prompts, no mutations. Consumed by hub-doctor.ps1 and setup-hub.ps1.
  Dot-source it:  . "$PSScriptRoot\hub-checks.ps1"
  Public: New-CheckResult, Get-ReadinessVerdict, Get-HubReadiness, plus pure helpers.
#>

# $PSScriptRoot here = the hub root (this file lives at the hub root).
$Hub = $PSScriptRoot

function New-CheckResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('prereq', 'hub', 'config', 'ledger', 'env', 'rules', 'info')][string]$Category,
        [Parameter(Mandatory)][ValidateSet('ok', 'warn', 'fail')][string]$Status,
        [string]$Detail = '',
        [string]$Fix = ''
    )
    [pscustomobject]@{ Name = $Name; Category = $Category; Status = $Status; Detail = $Detail; Fix = $Fix }
}

function Get-ReadinessVerdict {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results)
    $blockers = @($Results | Where-Object { $_.Status -eq 'fail' } | ForEach-Object { $_.Name })
    $warnings = @($Results | Where-Object { $_.Status -eq 'warn' } | ForEach-Object { $_.Name })
    [pscustomobject]@{ Ready = ($blockers.Count -eq 0); Blockers = $blockers; Warnings = $warnings }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run:
```powershell
Invoke-Pester -Path .\hub-checks.Tests.ps1 -Output Detailed
```
Expected: PASS — all `New-CheckResult` and `Get-ReadinessVerdict` tests green.

- [ ] **Step 6: Commit**

```powershell
git add hub-checks.ps1 hub-checks.Tests.ps1
git commit -m "feat(checks): add hub-checks scaffold with New-CheckResult + Get-ReadinessVerdict" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Pure helper — `Get-PackageManagerFromLockfile`

**Files:**
- Modify: `hub-checks.ps1`
- Test: `hub-checks.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Append to `hub-checks.Tests.ps1` (a new top-level `Describe`):
```powershell
Describe 'Get-PackageManagerFromLockfile' {
    It 'returns pnpm for pnpm-lock.yaml' {
        New-Item -ItemType File -Path (Join-Path $TestDrive 'pnpm-lock.yaml') | Out-Null
        Get-PackageManagerFromLockfile -WorktreePath $TestDrive | Should -Be 'pnpm'
    }
    It 'returns npm for package-lock.json' {
        $d = Join-Path $TestDrive 'npmproj'; New-Item -ItemType Directory -Path $d | Out-Null
        New-Item -ItemType File -Path (Join-Path $d 'package-lock.json') | Out-Null
        Get-PackageManagerFromLockfile -WorktreePath $d | Should -Be 'npm'
    }
    It 'returns yarn for yarn.lock' {
        $d = Join-Path $TestDrive 'yarnproj'; New-Item -ItemType Directory -Path $d | Out-Null
        New-Item -ItemType File -Path (Join-Path $d 'yarn.lock') | Out-Null
        Get-PackageManagerFromLockfile -WorktreePath $d | Should -Be 'yarn'
    }
    It 'returns bun for bun.lockb' {
        $d = Join-Path $TestDrive 'bunproj'; New-Item -ItemType Directory -Path $d | Out-Null
        New-Item -ItemType File -Path (Join-Path $d 'bun.lockb') | Out-Null
        Get-PackageManagerFromLockfile -WorktreePath $d | Should -Be 'bun'
    }
    It 'returns $null when no lockfile is present' {
        $d = Join-Path $TestDrive 'empty'; New-Item -ItemType Directory -Path $d | Out-Null
        Get-PackageManagerFromLockfile -WorktreePath $d | Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```powershell
Invoke-Pester -Path .\hub-checks.Tests.ps1 -Output Detailed
```
Expected: FAIL — `Get-PackageManagerFromLockfile` not defined.

- [ ] **Step 3: Write the minimal implementation**

Add to `hub-checks.ps1` (after `Get-ReadinessVerdict`):
```powershell
function Get-PackageManagerFromLockfile {
    param([Parameter(Mandatory)][string]$WorktreePath)
    # Ordered so pnpm wins if multiple lockfiles coexist (matches the repo's pnpm default).
    $map = [ordered]@{
        'pnpm-lock.yaml'    = 'pnpm'
        'package-lock.json' = 'npm'
        'yarn.lock'         = 'yarn'
        'bun.lockb'         = 'bun'
    }
    foreach ($file in $map.Keys) {
        if (Test-Path (Join-Path $WorktreePath $file)) { return $map[$file] }
    }
    return $null
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```powershell
Invoke-Pester -Path .\hub-checks.Tests.ps1 -Output Detailed
```
Expected: PASS — all 5 lockfile cases green.

- [ ] **Step 5: Commit**

```powershell
git add hub-checks.ps1 hub-checks.Tests.ps1
git commit -m "feat(checks): detect package manager from lockfile" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Pure helper — `Test-ConfigPlaceholder`

**Files:**
- Modify: `hub-checks.ps1`
- Test: `hub-checks.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Append to `hub-checks.Tests.ps1`:
```powershell
Describe 'Test-ConfigPlaceholder' {
    It 'is true when config is $null' {
        Test-ConfigPlaceholder -Config $null | Should -BeTrue
    }
    It 'is true when repo is missing' {
        Test-ConfigPlaceholder -Config ([pscustomobject]@{ defaultBranch = 'main' }) | Should -BeTrue
    }
    It 'is true when repo is the owner/repo placeholder' {
        Test-ConfigPlaceholder -Config ([pscustomobject]@{ repo = 'owner/repo' }) | Should -BeTrue
    }
    It 'is false for a real repo slug' {
        Test-ConfigPlaceholder -Config ([pscustomobject]@{ repo = 'acme/widgets' }) | Should -BeFalse
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```powershell
Invoke-Pester -Path .\hub-checks.Tests.ps1 -Output Detailed
```
Expected: FAIL — `Test-ConfigPlaceholder` not defined.

- [ ] **Step 3: Write the minimal implementation**

Add to `hub-checks.ps1`:
```powershell
function Test-ConfigPlaceholder {
    param($Config)
    if (-not $Config -or -not $Config.repo) { return $true }
    return ($Config.repo -eq 'owner/repo')
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```powershell
Invoke-Pester -Path .\hub-checks.Tests.ps1 -Output Detailed
```
Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add hub-checks.ps1 hub-checks.Tests.ps1
git commit -m "feat(checks): detect unconfigured repo placeholder" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Pure helper — `Test-GitPointer`

**Files:**
- Modify: `hub-checks.ps1`
- Test: `hub-checks.Tests.ps1`

This guards the real first-run bug class: the `.git` pointer must be a BOM-free file containing exactly `gitdir: ./.bare`.

- [ ] **Step 1: Write the failing test**

Append to `hub-checks.Tests.ps1`:
```powershell
Describe 'Test-GitPointer' {
    It 'is true for a BOM-free file containing gitdir: ./.bare' {
        $p = Join-Path $TestDrive 'good.git'
        [System.IO.File]::WriteAllText($p, "gitdir: ./.bare`n", (New-Object System.Text.UTF8Encoding($false)))
        Test-GitPointer -Path $p | Should -BeTrue
    }
    It 'is false when the file has a UTF-8 BOM' {
        $p = Join-Path $TestDrive 'bom.git'
        [System.IO.File]::WriteAllText($p, "gitdir: ./.bare`n", (New-Object System.Text.UTF8Encoding($true)))
        Test-GitPointer -Path $p | Should -BeFalse
    }
    It 'is false when the content is wrong' {
        $p = Join-Path $TestDrive 'wrong.git'
        [System.IO.File]::WriteAllText($p, "gitdir: ./elsewhere`n", (New-Object System.Text.UTF8Encoding($false)))
        Test-GitPointer -Path $p | Should -BeFalse
    }
    It 'is false when the path is a directory' {
        $p = Join-Path $TestDrive 'dir.git'; New-Item -ItemType Directory -Path $p | Out-Null
        Test-GitPointer -Path $p | Should -BeFalse
    }
    It 'is false when the path does not exist' {
        Test-GitPointer -Path (Join-Path $TestDrive 'missing.git') | Should -BeFalse
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```powershell
Invoke-Pester -Path .\hub-checks.Tests.ps1 -Output Detailed
```
Expected: FAIL — `Test-GitPointer` not defined.

- [ ] **Step 3: Write the minimal implementation**

Add to `hub-checks.ps1`:
```powershell
function Test-GitPointer {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path -PathType Leaf)) { return $false }   # missing, or a directory
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return $false   # UTF-8 BOM - git silently fails to parse this
    }
    return ([System.IO.File]::ReadAllText($Path).Trim() -eq 'gitdir: ./.bare')
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```powershell
Invoke-Pester -Path .\hub-checks.Tests.ps1 -Output Detailed
```
Expected: PASS — all 5 pointer cases green.

- [ ] **Step 5: Commit**

```powershell
git add hub-checks.ps1 hub-checks.Tests.ps1
git commit -m "feat(checks): validate the .git pointer (BOM-free gitdir)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Thin probe wrappers (isolate the side effects)

**Files:**
- Modify: `hub-checks.ps1`
- Test: `hub-checks.Tests.ps1`

These one-line wrappers isolate every environment probe so `Get-HubReadiness` (Task 6) is mockable in Pester.

- [ ] **Step 1: Write the failing test**

Append to `hub-checks.Tests.ps1`:
```powershell
Describe 'Test-OnPath' {
    It 'is true for a command that exists (git)' {
        Test-OnPath -Name 'git' | Should -BeTrue
    }
    It 'is false for a command that does not exist' {
        Test-OnPath -Name 'definitely-not-a-real-command-xyz' | Should -BeFalse
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```powershell
Invoke-Pester -Path .\hub-checks.Tests.ps1 -Output Detailed
```
Expected: FAIL — `Test-OnPath` not defined.

- [ ] **Step 3: Write the implementation**

Add to `hub-checks.ps1`:
```powershell
# --- thin probe wrappers (mock these in tests; they isolate all side effects) ---

function Test-OnPath {
    param([Parameter(Mandatory)][string]$Name)
    [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-GhAuth {
    & gh auth status *> $null
    return ($LASTEXITCODE -eq 0)
}

function Test-GhCredentialHelper {
    # gh auth setup-git writes a credential.<host>.helper that invokes gh. Best-effort detection.
    $cfg = (& git config --get-regexp '^credential.*\.helper$' 2>$null)
    return [bool]($cfg -match 'gh')
}

function Test-BareRepo {
    param([Parameter(Mandatory)][string]$HubRoot)
    $r = (& git -C (Join-Path $HubRoot '.bare') rev-parse --is-bare-repository 2>$null)
    return ($r -eq 'true')
}

function Test-HubGitConfig {
    param([Parameter(Mandatory)][string]$HubRoot)
    $fetch = (& git -C $HubRoot config --get-all remote.origin.fetch 2>$null)
    $gc = (& git -C $HubRoot config --get gc.auto 2>$null)
    return (($fetch -match '\+refs/heads/\*') -and ($gc -eq '0'))
}

function Test-BaseWorktree {
    param([Parameter(Mandatory)][string]$HubRoot, $Config)
    $base = if ($Config -and $Config.baseWorktree) { $Config.baseWorktree } else { 'main' }
    $wt = Join-Path $HubRoot $base
    if (-not (Test-Path $wt)) { return $false }
    $up = (& git -C $wt rev-parse --abbrev-ref '@{upstream}' 2>$null)
    return [bool](($LASTEXITCODE -eq 0) -and $up)
}

function Test-LedgerSchema {
    param([Parameter(Mandatory)][string]$HubRoot)
    $db = Join-Path $HubRoot '.review\coverage.db'
    if (-not (Test-Path $db)) { return $false }
    $n = (& sqlite3 $db "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('topic','issue','finding','worktree');" 2>$null)
    return ($n -eq '4')
}

function Test-LedgerSeeded {
    param([Parameter(Mandatory)][string]$HubRoot)
    $db = Join-Path $HubRoot '.review\coverage.db'
    if (-not (Test-Path $db)) { return $false }
    $n = (& sqlite3 $db "SELECT count(*) FROM topic;" 2>$null)
    return ([int]$n -gt 0)
}

function Get-MissingEnvFiles {
    param([Parameter(Mandatory)][string]$HubRoot, $Config)
    $base = if ($Config -and $Config.baseWorktree) { $Config.baseWorktree } else { 'main' }
    $files = if ($Config -and $Config.envFiles) { $Config.envFiles } else { @('.env') }
    $baseDir = Join-Path $HubRoot $base
    return @($files | Where-Object { -not (Test-Path (Join-Path $baseDir $_)) })
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```powershell
Invoke-Pester -Path .\hub-checks.Tests.ps1 -Output Detailed
```
Expected: PASS — `Test-OnPath` true for `git`, false for the bogus name.

- [ ] **Step 5: Commit**

```powershell
git add hub-checks.ps1 hub-checks.Tests.ps1
git commit -m "feat(checks): add thin probe wrappers for env/git/ledger/auth" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: `Get-HubReadiness` orchestrator (all 21 checks)

**Files:**
- Modify: `hub-checks.ps1`
- Test: `hub-checks.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Append to `hub-checks.Tests.ps1`:
```powershell
Describe 'Get-HubReadiness' {
    BeforeAll {
        $script:goodConfig = [pscustomobject]@{
            repo = 'acme/widgets'; baseWorktree = 'main'; defaultBranch = 'main'
            packageManager = 'pnpm'; envFiles = @('.env')
            complexPromptPreamble = ''
        }
    }

    Context 'when everything is healthy' {
        BeforeAll {
            Mock Test-OnPath { $true }
            Mock Test-GhAuth { $true }
            Mock Test-GhCredentialHelper { $true }
            Mock Test-BareRepo { $true }
            Mock Test-HubGitConfig { $true }
            Mock Test-BaseWorktree { $true }
            Mock Test-GitPointer { $true }
            Mock Test-LedgerSchema { $true }
            Mock Test-LedgerSeeded { $true }
            Mock Get-MissingEnvFiles { @() }
            Mock Test-Path { $true }   # WORKTREE.md present
            $script:results = Get-HubReadiness -Config $script:goodConfig -HubRoot 'TestDrive:\hub'
        }
        It 'returns one result per check with no blockers' {
            (Get-ReadinessVerdict -Results $script:results).Ready | Should -BeTrue
        }
        It 'every result has the contract shape' {
            foreach ($r in $script:results) {
                $r.Status   | Should -BeIn @('ok', 'warn', 'fail')
                $r.Category | Should -BeIn @('prereq', 'hub', 'config', 'ledger', 'env', 'rules', 'info')
            }
        }
    }

    Context 'when sqlite3 is missing' {
        BeforeAll {
            Mock Test-OnPath { $true }
            Mock Test-OnPath { $false } -ParameterFilter { $Name -eq 'sqlite3' }
            Mock Test-GhAuth { $true }
            Mock Test-GhCredentialHelper { $true }
            Mock Test-BareRepo { $true }
            Mock Test-HubGitConfig { $true }
            Mock Test-BaseWorktree { $true }
            Mock Test-GitPointer { $true }
            Mock Test-LedgerSchema { $true }
            Mock Test-LedgerSeeded { $true }
            Mock Get-MissingEnvFiles { @() }
            Mock Test-Path { $true }
            $script:results = Get-HubReadiness -Config $script:goodConfig -HubRoot 'TestDrive:\hub'
        }
        It 'reports NOT ready' {
            (Get-ReadinessVerdict -Results $script:results).Ready | Should -BeFalse
        }
        It 'flags the sqlite3 check as fail' {
            ($script:results | Where-Object { $_.Name -eq 'sqlite3 on PATH' }).Status | Should -Be 'fail'
        }
    }

    Context 'when config is $null (un-bootstrapped)' {
        BeforeAll {
            Mock Test-OnPath { $true }
            Mock Test-GhAuth { $true }
            Mock Test-GhCredentialHelper { $true }
            Mock Test-BareRepo { $false }
            Mock Test-HubGitConfig { $false }
            Mock Test-BaseWorktree { $false }
            Mock Test-GitPointer { $false }
            Mock Test-LedgerSchema { $false }
            Mock Test-LedgerSeeded { $false }
            Mock Get-MissingEnvFiles { @('.env') }
            Mock Test-Path { $true }
            $script:results = Get-HubReadiness -Config $null -HubRoot 'TestDrive:\hub'
        }
        It 'does not throw and reports NOT ready' {
            (Get-ReadinessVerdict -Results $script:results).Ready | Should -BeFalse
        }
        It 'flags the config check as fail' {
            ($script:results | Where-Object { $_.Name -eq 'hub.config.json valid + repo set' }).Status | Should -Be 'fail'
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```powershell
Invoke-Pester -Path .\hub-checks.Tests.ps1 -Output Detailed
```
Expected: FAIL — `Get-HubReadiness` not defined.

- [ ] **Step 3: Write the implementation**

Add to `hub-checks.ps1`:
```powershell
function Get-HubReadiness {
    <# Assemble the ordered list of all readiness checks. $Config may be $null on an
       un-bootstrapped hub - config-dependent checks degrade to 'fail', never throw. #>
    param($Config, [Parameter(Mandatory)][string]$HubRoot)

    $st = { param($ok, $good = 'ok', $bad = 'fail') if ($ok) { $good } else { $bad } }
    $r = New-Object System.Collections.Generic.List[object]

    # --- prerequisites ---
    $r.Add( (New-CheckResult -Name 'PowerShell 7+' -Category prereq `
                -Status (& $st ($PSVersionTable.PSVersion.Major -ge 7)) `
                -Detail "detected $($PSVersionTable.PSVersion)" -Fix 'winget install Microsoft.PowerShell') )

    $tools = @(
        @{ n = 'git';     fix = 'Install Git for Windows' },
        @{ n = 'gh';      fix = 'winget install GitHub.cli' },
        @{ n = 'sqlite3'; fix = 'choco install sqlite  (or winget install SQLite.SQLite)' },
        @{ n = 'bash';    fix = 'Install Git for Windows (provides Git Bash)' },
        @{ n = 'claude';  fix = 'Install Claude Code (npm i -g @anthropic-ai/claude-code)' }
    )
    foreach ($t in $tools) {
        $ok = Test-OnPath -Name $t.n
        $r.Add( (New-CheckResult -Name "$($t.n) on PATH" -Category prereq `
                    -Status (& $st $ok) -Detail $(if ($ok) { 'found' } else { 'not found' }) -Fix $t.fix) )
    }

    $authOk = (Test-OnPath -Name 'gh') -and (Test-GhAuth)
    $r.Add( (New-CheckResult -Name 'gh authenticated' -Category prereq -Status (& $st $authOk) `
                -Detail $(if ($authOk) { 'authenticated' } else { 'not authenticated' }) -Fix 'gh auth login') )

    $credOk = (Test-OnPath -Name 'gh') -and (Test-GhCredentialHelper)
    $r.Add( (New-CheckResult -Name 'gh git credential helper' -Category prereq -Status (& $st $credOk 'ok' 'warn') `
                -Detail $(if ($credOk) { 'configured' } else { 'not detected' }) -Fix 'gh auth setup-git') )

    $pm = if ($Config -and $Config.packageManager) { $Config.packageManager } else { 'pnpm' }
    if ($pm -eq 'none') {
        $r.Add( (New-CheckResult -Name 'package manager' -Category prereq -Status ok -Detail 'n/a (packageManager=none)') )
    }
    else {
        $pmOk = Test-OnPath -Name $pm
        $r.Add( (New-CheckResult -Name "package manager ($pm)" -Category prereq -Status (& $st $pmOk 'ok' 'warn') `
                    -Detail $(if ($pmOk) { 'found' } else { 'not found' }) -Fix "Install $pm (e.g. corepack enable)") )
    }

    # --- hub artifacts ---
    $bareOk = Test-BareRepo -HubRoot $HubRoot
    $r.Add( (New-CheckResult -Name '.bare is a valid bare repo' -Category hub -Status (& $st $bareOk) `
                -Detail $(if ($bareOk) { 'ok' } else { 'missing/invalid' }) -Fix '.\init-hub.ps1 -CloneUrl <url>') )

    $ptrOk = Test-GitPointer -Path (Join-Path $HubRoot '.git')
    $r.Add( (New-CheckResult -Name '.git pointer (BOM-free gitdir)' -Category hub -Status (& $st $ptrOk) `
                -Detail $(if ($ptrOk) { 'ok' } else { 'missing/invalid/BOM' }) -Fix '.\init-hub.ps1 rewrites it') )

    $cfgGitOk = Test-HubGitConfig -HubRoot $HubRoot
    $r.Add( (New-CheckResult -Name 'fetch refspec + gc.auto=0' -Category hub -Status (& $st $cfgGitOk 'ok' 'warn') `
                -Detail $(if ($cfgGitOk) { 'configured' } else { 'not configured' }) -Fix '.\init-hub.ps1') )

    $baseOk = Test-BaseWorktree -HubRoot $HubRoot -Config $Config
    $r.Add( (New-CheckResult -Name 'base worktree + upstream' -Category hub -Status (& $st $baseOk) `
                -Detail $(if ($baseOk) { 'present + tracking' } else { 'missing/no upstream' }) -Fix '.\init-hub.ps1') )

    # --- config ---
    $cfgOk = ($null -ne $Config) -and -not (Test-ConfigPlaceholder -Config $Config)
    $r.Add( (New-CheckResult -Name 'hub.config.json valid + repo set' -Category config -Status (& $st $cfgOk) `
                -Detail $(if ($cfgOk) { "repo=$($Config.repo)" } else { 'missing or placeholder' }) `
                -Fix 'Run setup-hub.ps1 (or edit hub.config.json: set "repo")') )

    # config commands match the project - only meaningful when config + a Node project exist
    if ($cfgOk) {
        $baseDir = Join-Path $HubRoot $Config.baseWorktree
        $detected = Get-PackageManagerFromLockfile -WorktreePath $baseDir
        $hasNode = $detected -or (Test-Path (Join-Path $baseDir 'package.json'))
        if (-not $hasNode) {
            $r.Add( (New-CheckResult -Name 'config commands match project' -Category config -Status ok -Detail 'n/a (no lockfile/package.json)') )
        }
        else {
            $match = (-not $detected) -or ($Config.packageManager -eq $detected)
            $r.Add( (New-CheckResult -Name 'config commands match project' -Category config -Status (& $st $match 'ok' 'warn') `
                        -Detail $(if ($match) { "packageManager=$($Config.packageManager)" } else { "config=$($Config.packageManager) but lockfile=$detected" }) `
                        -Fix 'setup-hub.ps1 offers to update installCmd/verifyCmd/testCmd') )
        }
    }

    # --- ledger ---
    $schemaOk = Test-LedgerSchema -HubRoot $HubRoot
    $r.Add( (New-CheckResult -Name 'ledger schema (coverage.db)' -Category ledger -Status (& $st $schemaOk) `
                -Detail $(if ($schemaOk) { 'tables present' } else { 'missing/incomplete' }) -Fix '.\review-coverage.ps1 init') )

    $seedOk = Test-LedgerSeeded -HubRoot $HubRoot
    $r.Add( (New-CheckResult -Name 'ledger seeded (topics)' -Category ledger -Status (& $st $seedOk 'ok' 'warn') `
                -Detail $(if ($seedOk) { 'topics present' } else { 'no topics' }) -Fix '.\review-coverage.ps1 seed') )

    # --- env ---
    $missingEnv = Get-MissingEnvFiles -HubRoot $HubRoot -Config $Config
    $envOk = ($missingEnv.Count -eq 0)
    $r.Add( (New-CheckResult -Name '.env scaffolded in base worktree' -Category env -Status (& $st $envOk 'ok' 'warn') `
                -Detail $(if ($envOk) { 'present' } else { "missing: $($missingEnv -join ', ')" }) `
                -Fix 'setup-hub.ps1 copies .example -> target; then fill in secrets') )

    # --- rules ---
    $wtRulesOk = Test-Path (Join-Path $HubRoot 'WORKTREE.md')
    $r.Add( (New-CheckResult -Name 'WORKTREE.md present' -Category rules -Status (& $st $wtRulesOk) `
                -Detail $(if ($wtRulesOk) { 'present' } else { 'missing' }) -Fix 'git checkout -- WORKTREE.md') )

    # --- info (non-blocking) ---
    $wtTerm = Test-OnPath -Name 'wt'
    $r.Add( (New-CheckResult -Name 'Windows Terminal (tab coloring)' -Category info -Status (& $st $wtTerm 'ok' 'warn') `
                -Detail $(if ($wtTerm) { 'found' } else { 'not found (optional)' }) -Fix 'Optional: install Windows Terminal') )

    $preamble = if ($Config) { $Config.complexPromptPreamble } else { '' }
    if ($preamble -match 'superpowers') {
        $r.Add( (New-CheckResult -Name 'superpowers plugin (preamble)' -Category info -Status warn `
                    -Detail 'complexPromptPreamble references superpowers' `
                    -Fix 'Install the superpowers plugin, or set complexPromptPreamble to "" in hub.config.json') )
    }

    return $r.ToArray()
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```powershell
Invoke-Pester -Path .\hub-checks.Tests.ps1 -Output Detailed
```
Expected: PASS — healthy → Ready; missing sqlite3 → blocker; `$null` config → not ready + config fail, no exceptions.

- [ ] **Step 5: Commit**

```powershell
git add hub-checks.ps1 hub-checks.Tests.ps1
git commit -m "feat(checks): assemble Get-HubReadiness (21 checks, null-config safe)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: `hub-doctor.ps1` — non-interactive readiness report

**Files:**
- Create: `hub-doctor.ps1`

`hub-doctor.ps1` loads config defensively, calls `Get-HubReadiness`, prints grouped/colored results, and exits `0` (ready) or `1` (blockers).

- [ ] **Step 1: Write the implementation**

Create `hub-doctor.ps1`:
```powershell
<#
.SYNOPSIS
  Report whether the hub is fully initialized and ready to work. Read-only.
.DESCRIPTION
  Runs every readiness check (hub-checks.ps1) and prints a grouped, color-coded
  report. Exit code 0 when there are no blockers, 1 otherwise (scriptable).
.EXAMPLE
  .\hub-doctor.ps1
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hub-checks.ps1')

# Load config defensively: an un-bootstrapped hub has no hub.config.json, and
# hub-config.ps1 THROWS in that case - which must not crash the doctor.
$cfg = $null
try {
    . (Join-Path $PSScriptRoot 'hub-config.ps1')
    $cfg = $HubConfig
}
catch { $cfg = $null }

$results = Get-HubReadiness -Config $cfg -HubRoot $PSScriptRoot
$verdict = Get-ReadinessVerdict -Results $results

$glyph = @{ ok = 'OK  '; warn = 'WARN'; fail = 'FAIL' }
$color = @{ ok = 'Green'; warn = 'Yellow'; fail = 'Red' }
$catTitle = [ordered]@{
    prereq = 'Prerequisites'; hub = 'Hub artifacts'; config = 'Configuration'
    ledger = 'Ledger'; env = 'Secrets / env'; rules = 'Worktree rules'; info = 'Optional'
}

Write-Host ''
Write-Host '=== Hub readiness ===' -ForegroundColor Cyan
foreach ($cat in $catTitle.Keys) {
    $group = @($results | Where-Object { $_.Category -eq $cat })
    if (-not $group) { continue }
    Write-Host ''
    Write-Host $catTitle[$cat] -ForegroundColor Cyan
    foreach ($c in $group) {
        Write-Host ("  [{0}] {1}" -f $glyph[$c.Status], $c.Name) -ForegroundColor $color[$c.Status] -NoNewline
        if ($c.Detail) { Write-Host ("  - {0}" -f $c.Detail) -ForegroundColor DarkGray -NoNewline }
        Write-Host ''
        if ($c.Status -ne 'ok' -and $c.Fix) {
            Write-Host ("        fix: {0}" -f $c.Fix) -ForegroundColor DarkGray
        }
    }
}

Write-Host ''
if ($verdict.Ready) {
    Write-Host 'HUB READY - no blockers.' -ForegroundColor Green
    if ($verdict.Warnings.Count) { Write-Host ("  ({0} warning(s) - review above)" -f $verdict.Warnings.Count) -ForegroundColor Yellow }
    exit 0
}
else {
    Write-Host ("NOT READY - {0} blocker(s): {1}" -f $verdict.Blockers.Count, ($verdict.Blockers -join ', ')) -ForegroundColor Red
    Write-Host 'Run .\setup-hub.ps1 to fix interactively.' -ForegroundColor Yellow
    exit 1
}
```

- [ ] **Step 2: Verify it runs and reports against THIS repo**

This source repo is not a bootstrapped hub (no `.bare`), so the doctor must run cleanly and report blockers (proving the null-config path and the rendering work).

Run:
```powershell
.\hub-doctor.ps1
$LASTEXITCODE
```
Expected: a grouped report prints; hub-artifact + ledger checks show `FAIL`/`WARN`; final line `NOT READY - N blocker(s): ...`; `$LASTEXITCODE` is `1`.

- [ ] **Step 3: Commit**

```powershell
git add hub-doctor.ps1
git commit -m "feat(doctor): add non-interactive hub readiness report" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: `setup-hub.ps1` — scaffold + phases 1–3 (preflight, bootstrap, config)

**Files:**
- Create: `setup-hub.ps1`

- [ ] **Step 1: Write the scaffold + prompt helper + phases 1–3**

Create `setup-hub.ps1`:
```powershell
<#
.SYNOPSIS
  Interactive first-run setup for the claude-worktree-hub. Idempotent: re-run anytime
  to resume/repair. Does everything it can; offers fixes for the rest; ends by running
  the doctor.
.DESCRIPTION
  Phases: (1) preflight prerequisites, (2) bare-repo bootstrap, (3) config confirmation,
  (4) env scaffold, (5) ledger init+seed, (6) final readiness report.
.EXAMPLE
  .\setup-hub.ps1
  .\setup-hub.ps1 -CloneUrl https://github.com/acme/widgets.git
  .\setup-hub.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$CloneUrl,       # used for the bootstrap phase on a fresh hub
    [switch]$DryRun,         # show intended actions, change nothing
    [switch]$Yes             # accept the safe default for every prompt (non-interactive)
)
$ErrorActionPreference = 'Stop'
$Hub = $PSScriptRoot
. (Join-Path $Hub 'hub-checks.ps1')

function Write-Phase { param([string]$Title) Write-Host "`n==> $Title" -ForegroundColor Cyan }
function Write-Note  { param([string]$Msg)   Write-Host "    $Msg" -ForegroundColor DarkGray }

function Confirm-Action {
    <# Y/n prompt. -Yes auto-accepts; -DryRun reports and declines (no side effects). #>
    param([Parameter(Mandatory)][string]$Prompt, [switch]$DefaultNo)
    if ($DryRun) { Write-Note "(dry-run) would offer: $Prompt"; return $false }
    if ($Yes)    { return -not $DefaultNo }
    $suffix = if ($DefaultNo) { '[y/N]' } else { '[Y/n]' }
    $ans = Read-Host "    $Prompt $suffix"
    if (-not $ans) { return (-not $DefaultNo) }
    return ($ans -match '^(y|yes)$')
}

function Get-ConfigSafe {
    # Returns the parsed config or $null (never throws) so phases work pre-bootstrap.
    try { . (Join-Path $Hub 'hub-config.ps1'); return $HubConfig } catch { return $null }
}

# ---------------- Phase 1: prerequisites ----------------
function Invoke-PreflightPhase {
    Write-Phase 'Phase 1/6 - Prerequisites'
    $cfg = Get-ConfigSafe
    $checks = @(Get-HubReadiness -Config $cfg -HubRoot $Hub | Where-Object { $_.Category -eq 'prereq' })
    $hasInstaller = (Test-OnPath -Name 'winget') -or (Test-OnPath -Name 'choco')
    foreach ($c in $checks) {
        if ($c.Status -eq 'ok') { Write-Note "OK   $($c.Name)"; continue }
        Write-Host ("    NEEDS: {0} - {1}" -f $c.Name, $c.Detail) -ForegroundColor Yellow
        Write-Note "fix: $($c.Fix)"
        if ($c.Name -eq 'gh authenticated') {
            if (Confirm-Action "Run 'gh auth login' now?") {
                if (-not $DryRun) { & gh auth login; & gh auth setup-git }
            }
        }
        elseif ($c.Fix -match '^(winget|choco) ' -and $hasInstaller) {
            if (Confirm-Action "Run '$($c.Fix)' now?") {
                if (-not $DryRun) { & cmd /c $c.Fix }
            }
        }
        else {
            Write-Note 'Install it, then re-run setup-hub.ps1.'
        }
    }
}

# ---------------- Phase 2: bare-repo bootstrap ----------------
function Invoke-BootstrapPhase {
    Write-Phase 'Phase 2/6 - Bare-repo bootstrap'
    if (Test-BareRepo -HubRoot $Hub) { Write-Note 'Already bootstrapped (.bare present). Skipping.'; return }
    $url = $CloneUrl
    if (-not $url) {
        if ($DryRun) { Write-Note '(dry-run) would prompt for a clone URL and run init-hub.ps1'; return }
        if ($Yes) { throw 'No -CloneUrl provided and -Yes set; cannot bootstrap non-interactively. Re-run with -CloneUrl.' }
        $url = Read-Host '    Target repo clone URL (https://github.com/<owner>/<repo>.git)'
    }
    if (-not $url) { Write-Note 'No clone URL given; skipping bootstrap.'; return }
    Write-Note "Running init-hub.ps1 -CloneUrl $url"
    if (-not $DryRun) { & (Join-Path $Hub 'init-hub.ps1') -CloneUrl $url }
}

# ---------------- Phase 3: config confirmation ----------------
function Invoke-ConfigPhase {
    Write-Phase 'Phase 3/6 - Configuration'
    $cfgPath = Join-Path $Hub 'hub.config.json'
    if (-not (Test-Path $cfgPath)) { Write-Note 'No hub.config.json yet (bootstrap did not run). Skipping.'; return }
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $dirty = $false

    if (Test-ConfigPlaceholder -Config $cfg) {
        if ($DryRun) { Write-Note '(dry-run) would prompt for the repo slug' }
        elseif (-not $Yes) {
            $repo = Read-Host "    'repo' is unset/placeholder. Enter owner/repo"
            if ($repo) { $cfg.repo = $repo; $dirty = $true }
        }
    }

    $baseDir = Join-Path $Hub $cfg.baseWorktree
    $detected = Get-PackageManagerFromLockfile -WorktreePath $baseDir
    if ($detected -and $detected -ne $cfg.packageManager) {
        Write-Host ("    Lockfile suggests '{0}' but config uses '{1}'." -f $detected, $cfg.packageManager) -ForegroundColor Yellow
        if (Confirm-Action "Update installCmd/verifyCmd/testCmd to '$detected'?") {
            $cfg.packageManager = $detected
            $cfg.installCmd = "$detected install"
            $cfg.verifyCmd = "$detected run verify"
            $cfg.testCmd = "$detected test"
            $dirty = $true
        }
    }

    if ($dirty -and -not $DryRun) {
        ($cfg | ConvertTo-Json -Depth 6) | Set-Content -Path $cfgPath -Encoding utf8
        Write-Note 'hub.config.json updated.'
    }
    elseif (-not $dirty) { Write-Note 'Config looks good; no changes.' }
}
```

- [ ] **Step 2: Add the main orchestration at the end of `setup-hub.ps1`**

Append to `setup-hub.ps1` (phases 4–6 are filled in Task 9; reference them now):
```powershell
# ---------------- main ----------------
if ($DryRun) { Write-Host 'DRY RUN - no changes will be made.' -ForegroundColor Yellow }
Invoke-PreflightPhase
Invoke-BootstrapPhase
Invoke-ConfigPhase
Invoke-EnvPhase
Invoke-LedgerPhase
Invoke-ReadinessPhase
```

> NOTE: `Invoke-EnvPhase`, `Invoke-LedgerPhase`, and `Invoke-ReadinessPhase` are defined in Task 9. The script will not run end-to-end until Task 9 is complete — that is expected. Do **not** run it yet beyond a syntax parse.

- [ ] **Step 3: Verify the script parses (no syntax errors)**

Run:
```powershell
$null = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\setup-hub.ps1), [ref]$null, [ref]$null); 'parsed ok'
```
Expected: prints `parsed ok` with no parser errors.

- [ ] **Step 4: Commit**

```powershell
git add setup-hub.ps1
git commit -m "feat(setup): wizard scaffold + phases 1-3 (preflight, bootstrap, config)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: `setup-hub.ps1` — phases 4–6 (env, ledger, readiness) + dry-run verify

**Files:**
- Modify: `setup-hub.ps1`

- [ ] **Step 1: Add phases 4–6 before the `# ---------------- main ----------------` block**

Insert into `setup-hub.ps1` (immediately after `Invoke-ConfigPhase`'s closing brace, before the main block):
```powershell
# ---------------- Phase 4: env scaffold ----------------
function Invoke-EnvPhase {
    Write-Phase 'Phase 4/6 - Secrets / env scaffold'
    $cfg = Get-ConfigSafe
    if (-not $cfg) { Write-Note 'No config; skipping env scaffold.'; return }
    $baseDir = Join-Path $Hub $cfg.baseWorktree
    $missing = Get-MissingEnvFiles -HubRoot $Hub -Config $cfg
    if (-not $missing) { Write-Note 'All configured env files present.'; return }
    foreach ($f in $missing) {
        $example = Join-Path $baseDir "$f.example"
        if (Test-Path $example) {
            if (Confirm-Action "Copy $f.example -> $f in $($cfg.baseWorktree)\ (you fill in secrets)?") {
                if (-not $DryRun) { Copy-Item $example (Join-Path $baseDir $f) -Force }
                Write-Note "Created $($cfg.baseWorktree)\$f - edit it to add real secret values."
            }
        }
        else {
            Write-Note "Missing $f and no $f.example to copy. Create $($cfg.baseWorktree)\$f manually if your app needs it."
        }
    }
}

# ---------------- Phase 5: ledger ----------------
function Invoke-LedgerPhase {
    Write-Phase 'Phase 5/6 - Ledger (SQLite)'
    if (-not (Test-OnPath -Name 'sqlite3')) { Write-Note 'sqlite3 not on PATH; cannot init the ledger yet. Fix prereqs then re-run.'; return }
    $rc = Join-Path $Hub 'review-coverage.ps1'
    if (-not (Test-LedgerSchema -HubRoot $Hub)) {
        Write-Note 'Initializing ledger schema (review-coverage.ps1 init)...'
        if (-not $DryRun) { & $rc init }
    }
    else { Write-Note 'Ledger schema already present.' }
    if (-not (Test-LedgerSeeded -HubRoot $Hub)) {
        Write-Note 'Seeding starter topics (review-coverage.ps1 seed)...'
        if (-not $DryRun) { & $rc seed }
    }
    else { Write-Note 'Ledger already seeded.' }
}

# ---------------- Phase 6: final readiness ----------------
function Invoke-ReadinessPhase {
    Write-Phase 'Phase 6/6 - Readiness report'
    if ($DryRun) { Write-Note '(dry-run) would run hub-doctor.ps1 for the final verdict.'; return }
    & (Join-Path $Hub 'hub-doctor.ps1')
    if ($LASTEXITCODE -eq 0) { Write-Host "`nSetup complete - hub is READY." -ForegroundColor Green }
    else { Write-Host "`nSetup ran, but blockers remain (see above). Fix them and re-run .\setup-hub.ps1." -ForegroundColor Yellow }
}
```

- [ ] **Step 2: Verify the script parses**

Run:
```powershell
$null = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\setup-hub.ps1), [ref]$null, [ref]$null); 'parsed ok'
```
Expected: `parsed ok`.

- [ ] **Step 3: Dry-run the whole wizard against THIS repo (no side effects)**

Run:
```powershell
.\setup-hub.ps1 -DryRun
```
Expected: all six phases print; Phase 1 lists prereq statuses; Phase 2 notes `.bare` absent and that it *would* prompt for a clone URL; Phases 3–5 note what they *would* do; Phase 6 notes it *would* run the doctor. **No files created or modified** — confirm with:
```powershell
git status --short
```
Expected: only the (already-committed) new scripts; no unexpected new/modified files from the dry run.

- [ ] **Step 4: Commit**

```powershell
git add setup-hub.ps1
git commit -m "feat(setup): wizard phases 4-6 (env, ledger, readiness)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Point `init-hub.ps1` "Next:" output at the wizard/doctor

**Files:**
- Modify: `init-hub.ps1:77-82`

- [ ] **Step 1: Update the closing guidance**

In `init-hub.ps1`, replace the final `Write-Host` block (currently lines ~77–82, the "Next:" steps) with:
```powershell
Write-Host ""
Write-Host "Hub bootstrapped for $Repo." -ForegroundColor Green
Write-Host "Finish setup (idempotent - does config, ledger, env scaffold, prereq checks):" -ForegroundColor Green
Write-Host "  .\setup-hub.ps1" -ForegroundColor Green
Write-Host "Check readiness anytime:" -ForegroundColor Green
Write-Host "  .\hub-doctor.ps1" -ForegroundColor Green
```

- [ ] **Step 2: Verify the script still parses**

Run:
```powershell
$null = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\init-hub.ps1), [ref]$null, [ref]$null); 'parsed ok'
```
Expected: `parsed ok`.

- [ ] **Step 3: Commit**

```powershell
git add init-hub.ps1
git commit -m "docs(init-hub): point Next steps at setup-hub.ps1 / hub-doctor.ps1" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: Documentation — README + CLAUDE.md

**Files:**
- Modify: `README.md` (Quickstart ~96–119, file map ~58–71, Prerequisites ~81–93)
- Modify: `CLAUDE.md` (directory-structure listing + setup narrative)

- [ ] **Step 1: Collapse the README Quickstart to one command**

In `README.md`, replace the Quickstart code block (steps 1–6) with:
```powershell
# 1. Clone this hub template
git clone https://github.com/<you>/claude-worktree-hub.git
cd claude-worktree-hub

# 2. Run the setup wizard - idempotent; does bootstrap, config, ledger, env scaffold,
#    and prerequisite checks, then prints a readiness report. Re-run anytime.
.\setup-hub.ps1 -CloneUrl https://github.com/<owner>/<repo>.git

# 3. Confirm readiness at any time
.\hub-doctor.ps1

# 4. Provision a solver worktree for a GitHub issue and launch it
.\new-worktree.ps1 -Issue 123 -Install
cd issue-123-<slug>
& ..\claude-launch.ps1 --permission-mode auto --effort max --name "#123 my issue"
```
Add one line under the block: `The old step-by-step (init-hub.ps1, then review-coverage.ps1 init/seed) still works and is what setup-hub.ps1 runs under the hood.`

- [ ] **Step 2: Add the new scripts to the README file map**

In the `README.md` file-map (the `├──` listing), add these three lines near `init-hub.ps1`:
```text
├── setup-hub.ps1            <- interactive first-run wizard (bootstrap + config + ledger + env + prereqs)
├── hub-doctor.ps1           <- non-interactive readiness report (exit 0 ready / 1 blockers)
├── hub-checks.ps1           <- shared readiness-check library (single source of truth)
```

- [ ] **Step 3: Note Pester in README Prerequisites**

In the `README.md` Prerequisites table, add a row:
```text
| `Pester` v5 | Test-only; `Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser` to run `hub-checks.Tests.ps1` |
```

- [ ] **Step 4: Update CLAUDE.md directory structure + setup mention**

In `CLAUDE.md`, in the `## Directory structure` code block, add the same three script lines near `init-hub.ps1`:
```text
├── setup-hub.ps1            <- interactive first-run wizard (bootstrap + config + ledger + env + prereqs)
├── hub-doctor.ps1           <- non-interactive readiness report (exit 0 ready / 1 blockers)
├── hub-checks.ps1           <- shared readiness-check library (single source of truth for "ready")
```
And update the top-of-file pointer line from:
```text
> **New here? See `README.md`, then run `.\init-hub.ps1`.**
```
to:
```text
> **New here? See `README.md`, then run `.\setup-hub.ps1` (idempotent first-run setup). Check readiness with `.\hub-doctor.ps1`.**
```

- [ ] **Step 5: Verify the docs render (quick visual scan)**

Run:
```powershell
Select-String -Path README.md, CLAUDE.md -Pattern 'setup-hub|hub-doctor|hub-checks' | Select-Object Filename, LineNumber, Line
```
Expected: matches in both files for all three scripts.

- [ ] **Step 6: Commit**

```powershell
git add README.md CLAUDE.md
git commit -m "docs: document setup-hub wizard + hub-doctor in README and CLAUDE.md" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: Final verification pass

**Files:** none (verification only)

- [ ] **Step 1: Full test suite green**

Run:
```powershell
Invoke-Pester -Path .\hub-checks.Tests.ps1 -Output Detailed
```
Expected: all `Describe` blocks pass, 0 failed.

- [ ] **Step 2: Doctor runs and reports NOT READY on this (non-hub) repo with exit 1**

Run:
```powershell
.\hub-doctor.ps1; "exit=$LASTEXITCODE"
```
Expected: grouped report; `exit=1` (this source repo is intentionally not a bootstrapped hub).

- [ ] **Step 3: Wizard dry-run is side-effect free**

Run:
```powershell
.\setup-hub.ps1 -DryRun
git status --short
```
Expected: six phases print; `git status --short` shows no new/modified files caused by the dry run.

- [ ] **Step 4: All scripts parse**

Run:
```powershell
foreach ($f in 'hub-checks.ps1','hub-doctor.ps1','setup-hub.ps1','init-hub.ps1') {
    $null = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path ".\$f"), [ref]$null, [ref]$null)
    "$f parsed ok"
}
```
Expected: each prints `... parsed ok`.

- [ ] **Step 5: Report completion to the user**

Summarize: files added (`hub-checks.ps1`, `hub-checks.Tests.ps1`, `hub-doctor.ps1`, `setup-hub.ps1`), files changed (`init-hub.ps1`, `README.md`, `CLAUDE.md`), test result, and the branch state. Ask whether to push + open a PR (do not push unprompted).

---

## Self-Review (completed by plan author)

**Spec coverage:** every spec section maps to a task — checks library + 21-check definition → Tasks 1–6; doctor + exit codes → Task 7; interactive wizard's 6 phases → Tasks 8–9; init-hub "Next:" → Task 10; README/CLAUDE.md docs → Task 11; Pester + dry-run + manual testing → Tasks 1–6 (Pester) and 9/12 (dry-run + manual); the "checks must run on an un-bootstrapped hub" subtlety → Task 6 null-config test + Task 7 defensive load.

**Placeholder scan:** no TBD/TODO; every code step contains complete code; every command has expected output.

**Type consistency:** the result contract (`Name/Category/Status/Detail/Fix`) and helper signatures (`Get-HubReadiness -Config -HubRoot`, `Test-*` wrappers, `Get-MissingEnvFiles`, `Get-PackageManagerFromLockfile -WorktreePath`) are used identically across Tasks 5–9.
