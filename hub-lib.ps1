<#
  hub-lib.ps1 - shared helpers for the claude-worktree-hub.
  Dot-source it:  . "$PSScriptRoot\hub-lib.ps1"
  Functions: ConvertTo-Slug, Get-IssueAttachmentUrls, Save-IssueImages,
             ConvertTo-LocalLinks, Save-IssueBundle, Add-HubExclude, Copy-HubExperts
  Requires $HubConfig in scope: dot-source hub-config.ps1 before hub-lib.ps1.
#>

function ConvertTo-Slug {
    param([string]$Text, [int]$MaxWords = 6, [int]$MaxLen = 48)
    if (-not $Text) { $Text = '' }
    $s = $Text.ToLowerInvariant()
    $s = [regex]::Replace($s, '[^a-z0-9]+', '-').Trim('-')
    $words = $s.Split('-') | Where-Object { $_ } | Select-Object -First $MaxWords
    $s = ($words -join '-')
    if ($s.Length -gt $MaxLen) { $s = $s.Substring(0, $MaxLen).Trim('-') }
    if (-not $s) { $s = 'issue' }
    return $s
}

function Get-IssueAttachmentUrls {
    param([string]$Text)
    if (-not $Text) { return @() }
    $patterns = @(
        'https://github\.com/user-attachments/assets/[0-9a-fA-F-]+',
        'https://(?:private-)?user-images\.githubusercontent\.com/[^\s")''>]+'
    )
    $urls = @()
    foreach ($p in $patterns) { $urls += [regex]::Matches($Text, $p) | ForEach-Object { $_.Value } }
    return ($urls | Select-Object -Unique)
}

function Save-IssueImages {
    param([Parameter(Mandatory)][string[]]$Urls, [Parameter(Mandatory)][string]$OutDir)
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $tok = (gh auth token).Trim()
    $map = @()
    $i = 0
    foreach ($u in $Urls) {
        $i++
        $tmp = Join-Path $OutDir "img-$i"
        # -f fails on HTTP >=400; -L follows the github.com 302 to the signed CDN URL
        # (curl drops the auth header on the cross-host hop, which is correct).
        $ct = (& curl.exe -fsSL -H "Authorization: Bearer $tok" -o $tmp -w "%{content_type}" $u)
        if ($LASTEXITCODE -ne 0) {
            Write-Host "    WARNING: failed to download $u (curl exit $LASTEXITCODE)" -ForegroundColor Yellow
            if (Test-Path $tmp) { Remove-Item $tmp -Force }
            continue
        }
        $ext = switch -Regex ($ct) {
            'png' { '.png'; break }
            'jpe?g' { '.jpg'; break }
            'gif' { '.gif'; break }
            'webp' { '.webp'; break }
            'svg' { '.svg'; break }
            default { '.bin' }
        }
        $final = "$tmp$ext"
        Move-Item -Force $tmp $final
        $map += [pscustomobject]@{ Url = $u; File = $final; Name = (Split-Path $final -Leaf); ContentType = $ct }
    }
    return $map
}

function ConvertTo-LocalLinks {
    param([string]$Text, $Map, [string]$Subdir)
    if (-not $Text) { return $Text }
    foreach ($m in $Map) { $Text = $Text.Replace($m.Url, "$Subdir/$($m.Name)") }
    return $Text
}

function Add-HubExclude {
    param([Parameter(Mandatory)][string]$CommonGitDir, [Parameter(Mandatory)][string[]]$Patterns)
    $infoDir = Join-Path $CommonGitDir 'info'
    New-Item -ItemType Directory -Force -Path $infoDir | Out-Null
    $excl = Join-Path $infoDir 'exclude'
    $existing = if (Test-Path $excl) { Get-Content $excl } else { @() }
    $toAdd = $Patterns | Where-Object { $existing -notcontains $_ }
    if ($toAdd) {
        Add-Content -Path $excl -Value (@('', '# worktree hub: per-worktree issue bundles (never commit)') + $toAdd)
    }
}

function Save-IssueBundle {
    <# Fetch an issue's full resources into $Dest: ISSUE.md (text + comments + metadata,
       with image links rewritten to local paths) and an issue-assets\ folder of images.
       Returns an object with IssueMd, AssetsDir, Images, Title, Number. #>
    # Requires $HubConfig in scope: dot-source hub-config.ps1 before hub-lib.ps1.
    param(
        [Parameter(Mandatory)][int]$Issue,
        [Parameter(Mandatory)][string]$Dest,
        [string]$Repo,   # defaults to $HubConfig.repo when called from a hub script
        [string]$AssetsSubdir = "issue-assets",
        [string]$FileName = "ISSUE.md"   # grouped waves pass ISSUE-<n>.md; single-issue default unchanged
    )
    if (-not $Repo) { $Repo = $HubConfig.repo }
    $fields = 'number,title,state,body,author,assignees,labels,milestone,url,createdAt,updatedAt,comments'
    $raw = & gh issue view $Issue --repo $Repo --json $fields
    if ($LASTEXITCODE -ne 0) { throw "gh issue view failed for #$Issue (exit $LASTEXITCODE)." }
    $j = $raw | ConvertFrom-Json

    $allText = $j.body
    if ($j.comments) { $allText += "`n" + (($j.comments | ForEach-Object { $_.body }) -join "`n") }
    $urls = Get-IssueAttachmentUrls $allText

    $map = @()
    if ($urls) { $map = Save-IssueImages -Urls $urls -OutDir (Join-Path $Dest $AssetsSubdir) }

    $nl = [Environment]::NewLine
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Issue #$($j.number): $($j.title)")
    $lines.Add("")
    $lines.Add("- State: $($j.state)")
    $lines.Add("- Author: $($j.author.login)")
    if ($j.assignees) { $lines.Add("- Assignees: " + (($j.assignees | ForEach-Object { $_.login }) -join ', ')) }
    if ($j.labels) { $lines.Add("- Labels: " + (($j.labels | ForEach-Object { $_.name }) -join ', ')) }
    if ($j.milestone) { $lines.Add("- Milestone: $($j.milestone.title)") }
    $lines.Add("- URL: $($j.url)")
    $lines.Add("- Created: $($j.createdAt)   Updated: $($j.updatedAt)")
    $lines.Add("")
    $lines.Add("> Local copy fetched by the worktree hub. Git-excluded; safe to read, do not commit.")
    $lines.Add("")
    if ($map) {
        $lines.Add("## Attachments (downloaded locally - Read these to see the screenshots)")
        foreach ($m in $map) { $lines.Add("- ``$AssetsSubdir/$($m.Name)``  [$($m.ContentType)]") }
        $lines.Add("")
    }
    $lines.Add("## Description")
    $lines.Add("")
    $lines.Add((ConvertTo-LocalLinks $j.body $map $AssetsSubdir))
    $lines.Add("")
    if ($j.comments -and $j.comments.Count) {
        $lines.Add("## Comments ($($j.comments.Count))")
        $lines.Add("")
        foreach ($c in $j.comments) {
            $lines.Add("### $($c.author.login) - $($c.createdAt)")
            $lines.Add("")
            $lines.Add((ConvertTo-LocalLinks $c.body $map $AssetsSubdir))
            $lines.Add("")
        }
    }

    $issueMd = Join-Path $Dest $FileName
    [System.IO.File]::WriteAllText($issueMd, ($lines -join $nl), (New-Object System.Text.UTF8Encoding($false)))

    return [pscustomobject]@{
        IssueMd   = $issueMd
        AssetsDir = (Join-Path $Dest $AssetsSubdir)
        Images    = $map
        Title     = $j.title
        Number    = $j.number
    }
}

function Save-IssuesIndex {
    <# Write the grouped-wave cover sheet ISSUES.md into $Dest: the member issues (each with its own
       ISSUE-<n>.md brief), the shared owned paths (why these are one wave), and any advisory siblings to
       fold in opportunistically. Pure (no gh / no $HubConfig) so it is unit-testable. Returns the path. #>
    param(
        [Parameter(Mandatory)][string]$Dest,
        [Parameter(Mandatory)][object[]]$Members,   # objects with .Number .Title .Origin .Severity
        [string[]]$SharedPaths = @(),
        [object[]]$Siblings = @(),                   # objects with .Type .Id .Sev .Why .Title
        [string]$Area = ''
    )
    $nl = [Environment]::NewLine
    $lines = New-Object System.Collections.Generic.List[string]
    $nums = @($Members | ForEach-Object { $_.Number })
    $lines.Add("# Grouped wave: issues #" + ($nums -join ', #'))
    $lines.Add("")
    if ($Area) { $lines.Add("- Area: $Area") }
    $lines.Add("- Members: " + $Members.Count)
    $lines.Add("")
    $lines.Add("> Local cover sheet fetched by the worktree hub. Git-excluded; safe to read, do not commit.")
    $lines.Add("> You own ALL of these issues in this one worktree: implement each, then open ONE PR whose")
    $lines.Add("> body carries one ``Fixes #<n>`` line per member. Read each ``ISSUE-<n>.md`` for the full brief.")
    $lines.Add("")
    $lines.Add("## Members")
    $lines.Add("")
    foreach ($m in $Members) {
        $lines.Add("- **#$($m.Number)** [$($m.Origin) - $($m.Severity)] $($m.Title)  (brief: ``ISSUE-$($m.Number).md``)")
    }
    $lines.Add("")
    if ($SharedPaths.Count) {
        $lines.Add("## Shared owned files (why these are one wave)")
        $lines.Add("")
        foreach ($p in $SharedPaths) { $lines.Add("- ``$p``") }
        $lines.Add("")
    }
    if ($Siblings.Count) {
        $lines.Add("## Advisory siblings (proposed findings/recs - verify before bundling; fold in only if cheap & in scope)")
        $lines.Add("")
        foreach ($s in $Siblings) { $lines.Add("- $($s.Type) #$($s.Id) [$($s.Sev)] ($($s.Why)) - $($s.Title)") }
        $lines.Add("")
    }
    $issuesMd = Join-Path $Dest "ISSUES.md"
    [System.IO.File]::WriteAllText($issuesMd, ($lines -join $nl), (New-Object System.Text.UTF8Encoding($false)))
    return $issuesMd
}

function Copy-HubExperts {
    # Copy the hub's hub-*.md advisory agents into a worktree's .claude\agents (creating it).
    # Returns the number copied (0 if the hub has none). Leaves any app-owned agents untouched.
    param([Parameter(Mandatory)][string]$Hub, [Parameter(Mandatory)][string]$WtPath)
    $src = Join-Path $Hub '.claude\agents'
    $agents = @(Get-ChildItem -Path $src -Filter 'hub-*.md' -File -ErrorAction SilentlyContinue)
    if (-not $agents) { return 0 }
    $dest = Join-Path $WtPath '.claude\agents'
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    foreach ($a in $agents) { Copy-Item $a.FullName (Join-Path $dest $a.Name) -Force }
    return $agents.Count
}
