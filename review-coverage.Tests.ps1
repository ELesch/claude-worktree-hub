BeforeAll {
    $script:rc = $PSCommandPath.Replace('.Tests.ps1', '.ps1')   # path to review-coverage.ps1
    function New-TempDb {
        $p = Join-Path $TestDrive ("cov-" + [guid]::NewGuid().ToString('N') + ".db")
        & $script:rc init -DbPath $p | Out-Null
        return $p
    }
}

Describe 'review-coverage foundation (runs without hub.config.json)' {
    It 'init -DbPath creates the ledger schema without a configured hub' {
        $db = New-TempDb
        (& sqlite3 $db "SELECT name FROM sqlite_master WHERE type='table' AND name='finding';") | Should -Be 'finding'
    }
    It 'monitor -DbPath runs without a configured hub (does not throw)' {
        $db = New-TempDb
        { & $script:rc monitor -DbPath $db | Out-Null } | Should -Not -Throw
    }
}

Describe 'hubfinding schema' {
    It 'init creates the hubfinding table with the expected columns' {
        $db = New-TempDb
        $cols = (& sqlite3 $db "SELECT name FROM pragma_table_info('hubfinding') ORDER BY name;") -join ','
        $cols | Should -Be 'category,created_at,detail,id,resolution,resolved_at,severity,source,status,target,title,wtype'
    }
    It 'hubfinding.status defaults to open' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO hubfinding(title) VALUES('x');" | Out-Null
        (& sqlite3 $db "SELECT status FROM hubfinding WHERE id=1;") | Should -Be 'open'
    }
}

Describe 'hubfind' {
    It 'records an open finding with source, category, severity' {
        $db = New-TempDb
        & $script:rc hubfind -DbPath $db -Worktree 'issue-9-x' -Category env -Title 'assumed bash' -Detail 'ran rm -rf' -Severity High | Out-Null
        (& sqlite3 -separator '|' $db "SELECT source,category,severity,status FROM hubfinding WHERE id=1;") | Should -Be 'issue-9-x|env|High|open'
    }
    It 'defaults severity to Medium and source wtype to solver for an unknown worktree' {
        $db = New-TempDb
        & $script:rc hubfind -DbPath $db -Worktree 'agent-z' -Category tool -Title 'missing tool' | Out-Null
        (& sqlite3 -separator '|' $db "SELECT severity,wtype FROM hubfinding WHERE id=1;") | Should -Be 'Medium|solver'
    }
    It "tags wtype 'orchestrator' when the source is orchestrator" {
        $db = New-TempDb
        & $script:rc hubfind -DbPath $db -Worktree orchestrator -Category prompt -Title 'unclear rule' | Out-Null
        (& sqlite3 $db "SELECT wtype FROM hubfinding WHERE id=1;") | Should -Be 'orchestrator'
    }
    It 'throws when -Title is missing' {
        $db = New-TempDb
        { & $script:rc hubfind -DbPath $db -Worktree 'w' -Category env } | Should -Throw
    }
}

Describe 'hub-resolve' {
    It 'stamps resolved with target, note, and resolved_at' {
        $db = New-TempDb
        & $script:rc hubfind -DbPath $db -Worktree 'w' -Category config -Title 'wrong pm' | Out-Null
        & $script:rc hub-resolve -DbPath $db -Id 1 -Target config -Note 'set packageManager=npm' | Out-Null
        (& sqlite3 -separator '|' $db "SELECT status,target,resolution,(resolved_at IS NOT NULL) FROM hubfinding WHERE id=1;") |
            Should -Be 'resolved|config|set packageManager=npm|1'
    }
    It 'marks dismissed without requiring -Target' {
        $db = New-TempDb
        & $script:rc hubfind -DbPath $db -Worktree 'w' -Category other -Title 'noise' | Out-Null
        & $script:rc hub-resolve -DbPath $db -Id 1 -Dismiss -Note 'not a real problem' | Out-Null
        (& sqlite3 $db "SELECT status FROM hubfinding WHERE id=1;") | Should -Be 'dismissed'
    }
    It 'throws when neither -Target nor -Dismiss is given' {
        $db = New-TempDb
        & $script:rc hubfind -DbPath $db -Worktree 'w' -Category env -Title 'x' | Out-Null
        { & $script:rc hub-resolve -DbPath $db -Id 1 } | Should -Throw
    }
    It 'throws when -Id is missing' {
        $db = New-TempDb
        { & $script:rc hub-resolve -DbPath $db -Target prompt } | Should -Throw
    }
}

Describe 'hub-findings' {
    It 'lists only open by default and includes resolved/dismissed with -All' {
        $db = New-TempDb
        & $script:rc hubfind -DbPath $db -Worktree 'w' -Category env -Title 'open one' | Out-Null
        & $script:rc hubfind -DbPath $db -Worktree 'w' -Category env -Title 'to dismiss' | Out-Null
        & $script:rc hub-resolve -DbPath $db -Id 2 -Dismiss | Out-Null
        $open = (& $script:rc hub-findings -DbPath $db) -join "`n"
        $open | Should -Match 'open one'
        $open | Should -Not -Match 'to dismiss'
        $all = (& $script:rc hub-findings -DbPath $db -All) -join "`n"
        $all | Should -Match 'to dismiss'
    }
}

Describe 'monitor shows hub findings' {
    It 'includes the open hub-findings section and an open title' {
        $db = New-TempDb
        & $script:rc hubfind -DbPath $db -Worktree 'w' -Category env -Title 'pwsh-not-bash' | Out-Null
        $out = (& $script:rc monitor -DbPath $db 6>&1) -join "`n"
        $out | Should -Match 'Open hub findings'
        $out | Should -Match 'pwsh-not-bash'
    }
}

Describe 'ledger-to-html includes hub findings' {
    It 'renders a Hub findings section with an open finding (no hub.config.json needed)' {
        $db = New-TempDb
        & $script:rc hubfind -DbPath $db -Worktree 'w' -Category prompt -Title 'stale rule about pnpm' | Out-Null
        $html = Join-Path $TestDrive 'ledger.html'
        $renderer = $script:rc.Replace('review-coverage.ps1', 'ledger-to-html.ps1')
        & $renderer -Database $db -Out $html -Repo 'acme/widgets' -NoOpen | Out-Null
        $text = Get-Content $html -Raw
        $text | Should -Match 'Hub findings'
        $text | Should -Match 'stale rule about pnpm'
    }
}

Describe 'verify-rec' {
    It 'stamps verdict, verified_at, and recalibrated severity onto a recommendation (status stays proposed for still-valid)' {
        $db = New-TempDb
        & $script:rc recommend  -DbPath $db -Worktree 'issue-9-x' -Issue 9 -Title 'rec to verify' | Out-Null
        & $script:rc verify-rec -DbPath $db -Id 1 -Verdict still-valid -Severity High -Note 'still broken' | Out-Null
        (& sqlite3 -separator '|' $db "SELECT verdict,severity,(verified_at IS NOT NULL),status FROM recommendation WHERE id=1;") |
            Should -Be 'still-valid|High|1|proposed'
    }
    It 'auto-dismisses a recommendation on the already-fixed verdict' {
        $db = New-TempDb
        & $script:rc recommend  -DbPath $db -Worktree 'w' -Issue 9 -Title 'moot rec' | Out-Null
        & $script:rc verify-rec -DbPath $db -Id 1 -Verdict already-fixed -FixedBy 'PR #12' | Out-Null
        (& sqlite3 -separator '|' $db "SELECT verdict,status FROM recommendation WHERE id=1;") | Should -Be 'already-fixed|dismissed'
    }
    It 'throws when -Verdict is missing' {
        $db = New-TempDb
        & $script:rc recommend -DbPath $db -Worktree 'w' -Issue 9 -Title 'x' | Out-Null
        { & $script:rc verify-rec -DbPath $db -Id 1 } | Should -Throw
    }
    It 'throws when -Id is missing' {
        $db = New-TempDb
        { & $script:rc verify-rec -DbPath $db -Verdict still-valid } | Should -Throw
    }
}

Describe 'consult schema' {
    It 'init creates the consult table with the expected columns' {
        $db = New-TempDb
        $cols = (& sqlite3 $db "SELECT name FROM pragma_table_info('consult') ORDER BY name;") -join ','
        $cols | Should -Be 'advice,area,created_at,decision,expert,followed,id,issue,question,rationale,worktree,wtype'
    }
}

Describe 'consult verb' {
    It 'records a consultation with expert, area, issue, followed' {
        $db = New-TempDb
        & $script:rc consult -DbPath $db -Worktree 'issue-9-x' -Expert hub-architect -Area architecture -Question 'where does the cache layer live?' -Advice 'behind the repository interface' -Decision 'cache in the repository' -Followed yes -Issue 9 | Out-Null
        (& sqlite3 -separator '|' $db "SELECT worktree,expert,area,issue,followed FROM consult WHERE id=1;") | Should -Be 'issue-9-x|hub-architect|architecture|9|yes'
    }
    It 'captures an override with its rationale' {
        $db = New-TempDb
        & $script:rc consult -DbPath $db -Worktree 'w' -Expert hub-data -Question 'normalize tags?' -Advice 'separate tags table' -Decision 'inline JSON for now' -Followed overridden -Rationale 'YAGNI; under 100 rows expected' | Out-Null
        (& sqlite3 -separator '|' $db "SELECT followed,rationale FROM consult WHERE id=1;") | Should -Be 'overridden|YAGNI; under 100 rows expected'
    }
    It 'writes an activity row for the live feed' {
        $db = New-TempDb
        & $script:rc consult -DbPath $db -Worktree 'w' -Expert hub-security -Question 'sanitize this input?' | Out-Null
        (& sqlite3 $db "SELECT event FROM activity WHERE worktree='w' AND event='consult';") | Should -Be 'consult'
        (& sqlite3 $db "SELECT detail FROM activity WHERE worktree='w' AND event='consult';") | Should -Be 'hub-security: sanitize this input?'
    }
    It 'throws when -Worktree is missing' {
        $db = New-TempDb
        { & $script:rc consult -DbPath $db -Expert hub-architect -Question 'q' } | Should -Throw
    }
    It 'throws when -Expert is missing' {
        $db = New-TempDb
        { & $script:rc consult -DbPath $db -Worktree 'w' -Question 'q only' } | Should -Throw
    }
    It 'throws when -Question is missing' {
        $db = New-TempDb
        { & $script:rc consult -DbPath $db -Worktree 'w' -Expert hub-architect } | Should -Throw
    }
}

Describe 'monitor shows consults' {
    It 'includes the recent-consults section and a logged expert' {
        $db = New-TempDb
        & $script:rc consult -DbPath $db -Worktree 'w' -Expert hub-observability -Question 'what to log on retry?' -Followed yes | Out-Null
        $out = (& $script:rc monitor -DbPath $db 6>&1) -join "`n"
        $out | Should -Match 'Recent consults'
        $out | Should -Match 'hub-observability'
    }
}

Describe 'ledger-to-html includes consults' {
    It 'renders a Consults section with a logged decision (no hub.config.json needed)' {
        $db = New-TempDb
        & $script:rc consult -DbPath $db -Worktree 'w' -Expert hub-dx-product -Question 'flag name?' -Decision 'use --dry-run' -Followed yes | Out-Null
        $html = Join-Path $TestDrive 'ledger.html'
        $renderer = $script:rc.Replace('review-coverage.ps1', 'ledger-to-html.ps1')
        & $renderer -Database $db -Out $html -Repo 'acme/widgets' -NoOpen | Out-Null
        $text = Get-Content $html -Raw
        $text | Should -Match 'Consults'
        $text | Should -Match 'flag name\?'
    }
}

Describe 'product-necessity consult convention' {
    It 'records a hub-product persona review under area=product-necessity' {
        $db = New-TempDb
        & $script:rc consult -DbPath $db -Worktree 'issue-42-x' -Expert hub-product-owner -Area product-necessity `
            -Question 'Is #42 necessary for the product?' -Advice 'necessary, high' -Decision 'proceed' -Followed yes -Issue 42 | Out-Null
        (& sqlite3 -separator '|' $db "SELECT expert,area,followed,issue FROM consult WHERE id=1;") |
            Should -Be 'hub-product-owner|product-necessity|yes|42'
    }
    It 'captures a human override of a not-necessary verdict (the refinement signal)' {
        $db = New-TempDb
        & $script:rc consult -DbPath $db -Worktree 'issue-7-x' -Expert hub-product-owner -Area product-necessity `
            -Question 'Is #7 necessary?' -Advice 'not-necessary, high' -Decision 'user chose proceed' `
            -Followed overridden -Rationale 'user wants it for a launch demo' -Issue 7 | Out-Null
        (& sqlite3 -separator '|' $db "SELECT followed,rationale FROM consult WHERE id=1;") |
            Should -Be 'overridden|user wants it for a launch demo'
    }
}

Describe 'halted-unnecessary worktree status' {
    It 'progress records halted-unnecessary and it surfaces in monitor' {
        $db = New-TempDb
        & $script:rc progress -DbPath $db -Worktree 'issue-42-x' -Status halted-unnecessary -Note 'not necessary (recommend close)' | Out-Null
        (& sqlite3 $db "SELECT status FROM worktree WHERE name='issue-42-x';") | Should -Be 'halted-unnecessary'
        (& $script:rc monitor -DbPath $db | Out-String) | Should -Match 'halted-unnecessary'
    }
}

Describe 'issue clusters' {
    It 'prints the header, writes one activity row, and mutates nothing else (empty ledger)' {
        $db = New-TempDb
        $before = & sqlite3 $db "SELECT (SELECT count(*) FROM issue)||'/'||(SELECT count(*) FROM activity);"
        $out = (& $script:rc issue clusters -DbPath $db 6>&1) -join "`n"
        $out | Should -Match 'Proposed grouped waves'
        $out | Should -Match 'nothing approved to group'
        (& sqlite3 $db "SELECT event FROM activity WHERE event='clusters';") | Should -Be 'clusters'
        (& sqlite3 $db "SELECT count(*) FROM activity;") | Should -Be '1'
        $before | Should -Be '0/0'   # nothing existed before the run
    }

    It 'groups two simple approved issues that share an owned file into one cluster' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity) VALUES(12,'page n+1','approved','simple','user','High');" | Out-Null
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity) VALUES(15,'cache pages','approved','simple','recon','Medium');" | Out-Null
        & sqlite3 $db "INSERT INTO issue_target(issue_number,path,ownership) VALUES(12,'src/lib/page-queries.ts','owns'),(15,'src/lib/page-queries.ts','owns');" | Out-Null
        $out = (& $script:rc issue clusters -DbPath $db 6>&1) -join "`n"
        $out | Should -Match 'Cluster 1'
        $out | Should -Match '#12'
        $out | Should -Match '#15'
        $out | Should -Match 'new-worktree.ps1 -Issues 12,15'
    }

    It 'keeps file-disjoint simple issues as singletons (no cluster)' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity) VALUES(20,'a','approved','simple','user','High'),(21,'b','approved','simple','user','Low');" | Out-Null
        & sqlite3 $db "INSERT INTO issue_target(issue_number,path,ownership) VALUES(20,'src/a.ts','owns'),(21,'src/b.ts','owns');" | Out-Null
        $out = (& $script:rc issue clusters -DbPath $db 6>&1) -join "`n"
        $out | Should -Not -Match 'Cluster 1'
        $out | Should -Match 'Singletons'
        $out | Should -Match '#20'
        $out | Should -Match '#21'
    }

    It 'does not group a complex issue sharing a file - lists it as a not-grouped singleton' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity) VALUES(12,'simple','approved','simple','user','High'),(20,'big refactor','approved','complex','user','High');" | Out-Null
        & sqlite3 $db "INSERT INTO issue_target(issue_number,path,ownership) VALUES(12,'src/lib/x.ts','owns'),(20,'src/lib/x.ts','owns');" | Out-Null
        $out = (& $script:rc issue clusters -DbPath $db 6>&1) -join "`n"
        $out | Should -Not -Match 'Cluster 1'           # only one simple issue -> nothing to group
        $out | Should -Match '#20.*\[complex\]'
    }

    It 'groups a depends-on pair even with no shared file; ignores a related-only link' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity) VALUES(30,'dep a','approved','simple','user','High'),(31,'dep b','approved','simple','user','High'),(40,'rel a','approved','simple','user','Medium'),(41,'rel b','approved','simple','user','Medium');" | Out-Null
        & sqlite3 $db "INSERT INTO issue_target(issue_number,path,ownership) VALUES(30,'src/d1.ts','owns'),(31,'src/d2.ts','owns'),(40,'src/r1.ts','owns'),(41,'src/r2.ts','owns');" | Out-Null
        & sqlite3 $db "INSERT INTO issue_link(issue_number,related_number,kind) VALUES(30,31,'depends-on'),(40,41,'related');" | Out-Null
        $out = (& $script:rc issue clusters -DbPath $db 6>&1) -join "`n"
        $out | Should -Match 'new-worktree.ps1 -Issues 30,31'   # depends-on grouped
        $out | Should -Not -Match 'Issues 40,41'                # related NOT grouped
    }

    It 'caps an over-large component and defers the remainder' {
        $db = New-TempDb
        # five simple issues all sharing one hot file -> one component of 5; cap 2 -> cluster of 2, 3 deferred
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity) VALUES(50,'a','approved','simple','user','Critical'),(51,'b','approved','simple','user','High'),(52,'c','approved','simple','recon','Medium'),(53,'d','approved','simple','recon','Low'),(54,'e','approved','simple','recon','Low');" | Out-Null
        & sqlite3 $db "INSERT INTO issue_target(issue_number,path,ownership) VALUES(50,'src/hot.ts','owns'),(51,'src/hot.ts','owns'),(52,'src/hot.ts','owns'),(53,'src/hot.ts','owns'),(54,'src/hot.ts','owns');" | Out-Null
        $out = (& $script:rc issue clusters -DbPath $db -MaxIssues 2 6>&1) -join "`n"
        $out | Should -Match 'new-worktree.ps1 -Issues 50,51'   # top-priority 2 admitted
        $out | Should -Match 'Deferred:'
        $out | Should -Match '#52.*exceeds cap'
    }

    It 'defers an issue whose owned path is held by an active worktree (in-flight area)' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity) VALUES(30,'touches api','approved','simple','user','High');" | Out-Null
        & sqlite3 $db "INSERT INTO issue_target(issue_number,path,ownership) VALUES(30,'src/api/route.ts','owns'),(27,'src/api/route.ts','owns');" | Out-Null
        & sqlite3 $db "INSERT INTO worktree(name,wtype,issue,status) VALUES('issue-27-x','solver',27,'working');" | Out-Null
        $out = (& $script:rc issue clusters -DbPath $db 6>&1) -join "`n"
        $out | Should -Match 'Deferred:'
        $out | Should -Match "#30.*in-flight area"
    }

    It 'attaches a proposed finding whose scope mentions a cluster file (path match)' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity) VALUES(12,'a','approved','simple','user','High'),(15,'b','approved','simple','user','Medium');" | Out-Null
        & sqlite3 $db "INSERT INTO issue_target(issue_number,path,ownership) VALUES(12,'src/lib/page-queries.ts','owns'),(15,'src/lib/page-queries.ts','owns');" | Out-Null
        & sqlite3 $db "INSERT INTO finding(title,severity,status,scope,topic) VALUES('missing index hint','Medium','proposed','needs an index in src/lib/page-queries.ts','app/db');" | Out-Null
        $out = (& $script:rc issue clusters -DbPath $db 6>&1) -join "`n"
        $out | Should -Match 'advisory siblings'
        $out | Should -Match 'finding #1.*\[path\]'
    }

    It 'attaches a proposed recommendation by area token and excludes filed/dismissed rows' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity,labels) VALUES(12,'a','approved','simple','user','High',''),(15,'b','approved','simple','user','Medium','');" | Out-Null
        & sqlite3 $db "INSERT INTO issue_target(issue_number,path,ownership) VALUES(12,'src/lib/cache.ts','owns'),(15,'src/lib/cache.ts','owns');" | Out-Null
        & sqlite3 $db "INSERT INTO recommendation(title,severity,status,area) VALUES('extract helper','Low','proposed','src/lib');" | Out-Null
        & sqlite3 $db "INSERT INTO recommendation(title,severity,status,area) VALUES('already filed','High','filed','src/lib');" | Out-Null
        $out = (& $script:rc issue clusters -DbPath $db 6>&1) -join "`n"
        $out | Should -Match 'rec     #1.*\[area\]'
        $out | Should -Not -Match 'already filed'
    }

    It 'shows no advisory siblings when nothing matches' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity) VALUES(12,'a','approved','simple','user','High'),(15,'b','approved','simple','user','Medium');" | Out-Null
        & sqlite3 $db "INSERT INTO issue_target(issue_number,path,ownership) VALUES(12,'src/lib/x.ts','owns'),(15,'src/lib/x.ts','owns');" | Out-Null
        & sqlite3 $db "INSERT INTO finding(title,severity,status,scope,topic) VALUES('unrelated','High','proposed','src/auth/login.ts','app/auth');" | Out-Null
        $out = (& $script:rc issue clusters -DbPath $db 6>&1) -join "`n"
        $out | Should -Match 'Cluster 1'
        $out | Should -Not -Match 'advisory siblings'
    }

    It 'mutates only the activity table (read-only over the backlog)' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity) VALUES(12,'a','approved','simple','user','High'),(15,'b','approved','simple','user','Medium'),(20,'c','approved','complex','user','High');" | Out-Null
        & sqlite3 $db "INSERT INTO issue_target(issue_number,path,ownership) VALUES(12,'src/lib/x.ts','owns'),(15,'src/lib/x.ts','owns'),(20,'src/lib/x.ts','owns');" | Out-Null
        & sqlite3 $db "INSERT INTO finding(title,severity,status,scope,topic) VALUES('f','Medium','proposed','src/lib/x.ts','app/db');" | Out-Null
        & sqlite3 $db "INSERT INTO recommendation(title,severity,status,area) VALUES('r','Low','proposed','src/lib');" | Out-Null
        $sig = "SELECT (SELECT count(*) FROM issue)||'/'||(SELECT count(*) FROM issue_target)||'/'||(SELECT count(*) FROM finding)||'/'||(SELECT count(*) FROM recommendation)||'/'||(SELECT count(*) FROM worktree)||'|'||COALESCE((SELECT group_concat(status) FROM finding),'')||'|'||COALESCE((SELECT group_concat(status) FROM recommendation),'');"
        $before = & sqlite3 $db $sig
        & $script:rc issue clusters -DbPath $db 6>&1 | Out-Null
        $after = & sqlite3 $db $sig
        $after | Should -Be $before                                   # backlog rows + statuses unchanged
        (& sqlite3 $db "SELECT count(*) FROM activity WHERE event='clusters';") | Should -Be '1'
    }

    It 'lists a simple approved issue with no owned paths as not-grouped ([no owned paths] tag)' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity) VALUES(9,'orphan','approved','simple','user','High');" | Out-Null
        # no issue_target rows for issue 9
        $out = (& $script:rc issue clusters -DbPath $db 6>&1) -join "`n"
        $out | Should -Match '#9.*\[no owned paths\]'
        $out | Should -Not -Match 'Cluster 1'
    }

    It 'falls back to a 1-member cluster when every member individually exceeds MaxFiles' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity) VALUES(60,'a','approved','simple','user','High'),(61,'b','approved','simple','user','High');" | Out-Null
        & sqlite3 $db "INSERT INTO issue_target(issue_number,path,ownership) VALUES(60,'src/hot.ts','owns'),(60,'src/a.ts','owns'),(60,'src/b.ts','owns'),(61,'src/hot.ts','owns'),(61,'src/c.ts','owns'),(61,'src/d.ts','owns');" | Out-Null
        $out = (& $script:rc issue clusters -DbPath $db -MaxIssues 4 -MaxFiles 2 6>&1) -join "`n"
        $out | Should -Match 'Cluster 1'
        $out | Should -Match 'new-worktree.ps1 -Issues 60'   # fallback: top-priority member only
        $out | Should -Match 'Deferred:'
        $out | Should -Match '#61.*exceeds cap'
    }

    It 'matches an advisory sibling by issue-label area token (not just dir)' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity,labels) VALUES(12,'a','approved','simple','user','High','database'),(15,'b','approved','simple','user','Medium','');" | Out-Null
        & sqlite3 $db "INSERT INTO issue_target(issue_number,path,ownership) VALUES(12,'src/data/store.ts','owns'),(15,'src/data/store.ts','owns');" | Out-Null
        & sqlite3 $db "INSERT INTO recommendation(title,severity,status,area) VALUES('split the store','Low','proposed','database');" | Out-Null
        $out = (& $script:rc issue clusters -DbPath $db 6>&1) -join "`n"
        $out | Should -Match 'advisory siblings'
        $out | Should -Match 'rec     #1.*\[area\]'
    }
}

Describe 'worktree_issue (grouped-wave membership)' {
    It 'init creates the worktree_issue table and is idempotent' {
        $db = New-TempDb
        & $script:rc init -DbPath $db | Out-Null    # re-run init on an already-init'd db
        (& sqlite3 $db "SELECT name FROM sqlite_master WHERE type='table' AND name='worktree_issue';") | Should -Be 'worktree_issue'
    }
    It 'register -Issues records the lowest as primary and one worktree_issue row per member' {
        $db = New-TempDb
        & $script:rc register -Worktree 'cluster-12-x' -WType solver -Issues 15,12,19 -Branch 'fix/cluster-12-x' -DbPath $db | Out-Null
        (& sqlite3 $db "SELECT issue FROM worktree WHERE name='cluster-12-x';") | Should -Be '12'
        (& sqlite3 $db "SELECT group_concat(issue_number) FROM (SELECT issue_number FROM worktree_issue WHERE worktree='cluster-12-x' ORDER BY issue_number);") | Should -Be '12,15,19'
    }
    It 'register -Issue (single) writes no worktree_issue rows' {
        $db = New-TempDb
        & $script:rc register -Worktree 'issue-42-y' -WType solver -Issue 42 -Branch 'fix/issue-42-y' -DbPath $db | Out-Null
        (& sqlite3 $db "SELECT count(*) FROM worktree_issue WHERE worktree='issue-42-y';") | Should -Be '0'
    }
}
