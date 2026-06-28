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
