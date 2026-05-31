# PS1Timer profile loader — dot-source or add to $PROFILE:
#   . C:\path\to\PS1Timer\loader.ps1

#Requires -Version 7.4

if ($PSVersionTable.PSVersion.Major -lt 7 -or ($PSVersionTable.PSVersion.Major -eq 7 -and $PSVersionTable.PSVersion.Minor -lt 4)) {
    Write-Error 'PS1Timer requires PowerShell 7.4 or later.'
    return
}

if (-not $IsWindows) {
    Write-Warning 'PS1Timer requires Windows (Scheduled Task API). Commands may not work on this platform.'
}

$loaderRoot = $PSScriptRoot
Import-Module (Join-Path $loaderRoot 'PS1Timer.psd1') -Force -Global -DisableNameChecking
