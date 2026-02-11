# Tanium & VMware Performance Quality Analyzer (v12.1)

## Overview
This utility is a non-admin, portable diagnostic tool designed for analyzing performance telemetry from VMware Guest OS environments. It focuses on the impact of **Tanium Client** and **TaniumCX** child processes on hypervisor scheduling.

## Version 12 updates
- **Dedicated Directory**: Operations are centralized in `C:\TaniumPerformanceAnalysis`.
- **Non-Admin Support**: Replaced `relog.exe` with native `Import-Counter`.
- **Portability**: Designed to run on analyst workstations separate from the data collection source.

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
1. **Stage**: Place `.blg` files in `C:\TaniumPerformanceAnalysis\Source`.
2. **Run**: Execute the utility via standard PowerShell.
3. **Review**:
    - Sort `Fleet_Contention_Summary.csv` by **ContentionScore**.
    - Open Host-specific HTML reports in the `\Reports` folder.
