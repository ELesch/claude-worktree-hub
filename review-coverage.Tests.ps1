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
