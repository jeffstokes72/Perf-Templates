<#
.SYNOPSIS
    Professional Tanium & VMware Performance Utility.
    Version: 12.3

.DESCRIPTION
    - Fixes: Handles filenames with special chars ( ) [ ] by using a safe processing buffer.
    - Fixes: Skips 0-byte (empty) files automatically.
    - Diagnostics: Contention Score, K/U Ratio, Memory Slope, Priority.
#>

# --- CONFIGURATION ---
$BaseDir      = "C:\TaniumPerformanceAnalysis"
$SourceDir    = "$BaseDir\Source"
$ReportDir    = "$BaseDir\Reports"
$TempDir      = "$BaseDir\Temp"
$LogFile      = "$BaseDir\Analysis_Log.txt"
$SummaryFile  = Join-Path $ReportDir "Fleet_Contention_Summary.csv"

# Ensure Directory Structure
foreach ($path in @($BaseDir, $SourceDir, $ReportDir, $TempDir)) {
    if (!(Test-Path $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
}

# Initialize Log
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Add-Content -Path $LogFile -Value "`n[$timestamp] === Starting Analysis Run (v12.3) ==="

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
    return if ($denominator -eq 0) { 0 } else { [Math]::Round(($sumNum / $denominator), 3) }
}

function Get-TrendSlope ($yValues) {
    $n = $yValues.Count
    if ($n -lt 10) { return 0 }
    $sumX = 0; $sumY = 0; $sumXY = 0; $sumX2 = 0
    for ($x = 0; $x -lt $n; $x++) {
        $y = ConvertTo-SafeDouble $yValues[$x]
        $sumX += $x
        $sumY += $y
        $sumXY += ($x * $y)
        $sumX2 += ($x * $x)
    }
    $denominator = ($n * $sumX2) - ($sumX * $sumX)
    return if ($denominator -eq 0) { 0 } else { (($n * $sumXY) - ($sumX * $sumY)) / $denominator }
}

# --- STAGE 1: PROCESSING BLG FILES ---
Write-Log "Scanning $SourceDir for BLG files..." "INFO"
$blgFiles = Get-ChildItem -Path $SourceDir -Filter "*.blg"

if ($blgFiles.Count -eq 0) { Write-Log "No .blg files found!" "ERROR"; exit }

foreach ($file in $blgFiles) {
    Write-Log "Found: $($file.Name)" "INFO"

    # 1. Zero-Byte Check
    if ($file.Length -eq 0) {
        Write-Log "  -> SKIPPING: File is 0 KB (Empty). Capture likely failed or initialized without data." "WARN"
        continue
    }

    # 2. Safe Buffer Copy (Sanitizes Filename)
    $safeName = "safe_buffer_$($file.BaseName.GetHashCode()).blg"
    $bufferPath = Join-Path $TempDir $safeName

    try {
        Copy-Item -LiteralPath $file.FullName -Destination $bufferPath -Force -ErrorAction Stop
    } catch {
        Write-Log "  -> SKIPPING: File Locked. Could not copy to buffer. $($_.Exception.Message)" "ERROR"
        continue
    }

    # 3. Import Data from Safe Buffer
    try {
        $counterData = Import-Counter -Path $bufferPath -ErrorAction Stop
        Write-Log "  -> Successfully imported data." "SUCCESS"
    } catch {
        Write-Log "  -> FAILED to read data structure. Reason: $($_.Exception.Message)" "ERROR"
        Remove-Item $bufferPath -Force -ErrorAction SilentlyContinue
        continue
    }

    # Clean up buffer immediately
    Remove-Item $bufferPath -Force -ErrorAction SilentlyContinue

    # Determine Hostname
    $samplePath = $counterData[0].CounterSamples[0].Path
    if ($samplePath -match "\\\\(.*?)\\") { $hostName = $Matches[1] } else { $hostName = "Unknown" }

    # Fidelity Check
    $timeStamps = $counterData.Timestamp
    $intervals = for ($i = 1; $i -lt $timeStamps.Count; $i++) { ($timeStamps[$i] - $timeStamps[$i - 1]).TotalSeconds }
    $avgInterval = [Math]::Round(($intervals | Measure-Object -Average).Average, 1)

    if ($avgInterval -gt 15) { Write-Log "  -> Low Fidelity Warning: Sampling interval is $($avgInterval)s" "WARN" }

    # Initialize Containers
    $stolenList = New-Object System.Collections.Generic.List[double]
    $iopsList = New-Object System.Collections.Generic.List[double]
    $tanAggList = New-Object System.Collections.Generic.List[double]
    $procData = @{}

    # Iterate Samples
    foreach ($sampleSet in $counterData) {
        $intervalStolen = 0
        $intervalIops = 0
        $intervalTanSum = 0

        foreach ($s in $sampleSet.CounterSamples) {
            if ($s.Path -like "*VM Processor(_Total)\CPU stolen time") { $intervalStolen = $s.CookedValue }
            if ($s.Path -like "*PhysicalDisk(_Total)\Disk Transfers/sec") { $intervalIops = $s.CookedValue }

            if ($s.Path -like "*\Process(*)*") {
                $pidName = ([regex]::Match($s.Path, "\((.*?)\)")).Groups[1].Value
                if ($pidName -match "_Total|Idle") { continue }
                if (!$procData[$pidName]) { $procData[$pidName] = @{ CPU = @(); Priv = @(); User = @(); Mem = @(); Prio = @() } }

                if ($s.Path -like "*% Processor Time") {
                    $procData[$pidName].CPU += $s.CookedValue
                    if ($pidName -match "Tanium") { $intervalTanSum += $s.CookedValue }
                }
                if ($s.Path -like "*% Privileged Time") { $procData[$pidName].Priv += $s.CookedValue }
                if ($s.Path -like "*% User Time") { $procData[$pidName].User += $s.CookedValue }
                if ($s.Path -like "*Private Bytes") { $procData[$pidName].Mem += $s.CookedValue }
                if ($s.Path -like "*Priority Base") { $procData[$pidName].Prio += $s.CookedValue }
            }
        }
        $stolenList.Add($intervalStolen)
        $iopsList.Add($intervalIops)
        $tanAggList.Add($intervalTanSum)
    }

    # --- STAGE 2: ANALYSIS ---
    $processSummary = foreach ($pid in $procData.Keys) {
        $avgUser = ($procData[$pid].User | Measure-Object -Average).Average
        $avgPriv = ($procData[$pid].Priv | Measure-Object -Average).Average
        [PSCustomObject]@{
            PID       = $pid
            AvgCPU    = [Math]::Round(($procData[$pid].CPU | Measure-Object -Average).Average, 2)
            KURatio   = if ($avgUser -gt 0) { [Math]::Round(($avgPriv / $avgUser), 3) } else { 0 }
            MemSlope  = [Math]::Round((Get-TrendSlope $procData[$pid].Mem) / 1MB, 4)
            BasePrio  = [Math]::Round(($procData[$pid].Prio | Measure-Object -Average).Average, 0)
            PeakMemMB = [Math]::Round(($procData[$pid].Mem | Measure-Object -Maximum).Maximum / 1MB, 2)
            IsTan     = $pid -match "Tanium"
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
    $htmlBody | Out-File (Join-Path $ReportDir "$hostName`_Analysis.html")
    $masterSummary.Add([PSCustomObject]@{ HostName = $hostName; Contention = $score; Fidelity = "$($avgInterval)s"; Status = if ($score -gt 0.7) { "Critical" } else { "Healthy" } })
}

$masterSummary | Export-Csv $SummaryFile -NoTypeInformation
Write-Log "Analysis Complete. Reports located in: $ReportDir" "SUCCESS"
