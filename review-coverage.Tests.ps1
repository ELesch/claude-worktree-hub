BeforeAll {
    $script:rc = $PSCommandPath.Replace('.Tests.ps1', '.ps1')   # path to review-coverage.ps1
    function New-TempDb {
        $p = Join-Path $TestDrive ("cov-" + [guid]::NewGuid().ToString('N') + ".db")
        & $script:rc init -DbPath $p | Out-Null
        return $p
    }
}

Describe 'review-coverage foundation (runs without hub.config.json)' {
    It 'init -Db creates the ledger schema without a configured hub' {
        $db = New-TempDb
        (& sqlite3 $db "SELECT name FROM sqlite_master WHERE type='table' AND name='finding';") | Should -Be 'finding'
    }
    It 'monitor -Db runs without a configured hub (does not throw)' {
        $db = New-TempDb
        { & $script:rc monitor -DbPath $db | Out-Null } | Should -Not -Throw
    }
}
