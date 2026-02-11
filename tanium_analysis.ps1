# Logic for Health Color and Label
    $scoreColor = if ($score -gt 0.7) { "#d9534f" } elseif ($score -gt 0.4) { "#f0ad4e" } else { "#5cb85c" }
    $scoreLabel = if ($score -gt 0.7) { "CRITICAL" } elseif ($score -gt 0.4) { "WARNING" } else { "OPTIMAL" }

    $html = @"
    <html>
      <head>
        <script type="text/javascript" src="https://www.gstatic.com/charts/loader.js"></script>
        <script type="text/javascript">
          google.charts.load('current', {'packages':['corechart', 'gauge']});
          google.charts.setOnLoadCallback(drawCharts);
          function drawCharts() {
            // Contention Gauge
            var gaugeData = google.visualization.arrayToDataTable([['Label', 'Value'],['Contention', $($score * 100)]]);
            var gaugeOptions = { width: 400, height: 120, redFrom: 70, redTo: 100, yellowFrom: 40, yellowTo: 70, minorTicks: 5 };
            new google.visualization.Gauge(document.getElementById('gauge_div')).draw(gaugeData, gaugeOptions);

            // CPU Distribution Pie
            var pieData = google.visualization.arrayToDataTable([['PID', 'Avg'], $pieRows]);
            new google.visualization.PieChart(document.getElementById('pie_div')).draw(pieData, {title: 'Process CPU Distribution'});

            // Health Over Time Line
            var lineData = google.visualization.arrayToDataTable([['Time', 'Ready (ms)', 'Eff MHz'], $lineRows]);
            new google.visualization.LineChart(document.getElementById('line_div')).draw(lineData, {
              title: 'Hypervisor Health Context',
              series: { 0: {targetAxisIndex: 0}, 1: {targetAxisIndex: 1} },
              vAxes: { 0: {title: 'Ready Time'}, 1: {title: 'MHz'} }
            });
          }
        </script>
        <style>
          body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background: #f8f9fa; margin: 40px; }
          .header { background: white; padding: 20px; border-radius: 10px; border-left: 10px solid $scoreColor; box-shadow: 0 4px 6px rgba(0,0,0,0.1); }
          .score-badge { font-size: 2em; font-weight: bold; color: $scoreColor; }
          .grid { display: flex; flex-wrap: wrap; gap: 20px; margin-top: 20px; }
          .card { background: white; padding: 15px; border-radius: 10px; flex: 1; min-width: 45%; box-shadow: 0 2px 4px rgba(0,0,0,0.05); }
        </style>
      </head>
      <body>
        <div class="header">
          <h1>Quality Analysis: $hostName</h1>
          <div style="display: flex; align-items: center;">
            <div id="gauge_div" style="width: 150px;"></div>
            <div style="margin-left: 30px;">
              <span class="score-badge">$score</span> - <strong>$scoreLabel</strong><br/>
              <em>Correlation between Tanium CPU activity and VMware Ready Time spikes.</em>
            </div>
          </div>
        </div>
        <div class="grid">
          <div class="card" id="pie_div" style="height: 400px;"></div>
          <div class="card" id="line_div" style="height: 400px;"></div>
        </div>
        <div class="card" style="margin-top: 20px;">
          <h2>Tanium PID Performance Table</h2>
          <table style="width: 100%; border-collapse: collapse;">
            <thead><tr style="background: #eee;"><th>PID</th><th>Avg CPU</th><th>Peak Burst</th></tr></thead>
            <tbody>$tanRows</tbody>
          </table>
        </div>
      </body>
    </html>
"@
