# Setup Paths
$csvPath = "C:\PerfLogs\Analysis"
$outputPath = "C:\PerfLogs\Reports"
if (!(Test-Path $outputPath)) { New-Item -ItemType Directory -Path $outputPath }

$csvFiles = Get-ChildItem -Path $csvPath -Filter "*.csv"

foreach ($file in $csvFiles) {
    Write-Host "Processing $hostName Analysis..." -ForegroundColor Cyan
    $data = Import-Csv $file.FullName
    $sampleHeader = ($data[0].psobject.Properties.Name | Where-Object { $_ -like "\\*" })[0]
    $hostName = $sampleHeader.Split('\')[2]
    
    # 1. Gather VMware Metrics
    $vmStats = $data | ForEach-Object {
        [PSCustomObject]@{
            Time   = $_."(PDH-CSV 4.0)"
            Stolen = [double]$_."\\$hostName\VM Processor(_Total)\CPU stolen time"
            MHz    = [double]$_."\\$hostName\VM Processor(_Total)\Effective VM Speed in MHz"
        }
    }

    # 2. Gather Process Metrics with PEAK analysis
    $procCols = $data[0].psobject.Properties.Name | Where-Object { $_ -like "*Process(*)*% Processor Time*" }
    $processSummary = foreach ($col in $procCols) {
        $fullName = ([regex]::Match($col, "\((.*?)\)")).Groups[1].Value
        if ($fullName -match "_Total|Idle") { continue }
        
        $measurements = $data."$col" | Measure-Object -Average -Maximum
        [PSCustomObject]@{
            PID    = $fullName
            Avg    = [Math]::Round($measurements.Average, 2)
            Peak   = [Math]::Round($measurements.Maximum, 2)
            IsTan  = $fullName -match "Tanium"
        }
    }

    # Data Formatting for HTML
    $pieRows = ($processSummary | Sort-Object Avg -Descending | Select-Object -First 12 | ForEach-Object { "['$($_.PID)', $($_.Avg)]" }) -join ","
    $lineRows = ($vmStats | ForEach-Object { "['$($_.Time)', $($_.Stolen), $($_.MHz)]" }) -join ","
    
    $taniumTable = $processSummary | Where-Object IsTan | Sort-Object Peak -Descending | ForEach-Object {
        "<tr><td>$($_.PID)</td><td>$($_.Avg)%</td><td>$($_.Peak)%</td></tr>"
    }

    # Generate Report
    $reportFile = Join-Path $outputPath "$hostName`_Full_Analysis.html"
    $html = @"
    <html>
      <head>
        <script type="text/javascript" src="https://www.gstatic.com/charts/loader.js"></script>
        <script type="text/javascript">
          google.charts.load('current', {'packages':['corechart', 'line', 'table']});
          google.charts.setOnLoadCallback(drawCharts);
          function drawCharts() {
            var pieData = google.visualization.arrayToDataTable([['PID', 'Avg CPU'], $pieRows]);
            new google.visualization.PieChart(document.getElementById('pie')).draw(pieData, {title:'Top CPU Consumers (Avg)'});

            var lineData = google.visualization.arrayToDataTable([['Time', 'Stolen', 'MHz'], $lineRows]);
            new google.visualization.LineChart(document.getElementById('line')).draw(lineData, {
                title:'VMware Performance Context',
                vAxes: { 0:{title:'Ready (ms)'}, 1:{title:'MHz'} },
                series: { 0:{targetAxisIndex:0}, 1:{targetAxisIndex:1} }
            });
          }
        </script>
        <style>
            body { font-family: 'Segoe UI', sans-serif; margin: 30px; background: #f4f7f6; }
            .container { background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
            table { width: 100%; border-collapse: collapse; margin-top: 20px; }
            th, td { padding: 12px; text-align: left; border-bottom: 1px solid #ddd; }
            th { background-color: #004b87; color: white; }
            tr:hover { background-color: #f5f5f5; }
        </style>
      </head>
      <body>
        <div class="container">
            <h1>Host: $hostName Analysis</h1>
            <div style="display: flex;">
                <div id="pie" style="width: 50%; height: 400px;"></div>
                <div id="line" style="width: 50%; height: 400px;"></div>
            </div>
            <h2>Tanium Process Deep Dive (Peak vs Average)</h2>
            <table>
                <thead><tr><th>Process_PID</th><th>Average Load</th><th>Peak Burst</th></tr></thead>
                <tbody>$($taniumTable -join "")</tbody>
            </table>
        </div>
      </body>
    </html>
"@
    $html | Out-File $reportFile
}
