<#
.SYNOPSIS
  Refresh THIS hub deployment's tracked tooling files from the pristine source clone.
.DESCRIPTION
  Run from inside the hub deployment you want to update. Overlays the TRACKED tooling files
  (git ls-files) from a source clone of ELesch/claude-worktree-hub onto this hub, skipping
  files that are content-identical (ignoring CRLF-only differences) and never touching
  gitignored runtime data or the per-deployment HUB-STATE.md.
.PARAMETER Source
  Path to a normal (non-bare) clone of ELesch/claude-worktree-hub. Default C:\mydev\claude-worktree-hub.
.PARAMETER DryRun
  Preview every action; write nothing to this deployment. Still refreshes the source (ff-only) unless -NoPull.
.PARAMETER NoPull
  Skip the source refresh; overlay the source's current checkout as-is.
.EXAMPLE
  .\update-hub.ps1 -DryRun
  .\update-hub.ps1
  .\update-hub.ps1 -Source D:\src\claude-worktree-hub -NoPull
#>
[CmdletBinding()]
param(
    [string]$Source = 'C:\mydev\claude-worktree-hub',
    [switch]$DryRun,
    [switch]$NoPull
)

# ---------- pure, unit-testable helpers (safe to dot-source) ----------

function ConvertTo-Crlf {
    <# Normalize any mix of CRLF/LF/CR line endings to CRLF. Idempotent. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    ($Text -replace "`r`n", "`n" -replace "`r", "`n") -replace "`n", "`r`n"
}

# ---------- main (skipped when the script is dot-sourced, e.g. by the tests) ----------

function Invoke-UpdateHub {
    throw 'update-hub.ps1: Invoke-UpdateHub not yet implemented (see plan Task 4).'
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-UpdateHub -Source $Source -Target $PSScriptRoot -DryRun:$DryRun -NoPull:$NoPull
}
