# Shared Pester bootstrap — dot-source from BeforeAll (script scope).
# Loads config.example.ps1 then forces silent notification defaults.
# NEVER register real scheduled tasks or show popups/toasts/TTS during tests.

param(
    [Parameter(Mandatory)][string]$ModuleRoot,
    [Parameter(Mandatory)][string]$TestDrive
)

$script:PS1TimerTestMode = $true
$env:PS1TIMER_TEST = '1'

$exampleConfig = Join-Path $ModuleRoot 'config.example.ps1'
if (Test-Path -LiteralPath $exampleConfig) {
    . $exampleConfig
}
else {
    $global:Config = @{ TimerDefaults = @{}; Presets = @{}; Workouts = @{}; Webhooks = @{}; Sounds = @{}; Palettes = @{} }
}

$global:Config.TimerDefaults['Visual'] = 'none'
$global:Config.TimerDefaults['Sound'] = $false
$global:Config.TimerDefaults['Voice'] = $false
$global:Config.TimerDefaults['Countdown'] = 'none'
$global:Config.TimerDefaults['AfterStart'] = 'none'
$global:Config.TimerDefaults['Webhook'] = $null

. "$ModuleRoot\src\TimerHelpers.ps1"
. "$ModuleRoot\src\Timer.ps1"
Initialize-PS1TimerModuleConfig

$script:TimerDataFile = Join-Path $TestDrive 'ps-timers.json'
$script:TimerHistoryFile = Join-Path $TestDrive 'ps-timer-history.json'
$script:TimerForceSyncRegister = $true

function Reset-TimerDataCacheForTests {
    $script:TimerDataCache = $null
    $script:TimerDataCacheTime = [DateTime]::MinValue
    $script:TimerTaskNameCache = $null
    $script:TimerTaskNameCacheTime = [DateTime]::MinValue
    $script:TimerStaleCleanupLastRun = [DateTime]::MinValue
    $global:TimerTestGetPSTimerScheduledTaskNamesOverride = $null
    $global:TimerTestScheduledTaskNamesUseResultOverride = $false
    $global:TimerTestScheduledTaskNamesResultOverride = $null
}

function Set-TimerTestScheduledTaskNamesResultOverride {
    param([object]$Result)
    $global:TimerTestScheduledTaskNamesUseResultOverride = $true
    $global:TimerTestScheduledTaskNamesResultOverride = $Result
}

function Set-TimerTestScheduledTaskNamesOverride {
    param([scriptblock]$Implementation)
    $global:TimerTestGetPSTimerScheduledTaskNamesOverride = $Implementation
}

Mock Register-ScheduledTask { }
Mock Unregister-ScheduledTask { }
Mock Register-TimerScheduledTask { return $true }
Mock Start-Job { }
Mock Show-TimerPopup { }
Mock Show-TimerToast { }
Mock Show-TimerNotification { }
Mock Play-TimerSound { }
Mock Invoke-TimerSpeech { }
Mock Invoke-TimerAfterStart { }
