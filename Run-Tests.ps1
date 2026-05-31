# Run all Pester tests
# Usage: .\Run-Tests.ps1 [-Detailed] [-Coverage]

param(
    [switch]$Detailed,
    [switch]$Coverage
)

$ErrorActionPreference = 'Stop'

$pester = Get-Module Pester -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1

if (-not $pester -or $pester.Version.Major -lt 5) {
    Write-Host 'Pester 5.x required. Installing...' -ForegroundColor Yellow

    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    }

    if ((Get-PSRepository -Name PSGallery).InstallationPolicy -ne 'Trusted') {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    }

    Install-Module Pester -Force -Scope CurrentUser -SkipPublisherCheck
    Import-Module Pester -MinimumVersion 5.0 -Force
}
else {
    Import-Module Pester -MinimumVersion 5.0 -Force
}

$config = New-PesterConfiguration
$config.Run.Path = Join-Path $PSScriptRoot 'tests'
$config.Run.Exit = $true

if ($Detailed) {
    $config.Output.Verbosity = 'Detailed'
}
else {
    $config.Output.Verbosity = 'Normal'
}

if ($Coverage) {
    $config.CodeCoverage.Enabled = $true
    $config.CodeCoverage.Path = @(
        "$PSScriptRoot\src\*.ps1"
    )
}

Write-Host "`n--- PS1Timer TESTS ---`n" -ForegroundColor Cyan
Invoke-Pester -Configuration $config
