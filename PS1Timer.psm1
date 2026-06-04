# PS1Timer root module (PowerShell 7.4+, Windows)

$script:PS1TimerRoot = $PSScriptRoot

if (-not $global:Config) {
    $global:Config = @{}
}

$userConfig = Join-Path $script:PS1TimerRoot 'config.ps1'
$exampleConfig = Join-Path $script:PS1TimerRoot 'config.example.ps1'
$configPath = if (Test-Path -LiteralPath $userConfig) { $userConfig } else { $exampleConfig }
if (Test-Path -LiteralPath $configPath) {
    . $configPath
}

. (Join-Path $script:PS1TimerRoot 'src\TimerHelpers.ps1')
. (Join-Path $script:PS1TimerRoot 'src\Timer.ps1')

$quietLoad = $false
if ($global:Config -and $global:Config.TimerDefaults -and $global:Config.TimerDefaults.QuietLoad) {
    $quietLoad = [bool]$global:Config.TimerDefaults.QuietLoad
}
if (-not $quietLoad) {
    Write-Host 'PS1Timer loaded — type t or Timer for help' -ForegroundColor Green
}
