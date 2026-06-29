BeforeAll {
    . $PSCommandPath.Replace('.Tests.ps1', '.ps1')   # dot-source hub-lib.ps1
}

Describe 'Copy-HubExperts' {
    It 'copies only hub-*.md into <wt>\.claude\agents and returns the count' {
        $hub = Join-Path $TestDrive 'hub'; $wt = Join-Path $TestDrive 'wt'
        $src = Join-Path $hub '.claude\agents'
        New-Item -ItemType Directory -Force -Path $src | Out-Null
        Set-Content (Join-Path $src 'hub-architect.md') 'a'
        Set-Content (Join-Path $src 'hub-data.md') 'b'
        Set-Content (Join-Path $src 'app-own.md') 'c'   # must NOT be copied
        $n = Copy-HubExperts -Hub $hub -WtPath $wt
        $n | Should -Be 2
        (Test-Path (Join-Path $wt '.claude\agents\hub-architect.md')) | Should -BeTrue
        (Test-Path (Join-Path $wt '.claude\agents\app-own.md')) | Should -BeFalse
    }
    It 'returns 0 when the hub has no expert agents' {
        $hub = Join-Path $TestDrive 'hub2'; $wt = Join-Path $TestDrive 'wt2'
        New-Item -ItemType Directory -Force -Path $hub | Out-Null
        (Copy-HubExperts -Hub $hub -WtPath $wt) | Should -Be 0
    }
}
