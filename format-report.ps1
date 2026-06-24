<#
.SYNOPSIS
    Render a 2-column "Step | Result" report as a nicely aligned Unicode box table.
.DESCRIPTION
    The single source of truth for the completion / merge reports every issue worktree prints, so they all
    look identical. Handles emoji display width (✅ ❌ ⚠️ are 2 cells wide but count as 1 char) so columns
    actually line up, and wraps long Result cells to a max width.

    Rows are "Step|Result" strings (first `|` splits; later `|` stay in the result). Pass via -Rows or pipe.
.PARAMETER Rows     One or more "Step|Result" strings (pipeline-friendly).
.PARAMETER Title    Optional heading printed above the table.
.PARAMETER Header1  Left column header (default "Step").
.PARAMETER Header2  Right column header (default "Result").
.PARAMETER MaxResultWidth  Wrap the Result column past this display width (default 70).
.EXAMPLE
    .\format-report.ps1 -Title 'Issue #42 — merge' -Rows `
      'CI/build gate|✅ pass ("Deployment has completed") — checked before merging',
      'Mergeable state|✅ MERGEABLE / CLEAN',
      'Merge|✅ Squash-merged as abc1234, confirmed on origin/<defaultBranch>'
.EXAMPLE
    Get-Content rows.txt | .\format-report.ps1
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline = $true)][string[]]$Rows,
    [string]$Title = '',
    [string]$Header1 = 'Step',
    [string]$Header2 = 'Result',
    [int]$MaxResultWidth = 70
)
begin {
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
    $acc = [System.Collections.Generic.List[string]]::new()
}
process { if ($Rows) { foreach ($r in $Rows) { $acc.Add([string]$r) } } }
end {
    # --- display width: emoji / CJK = 2 cells; variation selector + ZWJ = 0 ---
    function Get-Width([string]$s) {
        if (-not $s) { return 0 }
        $w = 0; $ch = $s.ToCharArray()
        for ($i = 0; $i -lt $ch.Length; $i++) {
            $c = [int]$ch[$i]
            if ($c -eq 0xFE0F -or $c -eq 0x200D) { continue }                       # VS16 / ZWJ -> zero width
            elseif ($c -ge 0xD800 -and $c -le 0xDBFF) { $w += 2; $i++ }             # surrogate pair (emoji) -> 2
            elseif (($c -ge 0x2600 -and $c -le 0x27BF) -or                          # ✅ ❌ ⚠ ▶ symbols/dingbats
                    ($c -ge 0x2B00 -and $c -le 0x2BFF) -or                          # 🔻⭐-ish arrows/stars
                    ($c -ge 0x1100 -and $c -le 0x115F) -or                          # Hangul Jamo
                    ($c -ge 0x2E80 -and $c -le 0xA4CF) -or                          # CJK
                    ($c -ge 0xAC00 -and $c -le 0xD7A3) -or                          # Hangul syllables
                    ($c -ge 0xF900 -and $c -le 0xFAFF) -or
                    ($c -ge 0xFF00 -and $c -le 0xFF60)) { $w += 2 }
            else { $w += 1 }
        }
        return $w
    }
    # --- word-wrap a string to a max DISPLAY width, returning lines ---
    function Wrap([string]$s, [int]$max) {
        if ((Get-Width $s) -le $max) { return , @($s) }
        $out = [System.Collections.Generic.List[string]]::new(); $cur = ''
        foreach ($word in ($s -split ' ')) {
            $try = if ($cur) { "$cur $word" } else { $word }
            if ((Get-Width $try) -le $max) { $cur = $try }
            else { if ($cur) { $out.Add($cur) }; $cur = $word }
        }
        if ($cur) { $out.Add($cur) }
        return , $out.ToArray()
    }
    function Pad([string]$s, [int]$w) { return $s + (' ' * [Math]::Max(0, $w - (Get-Width $s))) }

    # --- build wrapped cell model ---
    $model = foreach ($r in $acc) {
        $p = $r -split '\|', 2
        $step = $p[0].Trim(); $res = if ($p.Count -gt 1) { $p[1].Trim() } else { '' }
        [pscustomobject]@{ Step = $step; ResLines = (Wrap $res $MaxResultWidth) }
    }
    $w1 = (@($Header1) + ($model.Step) | ForEach-Object { Get-Width $_ } | Measure-Object -Maximum).Maximum
    $w2 = (@($Header2) + ($model.ResLines | ForEach-Object { $_ }) | ForEach-Object { Get-Width $_ } | Measure-Object -Maximum).Maximum

    $h = '─'; $bar1 = $h * ($w1 + 2); $bar2 = $h * ($w2 + 2)
    $top = "┌$bar1┬$bar2┐"; $mid = "├$bar1┼$bar2┤"; $bot = "└$bar1┴$bar2┘"
    $lines = [System.Collections.Generic.List[string]]::new()
    if ($Title) { $lines.Add($Title); $lines.Add('') }
    $lines.Add($top)
    $lines.Add("│ $(Pad $Header1 $w1) │ $(Pad $Header2 $w2) │")
    $lines.Add($mid)
    for ($i = 0; $i -lt $model.Count; $i++) {
        $m = $model[$i]
        for ($j = 0; $j -lt $m.ResLines.Count; $j++) {
            $left = if ($j -eq 0) { $m.Step } else { '' }
            $lines.Add("│ $(Pad $left $w1) │ $(Pad $m.ResLines[$j] $w2) │")
        }
        if ($i -lt $model.Count - 1) { $lines.Add($mid) }
    }
    $lines.Add($bot)
    $lines -join "`n"
}
