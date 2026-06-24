<#
.SYNOPSIS
    Create + launch a READ-ONLY RECON (discovery) worktree for a surface (optionally a single lens).
.DESCRIPTION
    A recon worktree deeply reviews a surface/lens and writes its findings + lifecycle to the hub review
    LEDGER (.review\coverage.db via review-coverage.ps1). It does NOT change app code, create branches,
    open PRs, or file GitHub issues - a human triages the ledger and promotes findings to issues
    separately (review-coverage.ps1 findings | promote). Read-only base = latest origin/main.
.EXAMPLE
    .\new-recon.ps1 -Surface database -Lens security
    .\new-recon.ps1 -Surface module:components/calendar -Lens bugs
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Surface,
    [string]$Lens,
    [string]$Detail,
    [switch]$NoLaunch
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'hub-config.ps1')   # sets $Hub + $HubConfig

$base = ((($Surface -replace '[^a-zA-Z0-9]+', '-').Trim('-'))).ToLower()
$slug = if ($Lens) { "$base-$((($Lens -replace '[^a-zA-Z0-9]+','-')).ToLower())" } else { $base }
$folder = "recon-$slug"
$branch = "recon/$slug"
$wtPath = Join-Path $Hub $folder
if (Test-Path $wtPath) { throw "Recon worktree '$folder' already exists." }
$subjKey = ($Surface -replace '^module:?', '')
$topicKey = if ($Lens) { "$subjKey/$Lens" } else { $subjKey }

& "$Hub\new-worktree.ps1" -Name $folder -Branch $branch -NoEnv 2>&1 |
    Select-String -NotMatch 'Updating files|Preparing worktree|HEAD is now at|Remember to add' | Out-Host

$dbHint = if ($HubConfig.database.enabled) { " Database advisors: run your provider's security advisors ($($HubConfig.database.provider))." } else { '' }
$dbPerfHint = if ($HubConfig.database.enabled) { " Database: check indexes, slow queries, and N+1 patterns via your $($HubConfig.database.provider) provider." } else { '' }

$sources = switch -Regex ($Surface) {
    '^database' {
        if ($HubConfig.database.enabled) {
            "Database ($($HubConfig.database.provider)): get_advisors (security AND performance), get_logs, and READ-ONLY catalog queries for runtime stats (slow queries by total_exec_time, unused indexes, full seq-scans on hot tables). Review schema, access rules/RLS, constraints, indexes. Use SELECT/catalog reads ONLY - never DML/DDL."
        } else {
            'Database layer: schema, access rules, query patterns, indexes. READ-ONLY catalog/stats queries only - never DML/DDL.'
        }
        break
    }
    '^logs' { 'Runtime + build logs from your hosting/platform and database. Group errors/warnings by frequency and root cause.'; break }
    '^security' { "Code: authz on routes/server actions, access rules, multi-tenant isolation, secrets.$dbHint"; break }
    '^perf' { "Code: rendering/data-fetch waterfalls, heavy components, bundle size.$dbPerfHint"; break }
    '^a11y' { 'Code: keyboard nav + focus in overlays, ARIA/roles, contrast, responsive/mobile. Shared UI primitives, dialogs, tables, forms.'; break }
    '^deps' { 'package.json + lockfile: outdated / vulnerable deps, duplicate/heavy packages, unused deps.'; break }
    '^tests' { 'Test suite: coverage gaps on critical paths, flaky tests, missing e2e.'; break }
    '^module' { "The module/path '$subjKey' $Detail - review deeply for bugs, smells, missing tests, and risks."; break }
    '^platform' { 'Hosting/deploy/build platform: deployment + build health, runtime/edge config, caching/CDN, function limits, environment configuration. Use your platform provider''s logs/dashboards if available.'; break }
    default { 'The whole application - breadth-first across major modules; fan out a subagent per area.' }
}

$preamble = if ($HubConfig.complexPromptPreamble) { $HubConfig.complexPromptPreamble + "`n`n" } else { '' }
$prompt = @"
${preamble}You are a RECON (discovery) agent in a dedicated READ-ONLY git worktree for $($HubConfig.repo). Your job is a
DEEP review of the '$Surface' surface$(if($Lens){" through the '$Lens' lens"}). You write findings + your
lifecycle to the hub review LEDGER (SQLite). You do NOT change code, create branches, open PRs, or run
'gh issue create' - a human triages the ledger and promotes findings to issues separately.
Worktree folder: $folder
Ledger topic key: $topicKey

Sources for this surface: $sources

Review with the rigor of a professional security/quality auditor: investigate the real root cause of each
issue and report problems honestly and completely - never downplay, omit, or paper over a real problem (and
do not invent or pad findings). Every finding needs concrete evidence.

1. Log start:
     & "$Hub\review-coverage.ps1" activity -Worktree '$folder' -WType recon -Event started -Detail '$topicKey'
2. DISCOVER deeply - fan out SUBAGENTS in parallel across sub-areas (be thorough; this is meant to be
   token-intensive). For each DISTINCT problem capture: clear title, severity (Critical/High/Medium/Low),
   category, evidence (file:line / log line / advisor), impact, and a suggested fix.
3. DEDUP: check ``gh issue list --repo $($HubConfig.repo) --state all --limit 200`` AND the ledger
   (``review-coverage.ps1 findings``) - skip anything already captured.
4. RECORD each finding in the LEDGER (this is your output - do NOT file GitHub issues):
     & "$Hub\review-coverage.ps1" finding -Worktree '$folder' -Topic '$topicKey' -Title "..." -Severity High -Category "security|performance|a11y|bug|db|cost" -Detail "evidence file:line / log" -Suggestion "fix"
   Also drop a human-readable candidate-issues.md in this worktree.
5. When the review is complete:
     & "$Hub\review-coverage.ps1" complete -Topic '$topicKey' -Worktree '$folder'
     & "$Hub\review-coverage.ps1" activity -Worktree '$folder' -WType recon -Event completed -Detail '<n> findings'
NEVER write application code, create branches, open PRs, or run 'gh issue create'. Begin the deep review now.
"@

# Clean prompt file - handy for manual re-runs / inspection in a window (no cost).
$promptPath = Join-Path $wtPath '.recon-prompt.txt'
[System.IO.File]::WriteAllText($promptPath, $prompt, (New-Object System.Text.UTF8Encoding($false)))

$launchersDir = Join-Path $Hub '.launchers'
if (-not (Test-Path $launchersDir)) { New-Item -ItemType Directory -Force -Path $launchersDir | Out-Null }
$launcherPath = Join-Path $launchersDir "$folder.ps1"
$lc = @"
# Recon launcher for '$Surface'$(if($Lens){" / $Lens"}) - generated by new-recon.ps1. READ-ONLY discovery. Re-runnable.
`$Host.UI.RawUI.WindowTitle = 'recon $slug'
Set-Location '$wtPath'
`$prompt = @'
$prompt
'@
& "$Hub\claude-launch.ps1" $(Get-LaunchFlags) --name 'recon $slug' `$prompt
"@
[System.IO.File]::WriteAllText($launcherPath, $lc, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Recon worktree ready: $wtPath  (topic '$topicKey')" -ForegroundColor Green

# Launch ONLY through the windowed wrapper (subscription-covered). NEVER run `claude --print`
# / headless - that bills API usage outside the user's subscription (real money).
if (-not $NoLaunch) {
    Start-Process -FilePath 'pwsh' -ArgumentList '-NoExit', '-File', $launcherPath | Out-Null
    Write-Host "Launched 'recon $slug' (read-only; writes findings to the ledger)." -ForegroundColor Green
}
else { Write-Host "(-NoLaunch) launcher: $launcherPath" -ForegroundColor DarkGray }
