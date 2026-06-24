<#
.SYNOPSIS
    Hand a complex worktree off from its PLANNING session to a FRESH EXECUTION session, then close the
    planner window once the executor is confirmed up. Resets context / cuts token usage.
.DESCRIPTION
    Called by the planner agent AFTER the gate (plan approved). It:
      1. Requires SPEC.md + PLAN.md to exist and the worktree to be CLEAN (committed) - the executor
         reads the committed plan, so the user's gate corrections must already be in PLAN.md.
      2. Launches a fresh executor session in the SAME worktree/branch, seeded to read SPEC.md/PLAN.md
         and implement via subagents (no --continue -> empty context window).
      3. Launches a DETACHED watcher that waits until the executor process is actually up, then
         taskkills the planner's launcher-pwsh tree (closing the planner window). If the executor never
         appears, the planner is LEFT OPEN (fail-safe). Detached so killing the planner can't kill it.
    The planner is found by its launcher cmdline (.launchers\<worktree>.ps1); if the planner wasn't
    started via its launcher, it simply isn't auto-closed (safe).
.EXAMPLE
    & <hub root>\handoff.ps1 -Worktree issue-491-pwa-architecture
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Worktree,   # worktree FOLDER name (planner == executor worktree)
    [string]$Title,                                    # executor tab title (default "<worktree> exec")
    [string]$PrBase,                                   # PR base for the executor's PR (default: $HubConfig.defaultBranch)
    [switch]$NoClose,                                  # hand off but leave the planner window open
    [switch]$DryRun                                    # validate + generate launchers, but launch nothing
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'hub-config.ps1')   # sets $Hub + $HubConfig
if (-not $PrBase) { $PrBase = $HubConfig.defaultBranch }

$wtPath = Join-Path $Hub $Worktree
if (-not (Test-Path $wtPath)) { throw "Worktree '$Worktree' not found under the hub." }

# --- Guard 1: the approved plan must be on disk and COMMITTED ---
foreach ($f in @('SPEC.md', 'PLAN.md')) {
    if (-not (Test-Path (Join-Path $wtPath $f))) { throw "Missing $f in '$Worktree' - write & commit the plan before handing off." }
}
$dirty = ((& git -C $wtPath status --porcelain) | Out-String).Trim()
if ($dirty) { throw "Worktree '$Worktree' has uncommitted changes - commit SPEC.md/PLAN.md and your baseline before handoff (the executor reads the committed plan)." }

$branch = (& git -C $wtPath rev-parse --abbrev-ref HEAD).Trim()
if (-not $Title) { $Title = "$Worktree exec" }
$launchersDir = Join-Path $Hub '.launchers'
if (-not (Test-Path $launchersDir)) { New-Item -ItemType Directory -Force -Path $launchersDir | Out-Null }

# --- generate the fresh executor launcher (same worktree/branch, no planning context) ---
$execPrompt = @"
You are the EXECUTION agent for a worktree whose plan was already approved at the gate. You start FRESH
on purpose - the research/planning context is intentionally gone; everything you need is on disk.
Worktree folder: $Worktree   (use as -Parent for any child worktrees)
Branch:          $branch

Work to the standard of a professional app-development team: follow the repo's existing patterns and
conventions, write clean maintainable code, and prove it works with tests. Do NOT cover up, hide, or paper
over errors, failures, or problems - surface them honestly and fix the cause, not the symptom; if the plan
turns out wrong or you cannot fully implement it, say so plainly rather than masking it.

1. Read SPEC.md and PLAN.md here - the APPROVED plan (it already includes the user's gate corrections).
   Treat it as the source of truth; do NOT re-plan or re-open the gate.
2. Run: $($HubConfig.installCmd).
3. Implement PLAN.md using in-process SUBAGENTS for parallel work. For pieces PLAN.md marks as large
   AND independent, create child worktrees (started properly for you):
       & $Hub\spawn-child.ps1 -Parent $Worktree -Name <piece> -Title "<tab>" -Task "<brief>" [-Complex]
   (children PR into '$branch'; you assemble them.)
4. Validate with $($HubConfig.verifyCmd) + tests; commit, push, and open a PR with base '$PrBase'
   (gh pr create --base $PrBase). Do NOT merge.
5. FINISH with a COMPLETION REPORT as your last output, rendered by the shared box-table tool so every
   worktree matches:  & $Hub\format-report.ps1 -Title '<task> - completion' -Rows 'Issue|...',
   'Changes|<N> files', 'Verify|<OK/X> typecheck . lint', 'Tests|...', 'PR|#<M> <url> (base $PrBase, not merged)',
   'Status|pushed + PR opened'   (real values; mark pass/fail honestly). Also list any OUT-OF-SCOPE problems
   you found but did NOT fix as recommended follow-ups (second table + a section in your PR body).
   Report to the hub ledger too: & $Hub\review-coverage.ps1 progress -Worktree $Worktree -Status pr-open -Pr <M>
   and (per follow-up) & $Hub\review-coverage.ps1 recommend -Worktree $Worktree -Title '<title>' -Area '<area>' -Severity '<sev>' -Detail '<why>'.
NEVER apply a database migration to production, and NEVER run a headless 'claude --print' session.
Begin by reading SPEC.md and PLAN.md.
"@

$execLauncher = Join-Path $launchersDir "$Worktree--exec.ps1"
$execContent = @"
# Executor launcher for '$Worktree' - generated by handoff.ps1. Fresh execution session.
`$Host.UI.RawUI.WindowTitle = '$Title'
Set-Location '$wtPath'
`$prompt = @'
$execPrompt
'@
& "$Hub\claude-launch.ps1" $(Get-LaunchFlags) --name '$Title' `$prompt
"@
[System.IO.File]::WriteAllText($execLauncher, $execContent, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "==> Executor launcher written: $execLauncher" -ForegroundColor Green

# --- generate the detached watcher/closer (confirm executor up -> kill planner tree) ---
$closerPath = Join-Path $launchersDir "$Worktree--closer.ps1"
$closerContent = @"
# Detached watcher generated by handoff.ps1: closes the planner once the executor is confirmed up.
`$ErrorActionPreference = 'SilentlyContinue'
`$exec = `$null
for (`$i = 0; `$i -lt 40; `$i++) {
    Start-Sleep -Milliseconds 750
    `$exec = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { `$_.CommandLine -like '*$Worktree--exec.ps1*' }
    if (`$exec) { break }
}
if (-not `$exec) { return }   # executor never came up -> leave the planner open (fail-safe)
`$planner = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object {
    `$_.CommandLine -like '*\$Worktree.ps1*' -and `$_.CommandLine -notlike '*--exec.ps1*' -and `$_.CommandLine -notlike '*--closer.ps1*'
}
foreach (`$p in `$planner) { & taskkill /T /F /PID `$p.ProcessId 2>`$null | Out-Null }
"@
[System.IO.File]::WriteAllText($closerPath, $closerContent, (New-Object System.Text.UTF8Encoding($false)))

if ($DryRun) {
    Write-Host "==> -DryRun: launchers generated, nothing launched. Closer: $closerPath" -ForegroundColor Yellow
    return
}

Write-Host "==> Launching fresh executor '$Title'..." -ForegroundColor Cyan
Start-Process -FilePath 'pwsh' -ArgumentList '-NoExit', '-File', $execLauncher | Out-Null

if ($NoClose) {
    Write-Host "    handed off. Planner left open (-NoClose) - close this window when ready." -ForegroundColor Green
    return
}

# Launch the watcher DETACHED (Win32_Process.Create -> not a child of the planner) so that taskkilling
# the planner tree cannot kill the watcher mid-run.
$null = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
    CommandLine = "pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$closerPath`""
}
Write-Host "    handed off. This planner window will close automatically once the executor is confirmed up." -ForegroundColor Green
