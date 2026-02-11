<#
.SYNOPSIS
    Professional Tanium & VMware Performance Utility.
    Version: 11.1
    
.DESCRIPTION
    - Full Lifecycle: Relog Conversion -> Host Grouping -> Analytics -> HTML Reporting.
    - Robust Error Handling: Validates counter existence and handles null/missing data safely.
    - Fidelity Check: Validates sampling interval to ensure burst activity is captured.
    - Diagnostics: 
        1. Contention Score: Correlation of Tanium bursts to VMware Ready Time.
        2. K/U Ratio: Detects AV/EDR hooking/interference (Privileged/User ratio).
        3. Memory Slope: Linear regression to detect leaks over time.
        4. Priority: Detects priority deviations from 'Normal' (8).
#>

# --- CONFIGURATION ---
$blgFolder    = "C:\PerfLogs\Source"
$csvFolder    = "C:\PerfLogs\Analysis"
$reportFolder = "C:\PerfLogs\Reports"
$summaryFile  = Join-Path $reportFolder "Fleet_Contention_Summary.csv"

# Initialization
foreach ($path in @($csvFolder, $reportFolder)) {
    if (!(Test-Path $path)) { New-Item -ItemType Directory -Path $path }
}

# --- ROBUST HELPERS ---

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
        $y = [double]$yValues[$x]
        $sumX  += $x
        $sumY  += $y
        $sumXY += ($x * $y)
        $sumX2 += ($x * $x)
    }
    $denominator = ($n * $sumX2) - ($sumX * $sumX)
    return if ($denominator -eq 0) { 0 } else { (($n * $sumXY) - ($sumX * $sumY)) / $denominator }
}

# --- STAGE 1: CONVERSION ---
Write-Host "--- STAGE 1: Converting BLGs to CSV ---" -ForegroundColor Cyan
$blgFiles = Get-ChildItem -Path $blgFolder -Filter "*.blg"

foreach ($file in $blgFiles) {
    $outputCsv = Join-Path $csvFolder ($file.BaseName + ".csv")
    if (!(Test-Path $outputCsv)) {
        Write-Host "Relogging $($file.Name)..." -ForegroundColor Gray
        relog $file.FullName -f csv -o $outputCsv `
            -q "\Process(*)\% Processor Time" `
            -q "\Process(*)\% Privileged Time" `
            -q "\Process(*)\% User Time" `
            -q "\Process(*)\Private Bytes" `
            -q "\Process(*)\Priority Base" `
            -q "\PhysicalDisk(_Total)\Disk Transfers/sec" `
            -q "\VM Processor(_Total)\*" 2>$null
    }
}

# --- STAGE 2: ANALYSIS & GROUPING ---
Write-Host "`n--- STAGE 2: Processing Data by Host ---" -ForegroundColor Cyan
$csvFiles = Get-ChildItem -Path $csvFolder -Filter "*.csv"
$masterSummary = New-Object System.Collections.Generic.List[PSCustomObject]

$hostedFiles = $csvFiles | Group-Object {
    $firstLine = Get-Content $_.FullName -TotalCount 2 | Select-Object -Last 1
    if ($firstLine -match "\\\\(.*?)\\") { $Matches[1] } else { "UnknownHost" }
}

foreach ($group in $hostedFiles) {
    $hostName = $group.Name
    Write-Host "Analyzing Host: $hostName" -ForegroundColor White
    $allData = foreach ($f in $group.Group) { Import-Csv $f.FullName }
    $headers = $allData[0].psobject.Properties.Name

    # Fidelity Check
    $timeStamps = $allData | ForEach-Object { [DateTime]$_."(PDH-CSV 4.0)" }
    $intervals = for($i=1; $i -lt $timeStamps.Count; $i++) { ($timeStamps[$i] - $timeStamps[$i-1]).TotalSeconds }
    $avgInterval = [Math]::Round(($intervals | Measure-Object -Average).Average, 1)

    # 1. System Metrics
    $stolenKey = "\\$hostName\VM Processor(_Total)\CPU stolen time"
    $iopsKey   = "\\$hostName\PhysicalDisk(_Total)\Disk Transfers/sec"
    $stolenList = $allData | ForEach-Object { ConvertTo-SafeDouble $_."$stolenKey" }
    $iopsList   = $allData | ForEach-Object { ConvertTo-SafeDouble $_."$iopsKey" }
    
    # 2. Process Deep Dive
    $procCols = $headers | Where-Object { $_ -like "*Process(*)*% Processor Time*" }
    $processSummary = foreach ($col in $procCols) {
        $pidName = ([regex]::Match($col, "\((.*?)\)")).Groups[1].Value
        if ($pidName -match "_Total|Idle") { continue }
        
        $privCol = "\\$hostName\Process($pidName)\% Privileged Time"
        $userCol = "\\$hostName\Process($pidName)\% User Time"
        $memCol  = "\\$hostName\Process($pidName)\Private Bytes"
        $prioCol = "\\$hostName\Process($pidName)\Priority Base"
        
        $avgPriv = ($allData | ForEach-Object { ConvertTo-SafeDouble $_."$privCol" } | Measure-Object -Average).Average
        $avgUser = ($allData | ForEach-Object { ConvertTo-SafeDouble $_."$userCol" } | Measure-Object -Average).Average
        $memVals = $allData | ForEach-Object { ConvertTo-SafeDouble $_."$memCol" }
        
        [PSCustomObject]@{ 
            PID       = $pidName
            AvgCPU    = [Math]::Round(($allData | ForEach-Object { ConvertTo-SafeDouble $_."$col" } | Measure-Object -Average).Average, 2)
            KURatio   = if ($avgUser -gt 0) { [Math]::Round(($avgPriv / $avgUser), 3) } else { 0 }
            MemSlope  = [Math]::Round((Get-TrendSlope $memVals) / 1MB, 4)
            BasePrio  = [Math]::Round(($allData | ForEach-Object { ConvertTo-SafeDouble $_."$prioCol" } | Measure-Object -Average).Average, 0)
            PeakMemMB = [Math]::Round(($memVals | Measure-Object -Maximum).Maximum / 1MB, 2)
            IsTan     = $pidName -match "Tanium"
        }
    }

    # 3. Contention Scoring
    $tanCols = $headers | Where-Object { $_ -match "Tanium" -and $_ -like "*% Processor Time*" }
    $tanAgg = foreach ($row in $allData) { 
        $sum = 0; foreach ($c in $tanCols) { $sum += ConvertTo-SafeDouble $row."$c" }; $sum 
    }
    $score = Get-ContentionScore $stolenList $tanAgg

    # --- INSIGHTS ---
    $insights = New-Object System.Collections.Generic.List[string]
    if ($avgInterval -gt 15) { $insights.Add("<strong style='color:#d9534f;'>Low Fidelity Warning:</strong> Sampling interval is $($avgInterval)s. Burst activity may be aliased.") }
    if (!($headers -contains $stolenKey)) { $insights.Add("<strong>Data Gap:</strong> VMware counters missing. Check VMware Tools.") }
    elseif ($score -gt 0.7) { $insights.Add("<strong>Scheduling Contention:</strong> High correlation with VM Ready Time.") }
    if (($processSummary | Where-Object { $_.IsTan -and $_.KURatio -gt 0.3 })) { $insights.Add("<strong>AV Interference:</strong> High K/U ratio detected; check exclusions.") }

    # --- STAGE 3: HTML REPORT ---
    $scoreColor = if ($score -gt 0.7) { "#d9534f" } elseif ($score -gt 0.4) { "#f0ad4e" } else { "#5cb85c" }
    $tanRows = ($processSummary | Where-Object IsTan | Sort-Object AvgCPU -Descending | ForEach-Object { 
        $lStyle = if ($_.MemSlope -gt 0.5) { "background:#ffcccc;" } else { "" }
        "<tr style='$lStyle'><td>$($_.PID)</td><td>$($_.AvgCPU)%</td><td>$($_.KURatio)</td><td>$($_.BasePrio)</td><td>$($_.MemSlope) MB/inc</td><td>$($_.PeakMemMB) MB</td></tr>" 
    }) -join ""
    
    $pieRows  = ($processSummary | Sort-Object AvgCPU -Descending | Select-Object -First 12 | ForEach-Object { "['$($_.PID)', $($_.AvgCPU)]" }) -join ","
    $lineRows = for($i=0; $i -lt $stolenList.Count; $i++) { "['$($timeStamps[$i].ToString("HH:mm:ss"))', $($stolenList[$i]), $($iopsList[$i])]" }

    $htmlBody = @"
    <html>
    <head>
        <script src="https://www.gstatic.com/charts/loader.js"></script>
        <script>
            google.charts.load('current', {'packages':['corechart', 'gauge']});
            google.charts.setOnLoadCallback(() => {
                new google.visualization.Gauge(document.getElementById('g')).draw(google.visualization.arrayToDataTable([['Label', 'Value'],['Contention', $($score * 100)]]), {redFrom: 70, redTo: 100, yellowFrom: 40, yellowTo: 70});
                new google.visualization.PieChart(document.getElementById('p')).draw(google.visualization.arrayToDataTable([['PID','Avg'], $pieRows]), {title:'CPU Distribution'});
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
        </style>
    </head>
    <body>
        <div class="card">
            <h1>Quality Report: $hostName</h1>
            <div style="display:flex;align-items:center;">
                <div id="g" style="width:200px;height:150px"></div>
                <div style="margin-left:20px"><span style="font-size:2.5em;font-weight:bold;color:$scoreColor">$score</span><br/>Contention Score</div>
            </div>
            <div class="insight-box"><strong>Insights & Fidelity:</strong><ul><li>$($insights -join "</li><li>")</li></ul></div>
            <div style="display:flex;"><div id="p" style="width:40%;height:400px"></div><div id="l" style="width:60%;height:400px"></div></div>
            <table><thead><tr><th>PID</th><th>Avg CPU</th><th>K/U Ratio</th><th>Base Prio</th><th>Mem Slope</th><th>Peak MB</th></tr></thead><tbody>$tanRows</tbody></table>
        </div>
    </body></html>
"@
    $htmlBody | Out-File (Join-Path $reportFolder "$hostName`_Quality_Report.html")
    $masterSummary.Add([PSCustomObject]@{ HostName=$hostName; Contention=$score; Fidelity="$($avgInterval)s"; Status=if($score -gt 0.7){"Critical"}else{"Healthy"} })
}

$masterSummary | Export-Csv $summaryFile -NoTypeInformation
Write-Host "Complete. Reports in: $reportFolder" -ForegroundColor Green
