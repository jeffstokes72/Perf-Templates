<#
.SYNOPSIS
    Professional Tanium & VMware Performance Utility.
    Version: 10.0
    
.DESCRIPTION
    - Full Lifecycle: Relog Conversion -> Host Grouping -> Analytics -> HTML Reporting.
    - Robust Error Handling: Validates counter existence and handles null/missing data safely.
    - Diagnostics: Contention Score, K/U Ratio, Memory Slope, Priority.
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

# Safe conversion to Double to prevent script termination on missing counters
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
Write-Host "--- STAGE 1: Converting BLGs ---" -ForegroundColor Cyan
$blgFiles = Get-ChildItem -Path $blgFolder -Filter "*.blg"

foreach ($file in $blgFiles) {
    $outputCsv = Join-Path $csvFolder ($file.BaseName + ".csv")
    if (!(Test-Path $outputCsv)) {
        Write-Host "Relogging $($file.Name)..." -ForegroundColor Gray
        # Using -q to suppress error messages from relog if specific counters are missing
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
Write-Host "`n--- STAGE 2: Processing Hosts ---" -ForegroundColor Cyan
$csvFiles = Get-ChildItem -Path $csvFolder -Filter "*.csv"
$masterSummary = New-Object System.Collections.Generic.List[PSCustomObject]

$hostedFiles = $csvFiles | Group-Object {
    $firstLine = Get-Content $_.FullName -TotalCount 2 | Select-Object -Last 1
    if ($firstLine -match "\\\\(.*?)\\") { $Matches[1] } else { "UnknownHost" }
}

foreach ($group in $hostedFiles) {
    $hostName = $group.Name
    $allData = foreach ($f in $group.Group) { Import-Csv $f.FullName }
    $headers = $allData[0].psobject.Properties.Name
    
    # 1. System Metrics with Validation
    $stolenKey = "\\$hostName\VM Processor(_Total)\CPU stolen time"
    $iopsKey   = "\\$hostName\PhysicalDisk(_Total)\Disk Transfers/sec"
    
    $stolenList = $allData | ForEach-Object { ConvertTo-SafeDouble $_."$stolenKey" }
    $iopsList   = $allData | ForEach-Object { ConvertTo-SafeDouble $_."$iopsKey" }
    $timeList   = $allData | ForEach-Object { $_."(PDH-CSV 4.0)" }
    
    # 2. Process Metrics
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
        $avgPrio = ($allData | ForEach-Object { ConvertTo-SafeDouble $_."$prioCol" } | Measure-Object -Average).Average
        $memVals = $allData | ForEach-Object { ConvertTo-SafeDouble $_."$memCol" }
        
        [PSCustomObject]@{ 
            PID       = $pidName
            AvgCPU    = [Math]::Round(($allData | ForEach-Object { ConvertTo-SafeDouble $_."$col" } | Measure-Object -Average).Average, 2)
            KURatio   = if ($avgUser -gt 0) { [Math]::Round(($avgPriv / $avgUser), 3) } else { 0 }
            MemSlope  = [Math]::Round((Get-TrendSlope $memVals) / 1MB, 4)
            BasePrio  = [Math]::Round($avgPrio, 0)
            PeakMemMB = [Math]::Round(($memVals | Measure-Object -Maximum).Maximum / 1MB, 2)
            IsTan     = $pidName -match "Tanium"
        }
    }

    # 3. Contention Scoring
    $tanAgg = foreach ($row in $allData) { 
        $s = 0; foreach ($c in ($headers | Where-Object {$_ -match "Tanium.*Processor Time"})) { $s += ConvertTo-SafeDouble $row."$c" }; $s 
    }
    $score = Get-ContentionScore $stolenList $tanAgg

    # --- INSIGHTS WITH ERROR AWARENESS ---
    $insights = New-Object System.Collections.Generic.List[string]
    if (!($headers -contains $stolenKey)) { $insights.Add("<strong>Data Gap:</strong> VMware Processor counters were not found. Ensure VMware Tools is installed and running on the guest.") }
    elseif ($score -gt 0.7) { $insights.Add("<strong>Scheduling Contention:</strong> High correlation detected between workload bursts and hypervisor ready time.") }
    
    if (($processSummary | Where-Object { $_.IsTan -and $_.KURatio -gt 0.3 })) { $insights.Add("<strong>Filter Driver Overhead:</strong> Elevated kernel-to-user ratios detected; review security exclusions.") }
    if (($processSummary | Where-Object { $_.IsTan -and $_.MemSlope -gt 0.5 })) { $insights.Add("<strong>Memory Trend:</strong> Steady incline in private bytes observed; monitor for leaks.") }
    if ($insights.Count -eq 0) { $insights.Add("System metrics appear healthy.") }

    # --- STAGE 3: HTML REPORT ---
    $scoreColor = if ($score -gt 0.7) { "#d9534f" } elseif ($score -gt 0.4) { "#f0ad4e" } else { "#5cb85c" }
    $tanRows = ($processSummary | Where-Object IsTan | Sort-Object AvgCPU -Descending | ForEach-Object { 
        $lStyle = if ($_.MemSlope -gt 0.5) { "background:#ffcccc;" } else { "" }
        $kStyle = if ($_.KURatio -gt 0.3)  { "color:red; font-weight:bold;" } else { "" }
        "<tr style='$lStyle'><td>$($_.PID)</td><td>$($_.AvgCPU)%</td><td style='$kStyle'>$($_.KURatio)</td><td>$($_.BasePrio)</td><td>$($_.MemSlope) MB/inc</td><td>$($_.PeakMemMB) MB</td></tr>" 
    }) -join ""
    
    # Chart Data Assembly
    $pieRows  = ($processSummary | Sort-Object AvgCPU -Descending | Select-Object -First 12 | ForEach-Object { "['$($_.PID)', $($_.AvgCPU)]" }) -join ","
    $lineRows = for($i=0; $i -lt $stolenList.Count; $i++) { "['$($timeList[$i])', $($stolenList[$i]), $($iopsList[$i])]" }

    $htmlBody = @"
    <html>
    <head>
        <script src="https://www.gstatic.com/charts/loader.js"></script>
        <script>
            google.charts.load('current', {'packages':['corechart', 'gauge']});
            google.charts.setOnLoadCallback(() => {
                new google.visualization.Gauge(document.getElementById('g')).draw(google.visualization.arrayToDataTable([['Label', 'Value'],['Contention', $($score * 100)]]), {redFrom: 70, redTo: 100, yellowFrom: 40, yellowTo: 70});
                new google.visualization.PieChart(document.getElementById('p')).draw(google.visualization.arrayToDataTable([['PID','Avg'], $pieRows]), {title:'Process CPU Distribution'});
                new google.visualization.LineChart(document.getElementById('l')).draw(google.visualization.arrayToDataTable([['Time','Ready','IOPS'], $($lineRows -join ",")]), {title:'Scheduling vs Disk', series:{0:{targetAxisIndex:0},1:{targetAxisIndex:1}}, vAxes:{0:{title:'Ready (ms)'},1:{title:'IOPS'}}});
            });
        </script>
        <style>
            body{font-family:'Segoe UI',sans-serif;background:#f4f7f6;margin:30px} 
            .card{background:white;padding:20px;border-radius:10px;box-shadow:0 4px 6px rgba(0,0,0,0.1);margin-bottom:20px; border-left:10px solid $scoreColor;}
            .insight-box { background: #fdfdfe; border: 1px solid #d1d1d1; padding: 15px; border-radius: 5px; margin-top: 10px; }
            table{width:100%;border-collapse:collapse;margin-top:15px; font-size: 0.9em;}
            th, td{padding:10px;border-bottom:1px solid #ddd;text-align:left;}
            th{background:#eee}
        </style>
    </head>
    <body>
        <div class="card">
            <h1>Quality Analysis: $hostName</h1>
            <div style="display:flex;align-items:center;">
                <div id="g" style="width:200px;height:150px"></div>
                <div style="margin-left:20px"><span style="font-size:2em;font-weight:bold;color:$scoreColor">$score</span> - Contention Score</div>
            </div>
            <div class="insight-box"><strong>Observations:</strong><ul><li>$($insights -join "</li><li>")</li></ul></div>
            <div style="display:flex;"><div id="p" style="width:40%;height:400px"></div><div id="l" style="width:60%;height:400px"></div></div>
            <table><thead><tr><th>PID</th><th>Avg CPU</th><th>K/U Ratio</th><th>Base Prio</th><th>Mem Slope</th><th>Peak MB</th></tr></thead><tbody>$tanRows</tbody></table>
        </div>
    </body></html>
"@
    $htmlBody | Out-File (Join-Path $reportFolder "$hostName`_Quality_Report.html")

    $masterSummary.Add([PSCustomObject]@{
        HostName      = $hostName
        Contention    = $score
        Status        = if ($score -gt 0.7) { "Critical" } elseif (!($headers -contains $stolenKey)) { "Data Missing" } else { "Healthy" }
    })
}

$masterSummary | Export-Csv $summaryFile -NoTypeInformation
Write-Host "`nUtility Complete. See $reportFolder" -ForegroundColor Green
