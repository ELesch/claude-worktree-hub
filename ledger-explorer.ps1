<#
.SYNOPSIS
  Render the ENTIRE review-coverage ledger (.review\coverage.db) into a single self-contained,
  interactive HTML explorer and open it in Chrome. No web server — one static file, offline.

.DESCRIPTION
  The deep counterpart to ledger-to-html.ps1 (which is the lightweight open-items glance).
  This pulls EVERY row from all ledger tables and embeds them into one offline HTML page
  (all CSS/JS inlined, no CDN, works from file://). The page is a small single-page app:

    * Sidebar nav across every entity (Overview, Issues, Findings, Recommendations,
      Hub findings, Consults, Worktrees, Coverage/topics, Runs, Inventory, Activity) with live counts.
    * Overview landing page: summary tiles, CSS-bar charts, and "needs attention" lists.
    * Per-entity views: faceted filter rail (auto-built categorical filters with counts) +
      global text filter + fully sortable table.
    * A detail drawer: click any row to see EVERY field plus a "Connections" block of
      clickable chips (owned/read paths, related/duplicate/depends links, source finding/rec,
      the worktree working it, its grouped-wave issues, its consults, activity feed, …). Clicking a chip opens that
      entity's drawer with a back-stack — turning the whole ledger into a navigable graph.
    * "Show closed/retired/completed" toggle, global search, URL-hash routing (bookmarkable),
      copy buttons on ids & file paths, and keyboard shortcuts ('/' search, Esc close).

  Read-only: the page never writes to the DB. Regenerate it to refresh.

.PARAMETER Database
  Path to the SQLite ledger. Default: <hub>\.review\coverage.db

.PARAMETER Out
  Output HTML path. Default: <hub>\.review\ledger-explorer.html

.PARAMETER Repo
  GitHub repo slug (owner/repo) used for issue/PR links. Default: from hub.config.json.

.PARAMETER NoOpen
  Generate the file but do not launch a browser.

.EXAMPLE
  .\ledger-explorer.ps1
  .\ledger-explorer.ps1 -Out C:\temp\explorer.html -NoOpen
#>
[CmdletBinding()]
param(
    [string]$Database,
    [string]$Out,
    [string]$Repo,   # defaults to $HubConfig.repo (hub.config.json)
    [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'
try { . (Join-Path $PSScriptRoot 'hub-config.ps1') }   # sets $Hub + $HubConfig
catch { $Hub = $PSScriptRoot; $HubConfig = $null }

if (-not $Repo) { $Repo = if ($HubConfig) { $HubConfig.repo } else { 'owner/repo' } }
$Db = if ($Database) { $Database } else { Join-Path $Hub '.review\coverage.db' }
if (-not $Out) { $Out = Join-Path $Hub '.review\ledger-explorer.html' }

if (-not (Test-Path $Db)) { throw "ledger DB not found: $Db  (run review-coverage.ps1 init/seed first)" }
if (-not (Get-Command sqlite3 -ErrorAction SilentlyContinue)) {
    throw "sqlite3 not found on PATH (expected the chocolatey shim). Install: choco install sqlite"
}

# --- pull each table as a raw JSON array (compact-but-valid) ---------------------------
function Get-Json([string]$query) {
    $rows = & sqlite3 -json $Db $query
    if ($LASTEXITCODE -ne 0) { throw "sqlite3 query failed (exit $LASTEXITCODE)" }
    $text = (@($rows) -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return '[]' }
    return $text
}

$qIssues = Get-Json @"
SELECT number AS num, COALESCE(title,'') AS title, COALESCE(labels,'') AS labels,
  COALESCE(author,'') AS author, COALESCE(origin,'') AS origin, review_status AS status,
  COALESCE(verdict,'') AS verdict, COALESCE(severity,'') AS severity,
  COALESCE(orig_severity,'') AS orig_severity, COALESCE(effort,'') AS effort,
  COALESCE(track,'') AS track, COALESCE(confidence,'') AS confidence,
  COALESCE(review_notes,'') AS review_notes,
  COALESCE(finding_id,'') AS finding_id, COALESCE(recommendation_id,'') AS recommendation_id,
  substr(COALESCE(synced_at,''),1,16) AS synced_at,
  substr(COALESCE(reviewed_at,''),1,16) AS reviewed_at,
  substr(COALESCE(approved_at,''),1,16) AS approved_at,
  substr(COALESCE(updated_at,''),1,16) AS updated_at,
  (SELECT count(*) FROM issue_target t WHERE t.issue_number=issue.number AND t.ownership='owns') AS owns,
  (SELECT count(*) FROM issue_target t WHERE t.issue_number=issue.number AND t.ownership!='owns') AS reads
FROM issue ORDER BY number;
"@

$qTargets = Get-Json "SELECT issue_number AS num, path, COALESCE(ownership,'owns') AS ownership FROM issue_target ORDER BY issue_number, path;"
$qIssueLinks = Get-Json "SELECT issue_number AS num, related_number AS rel, kind, COALESCE(note,'') AS note FROM issue_link;"

$qFindings = Get-Json @"
SELECT id, COALESCE(run_id,'') AS run_id, COALESCE(worktree,'') AS worktree, COALESCE(topic,'') AS topic,
  COALESCE(title,'') AS title, COALESCE(severity,'') AS severity, COALESCE(category,'') AS category,
  COALESCE(evidence,'') AS evidence, COALESCE(suggestion,'') AS suggestion, status,
  COALESCE(github_issue,'') AS github_issue, substr(COALESCE(created_at,''),1,16) AS created_at,
  COALESCE(verdict,'') AS verdict, COALESCE(confidence,'') AS confidence,
  COALESCE(orig_severity,'') AS orig_severity, COALESCE(scope,'') AS scope,
  COALESCE(fixed_by,'') AS fixed_by, COALESCE(verify_notes,'') AS verify_notes,
  substr(COALESCE(verified_at,''),1,16) AS verified_at, substr(COALESCE(completed_at,''),1,16) AS completed_at
FROM finding ORDER BY id;
"@

$qFindingLinks = Get-Json "SELECT finding_id AS fid, related_id AS rel, kind, COALESCE(note,'') AS note FROM finding_link;"

$qRecs = Get-Json @"
SELECT id, COALESCE(worktree,'') AS worktree, COALESCE(source_issue,'') AS source_issue,
  COALESCE(title,'') AS title, COALESCE(detail,'') AS detail, COALESCE(area,'') AS area,
  COALESCE(severity,'') AS severity, status, COALESCE(github_issue,'') AS github_issue,
  substr(COALESCE(created_at,''),1,16) AS created_at,
  COALESCE(verdict,'') AS verdict, COALESCE(confidence,'') AS confidence,
  COALESCE(orig_severity,'') AS orig_severity, COALESCE(scope,'') AS scope,
  COALESCE(fixed_by,'') AS fixed_by, COALESCE(verify_notes,'') AS verify_notes,
  substr(COALESCE(verified_at,''),1,16) AS verified_at, substr(COALESCE(completed_at,''),1,16) AS completed_at
FROM recommendation ORDER BY id;
"@

$qWorktrees = Get-Json @"
SELECT name, COALESCE(wtype,'') AS wtype, COALESCE(issue,'') AS issue, COALESCE(branch,'') AS branch,
  COALESCE(pr,'') AS pr, status, COALESCE(batch,'') AS batch, COALESCE(note,'') AS note,
  substr(COALESCE(created_at,''),1,16) AS created_at, substr(COALESCE(updated_at,''),1,16) AS updated_at,
  CAST((julianday('now')-julianday(updated_at))*1440 AS INT) AS age_min,
  (SELECT count(*) FROM worktree_issue wi WHERE wi.worktree=worktree.name) AS members,
  (SELECT count(DISTINCT t.path) FROM issue_target t WHERE t.ownership='owns' AND t.issue_number IN (
     SELECT worktree.issue UNION SELECT wi.issue_number FROM worktree_issue wi WHERE wi.worktree=worktree.name)) AS owns,
  (SELECT count(*) FROM recommendation r WHERE r.worktree=worktree.name AND r.status='proposed') AS recs
FROM worktree ORDER BY updated_at DESC;
"@

$qTopics = Get-Json @"
SELECT id, subject, lens, COALESCE(title,'') AS title, priority, COALESCE(cadence_days,'') AS cadence_days,
  enabled, substr(COALESCE(last_run_at,''),1,16) AS last_run_at, COALESCE(last_status,'') AS last_status,
  COALESCE(last_issues,0) AS last_issues,
  CASE WHEN last_run_at IS NULL THEN '' ELSE CAST(julianday('now')-julianday(last_run_at) AS INT) END AS age_days
FROM topic ORDER BY priority, subject, lens;
"@

$qRuns = Get-Json @"
SELECT id, COALESCE(topic_id,'') AS topic_id, COALESCE(worktree,'') AS worktree,
  substr(COALESCE(started_at,''),1,16) AS started_at, substr(COALESCE(finished_at,''),1,16) AS finished_at,
  status, COALESCE(candidates,0) AS candidates, COALESCE(filed,0) AS filed
FROM run ORDER BY id DESC;
"@

$qInventory = Get-Json "SELECT id, kind, name, COALESCE(area,'') AS area, importance FROM inventory ORDER BY kind, area, name;"

$qWtIssues = Get-Json "SELECT worktree, issue_number AS num FROM worktree_issue ORDER BY worktree, issue_number;"

$qBatches = Get-Json @"
SELECT id, COALESCE(label,'') AS label, status,
  substr(COALESCE(created_at,''),1,16) AS created_at, substr(COALESCE(updated_at,''),1,16) AS updated_at,
  (SELECT count(*) FROM worktree w WHERE w.batch=batch.id) AS sets,
  (SELECT count(*) FROM worktree w WHERE w.batch=batch.id AND w.status IN ('merged','retired')) AS done,
  COALESCE(notes,'') AS notes
FROM batch ORDER BY id DESC;
"@

$qHubFindings = Get-Json @"
SELECT id, COALESCE(source,'') AS source, COALESCE(wtype,'') AS wtype, COALESCE(category,'') AS category,
  COALESCE(title,'') AS title, COALESCE(detail,'') AS detail, COALESCE(severity,'') AS severity,
  status, COALESCE(target,'') AS target, COALESCE(resolution,'') AS resolution,
  substr(COALESCE(created_at,''),1,16) AS created_at, substr(COALESCE(resolved_at,''),1,16) AS resolved_at
FROM hubfinding ORDER BY id DESC;
"@

$qConsults = Get-Json @"
SELECT id, COALESCE(worktree,'') AS worktree, COALESCE(wtype,'') AS wtype, expert, COALESCE(area,'') AS area,
  COALESCE(issue,'') AS issue, COALESCE(question,'') AS question, COALESCE(advice,'') AS advice,
  COALESCE(decision,'') AS decision, COALESCE(followed,'') AS followed, COALESCE(rationale,'') AS rationale,
  substr(COALESCE(created_at,''),1,16) AS created_at
FROM consult ORDER BY id DESC;
"@

$qActivity = Get-Json @"
SELECT id, COALESCE(worktree,'') AS worktree, COALESCE(wtype,'') AS wtype, COALESCE(event,'') AS event,
  COALESCE(detail,'') AS detail, substr(COALESCE(at,''),1,16) AS at
FROM activity ORDER BY at DESC, id DESC;
"@

# --- assemble the embedded data object ------------------------------------------------
$dataJson = "{`n" + (@(
        '"issues": ' + $qIssues
        '"targets": ' + $qTargets
        '"issue_links": ' + $qIssueLinks
        '"findings": ' + $qFindings
        '"finding_links": ' + $qFindingLinks
        '"recommendations": ' + $qRecs
        '"worktrees": ' + $qWorktrees
        '"worktree_issues": ' + $qWtIssues
        '"batches": ' + $qBatches
        '"hubfindings": ' + $qHubFindings
        '"consults": ' + $qConsults
        '"topics": ' + $qTopics
        '"runs": ' + $qRuns
        '"inventory": ' + $qInventory
        '"activity": ' + $qActivity
    ) -join ",`n") + "`n}"
# never let a stray </script> in evidence/detail/note text break the <script> block
$dataJson = $dataJson.Replace('</', '<\/')

$generated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

# --- HTML template (single-quoted here-string: $ and backticks are literal JS/CSS) -----
$template = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Ledger Explorer — __REPO__</title>
<style>
  :root{
    --bg:#0f1115; --bg2:#151922; --sidebar:#12151d; --panel:#fff; --ink:#1c2330;
    --muted:#7b8494; --faint:#aeb6c2; --line:#e6e9ef; --line2:#eef1f6;
    --accent:#3b82f6; --accent-d:#2563eb; --chip:#eef2f7; --drawer:#ffffff;
  }
  *{box-sizing:border-box}
  html,body{height:100%}
  body{margin:0;font:13.5px/1.5 -apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;
       color:var(--ink);background:#f4f6fa;overflow:hidden}
  a{color:var(--accent);text-decoration:none} a:hover{text-decoration:underline}
  code{font:12px/1.4 "Cascadia Code",Consolas,monospace;background:#f0f2f7;padding:1px 5px;border-radius:5px}
  button{font:inherit;cursor:pointer}

  /* shell */
  .app{display:grid;grid-template-columns:210px 1fr;grid-template-rows:52px 1fr;height:100vh}
  header{grid-column:1/3;background:var(--bg);color:#fff;display:flex;align-items:center;gap:14px;
         padding:0 16px;box-shadow:0 1px 0 rgba(0,0,0,.3);z-index:30}
  header .brand{font-size:14.5px;font-weight:600;letter-spacing:.2px;white-space:nowrap}
  header .brand .dot{color:#5b93f7}
  header .sub{color:#8a94a4;font-size:11.5px;white-space:nowrap}
  header .grow{flex:1}
  header .toggle{display:flex;align-items:center;gap:6px;color:#c3cad6;font-size:12px;user-select:none;cursor:pointer}
  header .toggle input{accent-color:var(--accent)}
  #gsearch{position:relative}
  #gsearch input{padding:7px 12px 7px 30px;border-radius:8px;border:1px solid #2a2f3a;background:#191d25;
          color:#fff;min-width:300px;font-size:13px}
  #gsearch input::placeholder{color:#6b7280}
  #gsearch .ico{position:absolute;left:10px;top:7px;color:#6b7280;font-size:13px}
  #gresults{position:absolute;top:40px;left:0;right:0;background:#fff;border:1px solid var(--line);
    border-radius:10px;box-shadow:0 12px 40px rgba(16,24,40,.22);max-height:60vh;overflow:auto;display:none;z-index:60}
  #gresults.on{display:block}
  #gresults .gr{padding:8px 12px;border-bottom:1px solid var(--line2);cursor:pointer;display:flex;gap:9px;align-items:baseline}
  #gresults .gr:hover{background:#f3f7ff}
  #gresults .gr .k{font-size:10.5px;color:var(--muted);text-transform:uppercase;letter-spacing:.4px;min-width:70px}
  #gresults .gr .t{color:#1c2330}
  #gresults .gh{padding:6px 12px;background:#f7f9fc;font-size:11px;color:var(--muted);position:sticky;top:0}

  /* sidebar */
  aside{background:var(--sidebar);color:#c7cedb;overflow-y:auto;padding:10px 8px}
  aside .grp{color:#5c6675;font-size:10.5px;text-transform:uppercase;letter-spacing:.6px;padding:12px 10px 5px}
  aside a.nav{display:flex;align-items:center;gap:9px;padding:7px 10px;border-radius:8px;color:#c7cedb;
    font-size:13px;margin:1px 0;cursor:pointer}
  aside a.nav:hover{background:#1c2230;text-decoration:none;color:#fff}
  aside a.nav.on{background:var(--accent);color:#fff;font-weight:600}
  aside a.nav .ic{width:17px;text-align:center;opacity:.9}
  aside a.nav .c{margin-left:auto;background:rgba(255,255,255,.09);border-radius:999px;padding:0 8px;
    font-size:11px;font-variant-numeric:tabular-nums;color:#aab2c0}
  aside a.nav.on .c{background:rgba(255,255,255,.22);color:#fff}

  /* main */
  main{overflow:auto;position:relative}
  .view{padding:18px 22px;max-width:1600px}
  .vhead{display:flex;align-items:baseline;gap:12px;margin:0 0 14px}
  .vhead h2{margin:0;font-size:19px;font-weight:650}
  .vhead .cnt{color:var(--muted);font-size:13px}
  .vhead .desc{color:var(--faint);font-size:12px;margin-left:auto}

  /* filter rail */
  .filters{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin:0 0 12px}
  .filters .fsearch{padding:6px 11px;border:1px solid var(--line);border-radius:8px;min-width:210px;font-size:13px;background:#fff}
  details.facet{position:relative}
  details.facet>summary{list-style:none;padding:6px 11px;border:1px solid var(--line);border-radius:8px;
    background:#fff;font-size:12.5px;color:#475067;white-space:nowrap;user-select:none;display:flex;gap:7px;align-items:center}
  details.facet>summary::-webkit-details-marker{display:none}
  details.facet>summary::after{content:"▾";color:var(--faint);font-size:10px}
  details.facet[open]>summary{border-color:var(--accent);color:var(--accent-d)}
  details.facet>summary .fc{background:var(--accent);color:#fff;border-radius:999px;font-size:10.5px;padding:0 6px}
  .facet .menu{position:absolute;z-index:40;top:36px;left:0;background:#fff;border:1px solid var(--line);
    border-radius:9px;box-shadow:0 10px 34px rgba(16,24,40,.18);padding:6px;min-width:190px;max-height:320px;overflow:auto}
  .facet .menu label{display:flex;align-items:center;gap:8px;padding:5px 8px;border-radius:6px;font-size:12.5px;cursor:pointer}
  .facet .menu label:hover{background:#f3f7ff}
  .facet .menu label input{accent-color:var(--accent)}
  .facet .menu label .n{margin-left:auto;color:var(--muted);font-size:11px;font-variant-numeric:tabular-nums}
  .clearf{padding:6px 10px;border:1px solid transparent;border-radius:8px;background:none;color:var(--accent);font-size:12.5px}
  .clearf:hover{background:#eef4ff}

  /* table */
  .tblwrap{background:var(--panel);border:1px solid var(--line);border-radius:12px;overflow:hidden;
    box-shadow:0 1px 2px rgba(16,24,40,.04)}
  .scroll{overflow:auto;max-height:calc(100vh - 210px)}
  table{border-collapse:collapse;width:100%;font-size:13px}
  th,td{padding:8px 12px;text-align:left;border-bottom:1px solid var(--line2);vertical-align:top;white-space:nowrap}
  th{position:sticky;top:0;background:#f7f9fc;cursor:pointer;user-select:none;font-weight:600;color:#475067;
     font-size:11.5px;text-transform:uppercase;letter-spacing:.3px;z-index:2}
  th:hover{background:#eef2f8}
  th .arrow{color:var(--accent);font-size:10px;margin-left:2px}
  tbody tr{cursor:pointer}
  tbody tr:hover{background:#f3f7ff}
  td.num{text-align:right;font-variant-numeric:tabular-nums;color:#475067}
  td .clip{max-width:420px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;display:block}
  td.wrap,td.wrap .clip{white-space:normal}
  .muted{color:#c8cdd6}
  .title{font-weight:600;color:#1c2330}
  .mono{font:12px/1.4 "Cascadia Code",Consolas,monospace}
  .empty{padding:26px;color:var(--muted);font-style:italic;text-align:center}

  /* badges */
  .badge{display:inline-block;padding:1px 8px;border-radius:999px;font-size:11px;font-weight:600;
         white-space:nowrap;border:1px solid transparent}
  .sev-critical{background:#fde8e8;color:#9b1c1c;border-color:#f6c6c6}
  .sev-high{background:#fde7d8;color:#9a4a00;border-color:#f5cfa8}
  .sev-medium{background:#fdf6cf;color:#7a5d00;border-color:#efe199}
  .sev-low{background:#e6effe;color:#1e429f;border-color:#c3d7fb}
  .sev-info,.sev-none{background:#eef1f6;color:#5b6472}
  .st-blocked,.st-failed,.st-aborted{background:#fde8e8;color:#9b1c1c}
  .st-proposed,.st-spec-gate,.st-in-process,.st-running,.st-needs-triage{background:#fdf6cf;color:#7a5d00}
  .st-reviewed,.st-working,.st-registered,.st-synced,.st-verified{background:#e6effe;color:#1e429f}
  .st-approved,.st-merged,.st-completed,.st-done,.st-still-valid{background:#def7ec;color:#03543f}
  .st-pr-open,.st-filed{background:#edebfe;color:#5521b5}
  .st-retired,.st-dismissed,.st-closed,.st-out-of-scope,.st-already-fixed,.st-disabled{background:#eef1f6;color:#6b7280}
  .bd-user{background:#e6effe;color:#1e429f}
  .bd-recon{background:#def7ec;color:#03543f}
  .bd-recommendation{background:#fdf6cf;color:#7a5d00}
  .badge.plain{background:var(--chip);color:#475067}
  /* hub-finding status + consult "followed" (overridden = the signal, so it reads red) */
  .st-open{background:#fdf6cf;color:#7a5d00}
  .st-resolved{background:#def7ec;color:#03543f}
  .fl-yes{background:#def7ec;color:#03543f}
  .fl-partial{background:#fdf6cf;color:#7a5d00}
  .fl-overridden{background:#fde8e8;color:#9b1c1c;border-color:#f6c6c6}

  /* overview */
  .tiles{display:grid;grid-template-columns:repeat(auto-fill,minmax(140px,1fr));gap:12px;margin:0 0 18px}
  .tile{background:#fff;border:1px solid var(--line);border-radius:12px;padding:13px 15px;cursor:pointer;
    box-shadow:0 1px 2px rgba(16,24,40,.04)}
  .tile:hover{border-color:var(--accent);box-shadow:0 3px 12px rgba(59,130,246,.12)}
  .tile .big{font-size:26px;font-weight:700;line-height:1}
  .tile .lbl{color:var(--muted);font-size:12px;margin-top:5px}
  .tile .of{color:var(--faint);font-size:11px}
  .cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:14px}
  .card{background:#fff;border:1px solid var(--line);border-radius:12px;padding:14px 16px;box-shadow:0 1px 2px rgba(16,24,40,.04)}
  .card h3{margin:0 0 11px;font-size:13px;font-weight:650;color:#2a3242}
  .bar{display:flex;align-items:center;gap:9px;margin:5px 0;font-size:12.5px}
  .bar .bl{min-width:96px;color:#475067;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .bar .bt{flex:1;background:#eef1f6;border-radius:5px;height:15px;overflow:hidden}
  .bar .bf{display:block;height:100%;border-radius:5px;background:var(--accent)}
  .bar .bv{min-width:30px;text-align:right;color:#6b7280;font-variant-numeric:tabular-nums}
  .bf.c-critical{background:#e02424}.bf.c-high{background:#e07a17}.bf.c-medium{background:#d9b400}
  .bf.c-low{background:#3b82f6}.bf.c-green{background:#0e9f6e}.bf.c-purple{background:#7e3af2}
  .bf.c-gray{background:#9aa4b2}.bf.c-red{background:#e02424}
  .attn a{display:flex;gap:8px;align-items:baseline;padding:5px 0;border-bottom:1px solid var(--line2);font-size:12.5px}
  .attn a:last-child{border-bottom:none} .attn a:hover{text-decoration:none;background:#f6f9ff}
  .attn .meta{margin-left:auto;color:var(--muted);font-size:11px;white-space:nowrap}

  /* drawer */
  .scrim{position:fixed;inset:0;background:rgba(15,17,21,.42);opacity:0;pointer-events:none;transition:opacity .16s;z-index:70}
  .scrim.on{opacity:1;pointer-events:auto}
  .drawer{position:fixed;top:0;right:0;height:100vh;width:min(640px,94vw);background:var(--drawer);
    box-shadow:-14px 0 46px rgba(16,24,40,.25);transform:translateX(100%);transition:transform .18s cubic-bezier(.2,.7,.2,1);
    z-index:80;display:flex;flex-direction:column}
  .drawer.on{transform:none}
  .drawer .dhead{padding:13px 18px;border-bottom:1px solid var(--line);display:flex;align-items:center;gap:10px;background:#fbfcfe}
  .drawer .dhead .kind{font-size:10.5px;text-transform:uppercase;letter-spacing:.5px;color:#fff;background:var(--accent);
    padding:2px 8px;border-radius:6px;font-weight:600}
  .drawer .dhead h3{margin:0;font-size:15px;font-weight:650;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .drawer .dhead .x{margin-left:auto;border:none;background:#eef1f6;border-radius:8px;width:30px;height:30px;font-size:16px;color:#475067}
  .drawer .dhead .x:hover{background:#e2e6ee}
  .drawer .back{border:none;background:none;color:var(--accent);font-size:12.5px;padding:2px 4px}
  .drawer .dbody{overflow:auto;padding:16px 18px;flex:1}
  .dsec{margin:0 0 18px}
  .dsec h4{margin:0 0 8px;font-size:11px;text-transform:uppercase;letter-spacing:.5px;color:var(--muted);
    border-bottom:1px solid var(--line2);padding-bottom:5px}
  .fields{display:grid;grid-template-columns:130px 1fr;gap:2px 12px;font-size:13px}
  .fields .fk{color:var(--muted);padding:4px 0}
  .fields .fv{color:#1c2330;padding:4px 0;word-break:break-word;white-space:pre-wrap}
  .fields .fv.mono{font-size:12px}
  .chips{display:flex;flex-wrap:wrap;gap:6px}
  .chip{display:inline-flex;align-items:center;gap:5px;padding:3px 9px;border-radius:8px;background:#eef2f7;
    color:#33405a;font-size:12px;border:1px solid #e2e7ef;cursor:pointer}
  .chip:hover{background:#e2ebfb;border-color:#c3d7fb;text-decoration:none;color:#1e429f}
  .chip .kk{font-size:10px;color:#8a94a4;text-transform:uppercase;letter-spacing:.3px}
  .chip.dead{cursor:default;color:#8a94a4;background:#f4f6fa}
  .chip.dead:hover{background:#f4f6fa;border-color:#e2e7ef}
  .paths{font:12px/1.7 "Cascadia Code",Consolas,monospace;display:flex;flex-direction:column;gap:2px}
  .paths .p{display:flex;gap:8px;align-items:center}
  .paths .p code{background:#f5f7fb;flex:1;overflow:hidden;text-overflow:ellipsis}
  .cpy{border:none;background:#eef1f6;border-radius:6px;font-size:10.5px;color:#5b6472;padding:2px 7px}
  .cpy:hover{background:#dde3ec}
  .tl{border-left:2px solid var(--line);margin-left:5px;padding-left:14px}
  .tl .ev{position:relative;padding:4px 0;font-size:12.5px}
  .tl .ev::before{content:"";position:absolute;left:-19px;top:9px;width:8px;height:8px;border-radius:50%;background:var(--accent);border:2px solid #fff}
  .tl .ev .when{color:var(--muted);font-size:11px;margin-left:8px}
  .longtext{white-space:pre-wrap;background:#f8fafc;border:1px solid var(--line2);border-radius:8px;padding:10px 12px;
    font-size:12.5px;color:#33405a;max-height:280px;overflow:auto}
  footer{grid-column:1/3;display:none}
  .kbd{font:11px/1 monospace;background:#eef1f6;border:1px solid #dfe4ec;border-bottom-width:2px;border-radius:4px;padding:2px 5px;color:#5b6472}
</style>
</head>
<body>
<div class="app">
  <header>
    <span class="brand">Ledger <span class="dot">Explorer</span></span>
    <span class="sub">__REPO__ · __GENERATED__</span>
    <span class="grow"></span>
    <label class="toggle"><input type="checkbox" id="showClosed"> show closed / retired</label>
    <div id="gsearch"><span class="ico">🔍</span>
      <input type="search" id="gq" placeholder="Search everything…  ( / )" autocomplete="off" spellcheck="false">
      <div id="gresults"></div>
    </div>
  </header>
  <aside id="side"></aside>
  <main id="main"></main>
</div>

<div class="scrim" id="scrim"></div>
<div class="drawer" id="drawer">
  <div class="dhead" id="dhead"></div>
  <div class="dbody" id="dbody"></div>
</div>

<script>
const DATA = __DATA__;
const REPO = "__REPO__";
const issueUrl = n => `https://github.com/${REPO}/issues/${n}`;
const prUrl    = n => `https://github.com/${REPO}/pull/${n}`;
const SEV_RANK = { critical:0, high:1, medium:2, low:3, info:4, none:5, '':9 };

const esc = s => String(s==null?'':s).replace(/[&<>"']/g, c => (
  {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const slug = s => String(s==null?'':s).toLowerCase().replace(/[^a-z0-9]+/g,'-').replace(/^-|-$/g,'');
const has  = v => v!=='' && v!=null;
const norm = v => String(v==null?'':v);

/* ---------- indexes & derived relationships ---------- */
const IX = {
  issue:  new Map(DATA.issues.map(r=>[String(r.num), r])),
  finding:new Map(DATA.findings.map(r=>[String(r.id), r])),
  rec:    new Map(DATA.recommendations.map(r=>[String(r.id), r])),
  worktree:new Map(DATA.worktrees.map(r=>[String(r.name), r])),
  batch:new Map(DATA.batches.map(r=>[String(r.id), r])),
  hubfinding:new Map(DATA.hubfindings.map(r=>[String(r.id), r])),
  consult:new Map(DATA.consults.map(r=>[String(r.id), r])),
  topic:  new Map(DATA.topics.map(r=>[String(r.id), r])),
  run:    new Map(DATA.runs.map(r=>[String(r.id), r])),
  inventory:new Map(DATA.inventory.map(r=>[String(r.id), r])),
  activity:new Map(DATA.activity.map(r=>[String(r.id), r])),
};
const targetsByIssue = new Map();      // num -> [{path,ownership}]
const ownersByPath   = new Map();      // path -> [num] (ownership='owns')
DATA.targets.forEach(t=>{
  (targetsByIssue.get(String(t.num)) || targetsByIssue.set(String(t.num),[]).get(String(t.num))).push(t);
  if(t.ownership==='owns'){ (ownersByPath.get(t.path) || ownersByPath.set(t.path,[]).get(t.path)).push(String(t.num)); }
});
const issueOverlaps = new Map();       // num -> Set(other num)
targetsByIssue.forEach((ts,num)=>{
  const set = new Set();
  ts.filter(t=>t.ownership==='owns').forEach(t=>(ownersByPath.get(t.path)||[]).forEach(o=>{ if(o!==num) set.add(o); }));
  if(set.size) issueOverlaps.set(num, set);
});
const issueLinksBy = new Map();        // num -> [{other,kind,note,dir}]
DATA.issue_links.forEach(l=>{
  const a=String(l.num), b=String(l.rel);
  (issueLinksBy.get(a)||issueLinksBy.set(a,[]).get(a)).push({other:b,kind:l.kind,note:l.note,dir:'→'});
  (issueLinksBy.get(b)||issueLinksBy.set(b,[]).get(b)).push({other:a,kind:l.kind,note:l.note,dir:'←'});
});
const findingLinksBy = new Map();
DATA.finding_links.forEach(l=>{
  const a=String(l.fid), b=String(l.rel);
  (findingLinksBy.get(a)||findingLinksBy.set(a,[]).get(a)).push({other:b,kind:l.kind,note:l.note,dir:'→'});
  (findingLinksBy.get(b)||findingLinksBy.set(b,[]).get(b)).push({other:a,kind:l.kind,note:l.note,dir:'←'});
});
// worktree <-> issue: a solo worktree owns worktree.issue; a grouped-wave (cluster) worktree owns
// several issues via worktree_issue. Union both so "working it" / "wave issues" resolve fully.
const memberIssuesByWt = new Map();   // wt name -> [issue num]  (grouped-wave members)
DATA.worktree_issues.forEach(m=>{ (memberIssuesByWt.get(m.worktree)||memberIssuesByWt.set(m.worktree,[]).get(m.worktree)).push(String(m.num)); });
const wtByIssue = new Map();           // issue num -> [worktree]
function linkWtIssue(num,w){ const k=String(num), arr=wtByIssue.get(k)||wtByIssue.set(k,[]).get(k); if(!arr.some(x=>x.name===w.name)) arr.push(w); }
DATA.worktrees.forEach(w=>{ if(has(w.issue)) linkWtIssue(w.issue,w); });
DATA.worktree_issues.forEach(m=>{ const w=IX.worktree.get(m.worktree); if(w) linkWtIssue(m.num,w); });
const recByWt   = new Map(); DATA.recommendations.forEach(r=>{ if(has(r.worktree)) (recByWt.get(r.worktree)||recByWt.set(r.worktree,[]).get(r.worktree)).push(r); });
const actByWt   = new Map(); DATA.activity.forEach(a=>{ if(has(a.worktree)) (actByWt.get(a.worktree)||actByWt.set(a.worktree,[]).get(a.worktree)).push(a); });
const consultByWt   = new Map(); DATA.consults.forEach(c=>{ if(has(c.worktree)) (consultByWt.get(c.worktree)||consultByWt.set(c.worktree,[]).get(c.worktree)).push(c); });
const wtByBatch = new Map();     DATA.worktrees.forEach(w=>{ if(has(w.batch)) (wtByBatch.get(String(w.batch))||wtByBatch.set(String(w.batch),[]).get(String(w.batch))).push(w); });
const consultByIssue= new Map(); DATA.consults.forEach(c=>{ if(has(c.issue)) (consultByIssue.get(String(c.issue))||consultByIssue.set(String(c.issue),[]).get(String(c.issue))).push(c); });
const runByTopic= new Map(); DATA.runs.forEach(r=>{ if(has(r.topic_id)) (runByTopic.get(String(r.topic_id))||runByTopic.set(String(r.topic_id),[]).get(String(r.topic_id))).push(r); });
const findByRun = new Map(); DATA.findings.forEach(f=>{ if(has(f.run_id)) (findByRun.get(String(f.run_id))||findByRun.set(String(f.run_id),[]).get(String(f.run_id))).push(f); });
const findByTopic=new Map(); DATA.findings.forEach(f=>{ if(has(f.topic)) (findByTopic.get(f.topic)||findByTopic.set(f.topic,[]).get(f.topic)).push(f); });

/* ---------- entity configuration ---------- */
const B_SEV={type:'sev'}, B_ST={type:'status'};
const ENTITIES = {
  issues: { title:'Issues', icon:'◆', key:'num', rows:DATA.issues,
    open:r=>r.status!=='closed',
    cols:[
      {k:'num',label:'#',type:'issuelink'},{k:'origin',label:'Origin',type:'origin'},
      {k:'severity',label:'Sev',...B_SEV},{k:'track',label:'Track'},{k:'status',label:'Status',...B_ST},
      {k:'effort',label:'Eff'},{k:'owns',label:'Owns',type:'num'},{k:'reads',label:'Reads',type:'num'},
      {k:'overlaps',label:'Ovlp',type:'num'},{k:'title',label:'Title',type:'title',wrap:1}],
    facets:['origin','severity','track','status','effort','verdict','confidence'],
    inject:r=>({overlaps:(issueOverlaps.get(String(r.num))||new Set()).size}) },
  findings: { title:'Findings', icon:'🔎', key:'id', rows:DATA.findings,
    open:r=>r.status!=='completed'&&r.status!=='dismissed',
    cols:[
      {k:'id',label:'ID',type:'num'},{k:'severity',label:'Sev',...B_SEV},{k:'status',label:'Status',...B_ST},
      {k:'verdict',label:'Verdict',...B_ST},{k:'github_issue',label:'GH',type:'issuelink'},
      {k:'topic',label:'Topic'},{k:'worktree',label:'Worktree'},{k:'category',label:'Cat'},
      {k:'title',label:'Title',type:'title',wrap:1},{k:'created_at',label:'Created',type:'date'}],
    facets:['severity','status','verdict','confidence','category','topic','worktree'] },
  recommendations: { title:'Recommendations', icon:'💡', key:'id', rows:DATA.recommendations,
    open:r=>r.status==='proposed',
    cols:[
      {k:'id',label:'ID',type:'num'},{k:'source_issue',label:'Src',type:'issuelink'},
      {k:'severity',label:'Sev',...B_SEV},{k:'area',label:'Area'},{k:'status',label:'Status',...B_ST},
      {k:'verdict',label:'Verdict',...B_ST},{k:'worktree',label:'Worktree'},
      {k:'title',label:'Title',type:'title',wrap:1},{k:'created_at',label:'Created',type:'date'}],
    facets:['severity','status','verdict','area','worktree'] },
  worktrees: { title:'Worktrees', icon:'🌿', key:'name', rows:DATA.worktrees,
    open:r=>r.status!=='retired',
    cols:[
      {k:'name',label:'Worktree',type:'title'},{k:'wtype',label:'Type'},{k:'issue',label:'Issue',type:'issuelink'},
      {k:'members',label:'Wave',type:'num'},{k:'pr',label:'PR',type:'prlink'},{k:'status',label:'Status',...B_ST},
      {k:'age_min',label:'Age(m)',type:'num'},{k:'owns',label:'Owns',type:'num'},{k:'recs',label:'Recs',type:'num'},
      {k:'branch',label:'Branch'},{k:'updated_at',label:'Updated',type:'date'}],
    facets:['wtype','status'] },
  batches: { title:'Batches', icon:'🧺', key:'id', rows:DATA.batches,
    open:r=>r.status!=='retired'&&r.status!=='aborted',
    cols:[
      {k:'id',label:'Batch',type:'title'},{k:'label',label:'Label'},{k:'status',label:'Status',...B_ST},
      {k:'sets',label:'Sets',type:'num'},{k:'done',label:'Done',type:'num'},
      {k:'created_at',label:'Created',type:'date'},{k:'updated_at',label:'Updated',type:'date'}],
    facets:['status'] },
  topics: { title:'Coverage', icon:'🗺️', key:'id', rows:DATA.topics,
    open:r=>r.enabled==1,
    cols:[
      {k:'id',label:'ID',type:'num'},{k:'subject',label:'Subject'},{k:'lens',label:'Lens'},
      {k:'priority',label:'Pri',type:'num'},{k:'cadence_days',label:'Cad',type:'num'},
      {k:'last_status',label:'Last',...B_ST},{k:'age_days',label:'Age(d)',type:'num'},
      {k:'last_issues',label:'Found',type:'num'},{k:'last_run_at',label:'Last run',type:'date'},{k:'enabled',label:'On'}],
    facets:['subject','lens','last_status','priority','enabled'] },
  runs: { title:'Runs', icon:'▶', key:'id', rows:DATA.runs, open:()=>true,
    cols:[
      {k:'id',label:'ID',type:'num'},{k:'topic_id',label:'Topic',type:'num'},{k:'worktree',label:'Worktree'},
      {k:'status',label:'Status',...B_ST},{k:'candidates',label:'Cand',type:'num'},{k:'filed',label:'Filed',type:'num'},
      {k:'started_at',label:'Started',type:'date'},{k:'finished_at',label:'Finished',type:'date'}],
    facets:['status','worktree'] },
  inventory: { title:'Inventory', icon:'📦', key:'id', rows:DATA.inventory, open:()=>true,
    cols:[
      {k:'id',label:'ID',type:'num'},{k:'kind',label:'Kind'},{k:'name',label:'Name',type:'title'},
      {k:'area',label:'Area'},{k:'importance',label:'Imp',type:'num'}],
    facets:['kind','area','importance'] },
  hubfindings: { title:'Hub findings', icon:'🛠️', key:'id', rows:DATA.hubfindings,
    open:r=>r.status==='open',
    cols:[
      {k:'id',label:'ID',type:'num'},{k:'severity',label:'Sev',...B_SEV},{k:'status',label:'Status',...B_ST},
      {k:'category',label:'Cat'},{k:'source',label:'Source'},{k:'target',label:'Fix target'},
      {k:'title',label:'Title',type:'title',wrap:1},{k:'created_at',label:'Created',type:'date'}],
    facets:['severity','status','category','source','target'] },
  consults: { title:'Consults', icon:'🧭', key:'id', rows:DATA.consults, open:()=>true,
    cols:[
      {k:'id',label:'ID',type:'num'},{k:'expert',label:'Expert'},{k:'area',label:'Area'},
      {k:'followed',label:'Followed',type:'followed'},{k:'worktree',label:'Worktree'},{k:'issue',label:'Issue',type:'issuelink'},
      {k:'question',label:'Question',type:'title',wrap:1},{k:'created_at',label:'Created',type:'date'}],
    facets:['expert','area','followed','wtype','worktree'] },
  activity: { title:'Activity', icon:'⚡', key:'id', rows:DATA.activity, open:()=>true,
    cols:[
      {k:'at',label:'When',type:'date'},{k:'worktree',label:'Worktree'},{k:'wtype',label:'Type'},
      {k:'event',label:'Event',type:'status'},{k:'detail',label:'Detail',type:'clip',wrap:1}],
    facets:['event','wtype','worktree'] },
};
const ORDER = ['issues','findings','recommendations','hubfindings','consults','worktrees','batches','topics','runs','inventory','activity'];
// precompute injected columns (e.g. issue overlaps) so filter/sort/search see them
Object.values(ENTITIES).forEach(e=>{ if(e.inject) e.rows.forEach(r=>Object.assign(r, e.inject(r))); });

/* ---------- view state ---------- */
const state = { view:'overview', showClosed:false };
ORDER.forEach(v=>state[v]={ sortK:null, dir:1, filters:{}, q:'' });
const drawerStack = [];

/* ---------- cell rendering ---------- */
function badge(v, pfx){ return has(v) ? `<span class="badge ${pfx}-${slug(v)}">${esc(v)}</span>` : '<span class="muted">·</span>'; }
function cell(col, r){
  const v = r[col.k];
  switch(col.type){
    case 'issuelink': return has(v) ? `<a href="${issueUrl(v)}" target="_blank" rel="noopener" onclick="event.stopPropagation()">#${esc(v)}</a>` : '<span class="muted">·</span>';
    case 'prlink':    return has(v) ? `<a href="${prUrl(v)}" target="_blank" rel="noopener" onclick="event.stopPropagation()">#${esc(v)}</a>` : '<span class="muted">·</span>';
    case 'sev':       return badge(v,'sev');
    case 'status':    return badge(v,'st');
    case 'origin':    return has(v) ? `<span class="badge bd-${slug(v)}">${esc(v)}</span>` : '<span class="muted">·</span>';
    case 'followed':  return has(v) ? `<span class="badge fl-${slug(v)}">${esc(v)}</span>` : '<span class="muted">·</span>';
    case 'date':      return has(v) ? `<span class="mono" style="color:#6b7280">${esc(v)}</span>` : '<span class="muted">·</span>';
    case 'title':     return has(v) ? `<span class="title">${esc(v)}</span>` : '<span class="muted">·</span>';
    case 'clip':      return has(v) ? `<span class="clip">${esc(v)}</span>` : '<span class="muted">·</span>';
    case 'num':       return has(v) ? esc(v) : '<span class="muted">·</span>';
    default:          return has(v) ? esc(v) : '<span class="muted">·</span>';
  }
}
function rowMatch(r, q){ if(!q) return true; return Object.values(r).some(v=>norm(v).toLowerCase().includes(q)); }
function passFilters(r, f){
  for(const k in f){ const sel=f[k]; if(sel && sel.size && !sel.has(norm(r[k]))) return false; }
  return true;
}
function currentRows(view){
  const e=ENTITIES[view], st=state[view];
  let rows=e.rows;
  if(!state.showClosed) rows=rows.filter(e.open);
  rows=rows.filter(r=>passFilters(r,st.filters));
  const q=st.q.trim().toLowerCase(); if(q) rows=rows.filter(r=>rowMatch(r,q));
  if(st.sortK){
    const col=e.cols.find(c=>c.k===st.sortK)||{k:st.sortK};
    rows=rows.slice().sort((a,b)=>{
      let x=a[col.k], y=b[col.k];
      if(col.type==='sev'){ x=SEV_RANK[slug(x)]??9; y=SEV_RANK[slug(y)]??9; }
      else { const nx=parseFloat(x),ny=parseFloat(y);
        if(col.type==='num'&&!isNaN(nx)&&!isNaN(ny)){x=nx;y=ny;}
        else if(has(x)&&has(y)&&!isNaN(nx)&&!isNaN(ny)&&col.type!=='title'){x=nx;y=ny;}
        else {x=norm(x).toLowerCase();y=norm(y).toLowerCase();} }
      return (x<y?-1:x>y?1:0)*st.dir;
    });
  }
  return rows;
}

/* ---------- sidebar ---------- */
function renderSide(){
  const s=document.getElementById('side');
  let h=`<div class="grp">Home</div><a class="nav ${state.view==='overview'?'on':''}" data-view="overview"><span class="ic">▤</span>Overview</a><div class="grp">Entities</div>`;
  ORDER.forEach(v=>{
    const e=ENTITIES[v];
    const openN=e.rows.filter(e.open).length, tot=e.rows.length;
    const shown=state.showClosed?tot:openN;
    h+=`<a class="nav ${state.view===v?'on':''}" data-view="${v}" title="${openN} open · ${tot} total">
      <span class="ic">${e.icon}</span>${e.title}<span class="c">${shown}</span></a>`;
  });
  s.innerHTML=h;
}

/* ---------- entity view ---------- */
function facetCounts(view, key){
  const e=ENTITIES[view];
  let base=state.showClosed?e.rows:e.rows.filter(e.open);
  const m=new Map();
  base.forEach(r=>{ const v=norm(r[key]); m.set(v,(m.get(v)||0)+1); });
  const arr=[...m.entries()];
  if(key==='severity'||key==='orig_severity') arr.sort((a,b)=>(SEV_RANK[slug(a[0])]??9)-(SEV_RANK[slug(b[0])]??9));
  else arr.sort((a,b)=>b[1]-a[1]);
  return arr;
}
function renderView(){
  const view=state.view;
  if(view==='overview') return renderOverview();
  const e=ENTITIES[view], st=state[view];

  // filters: STATIC rail — only the summary badge + table re-render on change, so
  // an open facet dropdown stays open while you tick multiple boxes.
  let filt=`<input class="fsearch" id="fq" placeholder="Filter ${e.title.toLowerCase()}…" value="${esc(st.q)}">`;
  e.facets.forEach(k=>{
    const opts=facetCounts(view,k), sel=st.filters[k]||new Set();
    const menu=opts.map(([v,n])=>`<label><input type="checkbox" data-facet="${k}" value="${esc(v)}" ${sel.has(v)?'checked':''}>
        <span>${v===''?'<span class="muted">(none)</span>':esc(v)}</span><span class="n">${n}</span></label>`).join('');
    filt+=`<details class="facet"><summary data-fsum="${k}">${cap(k)}<span class="fc" ${sel.size?'':'style="display:none"'}>${sel.size||''}</span></summary><div class="menu">${menu}</div></details>`;
  });
  filt+=`<button class="clearf" id="clearf" style="display:none">✕ clear</button>`;

  document.getElementById('main').innerHTML=`<div class="view">
    <div class="vhead"><h2>${e.icon} ${e.title}</h2><span class="cnt" id="cnt"></span></div>
    <div class="filters">${filt}</div>
    <div class="tblwrap" id="tbl"></div></div>`;
  renderTable();
}
function renderTable(){
  const view=state.view; if(view==='overview') return;
  const e=ENTITIES[view], st=state[view];
  const rows=currentRows(view);
  const openN=e.rows.filter(e.open).length, tot=e.rows.length;
  let body;
  if(!rows.length){ body=`<div class="empty">Nothing matches.</div>`; }
  else {
    const ths=e.cols.map(c=>{
      const a=(st.sortK===c.k)?`<span class="arrow">${st.dir>0?'▲':'▼'}</span>`:'';
      return `<th data-k="${c.k}">${c.label}${a}</th>`; }).join('');
    const trs=rows.map(r=>`<tr data-key="${esc(r[e.key])}">`+e.cols.map(c=>{
      const cls=(c.type==='num'?' class="num"':(c.wrap?' class="wrap"':''));
      return `<td${cls}>${cell(c,r)}</td>`; }).join('')+'</tr>').join('');
    body=`<div class="scroll"><table><thead><tr>${ths}</tr></thead><tbody>${trs}</tbody></table></div>`;
  }
  const tbl=document.getElementById('tbl'); if(tbl) tbl.innerHTML=body;
  const cnt=document.getElementById('cnt');
  if(cnt) cnt.textContent=`${rows.length}${rows.length!==(state.showClosed?tot:openN)?` of ${state.showClosed?tot:openN}`:''} shown · ${openN} open · ${tot} total`;
  const anyF=Object.values(st.filters).some(s=>s&&s.size)||st.q;
  const cb=document.getElementById('clearf'); if(cb) cb.style.display=anyF?'':'none';
}
const cap=s=>({wtype:'Type',topic_id:'Topic',last_status:'Last',source_issue:'Source',github_issue:'GH'}[s]
  || s.replace(/_/g,' ').replace(/^\w/,c=>c.toUpperCase()));

/* ---------- overview ---------- */
function bars(items){ const max=Math.max(1,...items.map(i=>i.value));
  return `<div>`+items.map(i=>`<div class="bar"><span class="bl">${esc(i.label||'(none)')}</span>
    <span class="bt"><span class="bf ${i.cls||''}" style="width:${(i.value/max*100).toFixed(1)}%"></span></span>
    <span class="bv">${i.value}</span></div>`).join('')+`</div>`; }
function groupBy(rows, key){ const m=new Map(); rows.forEach(r=>{const v=norm(r[key]);m.set(v,(m.get(v)||0)+1);}); return m; }
function sevBars(rows){ const m=groupBy(rows,'severity');
  return ['Critical','High','Medium','Low'].filter(s=>m.get(s)).map(s=>({label:s,value:m.get(s),cls:'c-'+s.toLowerCase()})); }
function renderOverview(){
  const oi=DATA.issues.filter(ENTITIES.issues.open), of=DATA.findings.filter(ENTITIES.findings.open),
        orc=DATA.recommendations.filter(ENTITIES.recommendations.open), ow=DATA.worktrees.filter(ENTITIES.worktrees.open);
  const tiles=ORDER.map(v=>{const e=ENTITIES[v];const o=e.rows.filter(e.open).length;
    return `<div class="tile" data-view="${v}"><div class="big">${o}</div><div class="lbl">${e.icon} ${e.title}</div><div class="of">of ${e.rows.length} total</div></div>`;}).join('');

  // issue status/track
  const isStatus=[...groupBy(oi,'status')].map(([k,n])=>({label:k,value:n,cls:'c-'+(({approved:'green',reviewed:'low',synced:'medium'})[k]||'gray')}));
  const isTrack=[...groupBy(oi.filter(r=>has(r.track)),'track')].map(([k,n])=>({label:k,value:n,cls:k==='complex'?'c-purple':'c-low'}));
  const wtStatus=[...groupBy(ow,'status')].sort((a,b)=>b[1]-a[1]).map(([k,n])=>({label:k,value:n,
    cls:'c-'+((/blocked|failed/.test(k)?'red':/merged|pr-open/.test(k)?'green':/working/.test(k)?'low':'gray'))}));
  const topStale=DATA.topics.filter(t=>t.enabled==1).slice().sort((a,b)=>(parseInt(b.age_days)||999)-(parseInt(a.age_days)||999)).slice(0,7)
    .map(t=>({label:`${t.subject}/${t.lens}`,value:(t.age_days===''?'∞':t.age_days),cls:'c-medium'}));

  // attention lists
  const blocked=ow.filter(w=>/blocked|failed/.test(w.status));
  const unverFind=of.filter(f=>!has(f.verdict)).slice(0,8);
  const unverRec=orc.filter(r=>!has(r.verdict)).slice(0,8);
  const approvedIdle=oi.filter(r=>r.status==='approved' && !(wtByIssue.get(String(r.num))||[]).some(w=>w.status!=='retired'));
  const openHub=DATA.hubfindings.filter(ENTITIES.hubfindings.open);
  const overridden=DATA.consults.filter(c=>slug(c.followed)==='overridden');

  const attn=(title,arr,fmt)=>`<div class="card"><h3>${title} <span style="color:#c8cdd6;font-weight:400">${arr.length}</span></h3>
    <div class="attn">${arr.length?arr.map(fmt).join(''):'<span class="muted" style="font-size:12.5px">— none —</span>'}</div></div>`;

  document.getElementById('main').innerHTML=`<div class="view">
    <div class="vhead"><h2>▤ Overview</h2><span class="desc">open items shown; toggle "show closed" for the full history</span></div>
    <div class="tiles">${tiles}</div>
    <div class="cards">
      <div class="card"><h3>Findings by severity</h3>${bars(sevBars(of))||'<span class="muted">none</span>'}</div>
      <div class="card"><h3>Recommendations by severity</h3>${bars(sevBars(orc))||'<span class="muted">none</span>'}</div>
      <div class="card"><h3>Issues by review status</h3>${bars(isStatus)}</div>
      <div class="card"><h3>Issues by track</h3>${bars(isTrack)||'<span class="muted">none</span>'}</div>
      <div class="card"><h3>Worktrees by status</h3>${bars(wtStatus)}</div>
      <div class="card"><h3>Stalest coverage topics (age days)</h3>${bars(topStale)}</div>
      ${attn('⛔ Blocked / failed worktrees',blocked,w=>`<a data-nav="worktree:${esc(w.name)}"><span>${esc(w.name)}</span><span class="badge st-${slug(w.status)}">${esc(w.status)}</span><span class="meta">${esc(w.updated_at)}</span></a>`)}
      ${attn('🕵️ Findings awaiting verify',unverFind,f=>`<a data-nav="finding:${f.id}"><span class="badge sev-${slug(f.severity)}">${esc(f.severity||'·')}</span><span>${esc(f.title)}</span><span class="meta">#${f.id}</span></a>`)}
      ${attn('💡 Recs awaiting verify',unverRec,r=>`<a data-nav="rec:${r.id}"><span class="badge sev-${slug(r.severity)}">${esc(r.severity||'·')}</span><span>${esc(r.title)}</span><span class="meta">#${r.id}</span></a>`)}
      ${attn('✅ Approved, not yet started',approvedIdle,r=>`<a data-nav="issue:${r.num}"><span class="badge sev-${slug(r.severity)}">${esc(r.severity||'·')}</span><span>${esc(r.title)}</span><span class="meta">#${r.num}</span></a>`)}
      ${attn('🛠️ Open hub findings',openHub,h=>`<a data-nav="hubfinding:${h.id}"><span class="badge sev-${slug(h.severity)}">${esc(h.severity||'·')}</span><span>${esc(h.title)}</span><span class="meta">${esc(h.category||'')} · #${h.id}</span></a>`)}
      ${attn('🧭 Overridden consults',overridden,c=>`<a data-nav="consult:${c.id}"><span class="badge fl-overridden">overridden</span><span>${esc(c.expert)} · ${esc((c.question||'').slice(0,54))}</span><span class="meta">#${c.id}</span></a>`)}
    </div></div>`;
}

/* ---------- detail drawer ---------- */
function fields(pairs){ return `<div class="fields">`+pairs.filter(p=>has(p[1])||p[2]).map(p=>
  `<div class="fk">${esc(p[0])}</div><div class="fv ${p[3]||''}">${p[2]?p[1]:esc(p[1])||'<span class=muted>·</span>'}</div>`).join('')+`</div>`; }
function chip(type,key,label,kind){ const exists=IX[type]&&IX[type].has(String(key));
  return `<span class="chip ${exists?'':'dead'}" ${exists?`data-nav="${type}:${esc(key)}"`:''}>${kind?`<span class="kk">${esc(kind)}</span>`:''}${esc(label)}</span>`; }
function chipRow(title,html){ return html ? `<div class="dsec"><h4>${title}</h4><div class="chips">${html}</div></div>` : ''; }
function pathList(title,arr){ if(!arr.length) return '';
  return `<div class="dsec"><h4>${title} <span style="color:#c8cdd6">${arr.length}</span></h4><div class="paths">`+
    arr.map(p=>`<div class="p"><code>${esc(p)}</code><button class="cpy" data-copy="${esc(p)}">copy</button></div>`).join('')+`</div></div>`; }
function longBlock(title,txt){ return has(txt)?`<div class="dsec"><h4>${title}</h4><div class="longtext">${esc(txt)}</div></div>`:''; }
function verifyBlock(r){
  if(!has(r.verdict)&&!has(r.verify_notes)&&!has(r.fixed_by)) return '';
  return `<div class="dsec"><h4>Verification</h4>${fields([
    ['Verdict', badge(r.verdict,'st'),true],['Confidence',r.confidence],
    ['Severity', has(r.orig_severity)&&r.orig_severity!==r.severity?`${esc(r.orig_severity)} → ${esc(r.severity)}`:r.severity,true],
    ['Scope',r.scope],['Fixed by',r.fixed_by],['Verified',r.verified_at],['Completed',r.completed_at]])}
    ${longBlock('Verify notes',r.verify_notes)}</div>`;
}
function linkChips(links, type){ return links.map(l=>{const t=IX[type].get(String(l.other));
  return chip(type,l.other, (type==='issue'?'#':'')+l.other+(t?` · ${(t.title||'').slice(0,40)}`:''), `${l.kind} ${l.dir}`); }).join(''); }

const DETAIL = {
  issue(r){
    const num=String(r.num), ts=targetsByIssue.get(num)||[];
    const owns=ts.filter(t=>t.ownership==='owns').map(t=>t.path), reads=ts.filter(t=>t.ownership!=='owns').map(t=>t.path);
    const ovl=[...(issueOverlaps.get(num)||new Set())];
    const wts=wtByIssue.get(num)||[];
    return { kind:'Issue', title:`#${r.num} · ${r.title}`, gh:issueUrl(r.num),
      html: fields([
        ['Origin',badge(r.origin,'bd'),true],['Severity',badge(r.severity,'sev'),true],
        ['Review status',badge(r.status,'st'),true],['Track',r.track],['Effort',r.effort],
        ['Verdict',r.verdict],['Confidence',r.confidence],['Author',r.author],['Labels',r.labels],
        ['Synced',r.synced_at],['Reviewed',r.reviewed_at],['Approved',r.approved_at],['Updated',r.updated_at]])
      + longBlock('Review notes', r.review_notes)
      + pathList('Owns', owns) + pathList('Reads', reads)
      + chipRow('Overlapping issues (shared owned file)', ovl.map(o=>chip('issue',o,'#'+o+' · '+((IX.issue.get(o)||{}).title||'').slice(0,40))).join(''))
      + chipRow('Linked issues', linkChips(issueLinksBy.get(num)||[], 'issue'))
      + chipRow('Working it', wts.map(w=>chip('worktree',w.name,w.name,w.status)).join(''))
      + chipRow('Consults on this issue', (consultByIssue.get(num)||[]).map(c=>chip('consult',c.id,c.expert+(has(c.followed)?' · '+c.followed:''),c.area)).join(''))
      + chipRow('Source', [
          has(r.finding_id)?chip('finding',r.finding_id,'finding #'+r.finding_id,'from'):'',
          has(r.recommendation_id)?chip('rec',r.recommendation_id,'rec #'+r.recommendation_id,'from'):'' ].join('')) };
  },
  finding(r){
    const id=String(r.id);
    return { kind:'Finding', title:`#${r.id} · ${r.title}`, gh:has(r.github_issue)?issueUrl(r.github_issue):null,
      html: fields([
        ['Severity',badge(r.severity,'sev'),true],['Status',badge(r.status,'st'),true],
        ['Category',r.category],['Topic',r.topic],['Worktree',r.worktree],['Created',r.created_at]])
      + longBlock('Evidence', r.evidence) + longBlock('Suggestion', r.suggestion)
      + verifyBlock(r)
      + chipRow('Became GitHub issue', has(r.github_issue)?chip('issue',r.github_issue,'#'+r.github_issue+' · '+((IX.issue.get(String(r.github_issue))||{}).title||'').slice(0,40),'filed'):'')
      + chipRow('Linked findings', linkChips(findingLinksBy.get(id)||[], 'finding'))
      + chipRow('Worktree', has(r.worktree)?chip('worktree',r.worktree,r.worktree):'')
      + chipRow('Run', has(r.run_id)?chip('run',r.run_id,'run #'+r.run_id):'') };
  },
  rec(r){
    return { kind:'Recommendation', title:`#${r.id} · ${r.title}`, gh:has(r.github_issue)?issueUrl(r.github_issue):null,
      html: fields([
        ['Severity',badge(r.severity,'sev'),true],['Status',badge(r.status,'st'),true],['Area',r.area],
        ['Worktree',r.worktree],['Source issue',has(r.source_issue)?'#'+r.source_issue:''],['Created',r.created_at]])
      + longBlock('Detail', r.detail) + verifyBlock(r)
      + chipRow('Source issue', has(r.source_issue)?chip('issue',r.source_issue,'#'+r.source_issue+' · '+((IX.issue.get(String(r.source_issue))||{}).title||'').slice(0,40)):'')
      + chipRow('Raised by worktree', has(r.worktree)?chip('worktree',r.worktree,r.worktree):'')
      + chipRow('Became GitHub issue', has(r.github_issue)?chip('issue',r.github_issue,'#'+r.github_issue,'filed'):'') };
  },
  worktree(r){
    const recs=recByWt.get(r.name)||[], acts=(actByWt.get(r.name)||[]).slice(0,25);
    const cons=consultByWt.get(r.name)||[], members=memberIssuesByWt.get(r.name)||[];
    const iss=has(r.issue)?IX.issue.get(String(r.issue)):null;
    return { kind:'Worktree', title:r.name, pr:has(r.pr)?prUrl(r.pr):null,
      html: fields([
        ['Type',r.wtype],['Status',badge(r.status,'st'),true],['Issue',has(r.issue)?'#'+r.issue:''],
        ['PR',has(r.pr)?`<a href="${prUrl(r.pr)}" target="_blank">#${r.pr}</a>`:'',true],
        ['Wave members',members.length||''],['Owns (paths)',r.owns],
        ['Branch',r.branch,false,'mono'],['Age (min)',r.age_min],['Created',r.created_at],['Updated',r.updated_at]])
      + longBlock('Note', r.note)
      + (members.length
          ? chipRow('Wave issues (grouped)', members.map(n=>chip('issue',n,'#'+n+' · '+((IX.issue.get(n)||{}).title||'').slice(0,38))).join(''))
          : chipRow('Issue', iss?chip('issue',r.issue,'#'+r.issue+' · '+(iss.title||'').slice(0,42)):''))
      + chipRow('Recommendations raised', recs.map(x=>chip('rec',x.id,'#'+x.id+' · '+(x.title||'').slice(0,38),x.severity)).join(''))
      + chipRow('Consults logged', cons.map(c=>chip('consult',c.id,c.expert+(has(c.followed)?' · '+c.followed:''),c.area)).join(''))
      + (has(r.batch)?chipRow('Batch', chip('batch', r.batch, 'batch '+r.batch)):'')
      + (acts.length?`<div class="dsec"><h4>Activity <span style="color:#c8cdd6">${(actByWt.get(r.name)||[]).length}</span></h4><div class="tl">`+
          acts.map(a=>`<div class="ev"><b>${esc(a.event)}</b>${has(a.detail)?' — '+esc(a.detail):''}<span class="when">${esc(a.at)}</span></div>`).join('')+`</div></div>`:'') };
  },
  batch(r){
    const wts=wtByBatch.get(String(r.id))||[];
    const issues=[...new Set(wts.flatMap(w=>{ const m=memberIssuesByWt.get(w.name)||[]; return m.length?m:(has(w.issue)?[String(w.issue)]:[]); }))];
    return { kind:'Batch', title:'batch '+r.id+(has(r.label)?' · '+r.label:''),
      html: fields([
        ['Label',r.label],['Status',badge(r.status,'st'),true],['Sets',r.sets],['Done',r.done],
        ['Created',r.created_at],['Updated',r.updated_at]])
      + longBlock('Notes', r.notes)
      + chipRow('Worktrees (sets)', wts.map(w=>{ const m=memberIssuesByWt.get(w.name)||[];
          return chip('worktree', w.name, w.name+(m.length?' · '+m.length+' issues':(has(w.issue)?' · #'+w.issue:'')), w.status); }).join(''))
      + chipRow('Issues in this batch', issues.map(n=>chip('issue',n,'#'+n+' · '+((IX.issue.get(String(n))||{}).title||'').slice(0,36))).join('')) };
  },
  topic(r){
    const runs=runByTopic.get(String(r.id))||[], finds=findByTopic.get(r.subject)||[];
    return { kind:'Coverage topic', title:`${r.subject} / ${r.lens}`,
      html: fields([
        ['Title',r.title],['Subject',r.subject],['Lens',r.lens],['Priority',r.priority],
        ['Cadence (days)',r.cadence_days],['Enabled',r.enabled==1?'yes':'no'],['Last status',badge(r.last_status,'st'),true],
        ['Last run',r.last_run_at],['Age (days)',r.age_days],['Last issues',r.last_issues]])
      + chipRow('Runs', runs.map(x=>chip('run',x.id,'run #'+x.id+' · '+x.status)).join(''))
      + chipRow('Findings under this subject', finds.slice(0,40).map(f=>chip('finding',f.id,'#'+f.id+' · '+(f.title||'').slice(0,36),f.severity)).join('')) };
  },
  run(r){
    const finds=findByRun.get(String(r.id))||[];
    return { kind:'Run', title:`Run #${r.id}`,
      html: fields([
        ['Topic',has(r.topic_id)?'#'+r.topic_id:''],['Worktree',r.worktree],['Status',badge(r.status,'st'),true],
        ['Candidates',r.candidates],['Filed',r.filed],['Started',r.started_at],['Finished',r.finished_at]])
      + chipRow('Topic', has(r.topic_id)?chip('topic',r.topic_id,'topic #'+r.topic_id):'')
      + chipRow('Worktree', has(r.worktree)?chip('worktree',r.worktree,r.worktree):'')
      + chipRow('Findings from this run', finds.map(f=>chip('finding',f.id,'#'+f.id+' · '+(f.title||'').slice(0,38),f.severity)).join('')) };
  },
  hubfinding(r){
    const src=has(r.source)&&IX.worktree.has(r.source)?r.source:null;
    return { kind:'Hub finding', title:`#${r.id} · ${r.title}`,
      html: fields([
        ['Severity',badge(r.severity,'sev'),true],['Status',badge(r.status,'st'),true],['Category',r.category],
        ['Source',r.source],['Fix target',r.target],['Created',r.created_at],['Resolved',r.resolved_at]])
      + longBlock('Detail', r.detail) + longBlock('Resolution', r.resolution)
      + chipRow('Logged by worktree', src?chip('worktree',src,src):'') };
  },
  consult(r){
    const iss=has(r.issue)?IX.issue.get(String(r.issue)):null;
    return { kind:'Consult', title:`#${r.id} · ${r.expert}`,
      html: fields([
        ['Expert',r.expert],['Area',r.area],['Followed',badge(r.followed,'fl'),true],
        ['Worktree',r.worktree],['Issue',has(r.issue)?'#'+r.issue:''],['Created',r.created_at]])
      + longBlock('Question', r.question) + longBlock('Advice', r.advice)
      + longBlock('Decision', r.decision) + longBlock('Rationale', r.rationale)
      + chipRow('Raised by worktree', has(r.worktree)&&IX.worktree.has(r.worktree)?chip('worktree',r.worktree,r.worktree):'')
      + chipRow('On issue', iss?chip('issue',r.issue,'#'+r.issue+' · '+(iss.title||'').slice(0,42)):'') };
  },
  inventory(r){
    const finds=findByTopic.get(r.name)||[];
    return { kind:'Inventory', title:`${r.kind} · ${r.name}`,
      html: fields([['Kind',r.kind],['Name',r.name,false,'mono'],['Area',r.area],['Importance',r.importance]]) };
  },
  activity(r){
    return { kind:'Activity', title:`${r.event||'event'} · ${r.worktree||''}`,
      html: fields([['When',r.at],['Worktree',r.worktree],['Type',r.wtype],['Event',badge(r.event,'st'),true]])
      + longBlock('Detail', r.detail)
      + chipRow('Worktree', has(r.worktree)&&IX.worktree.has(r.worktree)?chip('worktree',r.worktree,r.worktree):'') };
  },
};
function openEntity(type,key,push=true){
  const getter={issue:'issue',finding:'finding',rec:'rec',worktree:'worktree',batch:'batch',hubfinding:'hubfinding',consult:'consult',topic:'topic',run:'run',inventory:'inventory',activity:'activity'}[type];
  const bucket={issue:'issue',finding:'finding',rec:'rec',worktree:'worktree',batch:'batch',hubfinding:'hubfinding',consult:'consult',topic:'topic',run:'run',inventory:'inventory',activity:'activity'}[type];
  const row=IX[bucket] && IX[bucket].get(String(key));
  if(!row) return;
  if(push) drawerStack.push({type,key:String(key)});
  const d=DETAIL[getter](row);
  const head=document.getElementById('dhead');
  const back=drawerStack.length>1?`<button class="back" id="dback">‹ back</button>`:'';
  const ext=d.gh?`<a href="${d.gh}" target="_blank" style="font-size:12px;margin-left:2px">GitHub ↗</a>`:(d.pr?`<a href="${d.pr}" target="_blank" style="font-size:12px">PR ↗</a>`:'');
  head.innerHTML=`${back}<span class="kind">${esc(d.kind)}</span><h3 title="${esc(d.title)}">${esc(d.title)}</h3>${ext}<button class="x" id="dx">✕</button>`;
  document.getElementById('dbody').innerHTML=d.html;
  document.getElementById('drawer').classList.add('on');
  document.getElementById('scrim').classList.add('on');
}
function closeDrawer(){ drawerStack.length=0;
  document.getElementById('drawer').classList.remove('on');
  document.getElementById('scrim').classList.remove('on'); }
function drawerBack(){ drawerStack.pop(); const top=drawerStack[drawerStack.length-1];
  if(top) openEntity(top.type, top.key, false); else closeDrawer(); }

// row-click type per view -> drawer type
const VIEW_TYPE={issues:'issue',findings:'finding',recommendations:'rec',hubfindings:'hubfinding',consults:'consult',worktrees:'worktree',batches:'batch',topics:'topic',runs:'run',inventory:'inventory',activity:'activity'};

/* ---------- global search ---------- */
function globalSearch(q){
  q=q.trim().toLowerCase(); const box=document.getElementById('gresults');
  if(q.length<2){ box.classList.remove('on'); box.innerHTML=''; return; }
  const out=[]; const push=(type,label,sub)=>out.push({type,label,sub});
  const scan=(view,type,fmt,lim=8)=>{ let n=0;
    for(const r of ENTITIES[view].rows){ if(n>=lim) break;
      if(Object.values(r).some(v=>norm(v).toLowerCase().includes(q))){ out.push({type,...fmt(r)}); n++; } } };
  scan('issues','issue',r=>({key:r.num,label:`#${r.num} ${r.title}`}));
  scan('findings','finding',r=>({key:r.id,label:`#${r.id} ${r.title}`}));
  scan('recommendations','rec',r=>({key:r.id,label:`#${r.id} ${r.title}`}));
  scan('worktrees','worktree',r=>({key:r.name,label:`${r.name} · ${r.status}`}));
  scan('batches','batch',r=>({key:r.id,label:`batch ${r.id} · ${r.status}`}));
  scan('hubfindings','hubfinding',r=>({key:r.id,label:`#${r.id} ${r.title}`}),6);
  scan('consults','consult',r=>({key:r.id,label:`${r.expert} · ${r.followed||'—'} — ${(r.question||'').slice(0,44)}`}),6);
  scan('topics','topic',r=>({key:r.id,label:`${r.subject}/${r.lens}`}));
  scan('activity','activity',r=>({key:r.id,label:`${r.event} ${r.worktree} — ${(r.detail||'').slice(0,50)}`}),6);
  if(!out.length){ box.innerHTML='<div class="gh">no matches</div>'; box.classList.add('on'); return; }
  box.innerHTML=out.map(o=>`<div class="gr" data-nav="${o.type}:${esc(o.key)}"><span class="k">${o.type}</span><span class="t">${esc(o.label)}</span></div>`).join('');
  box.classList.add('on');
}

/* ---------- routing & events ---------- */
function go(view){ if(!ENTITIES[view]&&view!=='overview') view='overview';
  state.view=view; location.hash=view; renderSide(); renderView(); document.getElementById('main').scrollTop=0; }

function applyHash(){ const h=(location.hash||'').replace(/^#/,''); const [v,ent]=h.split('/');
  go(v||'overview');
  if(ent){ const [t,k]=ent.split(':'); if(t&&k) openEntity(t,k); } }

document.addEventListener('click',e=>{
  const nav=e.target.closest('[data-view]'); if(nav){ go(nav.dataset.view); return; }
  const jump=e.target.closest('[data-nav]'); if(jump){ const [t,k]=jump.dataset.nav.split(':');
    document.getElementById('gresults').classList.remove('on'); document.getElementById('gq').value='';
    openEntity(t, jump.dataset.nav.slice(t.length+1)); return; }
  const cpy=e.target.closest('[data-copy]'); if(cpy){ navigator.clipboard&&navigator.clipboard.writeText(cpy.dataset.copy);
    cpy.textContent='✓'; setTimeout(()=>cpy.textContent='copy',900); return; }
  if(e.target.id==='dx'){ closeDrawer(); return; }
  if(e.target.id==='dback'){ drawerBack(); return; }
  if(e.target.id==='clearf'){ const st=state[state.view]; st.filters={}; st.q=''; renderView(); return; }
  const th=e.target.closest('th[data-k]'); if(th){ const st=state[state.view];
    if(st.sortK===th.dataset.k) st.dir*=-1; else { st.sortK=th.dataset.k; st.dir=1; } renderTable(); return; }
  const tr=e.target.closest('tr[data-key]'); if(tr){ openEntity(VIEW_TYPE[state.view], tr.dataset.key); return; }
});
document.getElementById('scrim').addEventListener('click',closeDrawer);
document.addEventListener('change',e=>{
  if(e.target.id==='showClosed'){ state.showClosed=e.target.checked; renderSide(); renderView(); return; }
  if(e.target.dataset&&e.target.dataset.facet){ const st=state[state.view], k=e.target.dataset.facet;
    const set=st.filters[k]||(st.filters[k]=new Set());
    if(e.target.checked) set.add(e.target.value); else set.delete(e.target.value);
    const badge=document.querySelector(`summary[data-fsum="${k}"] .fc`);
    if(badge){ badge.textContent=set.size||''; badge.style.display=set.size?'':'none'; }
    renderTable(); return; }
});
document.addEventListener('input',e=>{
  if(e.target.id==='fq'){ state[state.view].q=e.target.value; renderTable(); return; }
  if(e.target.id==='gq'){ globalSearch(e.target.value); return; }
});
document.addEventListener('keydown',e=>{
  if(e.key==='Escape'){ if(document.getElementById('drawer').classList.contains('on')) closeDrawer();
    else { document.getElementById('gresults').classList.remove('on'); } return; }
  if(e.key==='/' && !/INPUT|TEXTAREA/.test(document.activeElement.tagName)){ e.preventDefault();
    document.getElementById('gq').focus(); }
});
window.addEventListener('hashchange',()=>{ const h=(location.hash||'').replace(/^#/,'').split('/')[0]||'overview';
  if(h!==state.view) go(h); });
document.getElementById('gq').addEventListener('blur',()=>setTimeout(()=>document.getElementById('gresults').classList.remove('on'),180));

renderSide();
applyHash();
</script>
</body>
</html>
'@

$html = $template.Replace('__DATA__', $dataJson).Replace('__GENERATED__', $generated).Replace('__REPO__', $Repo)

$outDir = Split-Path -Parent $Out
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
[System.IO.File]::WriteAllText($Out, $html, (New-Object System.Text.UTF8Encoding($false)))

function Count-Rows([string]$json) { if ($json -eq '[]') { 0 } else { @($json | ConvertFrom-Json).Count } }
$counts = [ordered]@{
    issues = Count-Rows $qIssues; findings = Count-Rows $qFindings; recs = Count-Rows $qRecs
    'hub-findings' = Count-Rows $qHubFindings; consults = Count-Rows $qConsults
    worktrees = Count-Rows $qWorktrees; batches = Count-Rows $qBatches; topics = Count-Rows $qTopics; runs = Count-Rows $qRuns
    inventory = Count-Rows $qInventory; activity = Count-Rows $qActivity
}
Write-Host ("wrote {0}" -f $Out) -ForegroundColor Green
Write-Host ("  " + (($counts.GetEnumerator() | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ' · ')) -ForegroundColor DarkGray

# --- open in Chrome -------------------------------------------------------------------
if ($NoOpen) { return }

$chrome = $null
$cmd = Get-Command chrome -ErrorAction SilentlyContinue
if ($cmd) { $chrome = $cmd.Source }
if (-not $chrome) {
    foreach ($p in @(
            "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
            "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
            "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")) {
        if (Test-Path $p) { $chrome = $p; break }
    }
}
$full = (Resolve-Path $Out).Path
if ($chrome) {
    Start-Process -FilePath $chrome -ArgumentList $full
    Write-Host "opened in Chrome." -ForegroundColor Green
}
else {
    Write-Warning "Chrome not found — opening in the default browser instead."
    Start-Process $full
}
