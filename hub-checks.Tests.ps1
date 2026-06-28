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

Describe 'Get-PackageManagerFromLockfile' {
    It 'returns pnpm for pnpm-lock.yaml' {
        New-Item -ItemType File -Path (Join-Path $TestDrive 'pnpm-lock.yaml') | Out-Null
        Get-PackageManagerFromLockfile -WorktreePath $TestDrive | Should -Be 'pnpm'
    }
    It 'returns npm for package-lock.json' {
        $d = Join-Path $TestDrive 'npmproj'; New-Item -ItemType Directory -Path $d | Out-Null
        New-Item -ItemType File -Path (Join-Path $d 'package-lock.json') | Out-Null
        Get-PackageManagerFromLockfile -WorktreePath $d | Should -Be 'npm'
    }
    It 'returns yarn for yarn.lock' {
        $d = Join-Path $TestDrive 'yarnproj'; New-Item -ItemType Directory -Path $d | Out-Null
        New-Item -ItemType File -Path (Join-Path $d 'yarn.lock') | Out-Null
        Get-PackageManagerFromLockfile -WorktreePath $d | Should -Be 'yarn'
    }
    It 'returns bun for bun.lockb' {
        $d = Join-Path $TestDrive 'bunproj'; New-Item -ItemType Directory -Path $d | Out-Null
        New-Item -ItemType File -Path (Join-Path $d 'bun.lockb') | Out-Null
        Get-PackageManagerFromLockfile -WorktreePath $d | Should -Be 'bun'
    }
    It 'returns $null when no lockfile is present' {
        $d = Join-Path $TestDrive 'empty'; New-Item -ItemType Directory -Path $d | Out-Null
        Get-PackageManagerFromLockfile -WorktreePath $d | Should -BeNullOrEmpty
    }
}

Describe 'Test-ConfigPlaceholder' {
    It 'is true when config is $null' {
        Test-ConfigPlaceholder -Config $null | Should -BeTrue
    }
    It 'is true when repo is missing' {
        Test-ConfigPlaceholder -Config ([pscustomobject]@{ defaultBranch = 'main' }) | Should -BeTrue
    }
    It 'is true when repo is the owner/repo placeholder' {
        Test-ConfigPlaceholder -Config ([pscustomobject]@{ repo = 'owner/repo' }) | Should -BeTrue
    }
    It 'is false for a real repo slug' {
        Test-ConfigPlaceholder -Config ([pscustomobject]@{ repo = 'acme/widgets' }) | Should -BeFalse
    }
}

Describe 'Test-GitPointer' {
    It 'is true for a BOM-free file containing gitdir: ./.bare' {
        $p = Join-Path $TestDrive 'good.git'
        [System.IO.File]::WriteAllText($p, "gitdir: ./.bare`n", (New-Object System.Text.UTF8Encoding($false)))
        Test-GitPointer -Path $p | Should -BeTrue
    }
    It 'is false when the file has a UTF-8 BOM' {
        $p = Join-Path $TestDrive 'bom.git'
        [System.IO.File]::WriteAllText($p, "gitdir: ./.bare`n", (New-Object System.Text.UTF8Encoding($true)))
        Test-GitPointer -Path $p | Should -BeFalse
    }
    It 'is false when the content is wrong' {
        $p = Join-Path $TestDrive 'wrong.git'
        [System.IO.File]::WriteAllText($p, "gitdir: ./elsewhere`n", (New-Object System.Text.UTF8Encoding($false)))
        Test-GitPointer -Path $p | Should -BeFalse
    }
    It 'is false when the path is a directory' {
        $p = Join-Path $TestDrive 'dir.git'; New-Item -ItemType Directory -Path $p | Out-Null
        Test-GitPointer -Path $p | Should -BeFalse
    }
    It 'is false when the path does not exist' {
        Test-GitPointer -Path (Join-Path $TestDrive 'missing.git') | Should -BeFalse
    }
}
