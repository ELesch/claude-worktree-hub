BeforeAll {
    . $PSCommandPath.Replace('.Tests.ps1', '.ps1')
}

Describe 'New-CheckResult' {
    It 'builds an object with the five contract properties' {
        $r = New-CheckResult -Name 'x' -Category prereq -Status ok -Detail 'd' -Fix 'f'
        $r.Name     | Should -Be 'x'
        $r.Category | Should -Be 'prereq'
        $r.Status   | Should -Be 'ok'
        $r.Detail   | Should -Be 'd'
        $r.Fix      | Should -Be 'f'
    }
    It 'rejects an invalid status' {
        { New-CheckResult -Name 'x' -Category prereq -Status nope } | Should -Throw
    }
}

Describe 'Get-ReadinessVerdict' {
    It 'is ready when there are no fail results' {
        $results = @(
            (New-CheckResult -Name 'a' -Category prereq -Status ok),
            (New-CheckResult -Name 'b' -Category env    -Status warn)
        )
        $v = Get-ReadinessVerdict -Results $results
        $v.Ready        | Should -BeTrue
        $v.Blockers     | Should -BeNullOrEmpty
        $v.Warnings     | Should -Be @('b')
    }
    It 'is not ready and lists blockers when a fail is present' {
        $results = @(
            (New-CheckResult -Name 'a' -Category prereq -Status fail),
            (New-CheckResult -Name 'b' -Category prereq -Status ok)
        )
        $v = Get-ReadinessVerdict -Results $results
        $v.Ready    | Should -BeFalse
        $v.Blockers | Should -Be @('a')
    }
    It 'treats an empty result set as ready' {
        (Get-ReadinessVerdict -Results @()).Ready | Should -BeTrue
    }
}
