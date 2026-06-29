<#
.SYNOPSIS
    Review-coverage ledger for the worktree hub (SQLite). Central store for review topics + schedule,
    findings, and all-worktree activity.
.DESCRIPTION
    DB: .review\coverage.db (hub-local, untracked). Tables:
      inventory  - modules + resources + surfaces (the coverage matrix source)
      topic      - a coverage cell (subject x lens) with priority, cadence, last_run
      run        - review-run history
      finding    - findings reviewers write (staged candidate issues): proposed -> verified -> filed -> completed
      finding_link - related/dependency edges between findings (kind: related|duplicate-of|depends-on|blocks)
      activity   - lifecycle events from EVERY worktree (recon/solver/...) = the live event feed
      worktree   - ONE row per worktree, status updated as it progresses = the live monitor view
      recommendation - out-of-scope follow-ups a SOLVER found: proposed -> filed (GH issue) / dismissed
    Commands:
      init | seed | due [-N k] | run [-N k] | report | status [-N k]
      activity -Worktree w -WType t -Event e [-Detail d]        (append a lifecycle event)
      finding  -Worktree w -Topic t -Title s [-Severity .. -Category .. -Detail .. -Suggestion ..]
      complete -Topic t -Worktree w [-Status s]                 (stamp topic last_run + finish run)
      findings [-Status proposed | -Unverified] | promote -Id n (recon triage + file as a GH issue)
      verify   -Id n -Verdict <still-valid|already-fixed|partially-fixed|out-of-scope|needs-info>
               [-Severity .. -Scope '..' -FixedBy '..' -Confidence .. -Note '..' -Related '12,15' -DependsOn '9' -Dismiss]
      resolve  -Id n [-Issue M]                                 (stamp completed_at + status=completed at merge)
      register -Worktree w -WType solver -Issue N -Branch b      (orchestrator: add a worktree to the monitor)
      progress -Worktree w -Status <working|spec-gate|pr-open|merged|retired|blocked|failed> [-Pr M] [-Note d]
      recommend -Worktree w -Issue N -Title '..' [-Area a -Severity s -Detail d]   (solver: out-of-scope issue)
      monitor | recommendations [-Status proposed] | file-rec -Id n | dismiss-rec -Id n
.EXAMPLE
    & .\review-coverage.ps1 init
    & .\review-coverage.ps1 seed
    & .\review-coverage.ps1 due -N 5
    & .\review-coverage.ps1 report
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'help',
    [Parameter(Position = 1)][string]$Sub,          # sub-command for 'issue' (sync|review|record-review|list|show|approve|dismiss|next|unreviewed)
    [int]$N = 8,
    [int]$Id,
    [string]$Worktree, [string]$WType, [string]$Event, [string]$Detail,
    [string]$Topic, [string]$Title, [string]$Severity = 'Medium', [string]$Category, [string]$Suggestion,
    [string]$Status = 'proposed',
    [int]$Issue, [string]$Branch, [int]$Pr, [string]$Area, [string]$Note,
    [string]$Verdict, [string]$Scope, [string]$FixedBy, [string]$Confidence, [string]$Related, [string]$DependsOn,
    [string]$Targets, [string]$Reads, [string]$Effort, [string]$Track,   # issue-review fields
    [switch]$Unverified, [switch]$Dismiss, [switch]$All,
    [string]$Repo,
    [string]$Target,    # hub-resolve: where the fix landed (prompt|config|script|memory). NB: distinct from -Targets (issue owned-paths).
    [string]$DbPath,    # override the ledger path (tests / pre-bootstrap); default <hub>\.review\coverage.db
    [string]$Expert, [string]$Question, [string]$Advice, [string]$Decision, [string]$Followed, [string]$Rationale,   # consult fields (-Followed: yes|partial|overridden)
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
# Ledger/monitor verbs are local SQLite and must work even before the hub is configured
# (no hub.config.json yet — tests, or `monitor` on a half-set-up hub). Only the GitHub/
# base-worktree verbs (seed / promote / file-rec / issue sync) actually need config.
try { . (Join-Path $PSScriptRoot 'hub-config.ps1') }   # sets $Hub + $HubConfig
catch { $Hub = $PSScriptRoot; $HubConfig = $null; $configError = $_ }
if (-not $Repo -and $HubConfig) { $Repo = $HubConfig.repo }
if (-not $HubConfig -and (($Command -in @('seed', 'promote', 'file-rec')) -or ($Command -eq 'issue' -and $Sub -eq 'sync'))) {
    throw $configError
}
$db = if ($DbPath) { $DbPath } else {
    $reviewDir = Join-Path $Hub '.review'
    if (-not (Test-Path $reviewDir)) { New-Item -ItemType Directory -Force -Path $reviewDir | Out-Null }
    Join-Path $reviewDir 'coverage.db'
}

function q([string]$s) { if ($null -eq $s) { return '' } ($s -replace "'", "''") }
# .timeout makes concurrent writers (8+ solver worktrees) wait instead of failing with "database is locked"
# (silently, unlike `PRAGMA busy_timeout` which echoes the value).
function Exec([string]$sql) {
    $sql | & sqlite3 -cmd ".timeout 8000" $db
    # Native sqlite3 failures do NOT trip $ErrorActionPreference='Stop'; surface them instead of
    # silently dropping the write (a stamped topic with no rows is worse than a loud failure).
    if ($LASTEXITCODE -ne 0) { throw "sqlite3 write failed (exit $LASTEXITCODE): $($sql.Substring(0,[Math]::Min(160,$sql.Length)))" }
}
function Query([string]$sql) {
    & sqlite3 -cmd ".timeout 8000" -header -column $db $sql
    if ($LASTEXITCODE -ne 0) { Write-Warning "sqlite3 query failed (exit $LASTEXITCODE)" }
}
# Scalar read with the same busy-timeout; throws on a real sqlite error instead of returning '' (which
# would silently misclassify issue origin/severity in `issue sync` under concurrent write locks).
function Scalar([string]$sql) {
    $r = & sqlite3 -cmd ".timeout 8000" $db $sql
    if ($LASTEXITCODE -ne 0) { throw "sqlite3 read failed (exit $LASTEXITCODE): $sql" }
    return $r
}
function NullableInt([int]$v) { if ($v -gt 0) { "$v" } else { 'NULL' } }

switch ($Command) {

    'init' {
        Exec @'
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS inventory(
  id INTEGER PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL UNIQUE, area TEXT, importance INTEGER DEFAULT 3);
CREATE TABLE IF NOT EXISTS topic(
  id INTEGER PRIMARY KEY, subject TEXT NOT NULL, lens TEXT NOT NULL, title TEXT,
  priority INTEGER DEFAULT 3, cadence_days INTEGER, enabled INTEGER DEFAULT 1,
  last_run_at TEXT, last_status TEXT, last_issues INTEGER DEFAULT 0, UNIQUE(subject,lens));
CREATE TABLE IF NOT EXISTS run(
  id INTEGER PRIMARY KEY, topic_id INTEGER, worktree TEXT,
  started_at TEXT DEFAULT (datetime('now')), finished_at TEXT, status TEXT DEFAULT 'running',
  candidates INTEGER DEFAULT 0, filed INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS finding(
  id INTEGER PRIMARY KEY, run_id INTEGER, worktree TEXT, topic TEXT, title TEXT NOT NULL,
  severity TEXT, category TEXT, evidence TEXT, suggestion TEXT, status TEXT DEFAULT 'proposed',
  github_issue INTEGER, created_at TEXT DEFAULT (datetime('now')),
  verdict TEXT, confidence TEXT, orig_severity TEXT, scope TEXT, fixed_by TEXT,
  verify_notes TEXT, verified_at TEXT, completed_at TEXT);
CREATE TABLE IF NOT EXISTS finding_link(
  id INTEGER PRIMARY KEY, finding_id INTEGER NOT NULL, related_id INTEGER NOT NULL,
  kind TEXT NOT NULL, note TEXT, created_at TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS activity(
  id INTEGER PRIMARY KEY, worktree TEXT, wtype TEXT, event TEXT, detail TEXT, at TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS worktree(
  id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, wtype TEXT, issue INTEGER, branch TEXT, pr INTEGER,
  status TEXT DEFAULT 'registered', note TEXT,
  created_at TEXT DEFAULT (datetime('now')), updated_at TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS recommendation(
  id INTEGER PRIMARY KEY, worktree TEXT, source_issue INTEGER, title TEXT NOT NULL, detail TEXT,
  area TEXT, severity TEXT, status TEXT DEFAULT 'proposed', github_issue INTEGER,
  created_at TEXT DEFAULT (datetime('now')),
  verdict TEXT, confidence TEXT, orig_severity TEXT, scope TEXT, fixed_by TEXT,
  verify_notes TEXT, verified_at TEXT, completed_at TEXT);
CREATE TABLE IF NOT EXISTS issue(
  number INTEGER PRIMARY KEY, title TEXT, labels TEXT, author TEXT, origin TEXT,
  review_status TEXT DEFAULT 'synced',
  verdict TEXT, severity TEXT, orig_severity TEXT, effort TEXT, track TEXT,
  confidence TEXT, review_notes TEXT, finding_id INTEGER, recommendation_id INTEGER,
  synced_at TEXT DEFAULT (datetime('now')), reviewed_at TEXT, approved_at TEXT,
  updated_at TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS issue_target(
  id INTEGER PRIMARY KEY, issue_number INTEGER NOT NULL, path TEXT NOT NULL,
  ownership TEXT DEFAULT 'owns');
CREATE TABLE IF NOT EXISTS issue_link(
  id INTEGER PRIMARY KEY, issue_number INTEGER NOT NULL, related_number INTEGER NOT NULL,
  kind TEXT NOT NULL, note TEXT, created_at TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS hubfinding(
  id INTEGER PRIMARY KEY, source TEXT, wtype TEXT, category TEXT, title TEXT NOT NULL, detail TEXT,
  severity TEXT, status TEXT DEFAULT 'open', target TEXT, resolution TEXT,
  created_at TEXT DEFAULT (datetime('now')), resolved_at TEXT);
CREATE TABLE IF NOT EXISTS consult(
  id INTEGER PRIMARY KEY, worktree TEXT, wtype TEXT, expert TEXT NOT NULL, area TEXT, issue INTEGER,
  question TEXT NOT NULL, advice TEXT, decision TEXT, followed TEXT, rationale TEXT,
  created_at TEXT DEFAULT (datetime('now')));
CREATE INDEX IF NOT EXISTS ix_activity_at ON activity(at);
CREATE INDEX IF NOT EXISTS ix_finding_status ON finding(status);
CREATE INDEX IF NOT EXISTS ix_worktree_status ON worktree(status);
CREATE INDEX IF NOT EXISTS ix_recommendation_status ON recommendation(status);
CREATE INDEX IF NOT EXISTS ix_finding_link_finding ON finding_link(finding_id);
CREATE INDEX IF NOT EXISTS ix_issue_status ON issue(review_status);
CREATE INDEX IF NOT EXISTS ix_issue_target_num ON issue_target(issue_number);
CREATE INDEX IF NOT EXISTS ix_issue_target_path ON issue_target(path);
CREATE INDEX IF NOT EXISTS ix_hubfinding_status ON hubfinding(status);
CREATE INDEX IF NOT EXISTS ix_consult_expert ON consult(expert);
'@
        # migrate pre-existing DBs: CREATE TABLE IF NOT EXISTS won't add columns to an existing table.
        $verifyCols = [ordered]@{ verdict = 'TEXT'; confidence = 'TEXT'; orig_severity = 'TEXT'; scope = 'TEXT'; fixed_by = 'TEXT'; verify_notes = 'TEXT'; verified_at = 'TEXT'; completed_at = 'TEXT' }
        foreach ($t in 'finding', 'recommendation') {
            $have = @((& sqlite3 $db "SELECT name FROM pragma_table_info('$t');") -split "`r?`n" | ForEach-Object { $_.Trim() })
            foreach ($c in $verifyCols.Keys) { if ($have -notcontains $c) { Exec "ALTER TABLE $t ADD COLUMN $c $($verifyCols[$c]);" } }
        }
        Write-Host "initialized $db" -ForegroundColor Green
    }

    'seed' {
        # 1) inventory: scan modules from the base worktree
        $rows = @()
        foreach ($d in 'components', 'lib') {
            $p = Join-Path $Hub "$($HubConfig.baseWorktree)\$d"
            if (Test-Path $p) { Get-ChildItem -Directory $p | ForEach-Object { $rows += "INSERT OR IGNORE INTO inventory(kind,name,area) VALUES('module','$(q "$d/$($_.Name)")','$(q $_.Name)');" } }
        }
        # surfaces (generic)
        'app', 'database', 'logs', 'security', 'performance', 'a11y', 'deps', 'tests' | ForEach-Object {
            $rows += "INSERT OR IGNORE INTO inventory(kind,name,area,importance) VALUES('surface','$_','$_',4);"
        }
        # 2) generic starter topics (subject|lens|title|priority|cadence_days)
        # Edit $seedTopics for your project, or extend with a repo scan.
        $seedTopics = @(
            'app|security|App: authz, input validation, secrets, multi-tenant isolation|1|14',
            'app|performance|App: data-fetch waterfalls, heavy components, bundle size|2|30',
            'app|a11y|App: accessibility (roles, labels, focus, contrast)|3|30',
            'database|security|Database: access rules / RLS, integrity, exposure|1|14',
            'database|performance|Database: indexes, slow queries, N+1|2|30',
            'deps|security|Dependencies: known-vuln + supply-chain risk|2|30',
            'logs|errors|Runtime + build logs: errors & warnings by frequency|1|7',
            'tests|coverage|Test coverage gaps on critical paths|3|30'
        )
        foreach ($t in $seedTopics) {
            $s, $l, $ti, $pr, $cd = $t -split '\|'
            $rows += "INSERT OR IGNORE INTO topic(subject,lens,title,priority,cadence_days) VALUES('$(q $s)','$(q $l)','$(q $ti)',$pr,$cd);"
        }
        Exec ($rows -join "`n")
        $inv = (& sqlite3 $db "SELECT count(*) FROM inventory"); $tc = (& sqlite3 $db "SELECT count(*) FROM topic")
        Write-Host "seeded: $inv inventory rows, $tc topics (generic starter)." -ForegroundColor Green
    }

    'due' {
        Query "SELECT id, subject, lens, priority AS pri, COALESCE(last_run_at,'never') AS last_run,
                 CAST(julianday('now')-julianday(COALESCE(last_run_at,'2000-01-01')) AS INT) AS age_days
               FROM topic WHERE enabled=1
                 AND (last_run_at IS NULL OR julianday('now')-julianday(last_run_at) >=
                      COALESCE(cadence_days, CASE priority WHEN 1 THEN 7 WHEN 2 THEN 14 WHEN 3 THEN 30 WHEN 4 THEN 60 ELSE 90 END))
               ORDER BY (last_run_at IS NOT NULL), priority, age_days DESC LIMIT $N;"
    }

    'run' {
        $sel = "SELECT id||'|'||subject||'|'||lens FROM topic WHERE enabled=1
                  AND (last_run_at IS NULL OR julianday('now')-julianday(last_run_at) >=
                       COALESCE(cadence_days, CASE priority WHEN 1 THEN 7 WHEN 2 THEN 14 WHEN 3 THEN 30 WHEN 4 THEN 60 ELSE 90 END))
                ORDER BY (last_run_at IS NOT NULL), priority,
                  julianday('now')-julianday(COALESCE(last_run_at,'2000-01-01')) DESC LIMIT $N;"
        $due = @(& sqlite3 $db $sel)
        if (-not $due) { Write-Host 'Nothing due.' -ForegroundColor Yellow; break }
        foreach ($line in $due) {
            $tid, $subj, $lens = $line -split '\|'
            $surface = if ($subj -match '/') { "module:$subj" } else { $subj }
            Write-Host ("due -> {0} / {1}   (surface: {2})" -f $subj, $lens, $surface) -ForegroundColor Cyan
            if ($DryRun) { continue }
            & "$Hub\new-recon.ps1" -Surface $surface -Lens $lens
            Exec "UPDATE topic SET last_run_at=datetime('now'), last_status='running' WHERE id=$tid;"
            Exec "INSERT INTO run(topic_id,worktree,status) VALUES($tid,'recon','running');"
            Exec "INSERT INTO activity(worktree,wtype,event,detail) VALUES('scheduler','recon','launched','$(q "$subj/$lens")');"
        }
        Write-Host ("$($due.Count) topic(s) due." + $(if ($DryRun) { ' (DRY RUN - nothing launched)' } else { ' Recon launched.' })) -ForegroundColor Green
    }

    'report' {
        Write-Host "=== Coverage ===" -ForegroundColor Cyan
        Query "SELECT count(*) AS topics, sum(last_run_at IS NULL) AS never_run,
                 sum(last_run_at >= datetime('now','-30 day')) AS reviewed_30d FROM topic;"
        Write-Host "`n=== Due now (top 5) ===" -ForegroundColor Cyan
        & $PSCommandPath due -N 5
        Write-Host "`n=== Findings by status ===" -ForegroundColor Cyan
        Query "SELECT status, count(*) AS n FROM finding GROUP BY status;"
        Write-Host "`n=== Oldest unreviewed (top 5) ===" -ForegroundColor Cyan
        Query "SELECT subject, lens, priority FROM topic WHERE last_run_at IS NULL ORDER BY priority LIMIT 5;"
    }

    'status' {
        Write-Host "=== Recent worktree activity ===" -ForegroundColor Cyan
        Query "SELECT at, worktree, wtype, event, substr(detail,1,50) AS detail FROM activity ORDER BY at DESC LIMIT $N;"
    }

    'activity' { Exec "INSERT INTO activity(worktree,wtype,event,detail) VALUES('$(q $Worktree)','$(q $WType)','$(q $Event)','$(q $Detail)');"; Write-Host "logged." }

    'finding' { Exec "INSERT INTO finding(worktree,topic,title,severity,category,evidence,suggestion) VALUES('$(q $Worktree)','$(q $Topic)','$(q $Title)','$(q $Severity)','$(q $Category)','$(q $Detail)','$(q $Suggestion)');"; Write-Host "finding recorded." }

    'complete' {
        Exec "UPDATE topic SET last_run_at=datetime('now'), last_status='$(q $Status)', last_issues=(SELECT count(*) FROM finding WHERE topic='$(q $Topic)') WHERE (subject||'/'||lens)='$(q $Topic)';"
        Exec "INSERT INTO activity(worktree,wtype,event,detail) VALUES('$(q $Worktree)','recon','completed','$(q $Topic)');"
        Write-Host "topic '$Topic' marked complete." -ForegroundColor Green
    }

    'findings' {
        $fwhere = if ($Unverified) { "status='proposed' AND verdict IS NULL" } else { "status='$(q $Status)'" }
        Query "SELECT id, severity AS sev, COALESCE(verdict,'-') AS verdict, status, COALESCE(github_issue,'') AS gh, substr(title,1,50) AS title FROM finding WHERE $fwhere ORDER BY CASE severity WHEN 'Critical' THEN 0 WHEN 'High' THEN 1 WHEN 'Medium' THEN 2 ELSE 3 END LIMIT $N;"
    }

    'promote' {
        if (-not $Id) { throw "promote requires -Id <finding id>" }
        # -json avoids separator collisions when evidence/suggestion contain '|'.
        $json = & sqlite3 -json $db "SELECT title, severity, category, evidence, suggestion, scope, verdict, confidence, verified_at FROM finding WHERE id=$Id AND status='proposed';"
        if (-not $json) { throw "no proposed finding with id $Id" }
        $f = $json | ConvertFrom-Json
        if ($f -is [array]) { $f = $f[0] }
        # gh issue create fails on unknown labels, so ensure each exists first (no-op if present).
        $labels = @('needs-triage', 'recon')
        if (-not [string]::IsNullOrWhiteSpace($f.category)) { $labels += ($f.category).Trim() }
        foreach ($l in $labels) { gh label create $l --repo $Repo --color BFD4F2 2>$null | Out-Null }
        $scopeLine = if ($f.scope) { "`n`n**Scope:** $($f.scope)" } else { '' }
        $verLine = if ($f.verdict) { "`n`n_Verified $($f.verified_at): $($f.verdict)$(if ($f.confidence) { " ($($f.confidence) confidence)" })._" } else { '' }
        $body = "**Severity:** $($f.severity)$scopeLine`n`n$($f.evidence)`n`n**Suggested fix:** $($f.suggestion)$verLine`n`n_(from recon finding #$Id)_"
        $url = gh issue create --repo $Repo --title $f.title --body $body --label ($labels -join ',') 2>&1
        $num = ([regex]::Match($url, '/issues/(\d+)')).Groups[1].Value
        if (-not $num) { throw "issue create failed for finding #$Id`: $url" }
        Exec "UPDATE finding SET status='filed', github_issue=$([int]($num)) WHERE id=$Id;"
        Write-Host "filed finding #$Id -> $url" -ForegroundColor Green
    }

    'verify' {
        if (-not $Id) { throw "verify requires -Id <finding id>" }
        if (-not $Verdict) { throw "verify requires -Verdict <still-valid|already-fixed|partially-fixed|out-of-scope|needs-info>" }
        $vw = if ($Worktree) { $Worktree } else { 'orchestrator' }
        $sets = @("verdict='$(q $Verdict)'", "verified_at=datetime('now')")
        if ($Confidence) { $sets += "confidence='$(q $Confidence)'" }
        if ($Scope) { $sets += "scope='$(q $Scope)'" }
        if ($FixedBy) { $sets += "fixed_by='$(q $FixedBy)'" }
        if ($Note) { $sets += "verify_notes='$(q $Note)'" }
        if ($PSBoundParameters.ContainsKey('Severity')) { $sets += "orig_severity=COALESCE(orig_severity,severity)"; $sets += "severity='$(q $Severity)'" }
        $dismissV = @('already-fixed', 'out-of-scope')
        if ($Dismiss -or $dismissV -contains $Verdict) { $sets += "status='dismissed'" }
        Exec "UPDATE finding SET $($sets -join ', ') WHERE id=$Id;"
        foreach ($r in @($Related -split '[\s,]+' | Where-Object { $_ -match '^\d+$' })) { Exec "INSERT INTO finding_link(finding_id,related_id,kind) VALUES($Id,$r,'related');" }
        foreach ($d in @($DependsOn -split '[\s,]+' | Where-Object { $_ -match '^\d+$' })) { Exec "INSERT INTO finding_link(finding_id,related_id,kind) VALUES($Id,$d,'depends-on');" }
        Exec "INSERT INTO activity(worktree,wtype,event,detail) VALUES('$(q $vw)','recon','verify','#$Id -> $(q $Verdict)');"
        $dis = if ($Dismiss -or $dismissV -contains $Verdict) { ' (dismissed)' } else { '' }
        Write-Host "verified finding #$Id -> $Verdict$dis." -ForegroundColor Green
    }

    # verify a RECOMMENDATION (solver out-of-scope follow-up) — same verdict vocabulary + auto-dismiss as
    # 'verify', but against the recommendation table (which carries the same verify columns). Lets the
    # orchestrator's verify-before-stale sweep stamp a rec without raw SQL. No link edges: there is no
    # recommendation_link table (finding_link is findings-only).
    'verify-rec' {
        if (-not $Id) { throw "verify-rec requires -Id <recommendation id>" }
        if (-not $Verdict) { throw "verify-rec requires -Verdict <still-valid|already-fixed|partially-fixed|out-of-scope|needs-info>" }
        $vw = if ($Worktree) { $Worktree } else { 'orchestrator' }
        $sets = @("verdict='$(q $Verdict)'", "verified_at=datetime('now')")
        if ($Confidence) { $sets += "confidence='$(q $Confidence)'" }
        if ($Scope) { $sets += "scope='$(q $Scope)'" }
        if ($FixedBy) { $sets += "fixed_by='$(q $FixedBy)'" }
        if ($Note) { $sets += "verify_notes='$(q $Note)'" }
        if ($PSBoundParameters.ContainsKey('Severity')) { $sets += "orig_severity=COALESCE(orig_severity,severity)"; $sets += "severity='$(q $Severity)'" }
        $dismissV = @('already-fixed', 'out-of-scope')
        if ($Dismiss -or $dismissV -contains $Verdict) { $sets += "status='dismissed'" }
        Exec "UPDATE recommendation SET $($sets -join ', ') WHERE id=$Id;"
        Exec "INSERT INTO activity(worktree,wtype,event,detail) VALUES('$(q $vw)','recon','verify-rec','#$Id -> $(q $Verdict)');"
        $dis = if ($Dismiss -or $dismissV -contains $Verdict) { ' (dismissed)' } else { '' }
        Write-Host "verified recommendation #$Id -> $Verdict$dis." -ForegroundColor Green
    }

    'resolve' {
        if (-not $Id) { throw "resolve requires -Id <finding id>" }
        $sets = @("completed_at=datetime('now')", "status='completed'")
        if ($Issue -gt 0) { $sets += "github_issue=$Issue" }
        Exec "UPDATE finding SET $($sets -join ', ') WHERE id=$Id;"
        Exec "INSERT INTO activity(worktree,wtype,event,detail) VALUES('orchestrator','recon','resolve','#$Id completed');"
        Write-Host "finding #$Id marked completed." -ForegroundColor Green
    }

    # ---- worktree status tracking (solver/recon/child worktrees report here; orchestrator monitors) ----

    'register' {
        if (-not $Worktree) { throw "register requires -Worktree" }
        $wt = q $Worktree; $wt2 = q $WType
        Exec "INSERT INTO worktree(name,wtype,issue,branch,status,note,updated_at) VALUES('$wt','$wt2',$(NullableInt $Issue),'$(q $Branch)','registered','$(q $Note)',datetime('now')) ON CONFLICT(name) DO UPDATE SET wtype=excluded.wtype, issue=excluded.issue, branch=excluded.branch, updated_at=datetime('now');"
        Exec "INSERT INTO activity(worktree,wtype,event,detail) VALUES('$wt','$wt2','registered','$(q $Branch)');"
        Write-Host "registered worktree '$Worktree' (issue $Issue)." -ForegroundColor Green
    }

    'progress' {
        if (-not $Worktree -or -not $Status) { throw "progress requires -Worktree and -Status (e.g. working|spec-gate|pr-open|merged|retired|blocked|failed)" }
        $wt = q $Worktree
        $cols = @('name', 'status', 'updated_at'); $vals = @("'$wt'", "'$(q $Status)'", "datetime('now')"); $cset = @('status=excluded.status', "updated_at=datetime('now')")
        if ($Pr -gt 0) { $cols += 'pr'; $vals += "$Pr"; $cset += 'pr=excluded.pr' }
        if ($Note) { $cols += 'note'; $vals += "'$(q $Note)'"; $cset += 'note=excluded.note' }
        Exec "INSERT INTO worktree($($cols -join ',')) VALUES($($vals -join ',')) ON CONFLICT(name) DO UPDATE SET $($cset -join ', ');"
        Exec "INSERT INTO activity(worktree,wtype,event,detail) VALUES('$wt',COALESCE((SELECT wtype FROM worktree WHERE name='$wt'),'solver'),'$(q $Status)','$(q $Note)');"
        Write-Host "worktree '$Worktree' -> $Status$(if ($Pr -gt 0) { " (PR #$Pr)" })." -ForegroundColor Green
    }

    'recommend' {
        if (-not $Worktree -or -not $Title) { throw "recommend requires -Worktree and -Title (the proposed issue title); use -Issue <source>, -Area, -Severity, -Detail" }
        $wt = q $Worktree
        Exec "INSERT INTO recommendation(worktree,source_issue,title,area,severity,detail) VALUES('$wt',$(NullableInt $Issue),'$(q $Title)','$(q $Area)','$(q $Severity)','$(q $Detail)');"
        Exec "INSERT INTO activity(worktree,wtype,event,detail) VALUES('$wt','solver','recommend','$(q $Title)');"
        Write-Host "recommendation recorded: $Title" -ForegroundColor Green
    }

    'monitor' {
        Write-Host "=== Worktrees (live status) ===" -ForegroundColor Cyan
        Query @"
SELECT name, wtype AS type, COALESCE(issue,'') AS issue, COALESCE(pr,'') AS pr, status,
  CAST((julianday('now')-julianday(updated_at))*1440 AS INT) AS upd_min,
  (SELECT count(*) FROM issue_target t WHERE t.issue_number=worktree.issue AND t.ownership='owns') AS owns,
  (SELECT count(*) FROM recommendation r WHERE r.worktree=worktree.name AND r.status='proposed') AS recs
FROM worktree
ORDER BY CASE status WHEN 'blocked' THEN 0 WHEN 'failed' THEN 1 WHEN 'spec-gate' THEN 2 WHEN 'working' THEN 3
  WHEN 'pr-open' THEN 4 WHEN 'merged' THEN 5 ELSE 6 END, updated_at DESC;
"@
        Write-Host "`n=== Proposed recommendations (out-of-scope follow-ups) ===" -ForegroundColor Cyan
        Query "SELECT id, COALESCE(source_issue,'') AS src, severity AS sev, substr(title,1,55) AS title, worktree FROM recommendation WHERE status='proposed' ORDER BY id LIMIT $N;"
        Write-Host "`n=== Open hub findings (prompt / env / config problems) ===" -ForegroundColor Cyan
        Query "SELECT id, source, category AS cat, severity AS sev, substr(title,1,55) AS title FROM hubfinding WHERE status='open' ORDER BY CASE severity WHEN 'High' THEN 0 WHEN 'Medium' THEN 1 ELSE 2 END, id LIMIT $N;"
    }

    'recommendations' { Query "SELECT id, COALESCE(source_issue,'') AS src, severity AS sev, status, COALESCE(github_issue,'') AS gh, substr(title,1,55) AS title, worktree FROM recommendation WHERE status='$(q $Status)' ORDER BY id LIMIT $N;" }

    'file-rec' {
        if (-not $Id) { throw "file-rec requires -Id <recommendation id>" }
        $json = & sqlite3 -json $db "SELECT title, detail, area, severity, source_issue, worktree FROM recommendation WHERE id=$Id AND status='proposed';"
        if (-not $json) { throw "no proposed recommendation with id $Id" }
        $r = $json | ConvertFrom-Json; if ($r -is [array]) { $r = $r[0] }
        foreach ($l in @('needs-triage')) { gh label create $l --repo $Repo --color BFD4F2 2>$null | Out-Null }
        $src = if ($r.source_issue) { " (out-of-scope follow-up found while working #$($r.source_issue))" } else { '' }
        $body = "$($r.detail)`n`n**Area:** $($r.area)  ·  **Severity:** $($r.severity)`n`n_Recorded$src by worktree ``$($r.worktree)`` (recommendation #$Id)._"
        $url = gh issue create --repo $Repo --title $r.title --body $body --label 'needs-triage' 2>&1
        $num = ([regex]::Match($url, '/issues/(\d+)')).Groups[1].Value
        if (-not $num) { throw "issue create failed for recommendation #$Id`: $url" }
        Exec "UPDATE recommendation SET status='filed', github_issue=$([int]$num) WHERE id=$Id;"
        Write-Host "filed recommendation #$Id -> $url" -ForegroundColor Green
    }

    'dismiss-rec' { if (-not $Id) { throw "dismiss-rec requires -Id" }; Exec "UPDATE recommendation SET status='dismissed' WHERE id=$Id;"; Write-Host "recommendation #$Id dismissed." -ForegroundColor Yellow }

    # ---- hub findings: problems with the hub's OWN operating layer (prompts/config/scripts/memory/env) ----
    'hubfind' {
        if (-not $Worktree -or -not $Title) { throw "hubfind requires -Worktree (folder or 'orchestrator') and -Title; use -Category <env|tool|prompt|config|memory|other>, -Detail, -Severity" }
        $wt = q $Worktree
        $defWty = if ($Worktree -eq 'orchestrator') { 'orchestrator' } else { 'solver' }
        Exec "INSERT INTO hubfinding(source,wtype,category,title,detail,severity) VALUES('$wt',COALESCE((SELECT wtype FROM worktree WHERE name='$wt'),'$defWty'),'$(q $Category)','$(q $Title)','$(q $Detail)','$(q $Severity)');"
        Exec "INSERT INTO activity(worktree,wtype,event,detail) VALUES('$wt','hub','hubfind','$(q $Title)');"
        Write-Host "hub finding recorded: $Title" -ForegroundColor Green
    }

    'hub-findings' {
        $where = if ($All) { '1=1' } else { "status='open'" }
        Query "SELECT id, source, category AS cat, severity AS sev, status, COALESCE(target,'') AS target, substr(title,1,55) AS title FROM hubfinding WHERE $where ORDER BY CASE severity WHEN 'High' THEN 0 WHEN 'Medium' THEN 1 ELSE 2 END, id LIMIT $N;"
    }

    'hub-resolve' {
        if (-not $Id) { throw "hub-resolve requires -Id <hub finding id>" }
        if ($Dismiss) {
            Exec "UPDATE hubfinding SET status='dismissed', resolution='$(q $Note)', resolved_at=datetime('now') WHERE id=$Id;"
            Write-Host "hub finding #$Id dismissed." -ForegroundColor Yellow
        }
        else {
            if (-not $Target) { throw "hub-resolve requires -Target <prompt|config|script|memory> (or use -Dismiss)" }
            Exec "UPDATE hubfinding SET status='resolved', target='$(q $Target)', resolution='$(q $Note)', resolved_at=datetime('now') WHERE id=$Id;"
            Exec "INSERT INTO activity(worktree,wtype,event,detail) VALUES('orchestrator','hub','hub-resolve','#$Id -> $(q $Target)');"
            Write-Host "hub finding #$Id resolved (fixed in $Target)." -ForegroundColor Green
        }
    }

    # ---- expert consultation: a worktree records the advice it got from a hub-* expert + the decision it made ----
    'consult' {
        if (-not $Worktree -or -not $Expert -or -not $Question) { throw "consult requires -Worktree, -Expert (hub-<x>), and -Question; use -Area, -Advice, -Decision, -Followed <yes|partial|overridden>, -Rationale, -Issue" }
        $wt = q $Worktree
        Exec "INSERT INTO consult(worktree,wtype,expert,area,issue,question,advice,decision,followed,rationale) VALUES('$wt',COALESCE((SELECT wtype FROM worktree WHERE name='$wt'),'solver'),'$(q $Expert)','$(q $Area)',$(NullableInt $Issue),'$(q $Question)','$(q $Advice)','$(q $Decision)','$(q $Followed)','$(q $Rationale)');"
        Exec "INSERT INTO activity(worktree,wtype,event,detail) VALUES('$wt',COALESCE((SELECT wtype FROM worktree WHERE name='$wt'),'solver'),'consult','$(q $Expert): $(q $Question)');"
        Write-Host "consult recorded: $Expert ($(if ($Followed) { $Followed } else { 'noted' }))" -ForegroundColor Green
    }

    # ---- issue lane: GH issue -> ledger -> review (orchestrator subagent fan-out) -> approve -> overlap-aware deploy ----

    'issue' {
        $lim = if ($PSBoundParameters.ContainsKey('N')) { $N } else { 200 }
        switch ($Sub) {

            'sync' {
                $fetchLimit = 1000
                $raw = & gh issue list --repo $Repo --state open --limit $fetchLimit --json number,title,labels,author 2>$null
                if (-not $raw) { Write-Host "no data from gh issue list (auth / repo?)." -ForegroundColor Yellow; break }
                $json = @($raw | ConvertFrom-Json)
                # If the fetch hit the cap the open-issue list may be TRUNCATED; in that case the
                # "mark closed" sweep below must be skipped (fail safe) or it would wrongly flip the
                # still-open overflow (issues beyond the cap) to 'closed' and drop them from the pipeline.
                $truncated = ($json.Count -ge $fetchLimit)
                $open = @(); $new = 0; $upd = 0
                foreach ($i in $json) {
                    $num = [int]$i.number; $open += $num
                    $title = q $i.title
                    $labels = q (@($i.labels | ForEach-Object { $_.name }) -join ',')
                    $author = if ($i.author) { q $i.author.login } else { '' }
                    $isRecon = (@($i.labels | Where-Object { $_.name -eq 'recon' }).Count -gt 0)
                    $fid = (Scalar "SELECT id FROM finding WHERE github_issue=$num LIMIT 1;")
                    $rid = (Scalar "SELECT id FROM recommendation WHERE github_issue=$num LIMIT 1;")
                    $origin = if ($isRecon -or $fid) { 'recon' } elseif ($rid) { 'recommendation' } else { 'user' }
                    $sevHint = (Scalar "SELECT COALESCE((SELECT severity FROM finding WHERE github_issue=$num LIMIT 1),(SELECT severity FROM recommendation WHERE github_issue=$num LIMIT 1));")
                    $sevVal = if ($sevHint) { "'$(q $sevHint)'" } else { 'NULL' }
                    $fidVal = if ($fid) { "$fid" } else { 'NULL' }
                    $ridVal = if ($rid) { "$rid" } else { 'NULL' }
                    if (Scalar "SELECT 1 FROM issue WHERE number=$num;") { $upd++ } else { $new++ }
                    Exec @"
INSERT INTO issue(number,title,labels,author,origin,severity,finding_id,recommendation_id,synced_at,updated_at)
VALUES($num,'$title','$labels','$author','$origin',$sevVal,$fidVal,$ridVal,datetime('now'),datetime('now'))
ON CONFLICT(number) DO UPDATE SET
  title=excluded.title, labels=excluded.labels, author=excluded.author, origin=excluded.origin,
  finding_id=COALESCE(issue.finding_id,excluded.finding_id),
  recommendation_id=COALESCE(issue.recommendation_id,excluded.recommendation_id),
  severity=COALESCE(issue.severity,excluded.severity),
  review_status=CASE WHEN issue.review_status='closed' THEN 'synced' ELSE issue.review_status END,
  updated_at=datetime('now');
"@
                }
                $openList = ($open -join ',')
                if ($truncated) {
                    Write-Host "WARNING: open-issue list may be truncated at $fetchLimit; SKIPPING the 'mark closed' sweep to avoid corrupting the ledger." -ForegroundColor Yellow
                }
                elseif ($openList) {
                    Exec "UPDATE issue SET review_status='closed', updated_at=datetime('now') WHERE number NOT IN ($openList) AND review_status!='closed';"
                }
                Exec "INSERT INTO activity(worktree,wtype,event,detail) VALUES('orchestrator','issue','sync','$($open.Count) open: $new new, $upd updated');"
                Write-Host "synced $($open.Count) open issues ($new new, $upd updated)." -ForegroundColor Green
            }

            'unreviewed' {
                Query "SELECT number AS num, origin, COALESCE(severity,'-') AS sev, COALESCE(labels,'') AS labels, substr(title,1,46) AS title
                       FROM issue WHERE review_status='synced' ORDER BY (origin='user') DESC, number LIMIT $lim;"
            }

            'record-review' {
                if (-not $Id) { throw "issue record-review requires -Id <issue number>" }
                Exec "DELETE FROM issue_target WHERE issue_number=$Id;"
                foreach ($p in @($Targets -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
                    Exec "INSERT INTO issue_target(issue_number,path,ownership) VALUES($Id,'$(q $p)','owns');"
                }
                foreach ($p in @($Reads -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
                    Exec "INSERT INTO issue_target(issue_number,path,ownership) VALUES($Id,'$(q $p)','reads');"
                }
                $sets = @("review_status='reviewed'", "reviewed_at=datetime('now')", "updated_at=datetime('now')")
                if ($Verdict) { $sets += "verdict='$(q $Verdict)'" }
                if ($Effort) { $sets += "effort='$(q $Effort)'" }
                if ($Track) { $sets += "track='$(q $Track)'" }
                if ($Confidence) { $sets += "confidence='$(q $Confidence)'" }
                if ($Note) { $sets += "review_notes='$(q $Note)'" }
                if ($PSBoundParameters.ContainsKey('Severity')) { $sets += "orig_severity=COALESCE(orig_severity,severity)"; $sets += "severity='$(q $Severity)'" }
                Exec "UPDATE issue SET $($sets -join ', ') WHERE number=$Id;"
                foreach ($r in @($Related -split '[\s,;]+' | Where-Object { $_ -match '^\d+$' })) { Exec "INSERT INTO issue_link(issue_number,related_number,kind) VALUES($Id,$r,'related');" }
                foreach ($d in @($DependsOn -split '[\s,;]+' | Where-Object { $_ -match '^\d+$' })) { Exec "INSERT INTO issue_link(issue_number,related_number,kind) VALUES($Id,$d,'depends-on');" }
                $vw = if ($Worktree) { q $Worktree } else { 'orchestrator' }
                Exec "INSERT INTO activity(worktree,wtype,event,detail) VALUES('$vw','issue','review','#$Id reviewed');"
                Write-Host "issue #$Id reviewed (targets recorded)." -ForegroundColor Green
            }

            'list' {
                $w = if ($PSBoundParameters.ContainsKey('Status')) { "review_status='$(q $Status)'" } else { "review_status!='closed'" }
                Query @"
SELECT number AS num, origin, COALESCE(severity,'-') AS sev, COALESCE(track,'-') AS track, review_status AS status,
  (SELECT count(*) FROM issue_target t WHERE t.issue_number=issue.number AND t.ownership='owns') AS owns,
  (SELECT count(DISTINCT t2.issue_number) FROM issue_target t1 JOIN issue_target t2 ON t1.path=t2.path
     WHERE t1.issue_number=issue.number AND t1.ownership='owns' AND t2.ownership='owns' AND t2.issue_number!=issue.number) AS ov,
  substr(title,1,42) AS title
FROM issue WHERE $w
ORDER BY (origin='user') DESC,
  CASE severity WHEN 'Critical' THEN 0 WHEN 'High' THEN 1 WHEN 'Medium' THEN 2 WHEN 'Low' THEN 3 ELSE 4 END, number
LIMIT $lim;
"@
            }

            'show' {
                if (-not $Id) { throw "issue show requires -Id <issue number>" }
                Query "SELECT number AS num, origin, review_status AS status, COALESCE(severity,'-') AS sev, COALESCE(orig_severity,'') AS orig, COALESCE(track,'-') AS track, COALESCE(effort,'-') AS effort, COALESCE(verdict,'-') AS verdict, COALESCE(confidence,'') AS conf FROM issue WHERE number=$Id;"
                Write-Host "`n-- title --" -ForegroundColor DarkGray; Query "SELECT title FROM issue WHERE number=$Id;"
                Write-Host "`n-- targets --" -ForegroundColor DarkGray; Query "SELECT ownership, path FROM issue_target WHERE issue_number=$Id ORDER BY ownership DESC, path;"
                Write-Host "`n-- links --" -ForegroundColor DarkGray; Query "SELECT kind, related_number AS issue FROM issue_link WHERE issue_number=$Id;"
                Write-Host "`n-- overlaps (share an owned path) --" -ForegroundColor DarkGray
                Query "SELECT DISTINCT t2.issue_number AS issue, t1.path FROM issue_target t1 JOIN issue_target t2 ON t1.path=t2.path WHERE t1.issue_number=$Id AND t1.ownership='owns' AND t2.ownership='owns' AND t2.issue_number!=$Id ORDER BY issue;"
                Write-Host "`n-- review notes --" -ForegroundColor DarkGray; Query "SELECT COALESCE(review_notes,'(none)') AS notes FROM issue WHERE number=$Id;"
            }

            'approve' {
                if (-not $Id) { throw "issue approve requires -Id <issue number>" }
                $cur = (& sqlite3 $db "SELECT review_status FROM issue WHERE number=$Id;")
                if (-not $cur) { throw "issue #$Id is not in the ledger - run 'issue sync' first." }
                if ($cur -eq 'synced') { Write-Host "WARNING: issue #$Id has not been reviewed yet (no targets recorded)." -ForegroundColor Yellow }
                Exec "UPDATE issue SET review_status='approved', approved_at=datetime('now'), updated_at=datetime('now') WHERE number=$Id;"
                Exec "INSERT INTO activity(worktree,wtype,event,detail) VALUES('orchestrator','issue','approve','#$Id');"
                Write-Host "issue #$Id approved (clear to provision a worktree)." -ForegroundColor Green
            }

            'dismiss' {
                if (-not $Id) { throw "issue dismiss requires -Id <issue number>" }
                Exec "UPDATE issue SET review_status='dismissed', updated_at=datetime('now') WHERE number=$Id;"
                Exec "INSERT INTO activity(worktree,wtype,event,detail) VALUES('orchestrator','issue','dismiss','#$Id');"
                Write-Host "issue #$Id dismissed." -ForegroundColor Yellow
            }

            'next' {
                $activeStatuses = "'registered','working','spec-gate','pr-open','blocked'"
                $activePaths = @(& sqlite3 $db "SELECT DISTINCT t.path FROM issue_target t JOIN worktree w ON w.issue=t.issue_number WHERE t.ownership='owns' AND w.status IN ($activeStatuses);")
                $claimed = [System.Collections.Generic.HashSet[string]]::new()
                foreach ($p in $activePaths) { if ($p) { [void]$claimed.Add($p) } }
                # candidates: approved issues NOT already in flight (no active worktree)
                $cands = @(& sqlite3 $db "SELECT number FROM issue WHERE review_status='approved' AND number NOT IN (SELECT issue FROM worktree WHERE issue IS NOT NULL AND status IN ($activeStatuses)) ORDER BY (origin='user') DESC, CASE severity WHEN 'Critical' THEN 0 WHEN 'High' THEN 1 WHEN 'Medium' THEN 2 WHEN 'Low' THEN 3 ELSE 4 END, number;")
                $picked = @(); $deferred = @()
                foreach ($numStr in $cands) {
                    if (-not $numStr) { continue }
                    if ($picked.Count -ge $N) { break }
                    $num = [int]$numStr
                    $paths = @(& sqlite3 $db "SELECT path FROM issue_target WHERE issue_number=$num AND ownership='owns';" | Where-Object { $_ })
                    $hit = $null
                    foreach ($p in $paths) { if ($claimed.Contains($p)) { $hit = $p; break } }
                    if ($hit) { $deferred += [pscustomobject]@{ Issue = $num; Collision = $hit }; continue }
                    foreach ($p in $paths) { [void]$claimed.Add($p) }
                    $picked += $num
                }
                Write-Host "=== Next wave (approved, non-overlapping, <= $N) ===" -ForegroundColor Cyan
                if (-not $picked.Count) { Write-Host "  (no approved+non-overlapping issues - run 'issue list -Status reviewed' then 'issue approve -Id N')" -ForegroundColor Yellow }
                foreach ($num in $picked) {
                    $meta = (& sqlite3 $db "SELECT origin, COALESCE(severity,'-'), COALESCE(track,'simple'), substr(title,1,42) FROM issue WHERE number=$num;")
                    $o, $s, $tk, $ti = $meta -split '\|', 4
                    $owns = (& sqlite3 $db "SELECT count(*) FROM issue_target WHERE issue_number=$num AND ownership='owns';")
                    Write-Host ("  #{0,-5} [{1,-13}] {2,-8} {3,-7} owns:{4}  {5}" -f $num, $o, $s, $tk, $owns, $ti) -ForegroundColor Green
                }
                if ($deferred.Count) {
                    Write-Host "`n=== Deferred (file overlap with a pick or active worktree) ===" -ForegroundColor Cyan
                    foreach ($d in $deferred) { Write-Host ("  #{0} -> collides on {1}" -f $d.Issue, $d.Collision) -ForegroundColor DarkYellow }
                }
            }

            default { Write-Host "issue sub-commands: sync | unreviewed | record-review -Id N -Targets 'a;b' [-Reads 'c' -Severity .. -Effort .. -Track simple|complex -Verdict .. -Note .. -Related '1,2' -DependsOn '3'] | list [-Status s] | show -Id N | approve -Id N | dismiss -Id N | next [-N k]" }
        }
    }

    default {
        Write-Host "review-coverage.ps1 commands:"
        Write-Host "  coverage : init | seed | due [-N k] | run [-N k] | report | status [-N k]"
        Write-Host "  recon    : activity | finding | complete | findings [-Status s | -Unverified] | verify -Id n -Verdict v [..] | resolve -Id n | promote -Id n"
        Write-Host "  worktree : register -Worktree w -WType solver -Issue N -Branch b"
        Write-Host "             progress -Worktree w -Status <working|spec-gate|pr-open|merged|retired|blocked|failed> [-Pr M] [-Note ..]"
        Write-Host "             recommend -Worktree w -Issue N -Title '..' [-Area a -Severity s -Detail d]"
        Write-Host "             monitor | recommendations [-Status proposed] | file-rec -Id n | dismiss-rec -Id n"
        Write-Host "  issue    : issue sync | issue unreviewed | issue list [-Status s] | issue show -Id N"
        Write-Host "             issue record-review -Id N -Targets 'a;b' [-Reads 'c' -Severity .. -Effort .. -Track simple|complex -Verdict .. -Note .. -Related '1,2' -DependsOn '3']"
        Write-Host "             issue approve -Id N | issue dismiss -Id N | issue next [-N k]    (review fan-out is orchestrator-driven; gate enforced in new-worktree.ps1)"
    }
}
