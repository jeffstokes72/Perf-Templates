<#
.SYNOPSIS
    Professional Tanium & VMware Performance Utility.
    Version: 12.7

.DESCRIPTION
    - Fixes: Handles filenames with special chars ( ) [ ] by using a safe processing buffer.
    - Fixes: Normalizes BLG input with relog.exe (better Process V2 compatibility).
    - Fixes: Recursively discovers BLG files under Source and supports duplicate names.
    - Performance: Uses up to 8 CPUs by default for parallel BLG processing.
    - Fixes: De-duplicates overlapping Process and Process V2 interval metrics.
    - Fixes: Skips 0-byte (empty) files automatically.
    - Diagnostics: Contention Score, K/U Ratio, Memory Slope, Priority.
#>

param(
    [switch]$WorkerMode,
    [string]$WorkerFilePath,
    [string]$WorkerResolvedRelogExe,
    [int]$MaxProcessingCpus = 8
)

# --- CONFIGURATION ---
$BaseDir      = "C:\TaniumPerformanceAnalysis"
$SourceDir    = "$BaseDir\Source"
$ReportDir    = "$BaseDir\Reports"
$TempDir      = "$BaseDir\Temp"
$RelogExe     = "$env:SystemRoot\System32\relog.exe"
$LogFile      = "$BaseDir\Analysis_Log.txt"
$SummaryFile  = Join-Path $ReportDir "Fleet_Contention_Summary.csv"

# Ensure Directory Structure
foreach ($path in @($BaseDir, $SourceDir, $ReportDir, $TempDir)) {
    if (!(Test-Path $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
}

# Initialize Log
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
if (-not $WorkerMode) {
    Add-Content -Path $LogFile -Value "`n[$timestamp] === Starting Analysis Run (v12.7) ==="
}

$masterSummary = New-Object System.Collections.Generic.List[PSCustomObject]

# --- HELPERS ---

function Write-Log ($Message, $Level = "INFO") {
    $time = Get-Date -Format "HH:mm:ss"
    $logMsg = "[$time] [$Level] $Message"
    Add-Content -Path $LogFile -Value $logMsg
    switch ($Level) {
        "ERROR" { Write-Host $logMsg -ForegroundColor Red }
        "WARN" { Write-Host $logMsg -ForegroundColor Yellow }
        "INFO" { Write-Host $logMsg -ForegroundColor Gray }
        "SUCCESS" { Write-Host $logMsg -ForegroundColor Green }
    }
}

function ConvertTo-SafeDouble ($Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return 0.0 }
    try { return [double]$Value } catch { return 0.0 }
}

function Get-CounterSampleValueOrNull ($Sample) {
    if ($null -eq $Sample) { return $null }

    # Invalid samples throw when CookedValue is accessed; skip those only.
    try { return ConvertTo-SafeDouble $Sample.CookedValue } catch { return $null }
}

function ConvertTo-SafeFileToken ($Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return "Unknown" }
    $safe = $Value -replace "[^A-Za-z0-9._-]+", "_"
    $safe = $safe.Trim("_")
    if ([string]::IsNullOrWhiteSpace($safe)) { return "Unknown" }
    return $safe
}

function Get-RelativeSourcePath ($FullPath) {
    if ([string]::IsNullOrWhiteSpace($FullPath)) { return "Unknown" }
    if ($FullPath.StartsWith($SourceDir, [System.StringComparison]::OrdinalIgnoreCase)) {
        return ($FullPath.Substring($SourceDir.Length) -replace "^[\\/]+", "")
    }
    return $FullPath
}

function Get-ProcessCounterSourceRank ($CounterPath) {
    if ($CounterPath -like "*\Process V2(*)*") { return 2 }
    if ($CounterPath -like "*\Process(*)*") { return 1 }
    return 0
}

function Get-ContentionScore ($listA, $listB) {
    if ($listA.Count -lt 2 -or $listB.Count -lt 2) { return 0.0 }
    $avgA = ($listA | Measure-Object -Average).Average
    $avgB = ($listB | Measure-Object -Average).Average
    $sumNum = 0; $sumDenA = 0; $sumDenB = 0
    for ($i = 0; $i -lt $listA.Count; $i++) {
        $diffA = $listA[$i] - $avgA
        $diffB = $listB[$i] - $avgB
        $sumNum += ($diffA * $diffB)
        $sumDenA += [Math]::Pow($diffA, 2)
        $sumDenB += [Math]::Pow($diffB, 2)
    }
    $denominator = [Math]::Sqrt($sumDenA * $sumDenB)
    if ($denominator -eq 0) {
        return 0
    } else {
        return [Math]::Round(($sumNum / $denominator), 3)
    }
}

function Get-TrendSlope ($yValues) {
    $n = $yValues.Count
    if ($n -lt 10) { return 0 }
    $sumX = 0; $sumY = 0; $sumXY = 0; $sumX2 = 0
    for ($x = 0; $x -lt $n; $x++) {
        $y = [double]$yValues[$x]
        $sumX += $x
        $sumY += $y
        $sumXY += ($x * $y)
        $sumX2 += ($x * $x)
    }
    $denominator = ($n * $sumX2) - ($sumX * $sumX)
    if ($denominator -eq 0) {
        return 0
    } else {
        return (($n * $sumXY) - ($sumX * $sumY)) / $denominator
    }
}

function Resolve-RelogExePath ($PreferredPath) {
    if (-not [string]::IsNullOrWhiteSpace($PreferredPath) -and (Test-Path -LiteralPath $PreferredPath)) {
        return $PreferredPath
    }
    $relogCmd = Get-Command "relog.exe" -ErrorAction SilentlyContinue
    if ($relogCmd) { return $relogCmd.Source }
    return $null
}

function Invoke-RelogConversion ($InputPath, $OutputPath) {
    $counterFile = Join-Path $TempDir ("relog_counters_{0}.txt" -f [Guid]::NewGuid().ToString("N"))
    $counterList = @(
        "\VM Processor(_Total)\CPU stolen time",
        "\PhysicalDisk(_Total)\Disk Transfers/sec",
        "\Process(*)\% Processor Time",
        "\Process(*)\% Privileged Time",
        "\Process(*)\% User Time",
        "\Process(*)\Private Bytes",
        "\Process(*)\Priority Base",
        "\Process V2(*)\% Processor Time",
        "\Process V2(*)\% Privileged Time",
        "\Process V2(*)\% User Time",
        "\Process V2(*)\Private Bytes",
        "\Process V2(*)\Priority Base"
    )

    try {
        $counterList | Set-Content -Path $counterFile -Encoding ASCII

        $relogOutput = & $script:ResolvedRelogExe $InputPath -cf $counterFile -f bin -o $OutputPath 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $OutputPath)) {
            Write-Log "  -> relog filtered conversion failed (exit $exitCode). Retrying without counter filter." "WARN"
            $relogOutput = & $script:ResolvedRelogExe $InputPath -f bin -o $OutputPath 2>&1
            $exitCode = $LASTEXITCODE
        }

        if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $OutputPath)) {
            $relogMessage = (($relogOutput | Select-Object -First 5) -join " ").Trim()
            Write-Log "  -> relog conversion failed (exit $exitCode). $relogMessage" "ERROR"
            return $false
        }

        if ((Get-Item -LiteralPath $OutputPath).Length -eq 0) {
            Write-Log "  -> relog conversion produced an empty output file." "ERROR"
            return $false
        }

        return $true
    } catch {
        Write-Log "  -> relog conversion failed unexpectedly. $($_.Exception.Message)" "ERROR"
        return $false
    } finally {
        Remove-Item -LiteralPath $counterFile -Force -ErrorAction SilentlyContinue
    }
}

function Complete-WorkerJob ($completedJob, $pendingJobs, $masterSummary) {
    $jobOutput = @()
    try {
        $jobOutput = @(Receive-Job -Job $completedJob -ErrorAction SilentlyContinue -ErrorVariable jobErrors)
    } catch {
        Write-Log "Worker job '$($completedJob.Name)' failed while receiving results. $($_.Exception.Message)" "ERROR"
    }

    if ($jobErrors -and $jobErrors.Count -gt 0) {
        Write-Log "Worker job '$($completedJob.Name)' encountered errors during execution. $(($jobErrors | Select-Object -First 1).Exception.Message)" "ERROR"
    }

    foreach ($entry in $jobOutput) {
        if ($null -ne $entry -and $entry.PSObject.Properties["HostName"]) {
            $masterSummary.Add([PSCustomObject]$entry)
        }
    }

    if ($completedJob.State -eq "Failed") {
        $reason = $null
        if ($completedJob.ChildJobs -and $completedJob.ChildJobs[0].JobStateInfo.Reason) {
            $reason = $completedJob.ChildJobs[0].JobStateInfo.Reason.Message
        }
        if ([string]::IsNullOrWhiteSpace($reason)) { $reason = "Unknown worker failure." }
        Write-Log "Worker job '$($completedJob.Name)' failed. $reason" "ERROR"
    }

    Remove-Job -Job $completedJob -Force -ErrorAction SilentlyContinue
    for ($i = $pendingJobs.Count - 1; $i -ge 0; $i--) {
        if ($pendingJobs[$i].Id -eq $completedJob.Id) {
            $pendingJobs.RemoveAt($i)
            break
        }
    }
}

# --- STAGE 1: PROCESSING BLG FILES ---
if ($WorkerMode -and -not [string]::IsNullOrWhiteSpace($WorkerResolvedRelogExe) -and (Test-Path -LiteralPath $WorkerResolvedRelogExe)) {
    $script:ResolvedRelogExe = $WorkerResolvedRelogExe
} else {
    $script:ResolvedRelogExe = Resolve-RelogExePath $RelogExe
}
if (-not $script:ResolvedRelogExe) {
    Write-Log "relog.exe was not found. Install Windows Performance tools or ensure relog is in PATH." "ERROR"
    exit 1
}

$blgFiles = @()
if ($WorkerMode) {
    if ([string]::IsNullOrWhiteSpace($WorkerFilePath) -or -not (Test-Path -LiteralPath $WorkerFilePath)) {
        Write-Log "Worker file path was not provided or does not exist: $WorkerFilePath" "ERROR"
        exit 1
    }
    $blgFiles = @(Get-Item -LiteralPath $WorkerFilePath -ErrorAction Stop)
} else {
    Write-Log "Scanning $SourceDir for BLG files..." "INFO"
    Write-Log "Using relog executable: $script:ResolvedRelogExe" "INFO"

    $blgFiles = Get-ChildItem -Path $SourceDir -Filter "*.blg" -File -Recurse | Sort-Object FullName
    if ($blgFiles.Count -eq 0) { Write-Log "No .blg files found!" "ERROR"; exit }

    $blgDirs = $blgFiles | Select-Object -ExpandProperty DirectoryName -Unique
    Write-Log "Discovered $($blgFiles.Count) BLG file(s) across $($blgDirs.Count) source folder(s)." "INFO"

    $availableCpuCount = [Math]::Max(1, [Environment]::ProcessorCount)
    $workerCount = [Math]::Max(1, [Math]::Min($MaxProcessingCpus, $availableCpuCount))
    Write-Log "Data processing concurrency: up to $workerCount CPU worker(s)." "INFO"

    if ($workerCount -gt 1 -and $blgFiles.Count -gt 1) {
        $pendingJobs = New-Object System.Collections.Generic.List[System.Management.Automation.Job]
        $scriptPath = $PSCommandPath
        if ([string]::IsNullOrWhiteSpace($scriptPath)) { $scriptPath = $MyInvocation.MyCommand.Path }

        foreach ($file in $blgFiles) {
            while ($pendingJobs.Count -ge $workerCount) {
                $completedJob = Wait-Job -Job $pendingJobs.ToArray() -Any -Timeout 5
                if (-not $completedJob) { continue }

                Complete-WorkerJob $completedJob $pendingJobs $masterSummary
            }

            $jobName = "BLG_{0}_{1}" -f (ConvertTo-SafeFileToken (Get-RelativeSourcePath $file.FullName)), ([Guid]::NewGuid().ToString("N").Substring(0, 8))
            $job = Start-Job -Name $jobName -ScriptBlock {
                param($workerScriptPath, $workerFilePath, $workerResolvedRelogExe, $workerMaxProcessingCpus)
                & $workerScriptPath -WorkerMode -WorkerFilePath $workerFilePath -WorkerResolvedRelogExe $workerResolvedRelogExe -MaxProcessingCpus $workerMaxProcessingCpus
            } -ArgumentList @($scriptPath, $file.FullName, $script:ResolvedRelogExe, $workerCount)
            $pendingJobs.Add($job)
        }

        while ($pendingJobs.Count -gt 0) {
            $completedJob = Wait-Job -Job $pendingJobs.ToArray() -Any
            if (-not $completedJob) { continue }

            Complete-WorkerJob $completedJob $pendingJobs $masterSummary
        }

        $masterSummary | Export-Csv $SummaryFile -NoTypeInformation
        Write-Log "Analysis Complete. Reports located in: $ReportDir" "SUCCESS"
        exit
    }
}

foreach ($file in $blgFiles) {
    $relativeSourcePath = Get-RelativeSourcePath $file.FullName
    Write-Log "Found: $relativeSourcePath" "INFO"

    # 1. Zero-Byte Check
    if ($file.Length -eq 0) {
        Write-Log "  -> SKIPPING: File is 0 KB (Empty). Capture likely failed or initialized without data." "WARN"
        continue
    }

    # 2. Safe Buffer Copy (Sanitizes Filename)
    $safeName = "safe_buffer_{0}.blg" -f ([Guid]::NewGuid().ToString("N"))
    $bufferPath = Join-Path $TempDir $safeName
    $normalizedPath = Join-Path $TempDir ("normalized_{0}.blg" -f [Guid]::NewGuid().ToString("N"))

    try {
        Copy-Item -LiteralPath $file.FullName -Destination $bufferPath -Force -ErrorAction Stop
    } catch {
        Write-Log "  -> SKIPPING: File Locked. Could not copy to buffer. $($_.Exception.Message)" "ERROR"
        continue
    }

    # 3. Normalize with relog.exe to handle modern counter sets (Process V2, etc.)
    if (-not (Invoke-RelogConversion -InputPath $bufferPath -OutputPath $normalizedPath)) {
        Remove-Item -LiteralPath $bufferPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $normalizedPath -Force -ErrorAction SilentlyContinue
        continue
    }

    # 4. Import Data from normalized BLG
    $counterData = $null
    $importIssues = @()
    try {
        # Use tolerant import so one invalid sample does not discard the entire capture.
        $counterData = Import-Counter -Path $normalizedPath -ErrorAction SilentlyContinue -ErrorVariable +importIssues
    } catch {
        $importIssues += $_
    }

    if (-not $counterData -or $counterData.Count -eq 0) {
        $importMsg = "No samples were returned."
        if ($importIssues.Count -gt 0) {
            $importMsg = (($importIssues | ForEach-Object { $_.Exception.Message } | Select-Object -First 1) -replace "\s+", " ").Trim()
        }
        Write-Log "  -> FAILED to read normalized data structure. Reason: $importMsg" "ERROR"
        Remove-Item -LiteralPath $bufferPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $normalizedPath -Force -ErrorAction SilentlyContinue
        continue
    }

    if ($importIssues.Count -gt 0) {
        $warnMsg = (($importIssues | ForEach-Object { $_.Exception.Message } | Select-Object -First 1) -replace "\s+", " ").Trim()
        Write-Log "  -> Imported with counter warnings. Invalid samples will be skipped. $warnMsg" "WARN"
    } else {
        Write-Log "  -> Successfully imported relog-normalized data." "SUCCESS"
    }

    # Clean up intermediate files immediately
    Remove-Item -LiteralPath $bufferPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $normalizedPath -Force -ErrorAction SilentlyContinue

    $firstSampleSet = $counterData | Select-Object -First 1
    if (-not $firstSampleSet -or -not $firstSampleSet.CounterSamples -or $firstSampleSet.CounterSamples.Count -eq 0) {
        Write-Log "  -> SKIPPING: No counter samples available after relog conversion." "WARN"
        continue
    }

    # Determine Hostname
    $samplePath = ($firstSampleSet.CounterSamples | Select-Object -First 1).Path
    if ($samplePath -match "\\\\(.*?)\\") { $hostName = $Matches[1] } else { $hostName = "Unknown" }

    # Fidelity Check
    $timeStamps = $counterData.Timestamp
    if ($timeStamps.Count -lt 2) {
        $avgInterval = 0
    } else {
        $intervals = for ($i = 1; $i -lt $timeStamps.Count; $i++) { ($timeStamps[$i] - $timeStamps[$i - 1]).TotalSeconds }
        $avgInterval = [Math]::Round(($intervals | Measure-Object -Average).Average, 1)
    }

    if ($avgInterval -gt 15) { Write-Log "  -> Low Fidelity Warning: Sampling interval is $($avgInterval)s" "WARN" }

    # Initialize Containers
    $stolenList = New-Object System.Collections.Generic.List[double]
    $iopsList = New-Object System.Collections.Generic.List[double]
    $tanAggList = New-Object System.Collections.Generic.List[double]
    $procData = @{}
    $dedupeHitCount = 0

    # Iterate Samples
    foreach ($sampleSet in $counterData) {
        $intervalStolen = 0
        $intervalIops = 0
        $intervalTanSum = 0
        $intervalProcBest = @{}

        foreach ($s in $sampleSet.CounterSamples) {
            $samplePath = $s.Path
            if ([string]::IsNullOrWhiteSpace($samplePath)) { continue }
            $sampleValue = Get-CounterSampleValueOrNull $s

            if ($samplePath -like "*VM Processor(_Total)\CPU stolen time" -and $null -ne $sampleValue) { $intervalStolen = [double]$sampleValue }
            if ($samplePath -like "*PhysicalDisk(_Total)\Disk Transfers/sec" -and $null -ne $sampleValue) { $intervalIops = [double]$sampleValue }

            if ($samplePath -like "*\Process(*)*" -or $samplePath -like "*\Process V2(*)*") {
                if ($null -eq $sampleValue) { continue }
                $pidName = ([regex]::Match($samplePath, "\((.*?)\)")).Groups[1].Value
                if ([string]::IsNullOrWhiteSpace($pidName) -or $pidName -match "_Total|Idle") { continue }

                $metric = $null
                if ($samplePath -like "*% Processor Time") { $metric = "CPU" }
                elseif ($samplePath -like "*% Privileged Time") { $metric = "Priv" }
                elseif ($samplePath -like "*% User Time") { $metric = "User" }
                elseif ($samplePath -like "*Private Bytes") { $metric = "Mem" }
                elseif ($samplePath -like "*Priority Base") { $metric = "Prio" }
                if (-not $metric) { continue }

                if (-not $intervalProcBest.ContainsKey($pidName)) {
                    $intervalProcBest[$pidName] = @{
                        CPU = $null; CPU_Rank = 0
                        Priv = $null; Priv_Rank = 0
                        User = $null; User_Rank = 0
                        Mem = $null; Mem_Rank = 0
                        Prio = $null; Prio_Rank = 0
                    }
                }

                $sourceRank = Get-ProcessCounterSourceRank $samplePath
                $rankKey = "{0}_Rank" -f $metric
                $entry = $intervalProcBest[$pidName]

                if ($null -ne $entry[$metric]) {
                    if ($sourceRank -gt $entry[$rankKey]) { $dedupeHitCount++ }
                    elseif ($sourceRank -le $entry[$rankKey]) { continue }
                }

                $entry[$metric] = [double]$sampleValue
                $entry[$rankKey] = $sourceRank
            }
        }

        foreach ($pidName in $intervalProcBest.Keys) {
            if (!$procData[$pidName]) { $procData[$pidName] = @{ CPU = @(); Priv = @(); User = @(); Mem = @(); Prio = @() } }
            $entry = $intervalProcBest[$pidName]

            if ($null -ne $entry.CPU) {
                $procData[$pidName].CPU += $entry.CPU
                if ($pidName -match "Tanium") { $intervalTanSum += $entry.CPU }
            }
            if ($null -ne $entry.Priv) { $procData[$pidName].Priv += $entry.Priv }
            if ($null -ne $entry.User) { $procData[$pidName].User += $entry.User }
            if ($null -ne $entry.Mem) { $procData[$pidName].Mem += $entry.Mem }
            if ($null -ne $entry.Prio) { $procData[$pidName].Prio += $entry.Prio }
        }

        $stolenList.Add($intervalStolen)
        $iopsList.Add($intervalIops)
        $tanAggList.Add($intervalTanSum)
    }

    if ($dedupeHitCount -gt 0) {
        Write-Log "  -> De-duplicated $dedupeHitCount overlapping Process/Process V2 metric samples (Process V2 preferred)." "INFO"
    }

    # --- STAGE 2: ANALYSIS ---
    $processSummary = foreach ($procName in $procData.Keys) {
        $avgUser = ($procData[$procName].User | Measure-Object -Average).Average
        $avgPriv = ($procData[$procName].Priv | Measure-Object -Average).Average
        [PSCustomObject]@{
            PID       = $procName
            AvgCPU    = [Math]::Round(($procData[$procName].CPU | Measure-Object -Average).Average, 2)
            KURatio   = if ($avgUser -gt 0) { [Math]::Round(($avgPriv / $avgUser), 3) } else { 0 }
            MemSlope  = [Math]::Round((Get-TrendSlope $procData[$procName].Mem) / 1MB, 4)
            BasePrio  = [Math]::Round(($procData[$procName].Prio | Measure-Object -Average).Average, 0)
            PeakMemMB = [Math]::Round(($procData[$procName].Mem | Measure-Object -Maximum).Maximum / 1MB, 2)
            IsTan     = $procName -match "Tanium"
        }
    }

    $score = Get-ContentionScore $stolenList $tanAggList

    # --- INSIGHTS ---
    $insights = New-Object System.Collections.Generic.List[string]
    if ($avgInterval -gt 15) { $insights.Add("<strong style='color:#d9534f;'>Low Fidelity Warning:</strong> Sampling interval is $($avgInterval)s. Burst activity may be aliased.") }
    if ($stolenList.Count -eq 0 -or ($stolenList | Measure-Object -Sum).Sum -eq 0) { $insights.Add("<strong>Data Gap:</strong> VMware counters missing or zero. Validate VMware Tools.") }
    elseif ($score -gt 0.7) { $insights.Add("<strong>Scheduling Contention:</strong> High correlation detected between workload bursts and hypervisor ready time.") }
    if (($processSummary | Where-Object { $_.IsTan -and $_.KURatio -gt 0.3 })) { $insights.Add("<strong>Filter Driver Overhead:</strong> Elevated kernel-to-user ratios observed. Validate security exclusions.") }
    if (($processSummary | Where-Object { $_.IsTan -and $_.MemSlope -gt 0.5 })) { $insights.Add("<strong>Memory Trend:</strong> Steady incline in private bytes observed (Potential Leak).") }
    if ($insights.Count -eq 0) { $insights.Add("System metrics appear healthy.") }

    # --- STAGE 3: HTML REPORT ---
    $scoreColor = if ($score -gt 0.7) { "#d9534f" } elseif ($score -gt 0.4) { "#f0ad4e" } else { "#5cb85c" }
    $tanRows = ($processSummary | Where-Object IsTan | Sort-Object AvgCPU -Descending | ForEach-Object {
            $lStyle = if ($_.MemSlope -gt 0.5) { "background:#ffcccc;" } else { "" }
            $kStyle = if ($_.KURatio -gt 0.3) { "color:red; font-weight:bold;" } else { "" }
            "<tr style='$lStyle'><td>$($_.PID)</td><td>$($_.AvgCPU)%</td><td style='$kStyle'>$($_.KURatio)</td><td>$($_.BasePrio)</td><td>$($_.MemSlope) MB/inc</td><td>$($_.PeakMemMB) MB</td></tr>"
        }) -join ""

    $pieRows = ($processSummary | Sort-Object AvgCPU -Descending | Select-Object -First 12 | ForEach-Object { "['$($_.PID)', $($_.AvgCPU)]" }) -join ","
    $lineRows = for ($i = 0; $i -lt $stolenList.Count; $i++) { "['$($timeStamps[$i].ToString("HH:mm:ss"))', $($stolenList[$i]), $($iopsList[$i])]" }

    $htmlBody = @"
    <html>
    <head>
        <script src="https://www.gstatic.com/charts/loader.js"></script>
        <script>
            google.charts.load('current', {'packages':['corechart', 'gauge']});
            google.charts.setOnLoadCallback(() => {
                new google.visualization.Gauge(document.getElementById('g')).draw(google.visualization.arrayToDataTable([['Label', 'Value'],['Contention', $($score * 100)]]), {redFrom: 70, redTo: 100, yellowFrom: 40, yellowTo: 70});
                new google.visualization.PieChart(document.getElementById('p')).draw(google.visualization.arrayToDataTable([['PID','Avg'], $pieRows]), {title:'Process CPU Distribution'});
                new google.visualization.LineChart(document.getElementById('l')).draw(google.visualization.arrayToDataTable([['Time','Ready','IOPS'], $($lineRows -join ",")]), {title:'Ready Time vs IOPS', series:{0:{targetAxisIndex:0},1:{targetAxisIndex:1}}, vAxes:{0:{title:'Ready (ms)'},1:{title:'IOPS'}}});
            });
        </script>
        <style>
            body{font-family:'Segoe UI',sans-serif;background:#f4f7f6;margin:30px}
            .card{background:white;padding:25px;border-radius:10px;box-shadow:0 4px 6px rgba(0,0,0,0.1);margin-bottom:20px; border-left:10px solid $scoreColor;}
            .insight-box { background: #fdfdfe; border: 1px solid #d1d1d1; padding: 15px; border-radius: 5px; margin: 10px 0; }
            table{width:100%;border-collapse:collapse;margin-top:15px;}
            th, td{padding:12px;border-bottom:1px solid #ddd;text-align:left;}
            th{background:#eee}
            .ref-box { background: #e9ecef; padding: 15px; border-radius: 5px; font-size: 0.85em; margin-top: 20px; }
            .ref-box a { color: #0056b3; text-decoration: none; font-weight: bold; }
        </style>
    </head>
    <body>
        <div class="card">
            <h1>Quality Report: $hostName</h1>
            <div style="display:flex;align-items:center;">
                <div id="g" style="width:200px;height:150px"></div>
                <div style="margin-left:20px"><span style="font-size:2.5em;font-weight:bold;color:$scoreColor">$score</span><br/>Contention Score (Sampling: $($avgInterval)s)</div>
            </div>

            <div class="insight-box">
                <strong>Observations & Opportunities:</strong>
                <ul><li>$($insights -join "</li><li>")</li></ul>
            </div>

            <div style="display:flex;"><div id="p" style="width:40%;height:400px"></div><div id="l" style="width:60%;height:400px"></div></div>
            <table><thead><tr><th>PID</th><th>Avg CPU</th><th>K/U Ratio</th><th>Base Prio</th><th>Mem Slope</th><th>Peak MB</th></tr></thead><tbody>$tanRows</tbody></table>

            <div class="ref-box">
                <strong>Technical Reference Library:</strong><br/><br/>
                • <strong>K/U Ratio:</strong> <a href="https://learn.microsoft.com/en-us/troubleshoot/windows-server/performance/troubleshoot-high-cpu-usage-privileged-time" target="_blank">Troubleshoot High Privileged Time</a><br/>
                • <strong>Process Memory:</strong> <a href="https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/the-!address-extension" target="_blank">Understanding Process Memory Counters</a><br/>
                • <strong>VMware Ready Time:</strong> <a href="https://kb.vmware.com/s/article/2002181" target="_blank">Troubleshooting ESXi CPU Contention</a>
            </div>
        </div>
    </body></html>
"@
    $sourceToken = ConvertTo-SafeFileToken (([System.IO.Path]::ChangeExtension($relativeSourcePath, $null)) -replace "[\\/]", "_")
    $reportName = "{0}_{1}_Analysis.html" -f (ConvertTo-SafeFileToken $hostName), $sourceToken
    $reportPath = Join-Path $ReportDir $reportName
    $htmlBody | Out-File -FilePath $reportPath
    $masterSummary.Add([PSCustomObject]@{
            HostName   = $hostName
            SourceFile = $relativeSourcePath
            ReportFile = $reportName
            Contention = $score
            Fidelity   = "$($avgInterval)s"
            Status     = if ($score -gt 0.7) { "Critical" } else { "Healthy" }
        })
}

if ($WorkerMode) {
    $masterSummary
    exit
}

$masterSummary | Export-Csv $SummaryFile -NoTypeInformation
Write-Log "Analysis Complete. Reports located in: $ReportDir" "SUCCESS"
