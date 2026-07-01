<#
.SYNOPSIS
    Shared ledger helpers for the worktree hub. Dot-sourced by review-coverage.ps1 and new-batch.ps1.
.DESCRIPTION
    Pure/read-only wave-composition logic (no script-scoped state):
      q                    - SQL single-quote escaper
      ActiveMemberIssuesSql- the membership-union SQL (worktree.issue UNION worktree_issue)
      Get-IssueClusterPlan - read-only overlap-aware wave engine (clusters/singletons/deferrals/siblings)
      ConvertTo-BatchSets  - map a wave plan -> ordered sets, applying -Only/-Exclude/-MaxSets (Task 3)
    sqlite3 must be on PATH. No writes; callers own all mutations.
#>

function q([string]$s) { if ($null -eq $s) { return '' } ($s -replace "'", "''") }
# Issue numbers owned by an ACTIVE worktree: the single worktree.issue UNION the worktree_issue
# join rows (grouped waves). The one in-flight/eligibility definition shared by clusters + next.
function ActiveMemberIssuesSql([string]$ActiveStatuses) {
    "SELECT issue FROM worktree WHERE issue IS NOT NULL AND status IN ($ActiveStatuses) " +
    "UNION SELECT wi.issue_number FROM worktree_issue wi JOIN worktree w ON w.name=wi.worktree WHERE w.status IN ($ActiveStatuses)"
}

# Read-only: compute a grouped-wave PROPOSAL from the ledger (no writes). Returns clusters (file-overlapping
# approved+simple issues, capped), singletons, not-grouped (complex/no-path), and deferrals, plus lookup maps.
function Get-IssueClusterPlan([string]$Db, [int]$MaxI, [int]$MaxF) {
    $activeStatuses = "'registered','working','spec-gate','pr-open','blocked'"
    $sevCase = "CASE severity WHEN 'Critical' THEN 0 WHEN 'High' THEN 1 WHEN 'Medium' THEN 2 WHEN 'Low' THEN 3 ELSE 4 END"

    # paths owned by an ACTIVE worktree (in-flight) - same semantics as 'issue next'
    $claimed = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($p in @(& sqlite3 $Db "SELECT DISTINCT path FROM issue_target WHERE ownership='owns' AND issue_number IN ($(ActiveMemberIssuesSql $activeStatuses));")) {
        if ($p) { [void]$claimed.Add($p) }
    }

    # approved issues not already owned by an active worktree, priority-ordered (user-origin, severity, number)
    $rows = @(& sqlite3 -separator '|' $Db "SELECT number, COALESCE(track,''), origin, COALESCE(severity,'-'), substr(replace(title,'|','/'),1,42) FROM issue WHERE review_status='approved' AND number NOT IN ($(ActiveMemberIssuesSql $activeStatuses)) ORDER BY (origin='user') DESC, $sevCase, number;")

    $meta = @{}; $ownPaths = @{}; $rank = @{}
    $eligible = [System.Collections.Generic.List[int]]::new()
    $notGrouped = @(); $deferInFlight = @()
    $idx = 0
    foreach ($r in $rows) {
        if (-not $r) { continue }
        $f = $r -split '\|', 5
        $num = [int]$f[0]; $track = $f[1]
        $meta[$num] = [pscustomobject]@{ Origin = $f[2]; Sev = $f[3]; Title = $f[4] }
        $rank[$num] = $idx; $idx++
        if ($track -ne 'simple') { $notGrouped += [pscustomobject]@{ Issue = $num; Tag = '[complex]' }; continue }
        $paths = @(& sqlite3 $Db "SELECT path FROM issue_target WHERE issue_number=$num AND ownership='owns';" | Where-Object { $_ })
        if (-not $paths.Count) { $notGrouped += [pscustomobject]@{ Issue = $num; Tag = '[no owned paths]' }; continue }
        $blocked = $null
        foreach ($p in $paths) { if ($claimed.Contains($p)) { $blocked = $p; break } }
        if ($blocked) { $deferInFlight += [pscustomobject]@{ Issue = $num; Path = $blocked }; continue }
        $ownPaths[$num] = $paths
        [void]$eligible.Add($num)
    }

    # overlap graph over eligible issues: shared owned path OR depends-on (both endpoints eligible)
    $adj = @{}
    foreach ($num in $eligible) { $adj[$num] = [System.Collections.Generic.HashSet[int]]::new() }
    $byPath = @{}
    foreach ($num in $eligible) {
        foreach ($p in $ownPaths[$num]) {
            if (-not $byPath.ContainsKey($p)) { $byPath[$p] = [System.Collections.Generic.List[int]]::new() }
            [void]$byPath[$p].Add($num)
        }
    }
    foreach ($p in $byPath.Keys) {
        $grp = $byPath[$p]
        foreach ($a in $grp) { foreach ($b in $grp) { if ($a -ne $b) { [void]$adj[$a].Add($b) } } }
    }
    $eligSet = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($n in $eligible) { [void]$eligSet.Add($n) }
    foreach ($num in $eligible) {
        foreach ($dStr in @(& sqlite3 $Db "SELECT related_number FROM issue_link WHERE issue_number=$num AND kind='depends-on';" | Where-Object { $_ })) {
            $d = [int]$dStr
            if ($eligSet.Contains($d)) { [void]$adj[$num].Add($d); [void]$adj[$d].Add($num) }
        }
    }

    # connected components (BFS)
    $seen = [System.Collections.Generic.HashSet[int]]::new()
    $components = [System.Collections.Generic.List[object]]::new()
    foreach ($num in $eligible) {
        if ($seen.Contains($num)) { continue }
        $comp = [System.Collections.Generic.List[int]]::new()
        $queue = [System.Collections.Generic.Queue[int]]::new()
        $queue.Enqueue($num); [void]$seen.Add($num)
        while ($queue.Count) {
            $cur = $queue.Dequeue(); [void]$comp.Add($cur)
            foreach ($nb in $adj[$cur]) { if (-not $seen.Contains($nb)) { [void]$seen.Add($nb); $queue.Enqueue($nb) } }
        }
        [void]$components.Add($comp)
    }

    # caps -> clusters / singletons / over-cap deferrals
    $ordered = @($components | Sort-Object { ($_ | ForEach-Object { $rank[$_] } | Measure-Object -Minimum).Minimum })
    $clusters = [System.Collections.Generic.List[object]]::new()
    $singletons = @(); $deferOverCap = @()
    foreach ($comp in $ordered) {
        $members = @($comp | Sort-Object { $rank[$_] })
        if ($members.Count -le 1) { $singletons += [int]$members[0]; continue }
        $union = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($m in $members) { foreach ($p in $ownPaths[$m]) { [void]$union.Add($p) } }
        if ($members.Count -le $MaxI -and $union.Count -le $MaxF) {
            [void]$clusters.Add([pscustomobject]@{ Members = $members; Files = @($union); Siblings = @() }); continue
        }
        # over a cap: greedily admit highest-priority members within both caps; defer the rest
        $pick = [System.Collections.Generic.List[int]]::new()
        $pf = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($m in $members) {
            if ($pick.Count -ge $MaxI) { break }
            $t = [System.Collections.Generic.HashSet[string]]::new($pf)
            foreach ($p in $ownPaths[$m]) { [void]$t.Add($p) }
            if ($t.Count -le $MaxF) { [void]$pick.Add($m); $pf = $t }
        }
        if (-not $pick.Count) { [void]$pick.Add($members[0]); foreach ($p in $ownPaths[$members[0]]) { [void]$pf.Add($p) } }
        [void]$clusters.Add([pscustomobject]@{ Members = @($pick); Files = @($pf); Siblings = @() })
        $ci = $clusters.Count
        foreach ($m in $members) { if (-not $pick.Contains($m)) { $deferOverCap += [pscustomobject]@{ Issue = $m; Cluster = $ci } } }
    }

    # advisory siblings: open (proposed) findings/recs matched to a cluster by scope-path (strong) or area (weak)
    $sib = @()
    foreach ($r in @(& sqlite3 -separator '|' $Db "SELECT id, COALESCE(severity,'-'), replace(COALESCE(scope,''),'|','/'), replace(COALESCE(topic,''),'|','/'), substr(replace(title,'|','/'),1,40) FROM finding WHERE status='proposed';")) {
        if ($r) { $g = $r -split '\|', 5; $sib += [pscustomobject]@{ Type = 'finding'; Id = [int]$g[0]; Sev = $g[1]; Scope = $g[2]; Area = $g[3]; Title = $g[4] } }
    }
    foreach ($r in @(& sqlite3 -separator '|' $Db "SELECT id, COALESCE(severity,'-'), replace(COALESCE(scope,''),'|','/'), replace(COALESCE(area,''),'|','/'), substr(replace(title,'|','/'),1,40) FROM recommendation WHERE status='proposed';")) {
        if ($r) { $g = $r -split '\|', 5; $sib += [pscustomobject]@{ Type = 'rec'; Id = [int]$g[0]; Sev = $g[1]; Scope = $g[2]; Area = $g[3]; Title = $g[4] } }
    }
    $sevRank = @{ 'Critical' = 0; 'High' = 1; 'Medium' = 2; 'Low' = 3 }
    foreach ($cl in $clusters) {
        # generic basenames are too common to be a STRONG path signal on their own -> demote to weak [path:base]
        $genericBase = @('index.ts','index.tsx','index.js','index.jsx','types.ts','utils.ts','helpers.ts','constants.ts','config.ts','mod.ts','main.ts','__init__.py')
        $strongNeedles = @(); $weakNeedles = @(); $dirs = @()
        foreach ($p in $cl.Files) {
            $strongNeedles += $p                                            # full path: always strong
            $base = ($p -split '[\\/]')[-1]
            if ($genericBase -contains $base.ToLowerInvariant()) { $weakNeedles += $base } else { $strongNeedles += $base }
            if ($p -match '[\\/]') { $dirs += ($p -replace '[\\/][^\\/]*$', '') }   # containing dir
        }
        $labelTokens = @()
        foreach ($m in $cl.Members) {
            $lab = (& sqlite3 $Db "SELECT COALESCE(labels,'') FROM issue WHERE number=$m;")
            $labelTokens += @($lab -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
        $areaNeedles = @(@($dirs + $labelTokens) | Where-Object { $_ } | Sort-Object -Unique)
        $matched = @()
        foreach ($s in $sib) {
            $why = $null
            foreach ($n in $strongNeedles) { if ($n) { $en = [System.Management.Automation.WildcardPattern]::Escape($n); if ($s.Scope -like "*$en*") { $why = 'path'; break } } }
            if (-not $why) { foreach ($n in $weakNeedles) { if ($n) { $en = [System.Management.Automation.WildcardPattern]::Escape($n); if ($s.Scope -like "*$en*") { $why = 'path:base'; break } } } }
            if (-not $why -and $s.Area) { foreach ($n in $areaNeedles) { if ($n) { $en = [System.Management.Automation.WildcardPattern]::Escape($n); if ($s.Area -like "*$en*") { $why = 'area'; break } } } }
            if ($why) { $matched += [pscustomobject]@{ Type = $s.Type; Id = $s.Id; Sev = $s.Sev; Title = $s.Title; Why = $why } }
        }
        $whyRank = @{ 'path' = 0; 'area' = 1; 'path:base' = 2 }
        $cl.Siblings = @($matched | Sort-Object `
            @{ e = { if ($sevRank.ContainsKey($_.Sev)) { $sevRank[$_.Sev] } else { 4 } } }, `
            @{ e = { $whyRank[$_.Why] } }, Id)
    }

    return [pscustomobject]@{
        Clusters = $clusters; Singletons = $singletons; NotGrouped = $notGrouped
        DeferOverCap = $deferOverCap; DeferInFlight = $deferInFlight
        Meta = $meta; OwnPaths = $ownPaths
    }
}
