<#
.SYNOPSIS
    Tanium & VMware Performance Quality Utility.
    
.DESCRIPTION
    - Converts BLG to CSV with extended metrics (Kernel Time, Memory, IOPS).
    - Groups files by Hostname for fleet-wide analysis.
    - Calculates "Contention Score" (Correlation between Tanium activity and VM Ready Time).
    - Identifies "Exclusion Issues" via Kernel vs User time ratios.
    - Generates interactive HTML reports and a Master Summary CSV.
#>

# --- CONFIGURATION ---
$blgFolder    = "C:\PerfLogs\Source"    # Input BLG files
$csvFolder    = "C:\PerfLogs\Analysis"  # Intermediate CSVs
$reportFolder = "C:\PerfLogs\Reports"   # Final Output
$summaryFile  = Join-Path $reportFolder "Fleet_Contention_Summary.csv"

# Ensure directories exist
foreach ($path in @($csvFolder, $reportFolder)) {
    if (!(Test-Path $path)) { New-Item -ItemType Directory -Path $path }
}

# --- HELPER: CORRELATION MATH ---
function Get-ContentionScore ($listA, $listB) {
    $count = $listA.Count
    if ($count -lt 2) { return 0 }
    $avgA = ($listA | Measure-Object -Average).Average
    $avgB = ($listB | Measure-Object -Average).Average
    $sumNum = 0; $sumDenA = 0; $sumDenB = 0
    for ($i = 0; $i -lt $count; $i++) {
        $diffA = $listA[$i] - $avgA
        $diffB = $listB[$i] - $avgB
        $sumNum += ($diffA * $diffB)
        $sumDenA += [Math]::Pow($diffA, 2)
        $sumDenB += [Math]::Pow($diffB, 2)
    }
    $denominator = [Math]::Sqrt($sumDenA * $sumDenB)
    if ($denominator -eq 0) { return 0 }
    return [Math]::Round(($sumNum / $denominator), 3)
}

# --- STAGE 1: CONVERSION ---
Write-Host "--- STAGE 1: Relogging BLG files with Extended Metrics ---" -ForegroundColor Cyan
$blgFiles = Get-ChildItem -Path $blgFolder -Filter "*.blg"

foreach ($file in $blgFiles) {
    $outputCsv = Join-Path $csvFolder ($file.BaseName + ".csv")
    if (!(Test-Path $outputCsv)) {
        Write-Host "Relogging $($file.Name)..." -ForegroundColor Gray
        # Capture Processor, Privileged (Kernel) Time, Memory, and Disk IOPS
        relog $file.FullName -f csv -o $outputCsv `
            -q "\Process(*)\% Processor Time" `
            -q "\Process(*)\% Privileged Time" `
            -q "\Process(*)\Private Bytes" `
            -q "\PhysicalDisk(_Total)\Disk Transfers/sec" `
            -q "\VM Processor(_Total)\*"
    }
}

# --- STAGE 2: GROUPING & ANALYSIS ---
Write-Host "`n--- STAGE 2: Processing Data by Host ---" -ForegroundColor Cyan
$csvFiles = Get-ChildItem -Path $csvFolder -Filter "*.csv"
$masterSummary = New-Object System.Collections.Generic.List[PSCustomObject]

$hostedFiles = $csvFiles | Group-Object {
    $firstLine = Get-Content $_.FullName -TotalCount 2 | Select-Object -Last 1
    if ($firstLine -match "\\\\(.*?)\\") { $Matches[1] } else { "UnknownHost" }
}

foreach ($group in $hostedFiles) {
    $hostName = $group.Name
    Write-Host "Analyzing $hostName..." -ForegroundColor White
    $allData = foreach ($f in $group.Group) { Import-Csv $f.FullName }
    
    # 1. System Metrics
    $stolenList = $allData | ForEach-Object { [double]$_."\\$hostName\VM Processor(_Total)\CPU stolen time" }
    $mhzList    = $allData | ForEach-Object { [double]$_."\\$hostName\VM Processor(_Total)\Effective VM Speed in MHz" }
    $iopsList   = $allData | ForEach-Object { [double]$_."\\$hostName\PhysicalDisk(_Total)\Disk Transfers/sec" }
    $timeList   = $allData | ForEach-Object { $_."(PDH-CSV 4.0)" }
    
    # 2. Tanium Aggregation for Contention Score
    $tanCols = $allData[0].psobject.Properties.Name | Where-Object { $_ -match "Tanium" -and $_ -like "*% Processor Time*" }
    $tanAggList = foreach ($row in $allData) {
        $sum = 0; foreach ($c in $tanCols) { $sum += [double]$row."$c" }; $sum
    }
    $contentionScore = Get-ContentionScore $stolenList $tanAggList

    # 3. Process Deep Dive (CPU, Kernel, Mem)
    $procCols = $allData[0].psobject.Properties.Name | Where-Object { $_ -like "*Process(*)*% Processor Time*" }
    $processSummary = foreach ($col in $procCols) {
        $pidName = ([regex]::Match($col, "\((.*?)\)")).Groups[1].Value
        if ($pidName -match "_Total|Idle") { continue }
        
        $privCol = "\\$hostName\Process($pidName)\% Privileged Time"
        $memCol  = "\\$hostName\Process($pidName)\Private Bytes"
        
        $cpuM = $allData."$col" | Measure-Object -Average -Maximum
        $kerM = $allData."$privCol" | Measure-Object -Average
        $memM = $allData."$memCol" | Measure-Object -Maximum
        
        [PSCustomObject]@{ 
            PID       = $pidName
            AvgCPU    = [Math]::Round($cpuM.Average, 2)
            PeakCPU   = [Math]::Round($cpuM.Maximum, 2)
            AvgKern   = [Math]::Round($kerM.Average, 2)
            PeakMemMB = [Math]::Round(($memM.Maximum / 1MB), 2)
            IsTan     = $pidName -match "Tanium"
        }
    }

    # --- STAGE 3: HTML REPORT GENERATION ---
    $scoreColor = if ($contentionScore -gt 0.7) { "#d9534f" } elseif ($contentionScore -gt 0.4) { "#f0ad4e" } else { "#5cb85c" }
    $pieRows  = ($processSummary | Sort-Object AvgCPU -Descending | Select-Object -First 12 | ForEach-Object { "['$($_.PID)', $($_.AvgCPU)]" }) -join ","
    $lineRows = for($i=0; $i -lt $stolenList.Count; $i++) { "['$($timeList[$i])', $($stolenList[$i]), $($iopsList[$i])]" }
    $lineRowsJoined = $lineRows -join ","
    $tanRows  = ($processSummary | Where-Object IsTan | Sort-Object PeakCPU -Descending | ForEach-Object { 
        "<tr><td>$($_.PID)</td><td>$($_.AvgCPU)%</td><td>$($_.AvgKern)%</td><td>$($_.PeakMemMB) MB</td></tr>" 
    }) -join ""

    $htmlBody = @"
    <html>
    <head>
        <script src="https://www.gstatic.com/charts/loader.js"></script>
        <script>
            google.charts.load('current', {'packages':['corechart', 'gauge']});
            google.charts.setOnLoadCallback(() => {
                new google.visualization.Gauge(document.getElementById('g')).draw(google.visualization.arrayToDataTable([['Label', 'Value'],['Contention', $($contentionScore * 100)]]), {redFrom: 70, redTo: 100, yellowFrom: 40, yellowTo: 70});
                new google.visualization.PieChart(document.getElementById('p')).draw(google.visualization.arrayToDataTable([['PID','Avg'], $pieRows]), {title:'Top CPU by PID'});
                new google.visualization.LineChart(document.getElementById('l')).draw(google.visualization.arrayToDataTable([['Time','Ready','IOPS'], $lineRowsJoined]), {title:'VM Health: Ready Time vs Disk IOPS', series:{0:{targetAxisIndex:0},1:{targetAxisIndex:1}}, vAxes:{0:{title:'Ready (ms)'},1:{title:'IOPS'}}});
            });
        </script>
        <style>
            body{font-family:'Segoe UI',sans-serif;background:#f4f7f6;margin:30px} 
            .card{background:white;padding:20px;border-radius:10px;box-shadow:0 4px 6px rgba(0,0,0,0.1);margin-bottom:20px; border-left: 10px solid $scoreColor;}
            table{width:100%;text-align:left;border-collapse:collapse;margin-top:15px;}
            th, td{padding:10px;border-bottom:1px solid #ddd;}
            th{background:#eee}
        </style>
    </head>
    <body>
        <div class="card">
            <h1>Host Performance Analysis: $hostName</h1>
            <div style="display:flex;align-items:center;">
                <div id="g" style="width:200px;height:150px"></div>
                <div><span style="font-size:2em;font-weight:bold;color:$scoreColor">$contentionScore</span><br/>Contention Score (Correlation of Tanium Bursts to VM Scheduling Delays)</div>
            </div>
            <div style="display:flex;"><div id="p" style="width:45%;height:400px"></div><div id="l" style="width:55%;height:400px"></div></div>
            <h3>Tanium Process Deep Dive (CPU, Kernel, Memory)</h3>
            <table><thead><tr><th>PID</th><th>Avg CPU</th><th>Avg Kernel Time</th><th>Peak Memory</th></tr></thead><tbody>$tanRows</tbody></table>
        </div>
    </body></html>
"@
    $htmlBody | Out-File (Join-Path $reportFolder "$hostName`_Report.html")

    # Add to Master Summary
    $masterSummary.Add([PSCustomObject]@{
        HostName       = $hostName
        Contention     = $contentionScore
        AvgStolen      = [Math]::Round(($stolenList | Measure-Object -Average).Average, 2)
        AvgIOPS        = [Math]::Round(($iopsList | Measure-Object -Average).Average, 2)
        MaxTanMemMB    = ($processSummary | Where-Object IsTan | Measure-Object PeakMemMB -Maximum).Maximum
        AvgSystemKern  = [Math]::Round(($processSummary | Measure-Object AvgKern -Average).Average, 2)
        Status         = if ($contentionScore -gt 0.6) { "High Contention" } else { "Healthy" }
    })
}

# --- FINALIZE ---
$masterSummary | Export-Csv $summaryFile -NoTypeInformation
Write-Host "`nAnalysis Complete. Summary: $summaryFile" -ForegroundColor Green
