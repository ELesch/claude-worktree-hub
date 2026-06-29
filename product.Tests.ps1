BeforeAll { $script:p = $PSCommandPath.Replace('.Tests.ps1', '.ps1') }   # path to product.ps1

Describe 'product.ps1' {
    It '-Append adds a dated note to the brief' {
        $f = Join-Path $TestDrive 'PRODUCT.md'
        Set-Content $f '# Product'
        & $script:p -Append 'prioritize speed for the MVP' -Path $f | Out-Null
        (Get-Content $f -Raw) | Should -Match '- \(\d{4}-\d{2}-\d{2}\) prioritize speed for the MVP'
    }
    It '-Show prints the brief' {
        $f = Join-Path $TestDrive 'PRODUCT2.md'
        Set-Content $f '# Vision: widgets for cats'
        ((& $script:p -Show -Path $f) -join "`n") | Should -Match 'widgets for cats'
    }
    It '-Append creates the brief if it does not exist' {
        $f = Join-Path $TestDrive 'PRODUCT_new.md'
        & $script:p -Append 'bootstrap note' -Path $f | Out-Null
        Test-Path $f | Should -BeTrue
        (Get-Content $f -Raw) | Should -Match 'bootstrap note'
    }
}
