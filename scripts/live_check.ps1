<#
.SYNOPSIS
  Repeatable live check: finds sites whose expected extractor tier is broken.

.DESCRIPTION
  WARNING: this hits real sites. For every entry in live_check_sites.json it
  runs a real mida-cli download, and the browser capture tier may start a
  headless Chrome or Edge. Run it only when you mean to. Nothing in the repo
  or the test suite runs it.

  Needs a mida-cli built with the "extractor" result field (this repo's current source); an older
  CLI aborts the run after the first site with one message.

  The CLI result line names the extractor that produced the media. A site is
  OK only when ALL of these hold: exit code 0, last event is a download
  result, a non-empty output file exists in the site folder, ffprobe ran
  successfully and shows a video stream (audio stream for type audio), and
  the extractor equals the corpus "expect". ffprobe missing, failing or
  timing out is FAIL ("unverified streams"), never OK.

  Verdicts:
    OK        everything above holds
    FALLBACK  a result, but another extractor produced it: the expected tier is broken
    BLOCKED   exit code 5 (policy stop: login, bot check, DRM). Not a bug.
    FAIL      any other error (code and message shown), or unverified/missing output
    TIMEOUT   no result within -TimeoutSec; the process tree was killed

  A corpus entry may carry a "knownIssue" string (a documented breakage). Its
  FAIL, FALLBACK or TIMEOUT is shown but is not a regression.

  Exit code: 0 when there is no regression (FAIL, FALLBACK or TIMEOUT on an
  entry without knownIssue), else 1.

  Process handling: output goes to <id>.stdout.txt and <id>.stderr.txt in the run folder (no pipes); after
  every run the whole process tree is killed, also descendants of an already exited CLI, but only processes
  created after that site started. Every run makes a NEW folder run-<yyyyMMdd-HHmmss> inside -OutDir and
  works only inside it; the only things deleted are the site folder and logs this run created there. The
  report live-check-<yyyy-MM-dd>.md and .json go into the run folder. Windows PowerShell 5.1 compatible.

.PARAMETER Cli        Path to mida-cli.exe. Default: the installed one, else dist\windows.
.PARAMETER Only       Run only these corpus ids, for example -Only youtube,pinterest.
.PARAMETER TimeoutSec Per-site limit in seconds, 1 to 3600 (default 240).
.PARAMETER OutDir     Parent folder for run folders (default: mida-live-check under TEMP).
.PARAMETER Keep       Keep the downloaded files (default: delete each site folder after probing).
.PARAMETER DryRun     Validate the corpus file only. No downloads, no network, no browser.
#>
[CmdletBinding()]
param(
  [string]$Cli = '',
  [string[]]$Only = @(),
  [ValidateRange(1, 3600)][int]$TimeoutSec = 240,
  [string]$OutDir = '',
  [switch]$Keep,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ -ne '' })   # powershell -File passes a,b as one string
$repoRoot = Split-Path -Parent $PSScriptRoot
$corpusPath = Join-Path $PSScriptRoot 'live_check_sites.json'
$stamp = Get-Date -Format 'yyyy-MM-dd'
$script:staleCli = $false

function ConvertTo-ArgString([string[]]$Items) {
  # Always quote; only trailing backslashes need doubling. Args here never hold a double quote.
  ($Items | ForEach-Object { '"' + ($_ -replace '(\\+)$', '$1$1') + '"' }) -join ' '
}

function Get-ProcTable { @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Select-Object ProcessId, ParentProcessId, CreationDate) }

# Descendants of RootPid (walk ParentProcessId, which survives the parent's exit), created at or after Since
# so a reused PID can never be picked up. Adds pid -> CreationDate into $Tracked.
function Add-Descendants([int]$RootPid, [datetime]$Since, $Table, $Tracked) {
  $known = @{ $RootPid = $true }
  do {
    $added = $false
    foreach ($pr in $Table) {
      $procId = [int]$pr.ProcessId
      if ($known.ContainsKey([int]$pr.ParentProcessId) -and -not $known.ContainsKey($procId) -and $pr.CreationDate -ge $Since) {
        $known[$procId] = $true; $Tracked[$procId] = $pr.CreationDate; $added = $true
      }
    }
  } while ($added)
}

# Kills every tracked descendant that is still the same process (same PID and creation time), then the parent
# if this script still holds it. Never touches anything created before $Since. Errors are swallowed.
function Stop-Tree($Proc, [datetime]$Since, $Tracked) {
  $table = Get-ProcTable
  Add-Descendants $Proc.Id $Since $table $Tracked
  foreach ($procId in @($Tracked.Keys)) {
    $same = @($table | Where-Object { [int]$_.ProcessId -eq $procId -and $_.CreationDate -eq $Tracked[$procId] })
    if ($same.Count -gt 0) { try { Stop-Process -Id $procId -Force -ErrorAction Stop } catch { } }
  }
  try { if (-not $Proc.HasExited) { $Proc.Kill() } } catch { }
}

# Runs a tool without a shell. Output goes to FILES (never pipes), so a grandchild that inherits the handles
# cannot hang the run and stderr costs no memory; only the last 200 stdout lines are read. One deadline covers
# the process. Whatever the outcome, the process tree (including descendants of an already exited parent)
# is swept in the finally block.
function Invoke-Tool([string]$Exe, [string[]]$Arguments, [int]$Seconds, [string]$StdoutPath = '', [string]$StderrPath = '') {
  $temps = @()
  if ($StdoutPath -eq '') { $StdoutPath = [System.IO.Path]::GetTempFileName(); $temps += $StdoutPath }
  if ($StderrPath -eq '') { $StderrPath = [System.IO.Path]::GetTempFileName(); $temps += $StderrPath }
  $p = $null
  $tracked = @{}
  $since = Get-Date
  try {
    $p = Start-Process -FilePath $Exe -ArgumentList (ConvertTo-ArgString $Arguments) -PassThru -NoNewWindow `
      -RedirectStandardOutput $StdoutPath -RedirectStandardError $StderrPath
    $null = $p.Handle   # caches the handle so ExitCode is readable after exit
    $deadline = $since.AddSeconds($Seconds)
    $exited = $false
    while ($true) {
      $left = [int]($deadline - (Get-Date)).TotalMilliseconds
      if ($left -le 0) { break }
      if ($p.WaitForExit([Math]::Min(5000, $left))) { $exited = $true; break }
      Add-Descendants $p.Id $since (Get-ProcTable) $tracked   # remember children in case an intermediate exits
    }
    $text = ''
    $code = $null
    if ($exited) {
      $code = $p.ExitCode
      $text = (@(Get-Content -LiteralPath $StdoutPath -Tail 200 -Encoding UTF8 -ErrorAction SilentlyContinue)) -join "`n"
    }
    return [pscustomobject]@{ TimedOut = (-not $exited); ExitCode = $code; Out = $text }
  } finally {
    if ($null -ne $p) {
      try { Stop-Tree $p $since $tracked } catch { }
      try { $p.Dispose() } catch { }
    }
    foreach ($t in $temps) { Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue }
  }
}

# The contract: parse the LAST non-empty stdout line.
function Get-LastJson([string]$Text) {
  $lines = @($Text -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
  if ($lines.Count -eq 0) { return $null }
  try { return $lines[$lines.Count - 1] | ConvertFrom-Json } catch { return $null }
}

# CLI text is untrusted page data: one line, no control characters, no table breakers, truncated.
function Format-Cell([object]$Value, [int]$Max = 90) {
  if ($null -eq $Value) { return '' }
  $s = ([string]$Value) -replace '[\x00-\x1f\x7f]', ' ' -replace '[|`]', "'"
  $s = $s.Trim()
  if ($s.Length -gt $Max) { $s = $s.Substring(0, $Max - 3) + '...' }
  return $s
}

# ---- locate tools -------------------------------------------------------
if ($Cli -eq '') {
  $installed = 'C:\Program Files\MiDa\mida-cli.exe'
  if (Test-Path -LiteralPath $installed) { $Cli = $installed } else { $Cli = Join-Path $repoRoot 'dist\windows\mida-cli.exe' }
}
if (-not (Test-Path -LiteralPath $Cli)) { Write-Host "mida-cli not found: $Cli" -ForegroundColor Red; exit 1 }
$Cli = (Resolve-Path -LiteralPath $Cli).Path
$cliDir = Split-Path -Parent $Cli

$ffmpeg = Join-Path $cliDir 'ffmpeg.exe'
$ffprobe = $null
foreach ($candidate in @((Join-Path $cliDir 'ffprobe.exe'), (Join-Path $repoRoot 'windows_binaries\ffprobe.exe'))) {
  if (Test-Path -LiteralPath $candidate) { $ffprobe = $candidate; break }
}

# ---- known ids from the CLI (offline) -----------------------------------
$sitesRun = Invoke-Tool $Cli @('sites') 30
$sitesJson = Get-LastJson $sitesRun.Out
if ($sitesRun.TimedOut -or $sitesRun.ExitCode -ne 0 -or $null -eq $sitesJson -or $sitesJson.kind -ne 'sites') {
  Write-Host "Could not read 'sites' from $Cli" -ForegroundColor Red; exit 1
}
$knownTiers = @($sitesJson.native) + @($sitesJson.tiers)

# ---- validate the corpus ------------------------------------------------
$problems = New-Object System.Collections.Generic.List[string]
$corpus = @()
if (-not (Test-Path -LiteralPath $corpusPath)) {
  $problems.Add("corpus file missing: $corpusPath")
} else {
  try {
    $parsed = (Get-Content -LiteralPath $corpusPath -Raw -Encoding UTF8) | ConvertFrom-Json
    $corpus = @($parsed | ForEach-Object { $_ })   # piping unrolls the array on 5.1
  }
  catch { $problems.Add("corpus is not valid JSON: $($_.Exception.Message)") }
}
if ($problems.Count -eq 0 -and $corpus.Count -eq 0) { $problems.Add('corpus is empty') }
$seen = @{}
$n = 0
foreach ($site in $corpus) {
  $n++
  $label = "entry $n"
  $id = [string]$site.id
  # Becomes a folder and file name: short, lowercase, and not a Windows device name.
  if ($id -notmatch '^[a-z0-9][a-z0-9-]{0,39}$' -or $id -match '^(con|prn|aux|nul|com[1-9]|lpt[1-9])$') {
    $problems.Add("$label has a missing, unsafe or reserved id"); continue
  }
  $label = "'$id'"
  if ($seen.ContainsKey($id)) { $problems.Add("$label is duplicated") }
  $seen[$id] = $true
  $url = [string]$site.url
  $uri = $null
  if ($url -notmatch '^https://[^\s"]+$' -or -not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri)) {
    $problems.Add("$label url is not a plain https URL")
  }
  if ($knownTiers -notcontains [string]$site.expect) { $problems.Add("$label expects unknown tier '$($site.expect)' (see: mida-cli sites)") }
  $type = [string]$site.type
  if ($type -ne '' -and $type -ne 'video' -and $type -ne 'audio') { $problems.Add("$label type must be video or audio") }
  $issue = $site.PSObject.Properties['knownIssue']
  if ($null -ne $issue -and ($issue.Value -isnot [string] -or $issue.Value.Trim() -eq '')) { $problems.Add("$label knownIssue must be a non-empty string") }
}
foreach ($wanted in $Only) {
  if (-not $seen.ContainsKey($wanted)) { $problems.Add("-Only names an id that is not in the corpus: $wanted") }
}
if ($problems.Count -gt 0) {
  $problems | ForEach-Object { Write-Host "corpus problem: $_" -ForegroundColor Red }
  exit 1
}
$selected = @($corpus | Where-Object { $Only.Count -eq 0 -or $Only -contains $_.id })
if ($DryRun) {
  $withIssue = @($selected | Where-Object { $null -ne $_.PSObject.Properties['knownIssue'] }).Count
  Write-Host "Dry run OK: $($selected.Count) of $($corpus.Count) corpus entries valid ($withIssue with a knownIssue); $($knownTiers.Count) known tier ids from $Cli. Nothing was downloaded."
  exit 0
}

# ---- live run -----------------------------------------------------------
if ($OutDir -eq '') { $OutDir = Join-Path $env:TEMP 'mida-live-check' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
# A fresh run folder, never an existing one (no -Force: it must not exist yet).
$runDir = $null
for ($k = 0; $k -lt 50 -and $null -eq $runDir; $k++) {
  $name = 'run-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
  if ($k -gt 0) { $name += "-$k" }
  $candidate = Join-Path $OutDir $name
  if (-not (Test-Path -LiteralPath $candidate)) {
    New-Item -ItemType Directory -Path $candidate -ErrorAction Stop | Out-Null
    $runDir = $candidate
  }
}
if ($null -eq $runDir) { Write-Host "Could not create a fresh run folder in $OutDir" -ForegroundColor Red; exit 1 }
if ($null -eq $ffprobe) { Write-Host 'Warning: ffprobe not found next to the CLI or in windows_binaries; every site will be FAIL (unverified streams).' -ForegroundColor Yellow }
Write-Host "Live check: $($selected.Count) sites, CLI $Cli, run folder $runDir"

# Ok=false means the streams are unverified: never treated as a pass.
function Get-StreamTypes([string]$File) {
  if ($null -eq $ffprobe) { return [pscustomobject]@{ Ok = $false; Types = @(); Why = 'ffprobe not found' } }
  $probe = Invoke-Tool $ffprobe @('-v', 'error', '-show_entries', 'stream=codec_type', '-of', 'json', $File) 60
  if ($probe.TimedOut) { return [pscustomobject]@{ Ok = $false; Types = @(); Why = 'ffprobe timed out' } }
  if ($probe.ExitCode -ne 0) { return [pscustomobject]@{ Ok = $false; Types = @(); Why = "ffprobe exit $($probe.ExitCode)" } }
  $json = $null
  try { $json = $probe.Out | ConvertFrom-Json } catch { }
  if ($null -eq $json -or $null -eq $json.PSObject.Properties['streams']) {
    return [pscustomobject]@{ Ok = $false; Types = @(); Why = 'ffprobe output unreadable' }
  }
  $types = @($json.streams | Where-Object { $_ } | ForEach-Object { [string]$_.codec_type })
  return [pscustomobject]@{ Ok = $true; Types = $types; Why = '' }
}

# The file to probe: the reported path if it is a non-empty file inside the site folder; otherwise exactly one
# candidate (same leaf name ignoring case, else the single non-temp file). Zero or several: null.
function Resolve-OutputFile([string]$SiteDir, [string]$Reported) {
  try {
    $full = [System.IO.Path]::GetFullPath($Reported)
    if ($full.StartsWith($SiteDir + '\', [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $full -PathType Leaf)) {
      $item = Get-Item -LiteralPath $full
      if ($item.Length -gt 0) { return $item }
    }
  } catch { }
  $files = @(Get-ChildItem -LiteralPath $SiteDir -File -Recurse -ErrorAction SilentlyContinue | Where-Object {
      $_.Length -gt 0 -and $_.Name -notlike '*.part' -and $_.Name -notlike '.mida_tmp*' -and
      $_.Name -notlike '*.stdout.txt' -and $_.Name -notlike '*.stderr.txt' })
  $leaf = ''
  try { $leaf = [System.IO.Path]::GetFileName($Reported) } catch { }
  $named = @($files | Where-Object { $leaf -ne '' -and $_.Name -ieq $leaf })
  if ($named.Count -eq 1) { return $named[0] }
  if ($named.Count -gt 1) { return $null }
  if ($files.Count -eq 1) { return $files[0] }
  return $null
}

function Test-Site($site, [int]$index, [int]$total) {
  $siteDir = Join-Path $runDir $site.id
  $outLog = Join-Path $runDir ($site.id + '.stdout.txt')
  $errLog = Join-Path $runDir ($site.id + '.stderr.txt')
  $audio = ([string]$site.type -eq 'audio')
  $cliArgs = @('download', [string]$site.url, '--out', $siteDir, '--headless')
  if ($audio) { $cliArgs += @('--type', 'audio') } else { $cliArgs += @('--quality', '360') }
  if (Test-Path -LiteralPath $ffmpeg) { $cliArgs += @('--ffmpeg', $ffmpeg) }

  Write-Host ("[{0}/{1}] {2} (expect {3}) ..." -f $index, $total, $site.id, $site.expect)
  $clock = [System.Diagnostics.Stopwatch]::StartNew()
  $row = [ordered]@{
    Id = $site.id; Verdict = 'FAIL'; Expect = [string]$site.expect; Extractor = ''
    Streams = ''; Bytes = ''; Secs = 0; KnownIssue = (Format-Cell $site.knownIssue 140); Detail = ''
  }
  $created = $false
  try {
    New-Item -ItemType Directory -Path $siteDir | Out-Null   # no -Force: fresh by construction
    $created = $true
    $run = Invoke-Tool $Cli $cliArgs $TimeoutSec $outLog $errLog
    $last = $null
    if (-not $run.TimedOut) { $last = Get-LastJson $run.Out }
    if ($run.TimedOut) {
      $row.Verdict = 'TIMEOUT'; $row.Detail = "no result in $TimeoutSec s"
    } elseif ($null -eq $last) {
      $row.Detail = Format-Cell "exit $($run.ExitCode), no JSON result line"
    } elseif ($last.event -eq 'error') {
      $row.Detail = Format-Cell "$($last.code): $($last.message)"
      if ($run.ExitCode -eq 5) { $row.Verdict = 'BLOCKED' }
    } elseif ($last.event -ne 'result' -or $last.kind -ne 'download' -or $run.ExitCode -ne 0) {
      $row.Detail = Format-Cell "unexpected end: event $($last.event), kind $($last.kind), exit $($run.ExitCode)"
    } elseif ($last.PSObject.Properties.Name -notcontains 'extractor') {
      $script:staleCli = $true
      $row.Detail = 'CLI result has no extractor field (stale CLI)'
    } else {
      $row.Extractor = Format-Cell $last.extractor 30
      $file = Resolve-OutputFile $siteDir ([string]$last.output_path)
      if ($null -eq $file) {
        $row.Detail = 'output file not found or ambiguous'
      } else {
        $row.Bytes = [string]$file.Length
        $probe = Get-StreamTypes $file.FullName
        $needed = if ($audio) { 'audio' } else { 'video' }
        if (-not $probe.Ok) {
          $row.Detail = "unverified streams: $($probe.Why)"
        } else {
          $row.Streams = (@($probe.Types | Select-Object -Unique) -join '+')
          if ($probe.Types -notcontains $needed) {
            $row.Detail = "no $needed stream in the output"
          } elseif ($row.Extractor -eq '') {
            $row.Detail = 'CLI result reported no extractor id'
          } elseif ($row.Extractor -ne $row.Expect) {
            $row.Verdict = 'FALLBACK'; $row.Detail = "expected $($row.Expect), resolved by $($row.Extractor)"
          } else {
            $row.Verdict = 'OK'
            if ($row.KnownIssue -ne '') { $row.Detail = 'known issue now passes: review knownIssue' }
          }
        }
      }
    }
  } catch {
    $row.Verdict = 'FAIL'; $row.Detail = Format-Cell "script error: $($_.Exception.Message)"
  }
  $row.Secs = [math]::Round($clock.Elapsed.TotalSeconds, 1)
  # Delete only what this run created inside its own run folder: the site folder and the two log files.
  if (-not $Keep) {
    if ($created -and $siteDir.StartsWith($runDir + '\')) { Remove-Item -LiteralPath $siteDir -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $outLog, $errLog -Force -ErrorAction SilentlyContinue
  }
  return [pscustomobject]$row
}

$results = @()
$i = 0
foreach ($site in $selected) {
  $i++
  $results += Test-Site $site $i $selected.Count
  if ($script:staleCli) {
    Write-Host 'Aborted after the first stale result: this mida-cli does not report the "extractor" result field. Rebuild it from this repo (dart compile exe bin/mida_cli.dart -o dist\windows\mida-cli.exe) and pass -Cli.' -ForegroundColor Red
    exit 1
  }
}

# ---- report -------------------------------------------------------------
$regressions = @($results | Where-Object { $_.Verdict -in 'FAIL', 'FALLBACK', 'TIMEOUT' -and $_.KnownIssue -eq '' })
$counts = $results | Group-Object Verdict | Sort-Object Name
$summary = ($counts | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
$summary += "; regressions: $($regressions.Count)"
Write-Host ''
Write-Host ($results | Select-Object Id, Verdict, Expect, Extractor, Streams, Secs, @{ n = 'Known'; e = { if ($_.KnownIssue -ne '') { 'known' } else { '' } } }, Detail | Format-Table -AutoSize | Out-String -Width 220)
Write-Host "Summary: $summary"

$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine("# Live check $stamp")
[void]$md.AppendLine('')
[void]$md.AppendLine("CLI: ``$Cli``. Quality 360, headless. Summary: $summary.")
[void]$md.AppendLine('')
[void]$md.AppendLine('| Site | Verdict | Expect | Extractor | Streams | Bytes | Secs | Known issue | Detail |')
[void]$md.AppendLine('|---|---|---|---|---|---|---|---|---|')
foreach ($r in $results) {
  [void]$md.AppendLine("| $($r.Id) | $($r.Verdict) | $($r.Expect) | $($r.Extractor) | $($r.Streams) | $($r.Bytes) | $($r.Secs) | $($r.KnownIssue) | $(Format-Cell $r.Detail) |")
}
$utf8 = New-Object System.Text.UTF8Encoding $false
$mdPath = Join-Path $runDir "live-check-$stamp.md"
$jsonPath = Join-Path $runDir "live-check-$stamp.json"
[System.IO.File]::WriteAllText($mdPath, $md.ToString(), $utf8)
[System.IO.File]::WriteAllText($jsonPath, (ConvertTo-Json -InputObject @($results) -Depth 4), $utf8)
Write-Host "Report: $mdPath"
Write-Host "JSON:   $jsonPath"

if ($regressions.Count -gt 0) { exit 1 }
exit 0
