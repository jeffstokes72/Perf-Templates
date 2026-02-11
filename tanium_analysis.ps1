<#
.SYNOPSIS
    Professional Tanium & VMware Performance Utility.
    Version: 9.0
    
.DESCRIPTION
    - Full Lifecycle: Relog Conversion -> Host Grouping -> Analytics -> HTML Reporting.
    - Diagnostics: 
        1. Contention Score: Correlation of Tanium bursts to VMware Ready Time.
        2. K/U Ratio: Detects AV/EDR hooking/interference (Privileged/User ratio).
        3. Memory Slope: Linear regression to detect leaks over time.
        4. Priority: Detects priority deviations from 'Normal' (8).
    - Features: Actionable Insights Summary providing peer-friendly, logic-based RCA suggestions.
#>

# --- CONFIGURATION ---
$blgFolder    = "C:\PerfLogs\Source"    # Input folder for BLG files
$csvFolder    = "C:\PerfLogs\Analysis"  # Work folder for CSVs
$reportFolder = "C:\PerfLogs\Reports"   # Output folder for HTML/CSV Summary
$summaryFile  = Join-Path $reportFolder "Fleet_Contention_Summary.csv"

# Initialization
foreach ($path in @($csvFolder, $reportFolder)) {
    if (!(Test-Path $path)) { New-Item -ItemType Directory -Path $path }
}

# --- MATH HELPERS ---

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
            -q "\VM Processor(_Total)\*"
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
    $allData = foreach ($f in $group.Group) { Import-Csv $f.FullName }
    
    # System Metrics
    $stolenList = $allData | ForEach-Object { [double]$_."\\$hostName\VM Processor(_Total)\CPU stolen time" }
    $iopsList   = $allData | ForEach-Object { [double]$_."\\$hostName\PhysicalDisk(_Total)\Disk Transfers/sec" }
    $timeList   = $allData | ForEach-Object { $_."(PDH-CSV 4.0)" }
    
    # Process Metrics
    $procCols = $allData[0].psobject.Properties.Name | Where-Object { $_ -like "*Process(*)*% Processor Time*" }
    $processSummary = foreach ($col in $procCols) {
        $pidName = ([regex]::Match($col, "\((.*?)\)")).Groups[1].Value
        if ($pidName -match "_Total|Idle") { continue }
        
        $privCol = "\\$hostName\Process($pidName)\% Privileged Time"
        $userCol = "\\$hostName\Process($pidName)\% User Time"
        $memCol  = "\\$hostName\Process($pidName)\Private Bytes"
        $prioCol = "\\$hostName\Process($pidName)\Priority Base"
        
        $avgPriv = ($allData."$privCol" | Measure-Object -Average).Average
        $avgUser = ($allData."$userCol" | Measure-Object -Average).Average
        $avgPrio = ($allData."$prioCol" | Measure-Object -Average).Average
        $memVals = $allData."$memCol" | ForEach-Object { [double]$_ }
        
        [PSCustomObject]@{ 
            PID       = $pidName
            AvgCPU    = [Math]::Round(($allData."$col" | Measure-Object -Average).Average, 2)
            KURatio   = if ($avgUser -gt 0) { [Math]::Round(($avgPriv / $avgUser), 3) } else { 0 }
            MemSlope  = [Math]::Round((Get-TrendSlope $memVals) / 1MB, 4)
            BasePrio  = [Math]::Round($avgPrio, 0)
            PeakMemMB = [Math]::Round(($memVals | Measure-Object -Maximum).Maximum / 1MB, 2)
            IsTan     = $pidName -match "Tanium"
        }
    }

    # Contention Math
    $tanCols = $allData[0].psobject.Properties.Name | Where-Object { $_ -match "Tanium" -and $_ -like "*% Processor Time*" }
    $tanAgg  = foreach ($row in $allData) { $s = 0; foreach ($c in $tanCols) { $s += [double]$row."$c" }; $s }
    $score   = Get-ContentionScore $stolenList $tanAgg

    # --- ACTIONABLE INSIGHTS LOGIC ---
    $insights = New-Object System.Collections.Generic.List[string]
    if ($score -gt 0.7) { $insights.Add("<strong>Scheduling Contention:</strong> High correlation detected between workload bursts and hypervisor ready time. Consider reviewing vCPU allocation or host over-commitment.") }
    if (($processSummary | Where-Object { $_.IsTan -and $_.KURatio -gt 0.3 })) { $insights.Add("<strong>Filter Driver Overhead:</strong> Elevated kernel-to-user ratios observed. Validating security/AV exclusions for Tanium paths may optimize performance.") }
    if (($processSummary | Where-Object { $_.IsTan -and $_.MemSlope -gt 0.5 })) { $insights.Add("<strong>Memory Trend:</strong> Steady incline in private bytes observed. Review of recently deployed sensors or content is recommended.") }
    if (($processSummary | Where-Object { $_.IsTan -and $_.BasePrio -ne 8 })) { $insights.Add("<strong>Priority Deviation:</strong> Process priorities differ from standard levels, which may impact guest-level scheduling stability.") }
    if ($insights.Count -eq 0) { $insights.Add("System metrics were within optimal parameters during this capture period.") }

    # --- STAGE 3: HTML REPORT ---
    $scoreColor = if ($score -gt 0.7) { "#d9534f" } elseif ($score -gt 0.4) { "#f0ad4e" } else { "#5cb85c" }
    $tanRows = ($processSummary | Where-Object IsTan | Sort-Object AvgCPU -Descending | ForEach-Object { 
        $lStyle = if ($_.MemSlope -gt 0.5) { "background:#ffcccc;" } else { "" }
        $kStyle = if ($_.KURatio -gt 0.3)  { "color:red; font-weight:bold;" } else { "" }
        $pStyle = if ($_.BasePrio -ne 8)   { "background:#fff3cd;" } else { "" }
        "<tr style='$lStyle'><td>$($_.PID)</td><td>$($_.AvgCPU)%</td><td style='$kStyle'>$($_.KURatio)</td><td style='$pStyle'>$($_.BasePrio)</td><td>$($_.MemSlope) MB/inc</td><td>$($_.PeakMemMB) MB</td></tr>" 
    }) -join ""

    $pieRows  = ($processSummary | Sort-Object AvgCPU -Descending | Select-Object -First 12 | ForEach-Object { "['$($_.PID)', $($_.AvgCPU)]" }) -join ","
    $lineRowsJoined = (for($i=0; $i -lt $stolenList.Count; $i++) { "['$($timeList[$i])', $($stolenList[$i]), $($iopsList[$i])]" }) -join ","

    $htmlBody = @"
    <html>
    <head>
        <script src="https://www.gstatic.com/charts/loader.js"></script>
        <script>
            google.charts.load('current', {'packages':['corechart', 'gauge']});
            google.charts.setOnLoadCallback(() => {
                new google.visualization.Gauge(document.getElementById('g')).draw(google.visualization.arrayToDataTable([['Label', 'Value'],['Contention', $($score * 100)]]), {redFrom: 70, redTo: 100, yellowFrom: 40, yellowTo: 70});
                new google.visualization.PieChart(document.getElementById('p')).draw(google.visualization.arrayToDataTable([['PID','Avg'], $pieRows]), {title:'Process CPU Distribution'});
                new google.visualization.LineChart(document.getElementById('l')).draw(google.visualization.arrayToDataTable([['Time','Ready','IOPS'], $lineRowsJoined]), {title:'Scheduling Health vs Disk Activity', series:{0:{targetAxisIndex:0},1:{targetAxisIndex:1}}, vAxes:{0:{title:'Ready (ms)'},1:{title:'IOPS'}}});
            });
        </script>
        <style>
            body{font-family:'Segoe UI',sans-serif;background:#f4f7f6;margin:30px} 
            .card{background:white;padding:20px;border-radius:10px;box-shadow:0 4px 6px rgba(0,0,0,0.1);margin-bottom:20px; border-left:10px solid $scoreColor;}
            .insight-box { background: #fdfdfe; border: 1px solid #d1d1d1; padding: 15px; border-radius: 5px; margin-top: 10px; }
            table{width:100%;border-collapse:collapse;margin-top:15px; font-size: 0.9em;}
            th, td{padding:10px;border-bottom:1px solid #ddd;text-align:left;}
            th{background:#eee}
            .ref-box { background: #e9ecef; padding: 15px; border-radius: 5px; font-size: 0.85em; margin-top: 20px; }
            .ref-box a { color: #0056b3; text-decoration: none; font-weight: bold; }
        </style>
    </head>
    <body>
        <div class="card">
            <h1>Quality Analysis: $hostName</h1>
            <div style="display:flex;align-items:center;">
                <div id="g" style="width:200px;height:150px"></div>
                <div style="margin-left:20px">
                    <span style="font-size:2em;font-weight:bold;color:$scoreColor">$score</span> - <strong>Contention Score</strong><br/>
                    <em>Correlation of workload activity to hypervisor scheduling delays.</em>
                </div>
            </div>
            
            <div class="insight-box">
                <strong>Observations & Opportunities:</strong>
                <ul><li>$($insights -join "</li><li>")</li></ul>
            </div>

            <div style="display:flex;"><div id="p" style="width:40%;height:400px"></div><div id="l" style="width:60%;height:400px"></div></div>
            <h3>Tanium Diagnostic Table</h3>
            <table><thead><tr><th>PID</th><th>Avg CPU</th><th>K/U Ratio</th><th>Base Prio</th><th>Mem Slope</th><th>Peak MB</th></tr></thead><tbody>$tanRows</tbody></table>
            
            <div class="ref-box">
                <strong>Technical Reference Library:</strong><br/><br/>
                • <strong>K/U Ratio & Privileged Time:</strong> <a href="https://learn.microsoft.com/en-us/troubleshoot/windows-server/performance/troubleshoot-high-cpu-usage-privileged-time" target="_blank">Troubleshooting High Privileged Time</a><br/>
                • <strong>Memory Management (Private Bytes):</strong> <a href="https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/the-!address-extension" target="_blank">Understanding Process Memory Counters</a><br/>
                • <strong>Process Priority:</strong> <a href="https://learn.microsoft.com/en-us/windows/win32/procthread/scheduling-priorities" target="_blank">Windows Scheduling Priorities</a><br/>
                • <strong>VMware Ready & Stolen Time:</strong> <a href="https://kb.vmware.com/s/article/2002181" target="_blank">Troubleshooting ESXi CPU Contention</a><br/>
                • <strong>VMware Tools Performance Counters:</strong> <a href="https://docs.vmware.com/en/VMware-Tools/12.4.0/com.vmware.vsphere.vmwaretools.doc/GUID-9626D686-224C-461B-8724-4B2E05763B34.html" target="_blank">Guest OS Performance Counters via VMware Tools</a>
            </div>
        </div>
    </body></html>
"@
    $htmlBody | Out-File (Join-Path $reportFolder "$hostName`_Quality_Report.html")

    $masterSummary.Add([PSCustomObject]@{
        HostName      = $hostName
        Contention    = $score
        AvgKURatio    = [Math]::Round(($processSummary | Where-Object IsTan | Measure-Object KURatio -Average).Average, 3)
        MaxMemSlope   = ($processSummary | Where-Object IsTan | Measure-Object MemSlope -Maximum).Maximum
        Status        = if ($score -gt 0.7) { "Critical" } elseif ($score -gt 0.4) { "Warning" } else { "Healthy" }
    })
}

# --- FINALIZE ---
$masterSummary | Export-Csv $summaryFile -NoTypeInformation
Write-Host "`nUtility Complete! Reports generated in: $reportFolder" -ForegroundColor Green
