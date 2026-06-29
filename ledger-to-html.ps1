<#
.SYNOPSIS
  Render the OPEN items in the review-coverage ledger (.review\coverage.db) into a single
  self-contained HTML dashboard and open it in Chrome. No web server — one static file.

.DESCRIPTION
  Pulls every still-in-flight ledger item across four tables and writes them into one
  offline HTML page (all CSS/JS inlined, no CDN, works from file://):

    * Issues          — review_status != 'closed'  (synced / reviewed / approved)
    * Findings        — status NOT IN ('completed','dismissed')  (proposed / filed)
    * Recommendations — status = 'proposed'  (out-of-scope solver follow-ups)
    * Hub findings    — status = 'open'  (problems with the hub's own prompts/config/scripts/env)
    * Worktrees       — status != 'retired'  (the live monitor view)

  The page has a global search box, per-column sorting, severity/status colour badges,
  click-to-expand long text, and GitHub links for issue/PR numbers.

.PARAMETER Database
  Path to the SQLite ledger. Default: <hub>\.review\coverage.db

.PARAMETER Out
  Output HTML path. Default: <hub>\.review\ledger-open-items.html

.PARAMETER Repo
  GitHub repo slug (owner/repo) used for issue/PR links. Default: from hub.config.json.

.PARAMETER NoOpen
  Generate the file but do not launch a browser.

.EXAMPLE
  .\ledger-to-html.ps1
  .\ledger-to-html.ps1 -Out C:\temp\ledger.html -NoOpen
#>
[CmdletBinding()]
param(
    [string]$Database,
    [string]$Out,
    [string]$Repo,   # defaults to $HubConfig.repo
    [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'
try { . (Join-Path $PSScriptRoot 'hub-config.ps1') }   # sets $Hub + $HubConfig
catch { $Hub = $PSScriptRoot; $HubConfig = $null }

if (-not $Repo) { $Repo = if ($HubConfig) { $HubConfig.repo } else { 'owner/repo' } }
$Db = if ($Database) { $Database } else { Join-Path $Hub '.review\coverage.db' }
if (-not $Out) { $Out = Join-Path $Hub '.review\ledger-open-items.html' }

if (-not (Test-Path $Db)) { throw "ledger DB not found: $Db  (run review-coverage.ps1 init/seed first)" }
if (-not (Get-Command sqlite3 -ErrorAction SilentlyContinue)) {
    throw "sqlite3 not found on PATH (expected the chocolatey shim). Install: choco install sqlite"
}

# --- pull each open-item set as a raw JSON array (compact-but-valid) -------------------
function Get-Json([string]$query) {
    $rows = & sqlite3 -json $Db $query
    if ($LASTEXITCODE -ne 0) { throw "sqlite3 query failed (exit $LASTEXITCODE)" }
    $text = (@($rows) -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return '[]' }
    return $text
}

$qIssues = Get-Json @"
SELECT number AS num, origin, COALESCE(severity,'') AS severity, COALESCE(track,'') AS track,
  review_status AS status,
  (SELECT count(*) FROM issue_target t WHERE t.issue_number=issue.number AND t.ownership='owns') AS owns,
  (SELECT count(DISTINCT t2.issue_number) FROM issue_target t1 JOIN issue_target t2 ON t1.path=t2.path
     WHERE t1.issue_number=issue.number AND t1.ownership='owns' AND t2.ownership='owns'
       AND t2.issue_number!=issue.number) AS overlaps,
  title
FROM issue
WHERE review_status!='closed'
ORDER BY (origin='user') DESC,
  CASE severity WHEN 'Critical' THEN 0 WHEN 'High' THEN 1 WHEN 'Medium' THEN 2 WHEN 'Low' THEN 3 ELSE 4 END,
  number;
"@

$qFindings = Get-Json @"
SELECT id, COALESCE(severity,'') AS severity, status, COALESCE(verdict,'') AS verdict,
  COALESCE(github_issue,'') AS github_issue, COALESCE(topic,'') AS topic,
  COALESCE(worktree,'') AS worktree, title, COALESCE(category,'') AS category,
  COALESCE(evidence,'') AS evidence, COALESCE(suggestion,'') AS suggestion,
  substr(COALESCE(created_at,''),1,10) AS created
FROM finding
WHERE status NOT IN ('completed','dismissed')
ORDER BY CASE severity WHEN 'Critical' THEN 0 WHEN 'High' THEN 1 WHEN 'Medium' THEN 2 WHEN 'Low' THEN 3 ELSE 4 END,
  id;
"@

$qRecs = Get-Json @"
SELECT id, COALESCE(source_issue,'') AS source_issue, COALESCE(severity,'') AS severity,
  COALESCE(area,'') AS area, title, COALESCE(detail,'') AS detail,
  COALESCE(worktree,'') AS worktree, substr(COALESCE(created_at,''),1,10) AS created
FROM recommendation
WHERE status='proposed'
ORDER BY CASE severity WHEN 'Critical' THEN 0 WHEN 'High' THEN 1 WHEN 'Medium' THEN 2 WHEN 'Low' THEN 3 ELSE 4 END,
  id;
"@

$qHubFindings = Get-Json @"
SELECT id, COALESCE(source,'') AS source, COALESCE(category,'') AS category,
  COALESCE(severity,'') AS severity, title, COALESCE(detail,'') AS detail,
  substr(COALESCE(created_at,''),1,10) AS created
FROM hubfinding
WHERE status='open'
ORDER BY CASE severity WHEN 'High' THEN 0 WHEN 'Medium' THEN 1 WHEN 'Low' THEN 2 ELSE 3 END,
  id;
"@

$qWorktrees = Get-Json @"
SELECT name, wtype AS type, COALESCE(issue,'') AS issue, COALESCE(pr,'') AS pr, status,
  CAST((julianday('now')-julianday(updated_at))*1440 AS INT) AS upd_min,
  (SELECT count(*) FROM issue_target t WHERE t.issue_number=worktree.issue AND t.ownership='owns') AS owns,
  (SELECT count(*) FROM recommendation r WHERE r.worktree=worktree.name AND r.status='proposed') AS recs,
  COALESCE(branch,'') AS branch, COALESCE(note,'') AS note
FROM worktree
WHERE status!='retired'
ORDER BY CASE status WHEN 'blocked' THEN 0 WHEN 'failed' THEN 1 WHEN 'spec-gate' THEN 2 WHEN 'working' THEN 3
  WHEN 'pr-open' THEN 4 WHEN 'merged' THEN 5 ELSE 6 END,
  updated_at DESC;
"@

# --- assemble the embedded data object ------------------------------------------------
$dataJson = "{`n" + (@(
        '"issues": ' + $qIssues
        '"findings": ' + $qFindings
        '"recommendations": ' + $qRecs
        '"hubFindings": ' + $qHubFindings
        '"worktrees": ' + $qWorktrees
    ) -join ",`n") + "`n}"
# never let a stray </script> in evidence/detail text break the <script> block
$dataJson = $dataJson.Replace('</', '<\/')

$generated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

# --- HTML template (single-quoted here-string: $ and backticks are literal) ------------
$template = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Open Ledger Items — Worktree Hub</title>
<style>
  :root{
    --bg:#0f1115; --panel:#fff; --ink:#1c2330; --muted:#7b8494; --line:#e6e9ef;
    --accent:#3b82f6; --chip:#eef2f7;
  }
  *{box-sizing:border-box}
  body{margin:0;font:14px/1.45 -apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;
       color:var(--ink);background:#f4f6fa}
  a{color:var(--accent);text-decoration:none}
  a:hover{text-decoration:underline}
  header{position:sticky;top:0;z-index:20;background:var(--bg);color:#fff;
         padding:14px 22px;display:flex;align-items:center;gap:18px;flex-wrap:wrap;
         box-shadow:0 1px 0 rgba(0,0,0,.25)}
  header h1{font-size:17px;margin:0;font-weight:600;letter-spacing:.2px}
  header .sub{color:#9aa4b2;font-size:12px}
  header .grow{flex:1}
  #search{padding:8px 12px;border-radius:8px;border:1px solid #2a2f3a;background:#191d25;
          color:#fff;min-width:260px;font-size:13px}
  #search::placeholder{color:#6b7280}
  nav{position:sticky;top:53px;z-index:15;background:#fff;border-bottom:1px solid var(--line);
      padding:8px 22px;display:flex;gap:8px;flex-wrap:wrap}
  nav a{display:inline-flex;align-items:center;gap:6px;padding:5px 11px;border-radius:999px;
        background:var(--chip);color:var(--ink);font-size:12.5px;font-weight:500}
  nav a .n{background:#fff;border:1px solid var(--line);border-radius:999px;padding:0 7px;
           font-variant-numeric:tabular-nums;font-size:11px}
  main{padding:22px;max-width:1500px;margin:0 auto}
  section{background:var(--panel);border:1px solid var(--line);border-radius:12px;
          margin:0 0 22px;overflow:hidden;box-shadow:0 1px 2px rgba(16,24,40,.04)}
  section > h2{margin:0;padding:13px 18px;font-size:15px;display:flex;align-items:center;gap:10px;
              border-bottom:1px solid var(--line);background:#fbfcfe}
  section > h2 .count{color:var(--muted);font-weight:500;font-size:12.5px}
  section > h2 .desc{color:var(--muted);font-weight:400;font-size:12px;margin-left:auto}
  .scroll{overflow-x:auto}
  table{border-collapse:collapse;width:100%;font-size:13px}
  th,td{padding:8px 12px;text-align:left;border-bottom:1px solid var(--line);vertical-align:top}
  th{position:sticky;top:0;background:#f7f9fc;cursor:pointer;white-space:nowrap;user-select:none;
     font-weight:600;color:#475067;font-size:12px}
  th:hover{background:#eef2f8}
  th .arrow{color:var(--accent);font-size:10px;margin-left:3px}
  tbody tr:hover{background:#f9fbff}
  td.num{text-align:right;font-variant-numeric:tabular-nums;color:#475067}
  .muted{color:#c2c8d2}
  .title{font-weight:600;color:#1c2330}
  .long{max-width:380px;max-height:3.1em;overflow:hidden;position:relative;cursor:zoom-in;
        white-space:pre-wrap;color:#3a4252;
        -webkit-mask-image:linear-gradient(180deg,#000 60%,transparent);mask-image:linear-gradient(180deg,#000 60%,transparent)}
  .long.expanded{max-height:none;cursor:zoom-out;-webkit-mask-image:none;mask-image:none}
  .empty{padding:18px;color:var(--muted);font-style:italic}
  .badge{display:inline-block;padding:2px 9px;border-radius:999px;font-size:11.5px;font-weight:600;
         white-space:nowrap;border:1px solid transparent}
  /* severity */
  .sev-critical{background:#fde8e8;color:#9b1c1c;border-color:#f6c6c6}
  .sev-high{background:#fde7d8;color:#9a4a00;border-color:#f5cfa8}
  .sev-medium{background:#fdf6cf;color:#7a5d00;border-color:#efe199}
  .sev-low{background:#e6effe;color:#1e429f;border-color:#c3d7fb}
  /* status */
  .st-blocked,.st-failed{background:#fde8e8;color:#9b1c1c}
  .st-proposed,.st-spec-gate{background:#fdf6cf;color:#7a5d00}
  .st-reviewed,.st-working,.st-registered,.st-synced{background:#e6effe;color:#1e429f}
  .st-approved,.st-merged{background:#def7ec;color:#03543f}
  .st-pr-open,.st-filed{background:#edebfe;color:#5521b5}
  /* origin */
  .bd-user{background:#e6effe;color:#1e429f}
  .bd-recon{background:#def7ec;color:#03543f}
  .bd-recommendation{background:#fdf6cf;color:#7a5d00}
  .badge:not([class*=" sev-"]):not([class*="st-"]):not([class*="bd-"]){background:var(--chip);color:#475067}
  footer{color:var(--muted);font-size:12px;text-align:center;padding:0 0 28px}
</style>
</head>
<body>
<header>
  <h1>Open Ledger Items</h1>
  <span class="sub">__REPO__ · generated __GENERATED__</span>
  <span class="grow"></span>
  <input id="search" type="search" placeholder="Filter all sections…" autocomplete="off" spellcheck="false">
</header>
<nav id="nav"></nav>
<main id="sections"></main>
<footer>Static snapshot of <code>.review\coverage.db</code> — regenerate with <code>ledger-to-html.ps1</code>.</footer>

<script>
const DATA = __DATA__;
const REPO = "__REPO__";
const issueUrl = n => `https://github.com/${REPO}/issues/${n}`;
const prUrl    = n => `https://github.com/${REPO}/pull/${n}`;
const SEV_RANK = { critical:0, high:1, medium:2, low:3 };

const SECTIONS = [
  { id:'issues', title:'Issues', desc:'review_status ≠ closed', rows:DATA.issues, cols:[
    {k:'num',label:'#',type:'issuelink'},
    {k:'origin',label:'Origin',type:'origin'},
    {k:'severity',label:'Sev',type:'severity'},
    {k:'track',label:'Track'},
    {k:'status',label:'Status',type:'status'},
    {k:'owns',label:'Owns',type:'num'},
    {k:'overlaps',label:'Overlap',type:'num'},
    {k:'title',label:'Title',type:'title'},
  ]},
  { id:'findings', title:'Findings', desc:'proposed / filed', rows:DATA.findings, cols:[
    {k:'id',label:'ID',type:'num'},
    {k:'severity',label:'Sev',type:'severity'},
    {k:'status',label:'Status',type:'status'},
    {k:'verdict',label:'Verdict'},
    {k:'github_issue',label:'GH',type:'issuelink'},
    {k:'topic',label:'Topic'},
    {k:'worktree',label:'Worktree'},
    {k:'title',label:'Title',type:'title'},
    {k:'evidence',label:'Evidence',type:'long'},
    {k:'suggestion',label:'Suggestion',type:'long'},
    {k:'created',label:'Created'},
  ]},
  { id:'recommendations', title:'Recommendations', desc:'out-of-scope follow-ups (proposed)', rows:DATA.recommendations, cols:[
    {k:'id',label:'ID',type:'num'},
    {k:'source_issue',label:'Src',type:'issuelink'},
    {k:'severity',label:'Sev',type:'severity'},
    {k:'area',label:'Area'},
    {k:'title',label:'Title',type:'title'},
    {k:'detail',label:'Detail',type:'long'},
    {k:'worktree',label:'Worktree'},
    {k:'created',label:'Created'},
  ]},
  { id:'hubFindings', title:'Hub findings', desc:'prompt / env / config problems (open)', rows:DATA.hubFindings, cols:[
    {k:'id',label:'ID',type:'num'},
    {k:'source',label:'Source'},
    {k:'category',label:'Category'},
    {k:'severity',label:'Sev',type:'severity'},
    {k:'title',label:'Title',type:'title'},
    {k:'detail',label:'Detail',type:'long'},
    {k:'created',label:'Created'},
  ]},
  { id:'worktrees', title:'Worktrees', desc:'status ≠ retired (live monitor)', rows:DATA.worktrees, cols:[
    {k:'name',label:'Worktree',type:'title'},
    {k:'type',label:'Type'},
    {k:'issue',label:'Issue',type:'issuelink'},
    {k:'pr',label:'PR',type:'prlink'},
    {k:'status',label:'Status',type:'status'},
    {k:'upd_min',label:'Age (min)',type:'num'},
    {k:'owns',label:'Owns',type:'num'},
    {k:'recs',label:'Recs',type:'num'},
    {k:'branch',label:'Branch'},
    {k:'note',label:'Note',type:'long'},
  ]},
];

const state = {}; // per-section sort
SECTIONS.forEach(s => state[s.id] = { sortK:null, dir:1 });

const esc = s => String(s==null?'':s).replace(/[&<>"']/g, c => (
  {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const slug = s => String(s==null?'':s).toLowerCase().replace(/[^a-z0-9]+/g,'-').replace(/^-|-$/g,'');

function cell(col, v){
  switch(col.type){
    case 'issuelink': return v!=='' && v!=null ? `<a href="${issueUrl(v)}" target="_blank" rel="noopener">#${esc(v)}</a>` : '<span class="muted">·</span>';
    case 'prlink':    return v!=='' && v!=null ? `<a href="${prUrl(v)}" target="_blank" rel="noopener">#${esc(v)}</a>` : '<span class="muted">·</span>';
    case 'severity':  return v ? `<span class="badge sev-${slug(v)}">${esc(v)}</span>` : '<span class="muted">·</span>';
    case 'status':    return v ? `<span class="badge st-${slug(v)}">${esc(v)}</span>` : '';
    case 'origin':    return v ? `<span class="badge bd-${slug(v)}">${esc(v)}</span>` : '';
    case 'long':      return v ? `<div class="long">${esc(v)}</div>` : '<span class="muted">·</span>';
    case 'title':     return v ? `<span class="title">${esc(v)}</span>` : '';
    case 'num':       return (v===''||v==null) ? '<span class="muted">·</span>' : esc(v);
    default:          return v ? esc(v) : '<span class="muted">·</span>';
  }
}

function rowMatches(row, q){
  if(!q) return true;
  return Object.values(row).some(v => String(v==null?'':v).toLowerCase().includes(q));
}

function sortRows(rows, col, dir){
  if(!col) return rows;
  return rows.slice().sort((a,b)=>{
    let x=a[col.k], y=b[col.k];
    if(col.type==='severity'){ x=SEV_RANK[slug(x)]??9; y=SEV_RANK[slug(y)]??9; }
    else {
      const nx=parseFloat(x), ny=parseFloat(y);
      if(col.type!=='title' && x!=='' && y!=='' && !isNaN(nx) && !isNaN(ny)){ x=nx; y=ny; }
      else { x=String(x==null?'':x).toLowerCase(); y=String(y==null?'':y).toLowerCase(); }
    }
    return (x<y?-1:x>y?1:0)*dir;
  });
}

function render(){
  const q = document.getElementById('search').value.trim().toLowerCase();
  const nav = document.getElementById('nav');
  const main = document.getElementById('sections');
  nav.innerHTML=''; main.innerHTML='';

  SECTIONS.forEach(sec=>{
    const st = state[sec.id];
    const sortCol = sec.cols.find(c=>c.k===st.sortK) || null;
    let rows = sec.rows.filter(r=>rowMatches(r,q));
    rows = sortRows(rows, sortCol, st.dir);

    const navA = document.createElement('a');
    navA.href = '#'+sec.id;
    navA.innerHTML = `${sec.title} <span class="n">${rows.length}</span>`;
    nav.appendChild(navA);

    const section = document.createElement('section');
    section.id = sec.id;
    const head = `<h2><span>${sec.title}</span>
        <span class="count">${rows.length}${q?` of ${sec.rows.length}`:''}</span>
        <span class="desc">${sec.desc}</span></h2>`;

    let body;
    if(!rows.length){
      body = `<div class="empty">${q?'No matches in this section.':'Nothing open here.'}</div>`;
    } else {
      const ths = sec.cols.map(c=>{
        const arrow = (sortCol && sortCol.k===c.k) ? `<span class="arrow">${st.dir>0?'▲':'▼'}</span>` : '';
        return `<th data-sec="${sec.id}" data-k="${c.k}">${c.label}${arrow}</th>`;
      }).join('');
      const trs = rows.map(r=>'<tr>'+sec.cols.map(c=>{
        const cls = c.type==='num' ? ' class="num"' : '';
        return `<td${cls}>${cell(c, r[c.k])}</td>`;
      }).join('')+'</tr>').join('');
      body = `<div class="scroll"><table><thead><tr>${ths}</tr></thead><tbody>${trs}</tbody></table></div>`;
    }
    section.innerHTML = head + body;
    main.appendChild(section);
  });
}

// sort on header click
document.addEventListener('click', e=>{
  const th = e.target.closest('th[data-k]');
  if(th){
    const st = state[th.dataset.sec];
    if(st.sortK===th.dataset.k){ st.dir*=-1; } else { st.sortK=th.dataset.k; st.dir=1; }
    render();
    return;
  }
  const long = e.target.closest('.long');
  if(long){ long.classList.toggle('expanded'); }
});
document.getElementById('search').addEventListener('input', render);
render();
</script>
</body>
</html>
'@

$html = $template.Replace('__DATA__', $dataJson).Replace('__GENERATED__', $generated).Replace('__REPO__', $Repo)

$outDir = Split-Path -Parent $Out
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
[System.IO.File]::WriteAllText($Out, $html, (New-Object System.Text.UTF8Encoding($false)))

# quick counts for the console summary
function Count-Rows([string]$json) { if ($json -eq '[]') { 0 } else { @($json | ConvertFrom-Json).Count } }
$ci = Count-Rows $qIssues; $cf = Count-Rows $qFindings; $cr = Count-Rows $qRecs; $ch = Count-Rows $qHubFindings; $cw = Count-Rows $qWorktrees
Write-Host ("wrote {0}" -f $Out) -ForegroundColor Green
Write-Host ("  issues {0} · findings {1} · recommendations {2} · hub-findings {3} · worktrees {4}" -f $ci, $cf, $cr, $ch, $cw) -ForegroundColor DarkGray

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
