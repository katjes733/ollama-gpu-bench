<#
.SYNOPSIS
    Benchmarks Ollama token generation speed alongside GPU power/clock/thermal
    telemetry, so you can compare MSI Afterburner profiles on a tokens/sec-per-watt
    basis rather than raw speed alone.

.DESCRIPTION
    Sends a fixed prompt to a local Ollama instance with a fixed output length
    (num_predict), so every run generates the same number of tokens. While the
    request is in flight, it polls nvidia-smi in the background to capture
    power draw, SM clock, memory clock, and temperature. At the end it prints
    tokens/sec, average watts, peak watts, and tokens/sec-per-watt, and appends
    a row to a CSV log so you can track results across multiple Afterburner
    profiles / OC settings over time.

.PARAMETER Model
    Ollama model name to benchmark (must already be pulled). Default: llama3:8b

.PARAMETER Prompt
    Prompt text to send. Keep it fixed across all your comparison runs.

.PARAMETER NumPredict
    Fixed number of tokens to generate. 256-512 is usually enough to reach
    steady-state power draw. Default: 300

.PARAMETER Runs
    Number of repetitions to average. Default: 3

.PARAMETER ProfileLabel
    A short label for the Afterburner profile you're currently testing
    (e.g. "Ollama-Efficient", "Gaming-OC"). Recorded in the CSV log so you
    can compare profiles later.

.PARAMETER OllamaHost
    Base URL of the Ollama API. Default: http://localhost:11434

.PARAMETER LogPath
    CSV file to append results to. Default: .\ollama-gpu-bench-log.csv

.PARAMETER LogPerRun
    Also append a row per individual run to the CSV, not just the summary
    (AVG) row. Off by default.

.PARAMETER TempLimitC
    The temperature limit (C) currently set in MSI Afterburner for this
    profile. Not exposed by nvidia-smi or by Afterburner's own profile file,
    so pass it manually. Recorded in the CSV. Default: 0 (unset).

.PARAMETER CurveEdited
    Pass this switch if the current Afterburner profile has a custom
    voltage/frequency curve applied, rather than a flat core/mem offset.
    Recorded in the CSV. There's no reliable way to detect this
    automatically, so it's manual.

.PARAMETER SoakMode
    Instead of -Runs short bursts, run one continuous soak: repeated
    back-to-back generations (same fixed prompt, no cooldown) for
    -SoakDurationMinutes, with the GPU telemetry poller running
    uninterrupted for the whole duration. A short burst can pass cleanly and
    still fail later under sustained load, so use this to validate a profile
    meant to run unattended for hours. Off by default.

.PARAMETER SoakDurationMinutes
    How long to run the soak for, in minutes. Only used with -SoakMode.
    Default: 15

.PARAMETER SoakCheckIntervalSec
    How often (seconds) to print a status heartbeat during the soak
    (elapsed time, generations so far, failures so far, running avg tok/s).
    Corruption/crash checks always run after every generation regardless of
    this interval - this only controls progress-reporting cadence. Only used
    with -SoakMode. Default: 30

.PARAMETER SoakLogPath
    CSV file to append soak-test summaries to. Kept separate from -LogPath
    by default since the soak summary has a different shape (min/avg/max
    telemetry, failure list, PASS/FAIL verdict) than the short-burst rows.
    Only used with -SoakMode. Default: .\ollama-gpu-bench-soak-log.csv

.EXAMPLE
    .\ollama-gpu-bench.ps1 -Model "llama3:8b" -ProfileLabel "Ollama-Efficient" -Runs 3

.EXAMPLE
    .\ollama-gpu-bench.ps1 -Model "qwen2.5:14b" -NumPredict 400 -ProfileLabel "Gaming-OC-forced"

.EXAMPLE
    .\ollama-gpu-bench.ps1 -Model "qwen3.6:27b" -ProfileLabel "Gaming-OC" -NumPredict 4000 -SoakMode -SoakDurationMinutes 120
#>

param(
    [string]$Model = "llama3:8b",
    [string]$Prompt = "Explain how transformer attention works, including the role of queries, keys, and values, in about 400 words.",
    [int]$NumPredict = 300,
    [int]$Runs = 3,
    [string]$ProfileLabel = "unlabeled",
    [string]$OllamaHost = "http://localhost:11434",
    [string]$LogPath = ".\ollama-gpu-bench-log.csv",
    [switch]$LogPerRun,
    [int]$TempLimitC = 0,
    [switch]$CurveEdited,
    [switch]$SoakMode,
    [int]$SoakDurationMinutes = 15,
    [int]$SoakCheckIntervalSec = 30,
    [string]$SoakLogPath = ".\ollama-gpu-bench-soak-log.csv"
)

$ErrorActionPreference = "Stop"

function Test-NvidiaSmi {
    try {
        $null = & nvidia-smi --query-gpu=name --format=csv,noheader 2>$null
        return $true
    } catch {
        return $false
    }
}

function Start-GpuPoll {
    param([string]$OutFile)

    # Poll every ~500ms in a background job. CSV columns: timestamp, power.draw (W),
    # clocks.sm (MHz), clocks.mem (MHz), temperature.gpu (C), utilization.gpu (%)
    $job = Start-Job -ScriptBlock {
        param($OutFile)
        "timestamp,power_w,sm_clock_mhz,mem_clock_mhz,temp_c,util_pct" | Out-File -FilePath $OutFile -Encoding utf8
        while ($true) {
            $line = & nvidia-smi --query-gpu=power.draw,clocks.sm,clocks.mem,temperature.gpu,utilization.gpu `
                --format=csv,noheader,nounits 2>$null
            if ($line) {
                $ts = Get-Date -Format "o"
                "$ts,$line" | Out-File -FilePath $OutFile -Append -Encoding utf8
            }
            Start-Sleep -Milliseconds 500
        }
    } -ArgumentList $OutFile
    return $job
}

function Get-GpuOcState {
    # Power limit is a driver-level value Afterburner sets directly, so
    # nvidia-smi reads it back regardless of which tool applied it.
    # (clocks.max.sm/clocks.max.memory were tried here too, but they report a
    # fixed hardware ceiling that doesn't move with Afterburner's core/mem
    # offsets - useless for telling runs apart. Use Get-AfterburnerOcOffsets
    # for the actual applied core/mem clock offsets instead.)
    try {
        $csv = & nvidia-smi --query-gpu=power.limit,power.default_limit --format=csv,noheader,nounits 2>$null
        if (-not $csv) { return $null }
        $parts = $csv -split ',\s*'
        $powerLimitW   = [double]$parts[0]
        $powerDefaultW = [double]$parts[1]
        return [PSCustomObject]@{
            PowerLimitW   = $powerLimitW
            PowerLimitPct = if ($powerDefaultW -gt 0) { [math]::Round(($powerLimitW / $powerDefaultW) * 100, 1) } else { 0 }
        }
    } catch {
        return $null
    }
}

function Get-AfterburnerOcOffsets {
    # MSI Afterburner mirrors the live-applied core/mem clock offsets into a
    # per-GPU profile file's [Startup] section, keyed by PCI bus number in the
    # filename. Values are in 1/1000 MHz. This is an undocumented, version-
    # specific format - if it can't be found or parsed, callers should fall
    # back gracefully rather than fail the whole run.
    try {
        $profilesDir = Join-Path ${env:ProgramFiles(x86)} "MSI Afterburner\Profiles"
        if (-not (Test-Path $profilesDir)) { return $null }

        $busHex = (& nvidia-smi --query-gpu=pci.bus --format=csv,noheader 2>$null).Trim()
        if (-not $busHex) { return $null }
        $busDec = [Convert]::ToInt32($busHex, 16)

        $cfgFile = Get-ChildItem -Path $profilesDir -Filter "*BUS_$busDec&DEV_0&FN_0.cfg" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $cfgFile) { return $null }

        $lines = Get-Content -Path $cfgFile.FullName
        $startupIdx = [array]::IndexOf($lines, "[Startup]")
        if ($startupIdx -lt 0) { return $null }

        $sectionLines = @()
        for ($j = $startupIdx + 1; $j -lt $lines.Count -and $lines[$j] -notmatch '^\['; $j++) {
            $sectionLines += $lines[$j]
        }

        $coreLine = $sectionLines | Where-Object { $_ -match '^CoreClkBoost=(.+)$' } | Select-Object -First 1
        $memLine  = $sectionLines | Where-Object { $_ -match '^MemClkBoost=(.+)$' } | Select-Object -First 1
        if (-not $coreLine -or -not $memLine) { return $null }

        $coreRaw = ($coreLine -split '=', 2)[1].Trim()
        $memRaw  = ($memLine -split '=', 2)[1].Trim()
        if ([string]::IsNullOrWhiteSpace($coreRaw) -or [string]::IsNullOrWhiteSpace($memRaw)) { return $null }

        return [PSCustomObject]@{
            CoreClockMHz = [math]::Round([double]$coreRaw / 1000, 0)
            MemClockMHz  = [math]::Round([double]$memRaw / 1000, 0)
        }
    } catch {
        return $null
    }
}

function Stop-GpuPoll {
    param($Job)
    Stop-Job -Job $Job -ErrorAction SilentlyContinue | Out-Null
    Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue | Out-Null
}

function Test-OutputCorruption {
    param(
        [string]$Text,
        [int]$ExpectedTokens,
        [int]$ActualTokens
    )

    $issues = @()

    if ([string]::IsNullOrWhiteSpace($Text)) {
        $issues += "EMPTY_OUTPUT"
        return $issues
    }

    # Unicode replacement character (U+FFFD) shows up when the GPU/driver returns
    # garbled bytes that can't be decoded as valid UTF-8 text.
    if ($Text -match [char]0xFFFD) {
        $issues += "REPLACEMENT_CHARS"
    }

    # Long runs of a single repeated character (not whitespace) - a common symptom
    # of a corrupted compute result (e.g. "aaaaaaaaaaaaaaaa...") rather than a crash.
    if ($Text -match '(.)\1{24,}') {
        $issues += "REPEATED_CHAR_RUN"
    }

    # Long runs of a repeated short token/word - another garbling pattern where the
    # model gets stuck emitting the same fragment over and over.
    if ($Text -match '(\b\S{1,12}\b)(\s+\1){14,}') {
        $issues += "REPEATED_TOKEN_LOOP"
    }

    # Non-printable control characters outside of normal whitespace (tab/newline/CR)
    # are another sign of corrupted decode output.
    if ($Text -match '[\x00-\x08\x0B\x0C\x0E-\x1F]') {
        $issues += "CONTROL_CHARACTERS"
    }

    # Truncation: got noticeably fewer tokens than requested without the model
    # naturally stopping (Ollama reports 'done_reason' separately; here we just
    # flag a big shortfall as suspicious - could be a timeout or crash mid-stream).
    if ($ExpectedTokens -gt 0 -and $ActualTokens -gt 0) {
        $shortfallPct = 1 - ($ActualTokens / $ExpectedTokens)
        if ($shortfallPct -gt 0.5) {
            $issues += "POSSIBLE_TRUNCATION"
        }
    }

    return $issues
}

function Invoke-OllamaGenerate {
    param(
        [string]$OllamaHost,
        [string]$Model,
        [string]$Prompt,
        [int]$NumPredict
    )

    $body = @{
        model   = $Model
        prompt  = $Prompt
        stream  = $false
        options = @{
            num_predict = $NumPredict
            # Fix sampling params so run-to-run variance comes from the GPU,
            # not from the model wandering into a shorter/longer response.
            temperature = 0.0
        }
    } | ConvertTo-Json -Depth 5

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        # Explicit timeout: if the GPU has hung/crashed, the request will otherwise
        # block forever instead of failing so we can log it and move on.
        $response = Invoke-RestMethod -Uri "$OllamaHost/api/generate" -Method Post `
            -Body $body -ContentType "application/json" -TimeoutSec 180
    } catch {
        $sw.Stop()
        return [PSCustomObject]@{
            WallClockSec = [math]::Round($sw.Elapsed.TotalSeconds, 2)
            EvalCount    = 0
            TokensPerSec = 0
            ResponseText = ""
            Crashed      = $true
            ErrorMessage = $_.Exception.Message
            Issues       = @("REQUEST_FAILED_OR_TIMED_OUT")
        }
    }

    $sw.Stop()

    # eval_count / eval_duration reflect actual token-generation (excludes prompt
    # processing time, which is what we want for a generation-speed benchmark).
    $evalCount    = $response.eval_count
    $evalDuration = $response.eval_duration   # nanoseconds
    $tokensPerSec = if ($evalDuration -gt 0) { [math]::Round(($evalCount / ($evalDuration / 1e9)), 2) } else { 0 }

    $issues = Test-OutputCorruption -Text $response.response -ExpectedTokens $NumPredict -ActualTokens $evalCount

    return [PSCustomObject]@{
        WallClockSec = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        EvalCount    = $evalCount
        TokensPerSec = $tokensPerSec
        ResponseText = $response.response
        Crashed      = $false
        ErrorMessage = ""
        Issues       = $issues
    }
}

if (-not (Test-NvidiaSmi)) {
    Write-Error "nvidia-smi not found or not working. Make sure NVIDIA drivers are installed and nvidia-smi is on PATH."
    exit 1
}

$gpuOc = Get-GpuOcState
if (-not $gpuOc) {
    Write-Warning "Could not read power limit from nvidia-smi; that column will be logged as 0."
    $gpuOc = [PSCustomObject]@{ PowerLimitW = 0; PowerLimitPct = 0 }
}

$ocOffsets = Get-AfterburnerOcOffsets
if (-not $ocOffsets) {
    Write-Warning "Could not read core/mem clock offsets from Afterburner's profile file; those columns will be logged as 0."
    $ocOffsets = [PSCustomObject]@{ CoreClockMHz = 0; MemClockMHz = 0 }
}

if ($SoakMode) {

Write-Host "=== Ollama GPU Soak Test ===" -ForegroundColor Cyan
Write-Host "Model:        $Model"
Write-Host "Profile tag:  $ProfileLabel"
Write-Host "num_predict:  $NumPredict (per generation)"
Write-Host "Duration:     $SoakDurationMinutes minute(s)"
Write-Host "Heartbeat:    every $SoakCheckIntervalSec sec"
Write-Host ("Power limit:  {0} W ({1}% of default)" -f $gpuOc.PowerLimitW, $gpuOc.PowerLimitPct)
Write-Host ("Clock offset: Core {0} MHz / Mem {1} MHz" -f $ocOffsets.CoreClockMHz, $ocOffsets.MemClockMHz)
Write-Host ("Temp limit:   {0} C{1}" -f $TempLimitC, $(if ($TempLimitC -eq 0) { " (not set)" } else { "" }))
Write-Host ("Curve edited: {0}" -f $CurveEdited.IsPresent)
Write-Host ""

$pollFile = [System.IO.Path]::GetTempFileName()
$job = Start-GpuPoll -OutFile $pollFile

# Small warm-up pause so the poll job is definitely running before we fire the first request
Start-Sleep -Milliseconds 300

$soakStart = Get-Date
$soakDeadline = $soakStart.AddMinutes($SoakDurationMinutes)
$genIndex = 0
$genResults = @()
$failures = @()
$lastHeartbeat = $soakStart

try {
    while ((Get-Date) -lt $soakDeadline) {
        $genIndex++
        $elapsed = (Get-Date) - $soakStart
        $elapsedStr = "{0}m{1}s" -f [int]$elapsed.TotalMinutes, $elapsed.Seconds

        $genResult = Invoke-OllamaGenerate -OllamaHost $OllamaHost -Model $Model -Prompt $Prompt -NumPredict $NumPredict
        $genResult | Add-Member -NotePropertyName GenIndex -NotePropertyValue $genIndex
        $genResult | Add-Member -NotePropertyName ElapsedSoak -NotePropertyValue $elapsedStr
        $genResults += $genResult

        # Corruption/crash check runs after every single generation - not just at the
        # end - so a failure at minute 11 is caught and timestamped, not averaged away.
        if ($genResult.Crashed -or $genResult.Issues.Count -gt 0) {
            $failType = if ($genResult.Crashed) { "CRASH" } else { "CORRUPTION" }
            $detail   = if ($genResult.Crashed) { $genResult.ErrorMessage } else { $genResult.Issues -join "|" }
            Write-Host ("  *** FAILURE at $elapsedStr into soak (gen #$genIndex): $failType - $detail ***") -ForegroundColor Red

            # Reuse the same suspect-output dump convention as short-burst mode.
            $badOutFile = "ollama-bench-suspect-output_{0}_soak_gen{1}.txt" -f ($ProfileLabel -replace '[^\w\-]', '_'), $genIndex
            $genResult.ResponseText | Out-File -FilePath $badOutFile -Encoding utf8
            Write-Host "  Suspect output saved to: $badOutFile" -ForegroundColor Red

            $failures += [PSCustomObject]@{
                GenIndex    = $genIndex
                Timestamp   = (Get-Date -Format "o")
                ElapsedSoak = $elapsedStr
                Type        = $failType
                Detail      = $detail
                OutputFile  = $badOutFile
            }
            # Deliberately not aborting: keep running so we learn whether the profile
            # recovers, fails repeatedly, or gets worse - the soak is flagged FAIL either way.
        } else {
            Write-Host ("  gen #{0,-4} [{1}]  tok/s: {2,7}   tokens: {3,5}" -f $genIndex, $elapsedStr, $genResult.TokensPerSec, $genResult.EvalCount)
        }

        if (((Get-Date) - $lastHeartbeat).TotalSeconds -ge $SoakCheckIntervalSec) {
            $lastHeartbeat = Get-Date
            $soFar = $genResults | Where-Object { -not $_.Crashed }
            $avgSoFar = if ($soFar.Count -gt 0) { [math]::Round(($soFar | Measure-Object -Property TokensPerSec -Average).Average, 2) } else { 0 }
            Write-Host ("  --- heartbeat: {0} elapsed, {1} generation(s) done, {2} failure(s), avg tok/s so far: {3} ---" -f $elapsedStr, $genIndex, $failures.Count, $avgSoFar) -ForegroundColor DarkCyan
        }
    }
} finally {
    Stop-GpuPoll -Job $job
}

$soakActualMinutes = [math]::Round(((Get-Date) - $soakStart).TotalMinutes, 2)

$telemetry = Import-Csv -Path $pollFile
Remove-Item -Path $pollFile -Force -ErrorAction SilentlyContinue

if ($telemetry.Count -eq 0) {
    Write-Warning "No GPU telemetry captured during the soak; telemetry columns will be logged as 0."
    $minWatts = 0; $avgWatts = 0; $maxWatts = 0
    $minSm = 0; $avgSm = 0; $maxSm = 0
    $minMem = 0; $avgMem = 0; $maxMem = 0
    $minTemp = 0; $avgTemp = 0; $maxTemp = 0
} else {
    $wattsStats = $telemetry | Measure-Object -Property power_w -Average -Minimum -Maximum
    $smStats    = $telemetry | Measure-Object -Property sm_clock_mhz -Average -Minimum -Maximum
    $memStats   = $telemetry | Measure-Object -Property mem_clock_mhz -Average -Minimum -Maximum
    $tempStats  = $telemetry | Measure-Object -Property temp_c -Average -Minimum -Maximum

    $minWatts = [math]::Round($wattsStats.Minimum, 1); $avgWatts = [math]::Round($wattsStats.Average, 1); $maxWatts = [math]::Round($wattsStats.Maximum, 1)
    $minSm    = [math]::Round($smStats.Minimum, 0);    $avgSm    = [math]::Round($smStats.Average, 0);    $maxSm    = [math]::Round($smStats.Maximum, 0)
    $minMem   = [math]::Round($memStats.Minimum, 0);   $avgMem   = [math]::Round($memStats.Average, 0);   $maxMem   = [math]::Round($memStats.Maximum, 0)
    $minTemp  = [math]::Round($tempStats.Minimum, 1);  $avgTemp  = [math]::Round($tempStats.Average, 1);  $maxTemp  = [math]::Round($tempStats.Maximum, 1)
}

$successfulGens = $genResults | Where-Object { -not $_.Crashed }
if ($successfulGens.Count -gt 0) {
    $tokStats = $successfulGens | Measure-Object -Property TokensPerSec -Average -Minimum -Maximum
    $minTok = $tokStats.Minimum
    $avgTok = [math]::Round($tokStats.Average, 2)
    $maxTok = $tokStats.Maximum
} else {
    $minTok = 0; $avgTok = 0; $maxTok = 0
}
$totalTokens = ($genResults | Measure-Object -Property EvalCount -Sum).Sum

$verdict = if ($failures.Count -gt 0) { "FAIL" } else { "PASS" }

Write-Host ""
Write-Host "=== Soak Test Summary ===" -ForegroundColor Cyan
Write-Host ("Duration:         {0} min target / {1} min actual" -f $SoakDurationMinutes, $soakActualMinutes)
Write-Host ("Generations run:  {0}" -f $genIndex)
Write-Host ("Total tokens:     {0}" -f $totalTokens)
Write-Host ("Tokens/sec:       min {0} / avg {1} / max {2}" -f $minTok, $avgTok, $maxTok)
Write-Host ("Watts:            min {0} / avg {1} / max {2}" -f $minWatts, $avgWatts, $maxWatts)
Write-Host ("SM clock (MHz):   min {0} / avg {1} / max {2}" -f $minSm, $avgSm, $maxSm)
Write-Host ("Mem clock (MHz):  min {0} / avg {1} / max {2}" -f $minMem, $avgMem, $maxMem)
Write-Host ("Temp (C):         min {0} / avg {1} / max {2}" -f $minTemp, $avgTemp, $maxTemp)
Write-Host ("Failures:         {0}" -f $failures.Count)
foreach ($f in $failures) {
    Write-Host ("  - gen #{0} at {1} into soak ({2}): {3}" -f $f.GenIndex, $f.ElapsedSoak, $f.Type, $f.Detail) -ForegroundColor Red
}

Write-Host ""
if ($verdict -eq "PASS") {
    Write-Host "VERDICT: PASS - no crashes or output corruption during the soak." -ForegroundColor Green
} else {
    Write-Host "VERDICT: FAIL - at least one crash/corruption event occurred. Do not trust this profile unattended." -ForegroundColor Red
}

$soakSummary = [PSCustomObject]@{
    Timestamp         = (Get-Date -Format "o")
    Profile           = $ProfileLabel
    PowerLimitW       = $gpuOc.PowerLimitW
    PowerLimitPct     = $gpuOc.PowerLimitPct
    CoreClockMHz      = $ocOffsets.CoreClockMHz
    MemClockMHz       = $ocOffsets.MemClockMHz
    TempLimitC        = $TempLimitC
    CurveEdited       = $CurveEdited.IsPresent
    Model             = $Model
    NumPredictPerGen  = $NumPredict
    SoakMinutesTarget = $SoakDurationMinutes
    SoakMinutesActual = $soakActualMinutes
    GenerationsRun    = $genIndex
    TotalTokens       = $totalTokens
    MinTokensPerSec   = $minTok
    AvgTokensPerSec   = $avgTok
    MaxTokensPerSec   = $maxTok
    MinWatts          = $minWatts
    AvgWatts          = $avgWatts
    MaxWatts          = $maxWatts
    MinSmClockMHz     = $minSm
    AvgSmClockMHz     = $avgSm
    MaxSmClockMHz     = $maxSm
    MinMemClockMHz    = $minMem
    AvgMemClockMHz    = $avgMem
    MaxMemClockMHz    = $maxMem
    MinTempC          = $minTemp
    AvgTempC          = $avgTemp
    MaxTempC          = $maxTemp
    FailureCount      = $failures.Count
    FailureDetails    = if ($failures.Count -gt 0) { ($failures | ForEach-Object { "gen#$($_.GenIndex)@$($_.ElapsedSoak):$($_.Type)" }) -join "|" } else { "" }
    Verdict           = $verdict
}

$soakLogExists = Test-Path $SoakLogPath
if (-not $soakLogExists) {
    $soakSummary | Export-Csv -Path $SoakLogPath -NoTypeInformation
} else {
    $soakSummary | Export-Csv -Path $SoakLogPath -NoTypeInformation -Append
}

Write-Host ""
Write-Host "Soak summary appended to: $SoakLogPath" -ForegroundColor DarkGray

} else {

Write-Host "=== Ollama GPU Benchmark ===" -ForegroundColor Cyan
Write-Host "Model:        $Model"
Write-Host "Profile tag:  $ProfileLabel"
Write-Host "num_predict:  $NumPredict"
Write-Host "Runs:         $Runs"
Write-Host ("Power limit:  {0} W ({1}% of default)" -f $gpuOc.PowerLimitW, $gpuOc.PowerLimitPct)
Write-Host ("Clock offset: Core {0} MHz / Mem {1} MHz" -f $ocOffsets.CoreClockMHz, $ocOffsets.MemClockMHz)
Write-Host ("Temp limit:   {0} C{1}" -f $TempLimitC, $(if ($TempLimitC -eq 0) { " (not set)" } else { "" }))
Write-Host ("Curve edited: {0}" -f $CurveEdited.IsPresent)
Write-Host ""

$results = @()

for ($i = 1; $i -le $Runs; $i++) {
    Write-Host "Run $i of $Runs..." -ForegroundColor Yellow

    $pollFile = [System.IO.Path]::GetTempFileName()
    $job = Start-GpuPoll -OutFile $pollFile

    # Small warm-up pause so the poll job is definitely running before we fire the request
    Start-Sleep -Milliseconds 300

    try {
        $genResult = Invoke-OllamaGenerate -OllamaHost $OllamaHost -Model $Model -Prompt $Prompt -NumPredict $NumPredict
    } finally {
        Start-Sleep -Milliseconds 300
        Stop-GpuPoll -Job $job
    }

    if ($genResult.Crashed) {
        Write-Host "  *** REQUEST FAILED / TIMED OUT: $($genResult.ErrorMessage) ***" -ForegroundColor Red
        Write-Host "  Treat this as a potential crash/instability signal for the current profile." -ForegroundColor Red
    } elseif ($genResult.Issues.Count -gt 0) {
        Write-Host "  *** OUTPUT ISSUES DETECTED: $($genResult.Issues -join ', ') ***" -ForegroundColor Red
        # Dump the raw suspect output to a file so you can inspect it manually.
        $badOutFile = "ollama-bench-suspect-output_{0}_run{1}.txt" -f ($ProfileLabel -replace '[^\w\-]', '_'), $i
        $genResult.ResponseText | Out-File -FilePath $badOutFile -Encoding utf8
        Write-Host "  Suspect output saved to: $badOutFile" -ForegroundColor Red
    }

    $telemetry = Import-Csv -Path $pollFile
    Remove-Item -Path $pollFile -Force -ErrorAction SilentlyContinue

    if ($telemetry.Count -eq 0) {
        Write-Warning "No GPU telemetry captured for run $i; skipping power stats for this run."
        $avgWatts = 0
        $peakWatts = 0
        $avgSmClock = 0
        $avgMemClock = 0
        $avgTemp = 0
    } else {
        $avgWatts   = [math]::Round(($telemetry | Measure-Object -Property power_w -Average).Average, 1)
        $peakWatts  = [math]::Round(($telemetry | Measure-Object -Property power_w -Maximum).Maximum, 1)
        $avgSmClock = [math]::Round(($telemetry | Measure-Object -Property sm_clock_mhz -Average).Average, 0)
        $avgMemClock= [math]::Round(($telemetry | Measure-Object -Property mem_clock_mhz -Average).Average, 0)
        $avgTemp    = [math]::Round(($telemetry | Measure-Object -Property temp_c -Average).Average, 1)
    }

    $tokensPerWatt = if ($avgWatts -gt 0) { [math]::Round($genResult.TokensPerSec / $avgWatts, 4) } else { 0 }

    $row = [PSCustomObject]@{
        Timestamp      = (Get-Date -Format "o")
        Profile        = $ProfileLabel
        PowerLimitW    = $gpuOc.PowerLimitW
        PowerLimitPct  = $gpuOc.PowerLimitPct
        CoreClockMHz   = $ocOffsets.CoreClockMHz
        MemClockMHz    = $ocOffsets.MemClockMHz
        TempLimitC     = $TempLimitC
        CurveEdited    = $CurveEdited.IsPresent
        Model          = $Model
        Run            = $i
        TokensPerSec   = $genResult.TokensPerSec
        EvalTokens     = $genResult.EvalCount
        WallClockSec   = $genResult.WallClockSec
        AvgWatts       = $avgWatts
        PeakWatts      = $peakWatts
        AvgSmClockMHz  = $avgSmClock
        AvgMemClockMHz = $avgMemClock
        AvgTempC       = $avgTemp
        TokensPerWatt  = $tokensPerWatt
        Crashed        = $genResult.Crashed
        Issues         = if ($genResult.Issues.Count -gt 0) { $genResult.Issues -join "|" } else { "" }
    }

    $results += $row

    Write-Host ("  tok/s: {0,7}   avg W: {1,6}   peak W: {2,6}   sm: {3,5} MHz   mem: {4,5} MHz   temp: {5,4}C   tok/s/W: {6}" -f `
        $row.TokensPerSec, $row.AvgWatts, $row.PeakWatts, $row.AvgSmClockMHz, $row.AvgMemClockMHz, $row.AvgTempC, $row.TokensPerWatt)

    # Brief cool-down between runs so one run's thermal state doesn't bleed into the next
    if ($i -lt $Runs) { Start-Sleep -Seconds 5 }
}

Write-Host ""
Write-Host "=== Summary (avg of $Runs runs) ===" -ForegroundColor Cyan

$summary = [PSCustomObject]@{
    Timestamp      = (Get-Date -Format "o")
    Profile        = $ProfileLabel
    PowerLimitW    = $gpuOc.PowerLimitW
    PowerLimitPct  = $gpuOc.PowerLimitPct
    CoreClockMHz   = $ocOffsets.CoreClockMHz
    MemClockMHz    = $ocOffsets.MemClockMHz
    TempLimitC     = $TempLimitC
    CurveEdited    = $CurveEdited.IsPresent
    Model          = $Model
    Run            = "AVG"
    TokensPerSec   = [math]::Round(($results | Measure-Object -Property TokensPerSec -Average).Average, 2)
    EvalTokens     = [math]::Round(($results | Measure-Object -Property EvalTokens -Average).Average, 0)
    WallClockSec   = [math]::Round(($results | Measure-Object -Property WallClockSec -Average).Average, 2)
    AvgWatts       = [math]::Round(($results | Measure-Object -Property AvgWatts -Average).Average, 1)
    PeakWatts      = [math]::Round(($results | Measure-Object -Property PeakWatts -Maximum).Maximum, 1)
    AvgSmClockMHz  = [math]::Round(($results | Measure-Object -Property AvgSmClockMHz -Average).Average, 0)
    AvgMemClockMHz = [math]::Round(($results | Measure-Object -Property AvgMemClockMHz -Average).Average, 0)
    AvgTempC       = [math]::Round(($results | Measure-Object -Property AvgTempC -Average).Average, 1)
    TokensPerWatt  = 0
    Crashed        = $false
    Issues         = ""
}
$summary.TokensPerWatt = if ($summary.AvgWatts -gt 0) { [math]::Round($summary.TokensPerSec / $summary.AvgWatts, 4) } else { 0 }

$crashCount = ($results | Where-Object { $_.Crashed }).Count
$issueCount = ($results | Where-Object { -not $_.Crashed -and $_.Issues -ne "" }).Count
$summary.Issues = if ($crashCount -gt 0 -or $issueCount -gt 0) { "$crashCount crash(es), $issueCount run(s) with output issues" } else { "clean" }

$results + $summary | Format-Table Run, PowerLimitW, PowerLimitPct, CoreClockMHz, MemClockMHz, TempLimitC, CurveEdited, TokensPerSec, AvgWatts, PeakWatts, AvgSmClockMHz, AvgMemClockMHz, AvgTempC, TokensPerWatt, Crashed, Issues -AutoSize

Write-Host ""
Write-Host ("Profile '{0}': {1} tok/s @ {2} W avg  ->  {3} tok/s per Watt" -f `
    $summary.Profile, $summary.TokensPerSec, $summary.AvgWatts, $summary.TokensPerWatt) -ForegroundColor Green

if ($crashCount -gt 0 -or $issueCount -gt 0) {
    Write-Host ("STABILITY WARNING: {0} crash(es)/timeout(s) and {1} run(s) with suspect output on this profile." -f $crashCount, $issueCount) -ForegroundColor Red
    Write-Host "Back off this OC/power step before trusting it as a daily-driver profile." -ForegroundColor Red
} else {
    Write-Host "No crashes or output corruption detected across all runs." -ForegroundColor Green
}

# Append to CSV log (creates file with header if it doesn't exist yet). By
# default only the summary (AVG) row is logged; pass -LogPerRun to also keep
# a row per individual run.
$logExists = Test-Path $LogPath
$rowsToLog = if ($LogPerRun) { $results + $summary } else { @($summary) }
if (-not $logExists) {
    $rowsToLog | Export-Csv -Path $LogPath -NoTypeInformation
} else {
    $rowsToLog | Export-Csv -Path $LogPath -NoTypeInformation -Append
}

Write-Host ""
Write-Host "Results appended to: $LogPath" -ForegroundColor DarkGray
Write-Host "Re-run this script with -ProfileLabel after each Afterburner profile change to build a comparison table."

}