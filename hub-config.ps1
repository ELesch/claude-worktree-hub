<#
  hub-config.ps1 - shared config loader for the claude-worktree-hub.
  Dot-source it FIRST from every hub script:  . (Join-Path $PSScriptRoot 'hub-config.ps1')
  After dot-sourcing, the caller has:
    $Hub        - the hub root (this file's directory, auto-derived)
    $HubConfig  - the parsed + defaulted config object
  and the function Get-LaunchFlags (launch flags string from config).
#>

# $PSScriptRoot here = the directory of hub-config.ps1 = the hub root (works at any path).
$Hub = $PSScriptRoot

function Get-HubConfig {
    param([string]$HubRoot = $PSScriptRoot)
    $cfgPath = Join-Path $HubRoot 'hub.config.json'
    if (-not (Test-Path $cfgPath)) {
        throw @"
No hub.config.json found at $cfgPath .
Bootstrap a target repo first:   .\init-hub.ps1 -CloneUrl https://github.com/owner/repo.git
or copy the template:            Copy-Item hub.config.example.json hub.config.json   (then edit it)
"@
    }
    try { $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json }
    catch { throw "hub.config.json is not valid JSON: $($_.Exception.Message)" }

    # --- defaults for optional fields ---
    if (-not $cfg.defaultBranch) { $cfg | Add-Member -NotePropertyName defaultBranch -NotePropertyValue 'main' -Force }
    if (-not $cfg.baseWorktree)  { $cfg | Add-Member -NotePropertyName baseWorktree  -NotePropertyValue 'main' -Force }
    if (-not $cfg.packageManager){ $cfg | Add-Member -NotePropertyName packageManager -NotePropertyValue 'pnpm' -Force }
    if (-not $cfg.installCmd)    { $cfg | Add-Member -NotePropertyName installCmd -NotePropertyValue "$($cfg.packageManager) install" -Force }
    if (-not $cfg.verifyCmd)     { $cfg | Add-Member -NotePropertyName verifyCmd  -NotePropertyValue "$($cfg.packageManager) run verify" -Force }
    if (-not $cfg.testCmd)       { $cfg | Add-Member -NotePropertyName testCmd    -NotePropertyValue "$($cfg.packageManager) test" -Force }
    if (-not $cfg.envFiles)      { $cfg | Add-Member -NotePropertyName envFiles   -NotePropertyValue @('.env') -Force }
    if ($null -eq $cfg.complexPromptPreamble) { $cfg | Add-Member -NotePropertyName complexPromptPreamble -NotePropertyValue '' -Force }
    if (-not $cfg.launch)   { $cfg | Add-Member -NotePropertyName launch   -NotePropertyValue ([pscustomobject]@{}) -Force }
    if (-not $cfg.launch.permissionMode) { $cfg.launch | Add-Member -NotePropertyName permissionMode -NotePropertyValue 'auto' -Force }
    if ($null -eq $cfg.launch.effort)    { $cfg.launch | Add-Member -NotePropertyName effort -NotePropertyValue 'max' -Force }
    if ($null -eq $cfg.launch.tabColor)  { $cfg.launch | Add-Member -NotePropertyName tabColor -NotePropertyValue $true -Force }
    if (-not $cfg.database) { $cfg | Add-Member -NotePropertyName database -NotePropertyValue ([pscustomobject]@{ enabled = $false }) -Force }

    # --- required fields ---
    if (-not $cfg.repo) { throw "hub.config.json is missing required field 'repo' (e.g. 'owner/repo')." }
    return $cfg
}

$HubConfig = Get-HubConfig -HubRoot $Hub

function Get-LaunchFlags {
    <# Build the claude-launch.ps1 flag string from config: permission mode + effort. #>
    $pm = $HubConfig.launch.permissionMode
    $flag = if ($pm -eq 'bypass') { '--dangerously-skip-permissions' } else { "--permission-mode $pm" }
    if ($HubConfig.launch.effort) { $flag += " --effort $($HubConfig.launch.effort)" }
    return $flag
}
