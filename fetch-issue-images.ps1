<#
.SYNOPSIS
    Download all image attachments from a (private) GitHub issue using gh auth.
.DESCRIPTION
    `gh issue view` returns the issue text and image URLs, but not the bytes; private-repo
    attachment URLs (github.com/user-attachments/assets/...) return 404 to unauthenticated
    requests. This fetches each one WITH your gh token (302 -> signed CDN URL) and saves it
    locally so a Claude Code session can Read it. Images go under .issue-images\ (in the hub,
    outside any worktree) unless -OutDir is given.

    For a worktree created with `new-worktree.ps1 -Issue <N>`, you usually don't need this -
    the full bundle (ISSUE.md + issue-assets\) is already in the worktree.
.EXAMPLE
    .\fetch-issue-images.ps1 -Issue 497
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][int]$Issue,
    [string]$Repo,   # defaults to $HubConfig.repo
    [string]$OutDir
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'hub-config.ps1')   # sets $Hub + $HubConfig
. (Join-Path $Hub 'hub-lib.ps1')

if (-not $Repo) { $Repo = $HubConfig.repo }
if (-not $OutDir) { $OutDir = Join-Path $Hub ".issue-images\issue-$Issue" }

$raw = & gh issue view $Issue --repo $Repo --json 'body,comments'
if ($LASTEXITCODE -ne 0) { throw "gh issue view failed for #$Issue (exit $LASTEXITCODE)." }
$j = $raw | ConvertFrom-Json
$text = $j.body
if ($j.comments) { $text += "`n" + (($j.comments | ForEach-Object { $_.body }) -join "`n") }

$urls = Get-IssueAttachmentUrls $text
if (-not $urls) { Write-Host "No image attachments found in issue #$Issue." -ForegroundColor Yellow; return }

$map = Save-IssueImages -Urls $urls -OutDir $OutDir
foreach ($m in $map) { Write-Host ("saved  {0,-22}  [{1}]" -f $m.Name, $m.ContentType) -ForegroundColor Green }

Write-Host ""
Write-Host "Downloaded $($map.Count) image(s) for issue #$Issue to:" -ForegroundColor Cyan
Write-Host "  $OutDir"
Write-Host "Read these files in the agent:" -ForegroundColor Cyan
$map | ForEach-Object { Write-Host "  $($_.File)" }
