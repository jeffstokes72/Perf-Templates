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
Write-Host "--- STAGE 1: Converting BLG to CSV
