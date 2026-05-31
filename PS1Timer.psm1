# PS1Timer root module (PowerShell 7.4+, Windows)

$script:PS1TimerRoot = $PSScriptRoot

if (-not $global:Config) {
    $global:Config = @{}
}

$configPath = Join-Path $script:PS1TimerRoot 'config.ps1'
if (Test-Path -LiteralPath $configPath) {
    . $configPath
}

. (Join-Path $script:PS1TimerRoot 'config\presets.ps1')
. (Join-Path $script:PS1TimerRoot 'src\TimerHelpers.ps1')
. (Join-Path $script:PS1TimerRoot 'src\Timer.ps1')

Write-Host 'PS1Timer loaded — type t or Timer for help' -ForegroundColor Green
