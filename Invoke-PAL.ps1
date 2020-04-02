<#
.Synopsis
A simple tool to execute the PAL tool on a folder of blg files.
.DESCRIPTION
A simple tool to execute the PAL tool on a folder of blg files.
.EXAMPLE
.\Invoke-PAL.ps1 -LogPath c:\Perf
.EXAMPLE
.\Invoke-PAL.ps1 -LogPath c:\Perf -PALps1 c:\PAL\PAL.ps1 -ThresholdFile C:\PAL\SystemOverview.xml -NumberofThreads -OutputDir C:\Perf\Reports
.NOTES
Created by: Jason Wasser @wasserja
Modified: 12/20/2019

Changelog
12/20/2019 - added the ability to look for blg and/or csv files

The genesis of this idea comes from Jeff Stokes @WindowsPerf.

.LINK
https://github.com/clinthuffman/PAL
#>
[cmdletbinding()]
param (
    [string]$LogPath = 'C:\Scratch\perf',
    [string]$FileTypes = '^.*\.(blg|csv)$',
    [string]$PALps1 = 'C:\PAL\PAL.ps1',
    [string]$ThresholdFile = 'C:\PAL\SystemOverview.xml',
    [int]$NumberOfThreads = 16,
    [string]$OS = 'Windows Server',
    [int]$PhysicalMemory = 16,
    [int]$UserVa = 2048,
    [string]$OutputDir = $LogPath
)

if (Test-Path $LogPath) {
    Write-Verbose "Found $LogPath. Continuing."
    if (Test-Path $PALps1) {
        Write-Verbose "Found PAL script $PALps1. Setting location to $((Get-Item -Path $PALps1).DirectoryName)"
        # Setting current directory to PAL tool. Required to find counter languages.
        Set-Location -Path (Get-Item -Path $PALps1).DirectoryName
        
        # Gathering all blg files in the specified path
        $LogFiles = Get-ChildItem -Path $LogPath | Where-Object -FilterScript {$_.Name -match $FileTypes}
        
        # Running PAL tool on each blg file found
        foreach ($LogFile in $LogFiles) {
            Write-Verbose -Message "Analyzing $($LogFile.FullName)"
            & cmd /c start /LOW /WAIT Powershell -ExecutionPolicy ByPass -NoProfile -File $PALps1 -Log $($LogFile.FullName)-ThresholdFile $ThresholdFile -Interval "AUTO" -IsOutputHtml $True -HtmlOutputFileName "[LogFileName]_PAL_ANALYSIS_[DateTimeStamp].htm" -IsOutputXml $False -XmlOutputFileName "[LogFileName]_PAL_ANALYSIS_[DateTimeStamp].xml" -AllCounterStats $True -OutputDir $OutputDir -NumberOfThreads $NumberOfThreads -IsLowPriority $True -OS $OS -PhysicalMemory $PhysicalMemory -UserVa $UserVa
            Write-Verbose -Message "Completed analysis of $($LogFile.FullName)"
        }
    }
    else {
        Write-Warning "Unable to find PAL script $PALps1"
        return
    }
}
else {
    Write-Warning -Message "Unable to find $LogPath"
}