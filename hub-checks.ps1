<#
  hub-checks.ps1 - readiness check library for the claude-worktree-hub.
  The SINGLE source of truth for "what a complete hub requires".
  Pure-ish: no prompts, no mutations. Consumed by hub-doctor.ps1 and setup-hub.ps1.
  Dot-source it:  . "$PSScriptRoot\hub-checks.ps1"
  Public: New-CheckResult, Get-ReadinessVerdict, Get-HubReadiness, plus pure helpers.
#>

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

function Test-ConfigPlaceholder {
    param($Config)
    if (-not $Config -or -not $Config.repo) { return $true }
    return ($Config.repo -eq 'owner/repo')
}

function Test-GitPointer {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path -PathType Leaf)) { return $false }   # missing, or a directory
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return $false   # UTF-8 BOM - git silently fails to parse this
    }
    return ([System.IO.File]::ReadAllText($Path).Trim() -eq 'gitdir: ./.bare')
}

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

function Resolve-InstallCommand {
    # Pure: given a check Name + which installers are present, return a runnable install
    # command string (winget preferred), or $null if we can't safely auto-install.
    param([Parameter(Mandatory)][string]$CheckName, [switch]$HasWinget, [switch]$HasChoco)
    $winget = @{ 'PowerShell 7+'='Microsoft.PowerShell'; 'git on PATH'='Git.Git'; 'gh on PATH'='GitHub.cli'; 'sqlite3 on PATH'='SQLite.SQLite'; 'bash on PATH'='Git.Git' }
    $choco  = @{ 'git on PATH'='git'; 'gh on PATH'='gh'; 'sqlite3 on PATH'='sqlite'; 'bash on PATH'='git' }
    if ($HasWinget -and $winget.ContainsKey($CheckName)) { return "winget install --id $($winget[$CheckName]) -e" }
    if ($HasChoco  -and $choco.ContainsKey($CheckName))  { return "choco install $($choco[$CheckName]) -y" }
    return $null
}

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
    # gh auth setup-git writes a credential.<host>.helper whose VALUE invokes `gh auth git-credential`.
    # Match that value (not the host) - a github.com host with a non-gh GCM helper must NOT match.
    if (-not (Test-OnPath -Name 'git')) { return $false }
    $cfg = (& git config --get-regexp '^credential.*\.helper$' 2>$null)
    return [bool]($cfg -match 'gh(\.exe)?["'']?\s+auth\s+git-credential')
}

function Test-BareRepo {
    param([Parameter(Mandatory)][string]$HubRoot)
    if (-not (Test-OnPath -Name 'git')) { return $false }   # a missing tool throws under Stop
    $r = (& git -C (Join-Path $HubRoot '.bare') rev-parse --is-bare-repository 2>$null)
    return ($r -eq 'true')
}

function Test-HubGitConfig {
    param([Parameter(Mandatory)][string]$HubRoot)
    if (-not (Test-OnPath -Name 'git')) { return $false }
    $fetch = (& git -C $HubRoot config --get-all remote.origin.fetch 2>$null)
    $gc = (& git -C $HubRoot config --get gc.auto 2>$null)
    return (($fetch -match '\+refs/heads/\*') -and ($gc -eq '0'))
}

function Test-BaseWorktree {
    param([Parameter(Mandatory)][string]$HubRoot, $Config)
    if (-not (Test-OnPath -Name 'git')) { return $false }
    $base = if ($Config -and $Config.baseWorktree) { $Config.baseWorktree } else { 'main' }
    $wt = Join-Path $HubRoot $base
    if (-not (Test-Path $wt)) { return $false }
    $up = (& git -C $wt rev-parse --abbrev-ref '@{upstream}' 2>$null)
    return [bool](($LASTEXITCODE -eq 0) -and $up)
}

function Test-LedgerSchema {
    param([Parameter(Mandatory)][string]$HubRoot)
    if (-not (Test-OnPath -Name 'sqlite3')) { return $false }
    $db = Join-Path $HubRoot '.review\coverage.db'
    if (-not (Test-Path $db)) { return $false }
    $n = (& sqlite3 $db "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('topic','issue','finding','worktree');" 2>$null)
    return ([int]$n -eq 4)
}

function Test-LedgerSeeded {
    param([Parameter(Mandatory)][string]$HubRoot)
    if (-not (Test-OnPath -Name 'sqlite3')) { return $false }
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

    # config commands match the project - lockfile-detected PM vs config, AND the npm scripts
    # referenced by verifyCmd/testCmd exist. Only meaningful when config + a Node project exist.
    if ($cfgOk) {
        $baseDir = Join-Path $HubRoot $Config.baseWorktree
        $detected = Get-PackageManagerFromLockfile -WorktreePath $baseDir
        $pkgPath = Join-Path $baseDir 'package.json'
        $hasNode = $detected -or (Test-Path $pkgPath)
        if (-not $hasNode) {
            $r.Add( (New-CheckResult -Name 'config commands match project' -Category config -Status ok -Detail 'n/a (no lockfile/package.json)') )
        }
        else {
            $problems = [System.Collections.Generic.List[string]]::new()
            if ($detected -and ($Config.packageManager -ne $detected)) {
                $problems.Add("config=$($Config.packageManager) but lockfile=$detected")
            }
            # Best-effort: pull the script names confidently referenced by verifyCmd/testCmd and
            # confirm they exist in package.json's .scripts. Skip commands that aren't a simple
            # pm-script invocation (don't false-warn). Read defensively - a bad/absent file just
            # skips the script half rather than throwing under $ErrorActionPreference='Stop'.
            $scripts = $null
            try {
                $pkg = Get-Content $pkgPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                $scripts = $pkg.scripts
            }
            catch { $scripts = $null }
            # Anchor extraction on the configured PM as the leading token, so only a real
            # pm-script invocation yields a name: `<pm> run <script>` / `<pm> [run] <script>`.
            # A direct binary (`vitest run`, `turbo test`, `tsc --noEmit`) matches neither and
            # is skipped - no false "missing script 'run'/'--coverage'" warning.
            if ($scripts -and $Config.packageManager) {
                $pmEsc = [regex]::Escape($Config.packageManager)
                $names = @($scripts.PSObject.Properties.Name)
                $refs = @()
                if ($Config.verifyCmd -and ($Config.verifyCmd -match "^\s*$pmEsc\s+run\s+(\S+)$")) { $refs += $Matches[1] }
                if ($Config.testCmd -and ($Config.testCmd -match "^\s*$pmEsc\s+(?:run\s+)?(\S+)$")) { $refs += $Matches[1] }
                foreach ($ref in $refs) {
                    if ($names -notcontains $ref) { $problems.Add("missing npm script '$ref'") }
                }
            }
            $match = ($problems.Count -eq 0)
            $r.Add( (New-CheckResult -Name 'config commands match project' -Category config -Status (& $st $match 'ok' 'warn') `
                        -Detail $(if ($match) { "packageManager=$($Config.packageManager)" } else { $problems -join '; ' }) `
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
