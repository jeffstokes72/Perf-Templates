# Tanium & VMware Performance Quality Analyzer (v12.7)

## Overview
This utility is a non-admin, portable diagnostic tool designed for analyzing performance telemetry from VMware Guest OS environments. It focuses on the impact of **Tanium Client** and **TaniumCX** child processes on hypervisor scheduling.

## Version 12.7 updates
- **Dedicated Directory**: Operations are centralized in `C:\TaniumPerformanceAnalysis`.
- **Compatibility Upgrade**: BLG files are normalized with `relog.exe` before analysis.
- **Portability**: Designed to run on analyst workstations separate from the data collection source.
- **Special Character Filename Support**: BLG files are copied to a safe temp buffer before import.
- **Empty Capture Guardrail**: 0-byte BLG files are skipped automatically with a clear log message.
- **Process V2 Support**: Parser accepts both `Process(*)` and `Process V2(*)` counters.
- **Duplicate Counter Protection**: Interval metrics are de-duplicated when both Process and Process V2 samples overlap.
- **Recursive Source Discovery**: BLG files are discovered recursively under `C:\TaniumPerformanceAnalysis\Source`.
- **Duplicate Filename Safe Output**: Report naming includes source path tokens so duplicate BLG filenames do not collide.
- **Parallel Processing Default**: Data processing uses up to **8 CPUs** by default for faster multi-BLG analysis.

## Core Diagnostic Logic

### 1. Contention Scoring (Pearson Correlation)
Identifies causality between workload bursts and hypervisor scheduling delays.
* **Metric**: Correlation of `Process\% Processor Time` to `VM Processor\CPU stolen time`.
* **Interpretation**: A score above **0.7** indicates that Guest OS activity is directly competing for physical CPU cycles.



### 2. Kernel-to-User (K/U) Ratio
A primary indicator of filter driver interference (AV, EDR, DLP).
* **Logic**: `Privileged Time / User Time`. Ratios > **0.3** suggest exclusion failures.



### 3. Memory Slope Analysis (Leak Detection)
* **Logic**: Linear regression slope of `Private Bytes`.
* **Flag**: A positive slope exceeding **0.5 MB per interval** indicates a sustained leak trend.



## Usage
1. **Stage**: Place `.blg` files anywhere under `C:\TaniumPerformanceAnalysis\Source` (subfolders supported).
2. **Run**: Execute the utility via standard PowerShell (defaults to up to 8 CPUs, override with `-MaxProcessingCpus <n>`).
3. **Review**:
    - Sort `Fleet_Contention_Summary.csv` by **ContentionScore**.
    - Open Host-specific HTML reports in the `\Reports` folder.
