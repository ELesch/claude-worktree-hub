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

Describe 'Test-HubSourceRemote' {
    It 'accepts an https URL with .git'    { Test-HubSourceRemote 'https://github.com/ELesch/claude-worktree-hub.git' | Should -BeTrue }
    It 'accepts an https URL without .git' { Test-HubSourceRemote 'https://github.com/ELesch/claude-worktree-hub'     | Should -BeTrue }
    It 'accepts an ssh URL'                { Test-HubSourceRemote 'git@github.com:ELesch/claude-worktree-hub.git'      | Should -BeTrue }
    It 'is case-insensitive'               { Test-HubSourceRemote 'https://github.com/elesch/Claude-Worktree-Hub'      | Should -BeTrue }
    It 'rejects a different repo'          { Test-HubSourceRemote 'https://github.com/someone/other-repo.git'          | Should -BeFalse }
    It 'rejects an empty string'           { Test-HubSourceRemote '' | Should -BeFalse }
}

Describe 'Get-HubUpdateSkipList' {
    It 'excludes HUB-STATE.md'      { Get-HubUpdateSkipList | Should -Contain 'HUB-STATE.md' }
    It 'does not exclude CLAUDE.md' { Get-HubUpdateSkipList | Should -Not -Contain 'CLAUDE.md' }
}

Describe 'Get-OverlayAction' {
    It "returns 'new' when the target is missing" {
        Get-OverlayAction -SourceNorm "a`r`nb" -TargetContent '' -TargetExists:$false | Should -Be 'new'
    }
    It "returns 'unchanged' when only the line endings differ" {
        $src = ConvertTo-Crlf "line1`nline2"
        Get-OverlayAction -SourceNorm $src -TargetContent "line1`nline2" -TargetExists | Should -Be 'unchanged'
    }
    It "returns 'unchanged' when identical (already CRLF)" {
        Get-OverlayAction -SourceNorm "a`r`nb" -TargetContent "a`r`nb" -TargetExists | Should -Be 'unchanged'
    }
    It "returns 'updated' when the content really differs" {
        Get-OverlayAction -SourceNorm "a`r`nb" -TargetContent "a`r`nCHANGED" -TargetExists | Should -Be 'updated'
    }
}
