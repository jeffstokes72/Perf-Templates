# Tanium & VMware Performance Quality Analyzer (v11.1)

## Overview
This utility is a professional diagnostic tool designed to resolve complex performance escalations in VMware Guest OS environments. It specifically correlates **Tanium Client** and **TaniumCX** child process activity with hypervisor-level scheduling health.

## Core Diagnostic Logic

### 1. Contention Scoring (Pearson Correlation)
Identifies causality between workload bursts and hypervisor scheduling delays.
* **Metric**: Correlation of `Process\% Processor Time` to `VM Processor\CPU stolen time`.
* **Interpretation**: A score above **0.7** indicates that Guest OS activity is directly competing for physical CPU cycles, leading to scheduling wait states (Ready Time).



### 2. Kernel-to-User (K/U) Ratio
A primary indicator of filter driver interference (AV, EDR, DLP, or Indexers).
* **Logic**: `Privileged Time / User Time`.
* **Benchmark**: Ratios exceeding **0.3** suggest the OS kernel is expending excessive resources to support application I/O, often pointing to a security software exclusion failure.



### 3. Memory Slope Analysis (Leak Detection)
Detects memory leaks through trend analysis rather than static thresholding.
* **Logic**: Uses linear regression to calculate the slope of `Private Bytes` over the capture duration.
* **Flag**: A positive slope exceeding **0.5 MB per interval** indicates a sustained incline in memory consumption.



### 4. Fidelity Check (Sampling Interval)
Validates the quality of telemetry.
* **Criteria**: Sampling intervals greater than **15 seconds** trigger a warning. 
* **Reasoning**: Coarse telemetry aliases short-lived Tanium sensor bursts, which often complete in 2–5 seconds, potentially leading to false-negative results.

## Usage
1. **Stage**: Place `.blg` files in `C:\PerfLogs\Source`.
2. **Run**: Execute the utility via PowerShell (Administrator).
3. **Review**:
    - Sort `Fleet_Contention_Summary.csv` by **ContentionScore**.
    - Open Host-specific HTML reports for interactive charts and "Actionable Insights."



## Prerequisites
- **Admin Rights**: Required for the `relog.exe` utility.
- **VMware Tools**: Must be running to provide `VM Processor` counters.
- **Pidness**: `ProcessNameFormat` registry key must be set to `2` for PID tracking.
