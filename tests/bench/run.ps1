# Benchmarks of BEAM.com on Windows, as tests/bench/run.sh: file sizes,
# start times and the workloads of tests/bench/bench.erl, for each
# variant in Dir (beam-emu.com, beam.com). The result is a Markdown table.
#
# Usage: tests/bench/run.ps1 -Dir DIR   (from the top of the repository)
param([string]$Dir = ".")
$ErrorActionPreference = "Stop"

# Windows runs an APE file as a PE executable: use an .exe name.
function Exe($Name) {
    $exe = Join-Path $Dir ($Name -replace '\.com$', '.exe')
    Copy-Item (Join-Path $Dir $Name) $exe -Force
    return (Resolve-Path $exe).Path
}

# The median of 10 runs, in milliseconds (Windows has no port programs,
# so bench.com cannot measure this itself).
function StartTime($Exe, [string[]]$Arguments) {
    $times = foreach ($i in 1..10) {
        (Measure-Command { & $Exe @Arguments | Out-Null }).TotalMilliseconds
    }
    return [int](($times | Sort-Object)[4])
}

$variants = @("beam-emu.com", "beam.com") | Where-Object { Test-Path (Join-Path $Dir $_) }
$results = @{}
foreach ($v in $variants) {
    $exe = Exe $v
    $prog = "bench." + ($v -replace '\.com$', '') + ".com"
    & $exe tests/bench/bench.erl -o (Join-Path $Dir $prog) | Out-Null
    $progExe = Exe $prog
    $r = [ordered]@{}
    $r["size_mb"] = "{0:N1}" -f ((Get-Item (Join-Path $Dir $v)).Length / 1MB)
    $r["program_mb"] = "{0:N1}" -f ((Get-Item (Join-Path $Dir $prog)).Length / 1MB)
    $r["start_version"] = StartTime $exe @("version")
    $r["start_program"] = StartTime $progExe @("none")
    foreach ($line in (& $progExe)) {
        if ($line -match '^bench (\S+) (\d+)') { $r[$Matches[1]] = $Matches[2] }
    }
    $results[$v] = $r
}

$labels = @{
    "size_mb" = "file size (MB)"; "program_mb" = "size of a program (MB)";
    "start_version" = "start: ``version`` (ms)"; "start_program" = "start: a program (ms)"
}
Write-Output ("| | " + ($variants -join " | ") + " |")
Write-Output ("|---|" + (($variants | ForEach-Object { "---:" }) -join "|") + "|")
foreach ($key in $results[$variants[0]].Keys) {
    $label = if ($labels.ContainsKey($key)) { $labels[$key] } else { "$key (ms)" }
    $row = foreach ($v in $variants) { $results[$v][$key] }
    Write-Output ("| $label | " + ($row -join " | ") + " |")
}
