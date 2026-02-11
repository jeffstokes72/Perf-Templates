<#
.SYNOPSIS
    Analyzes Perfmon BLG files for Tanium CPU consumption and VMware Scheduling Contention.
    
.DESCRIPTION
    1. Converts BLG to CSV using relog with specific counter filters.
    2. Groups files by Hostname.
    3. Calculates a "Contention Score" (Correlation between Tanium CPU and VM Ready Time).
    4. Generates a Master Summary CSV and detailed HTML reports per host.
#>

# --- CONFIGURATION ---
$blgFolder    = "C:\PerfLogs\Source"    # Put your 19+ BLG files here
$csvFolder    = "C:\PerfLogs\Analysis"  # Intermediate CSV storage
$reportFolder = "C:\PerfLogs\Reports"   # Final HTML and Summary CSV output
$summaryFile  = Join-Path $reportFolder "Fleet_Contention_Summary.csv"

# Ensure directories exist
foreach ($path in @($csvFolder, $reportFolder)) {
    if (!(Test-Path $path)) { New-Item -ItemType Directory -Path $path }
}

# --- HELPER FUNCTIONS ---

# Pearson Correlation to determine how much Tanium causes VM Ready Time spikes
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

# --- STAGE 1: RELOG CONVERSION ---
Write-Host "--- STAGE 1: Converting BLG to CSV ---" -ForegroundColor Cyan
$blgFiles = Get-ChildItem -Path $blgFolder -Filter "*.blg"

foreach ($file in $blgFiles) {
    $outputCsv = Join-Path $csvFolder ($file.BaseName + ".csv")
    if (!(Test-Path $outputCsv)) {
        Write-Host "Relogging $($file.Name)..." -ForegroundColor Gray
        # Filter for relevant counters only to improve processing speed
        relog $file.FullName -f csv -o $outputCsv -q "\Process(*)\% Processor Time" -q "\VM Processor(_Total)\*"
    }
}

# --- STAGE 2: ANALYSIS & GROUPING ---
Write-Host "`n--- STAGE 2: Grouping by Host & Calculating Contention ---" -ForegroundColor Cyan
$csvFiles = Get-ChildItem -Path $csvFolder -Filter "*.csv"
$masterSummary = New-Object System.Collections.Generic.List[PSCustomObject]

# Group files by the hostname found in the CSV headers
$hostedFiles = $csvFiles | Group-Object {
    $firstLine = Get-Content $_.FullName -TotalCount 2 | Select-Object -Last 1
    if ($firstLine -match "\\\\(.*?)\\") { $Matches[1] } else { "UnknownHost" }
}

foreach ($group in $hostedFiles) {
    $hostName = $group.Name
    Write-Host "Analyzing Host: $hostName" -ForegroundColor White
    
    # Merge data if multiple files exist for one host
    $allData = foreach ($f in $group.Group) { Import-Csv $f.FullName }
    
    # 1. VMware Ready Time (Stolen) and MHz
    $stolenList = $allData | ForEach-Object { [double]$_."\\$hostName\VM Processor(_Total)\CPU stolen time" }
    $mhzList    = $allData | ForEach-Object { [double]$_."\\$hostName\VM Processor(_Total)\Effective VM Speed in MHz" }
    $timeList   = $allData | ForEach-Object { $_."(PDH-CSV 4.0)" }
    
    # 2. Aggregated Tanium CPU (Sum of all Tanium PIDs)
    $tanCols = $allData[0].psobject.Properties.Name | Where-Object { $_ -match "Tanium" -and $_ -like "*% Processor Time*" }
    $tanAggList = foreach ($row in $allData) {
        $sum = 0; foreach ($col in $tanCols) { $sum += [double]$row."$col" }; $sum
    }

    # 3. Individual Process Statistics (Peak vs Avg)
    $procCols = $allData[0].psobject.Properties.Name | Where-Object { $_ -like "*Process(*)*% Processor Time*" }
    $processSummary = foreach ($col in $procCols) {
        $pidName = ([regex]::Match($col, "\((.*?)\)")).Groups[1].Value
        if ($pidName -match "_Total|Idle") { continue }
        $m = $allData."$col" | Measure-Object -Average -Maximum
        [PSCustomObject]@{ PID=$pidName; Avg=[Math]::Round($m.Average,2); Peak=[Math]::Round($m.Maximum,2); IsTan=$pidName -match "Tanium" }
    }

    # 4. Final Score & Max Contention Event
    $contentionScore = Get-ContentionScore $stolenList $tanAggList
    $maxStolen = ($stolenList | Measure-Object -Maximum).Maximum
    $maxStolenIndex = [array]::IndexOf($stolenList, $maxStolen)
    $peakTime = $timeList[$maxStolenIndex]

    # --- STAGE 3: REPORT GENERATION ---
    $scoreColor = if ($contentionScore -gt 0.7) { "#d9534f" } elseif ($contentionScore -gt 0.4) { "#f0ad4e" } else { "#5cb85c" }
    $pieRows  = ($processSummary | Sort-Object Avg -Descending | Select-Object -First 12 | ForEach-Object { "['$($_.PID)', $($_.Avg)]" }) -join ","
    $lineRows = for($i=0; $i -lt $stolenList.Count; $i++) { "['$($timeList[$i])', $($stolenList[$i]), $($mhzList[$i])]" }
    $lineRowsJoined = $lineRows -join ","
    $tanRows  = ($processSummary | Where-Object IsTan | Sort-Object Peak -Descending | ForEach-Object { "<tr><td>$($_.PID)</td><td>$($_.Avg)%</td><td>$($_.Peak)%</td></tr>" }) -join ""

    $htmlBody = @"
    <html>
    <head>
        <script src="https://www.gstatic.com/charts/loader.js"></script>
        <script>
            google.charts.load('current', {'packages':['corechart', 'gauge']});
            google.charts.setOnLoadCallback(() => {
                new google.visualization.Gauge(document.getElementById('g')).draw(google.visualization.arrayToDataTable([['Label', 'Value'],['Contention', $($contentionScore * 100)]]), {redFrom: 70, redTo: 100, yellowFrom: 40, yellowTo: 70});
                new google.visualization.PieChart(document.getElementById('p')).draw(google.visualization.arrayToDataTable([['PID','Avg'], $pieRows]), {title:'Top CPU by PID'});
                new google.visualization.LineChart(document.getElementById('l')).draw(google.visualization.arrayToDataTable([['Time','Ready','MHz'], $lineRowsJoined]), {title:'VMware Health Context', series:{0:{targetAxisIndex:0},1:{targetAxisIndex:1}}, vAxes:{0:{title:'Ready (ms)'},1:{title:'MHz'}}});
            });
        </script>
        <style>body{font-family:'Segoe UI',sans-serif;background:#f4f7f6;margin:30px} .card{background:white;padding:20px;border-radius:10px;box-shadow:0 4px 6px rgba(0,0,0,0.1);margin-bottom:20px; border-left: 10px solid $scoreColor;}</style>
    </head>
    <body>
        <div class="card">
            <h1>Host: $hostName</h1>
            <div style="display:flex;align-items:center;">
                <div id="g" style="width:200px;height:150px"></div>
                <div><span style="font-size:2em;font-weight:bold;color:$scoreColor">$contentionScore</span><br/>Score correlates Tanium Bursts to VM Scheduling Wait Time.</div>
            </div>
            <div style="display:flex;"><div id="p" style="width:45%;height:400px"></div><div id="l" style="width:55%;height:400px"></div></div>
            <h3>Tanium PID Detail</h3>
            <table style="width:100%;text-align:left;border-collapse:collapse;"><thead><tr style="background:#eee"><th>PID</th><th>Avg</th><th>Peak</th></tr></thead><tbody>$tanRows</tbody></table>
        </div>
    </body></html>
"@
    $htmlBody | Out-File (Join-Path $reportFolder "$hostName`_Analysis.html")

    # Add to Summary CSV
    $masterSummary.Add([PSCustomObject]@{
        HostName        = $hostName
        ContentionScore = $contentionScore
        AvgStolenTime   = [Math]::Round(($stolenList | Measure-Object -Average).Average, 2)
        MaxTaniumPeak   = ($processSummary | Where-Object IsTan | Measure-Object Peak -Maximum).Maximum
        PeakStolenEvent = $peakTime
        Status          = if ($contentionScore -gt 0.6) { "High Contention" } else { "Healthy" }
    })
}

# --- FINALIZE ---
$masterSummary | Export-Csv $summaryFile -NoTypeInformation
Write-Host "`nUtility Complete!" -ForegroundColor Green
Write-Host "1. Detailed HTML reports in: $reportFolder"
Write-Host "2. Fleet Summary CSV: $summaryFile"
