BeforeAll {
    . $PSCommandPath.Replace('.Tests.ps1', '.ps1')   # dot-source update-hub.ps1 (main is guarded off)
}

Describe 'ConvertTo-Crlf' {
    It 'converts LF to CRLF'                  { ConvertTo-Crlf "a`nb"        | Should -Be "a`r`nb" }
    It 'leaves CRLF unchanged (idempotent)'   { ConvertTo-Crlf "a`r`nb"      | Should -Be "a`r`nb" }
    It 'normalizes mixed CRLF/LF/CR to CRLF'  { ConvertTo-Crlf "a`r`nb`nc`rd"| Should -Be "a`r`nb`r`nc`r`nd" }
    It 'is idempotent on double application'  {
        $once = ConvertTo-Crlf "x`ny`r`nz"
        ConvertTo-Crlf $once | Should -Be $once
    }
    It 'handles the empty string'             { ConvertTo-Crlf '' | Should -Be '' }
}
