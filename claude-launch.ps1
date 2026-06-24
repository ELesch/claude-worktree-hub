<#
  claude-launch.ps1 - bundled session launcher for the hub.
  Forwards ALL arguments straight to `claude`. If the user has a personal
  tab-color hook (~/.claude/hooks/claude-color.ps1) AND launch.tabColor is true,
  it delegates to that hook (Windows Terminal tab coloring); otherwise it runs
  `claude` directly. This removes any hard dependency on a per-user hook.
#>
[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments = $true)] $Rest)

. (Join-Path $PSScriptRoot 'hub-config.ps1')

$personalHook = Join-Path $env:USERPROFILE '.claude\hooks\claude-color.ps1'
if ($HubConfig.launch.tabColor -and (Test-Path $personalHook)) {
    & $personalHook @Rest
}
else {
    & claude @Rest
}
