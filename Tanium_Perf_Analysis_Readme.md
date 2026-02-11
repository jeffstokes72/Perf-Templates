# Tanium & VMware Performance Quality Analyzer

## Overview
This utility is designed for **Principal Escalation Engineers** and performance specialists to conduct root cause analysis (RCA) on Windows workloads running as VMware guests. It specifically focuses on identifying resource contention between Tanium client operations and hypervisor scheduling.

## Key Features
- **Automated Processing**: Batch converts `.blg` files to CSV and groups data by Hostname.
- **PID-Level Tracking**: Leverages the "pidness" format to track individual Tanium processes (Client vs. CX containers).
- **Contention Scoring**: A proprietary correlation metric linking application bursts to VMware "Ready Time" (Stolen Time).
- **AV Interference Detection**: Calculates Kernel-to-User (K/U) ratios to identify filter driver hooking.
- **Leak Detection**: Uses linear regression to calculate memory slopes (Private Bytes growth) over time.



## Diagnostic Metrics Explained

### Contention Score (0.0 - 1.0)
Measures the mathematical correlation between Tanium CPU bursts and hypervisor scheduling delays.
- **> 0.7**: Direct Contention. Application workload is clashing with host core availability.
- **< 0.4**: Healthy. Workload is independent of hypervisor scheduling pressure.

### Kernel-to-User (K/U) Ratio
A high ratio (> 0.3) indicates that for every unit of "User" work, the "Kernel" is working overtime. This is a primary indicator of security software (AV/EDR) intercepting application I/O.

### Memory Slope
Calculates the rate of change in `Private Bytes`. A positive slope (> 0.5 MB/interval) indicates a steady memory incline, suggesting a potential leak rather than a standard peak.


## Getting Started
1. Place all `.blg` files in `C:\PerfLogs\Source`.
2. Execute the PowerShell script.
3. Review `Fleet_Contention_Summary.csv` for high-level triage.
4. Open individual HTML reports for peer-friendly, actionable insights.

## Prerequisites
- Windows PowerShell 5.1+
- Administrative privileges (required for the `relog` utility).
- VMware Tools installed on Guest VMs (for `VM Processor` counters).
