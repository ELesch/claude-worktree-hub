BeforeAll {
    $script:AgentsDir = Join-Path $PSScriptRoot '.claude/agents'
    $script:Personas  = 'hub-product-owner', 'hub-product-user', 'hub-product-maintenance'
}

Describe 'product-aware reviewer personas' {
    It 'has all three persona agent files' {
        foreach ($p in $Personas) {
            (Test-Path (Join-Path $AgentsDir "$p.md")) | Should -BeTrue -Because "$p.md must exist"
        }
    }

    It 'each persona has valid read-only frontmatter (name, tools, opus, description)' {
        foreach ($p in $Personas) {
            $c = Get-Content (Join-Path $AgentsDir "$p.md") -Raw
            $c | Should -Match "(?m)^name:\s*$p\s*$"
            $c | Should -Match "(?m)^tools:\s*Read,\s*Grep,\s*Glob\s*$"
            $c | Should -Match "(?m)^model:\s*opus\s*$"
            $c | Should -Match "(?m)^description:\s*\S"
        }
    }

    It 'each persona prompt has the required review output structure' {
        foreach ($p in $Personas) {
            $c = Get-Content (Join-Path $AgentsDir "$p.md") -Raw
            $c | Should -Match '\*\*Legitimacy:\*\*'
            $c | Should -Match '\*\*Necessity:\*\*'
            $c | Should -Match '\*\*Scope/effort:\*\*'
            $c | Should -Match '\*\*Recommendation:\*\*'
            $c | Should -Match '\*\*Also consult:\*\*'
        }
    }

    It 'each persona grounds in PRODUCT.md and calibrates by issue origin' {
        foreach ($p in $Personas) {
            $c = Get-Content (Join-Path $AgentsDir "$p.md") -Raw
            $c | Should -Match 'PRODUCT\.md'
            $c | Should -Match '(?i)origin'
        }
    }

    It 'personas match the hub-*.md provisioning glob (so worktrees receive them)' {
        $globbed = @(Get-ChildItem -Path $AgentsDir -Filter 'hub-*.md' -File).Name
        foreach ($p in $Personas) { $globbed | Should -Contain "$p.md" }
    }
}
