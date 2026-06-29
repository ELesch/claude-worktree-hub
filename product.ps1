<#
.SYNOPSIS
  View or append to the hub's product brief (PRODUCT.md) — the product thinking the hub-dx-product /
  hub-principal expert advisors ground their advice in. Edit PRODUCT.md directly for big changes; use
  -Append for quick, dated notes during development.
.EXAMPLE
  .\product.ps1 -Show
  .\product.ps1 -Append 'we are prioritizing speed over breadth for the MVP'
#>
[CmdletBinding()]
param(
    [switch]$Show,
    [string]$Append,
    [string]$Path        # override the brief path (default <hub>\PRODUCT.md); used by tests
)
$ErrorActionPreference = 'Stop'
if (-not $Path) {
    try { . (Join-Path $PSScriptRoot 'hub-config.ps1'); $hubRoot = $Hub }   # sets $Hub
    catch { $hubRoot = $PSScriptRoot }
    $Path = Join-Path $hubRoot 'PRODUCT.md'
}
if ($Append) {
    $stamp = (Get-Date).ToString('yyyy-MM-dd')
    if (-not (Test-Path $Path)) { Set-Content -Path $Path -Value "# Product Brief`n" }
    Add-Content -Path $Path -Value "- ($stamp) $Append"
    Write-Host "appended to $Path" -ForegroundColor Green
}
elseif ($Show) {
    if (Test-Path $Path) { Get-Content $Path -Raw }
    else { Write-Host "no PRODUCT.md yet at $Path — copy PRODUCT.example.md to PRODUCT.md and fill it in." -ForegroundColor Yellow }
}
else {
    Write-Host "usage: product.ps1 -Show | -Append '<note>' [-Path <PRODUCT.md>]" -ForegroundColor Cyan
}
