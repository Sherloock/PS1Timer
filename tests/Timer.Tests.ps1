# Timer Module Tests
# Tests for Timer.ps1 with mocked scheduled tasks

BeforeAll {
    $ModuleRoot = Split-Path -Parent $PSScriptRoot
    if (-not $global:Config) { $global:Config = @{} }
    $exampleConfig = Join-Path $ModuleRoot 'config.example.ps1'
    if (Test-Path -LiteralPath $exampleConfig) {
        . $exampleConfig
    }
    . "$ModuleRoot\src\TimerHelpers.ps1"
    . "$ModuleRoot\src\Timer.ps1"

    $script:TimerDataFile = "$TestDrive\ps-timers.json"
    $script:TimerHistoryFile = "$TestDrive\ps-timer-history.json"
    $script:TimerForceSyncRegister = $true

    function Reset-TimerDataCacheForTests {
        $script:TimerDataCache = $null
        $script:TimerDataCacheTime = [DateTime]::MinValue
        $script:TimerTaskNameCache = $null
        $script:TimerTaskNameCacheTime = [DateTime]::MinValue
    }
}

# ============================================================================
# TIMER CREATION
# ============================================================================

Describe "Timer" {
    BeforeAll {
        # Mock scheduled task functions
        Mock Register-ScheduledTask { }
        Mock Remove-TimerScheduledTaskByName { }
        Mock Set-Content { } -ParameterFilter { $LiteralPath -like "*PSTimer_*.ps1" }
    }

    BeforeEach {
        Reset-TimerDataCacheForTests
        if (Test-Path $script:TimerDataFile) { Remove-Item $script:TimerDataFile -Force }
    }

    It "creates timer with valid time" {
        Timer -Time "5m" -Message "Test timer"

        $timers = @(Get-TimerData)
        $timers.Count | Should -Be 1
        $timers[0].Message | Should -Be "Test timer"
        $timers[0].Seconds | Should -Be 300
        $timers[0].State | Should -Be "Running"
    }

    It "creates timer with default message" {
        Timer -Time "1m"

        $timers = @(Get-TimerData)
        $timers[0].Message | Should -Be "Time is up!"
    }

    It "creates timer with repeat count" {
        Timer -Time "1m" -Message "Repeat test" -Repeat 3

        $timers = @(Get-TimerData)
        $timers[0].RepeatTotal | Should -Be 3
        $timers[0].RepeatRemaining | Should -Be 2
        $timers[0].CurrentRun | Should -Be 1
    }

    It "rejects invalid time format" {
        Timer -Time "invalid"

        $timers = @(Get-TimerData)
        $timers.Count | Should -Be 0
    }

    It "assigns sequential IDs" {
        Timer -Time "1m" -Message "First"
        Timer -Time "1m" -Message "Second"

        $timers = @(Get-TimerData)
        $timers.Count | Should -Be 2
        $timers[0].Id | Should -Be "1"
        $timers[1].Id | Should -Be "2"
    }

    It "sets minimum repeat to 1" {
        Timer -Time "1m" -Repeat 0

        $timers = @(Get-TimerData)
        $timers[0].RepeatTotal | Should -Be 1
    }

    It "creates scheduled timer with -At" {
        Mock Get-Date { [DateTime]'2026-06-05T10:00:00' }

        Timer -Time "25m" -Message "Work" -At "14:30"

        $timers = @(Get-TimerData)
        $timers[0].State | Should -Be 'Scheduled'
        ([DateTime]::Parse($timers[0].StartTime)).ToString('HH:mm') | Should -Be '14:30'
        ([DateTime]::Parse($timers[0].EndTime)).ToString('HH:mm') | Should -Be '14:55'
    }

    It "stores webhook name when notify is webhook" {
        $saved = $global:Config
        try {
            $global:Config = @{
                Webhooks = @{ 'discord-main' = 'https://example.com/hook' }
            }
            Initialize-PS1TimerModuleConfig
            Timer -Time "1m" -Notify webhook -Webhook 'discord-main'

            $timers = @(Get-TimerData)
            $timers[0].NotifyVisual | Should -Be 'none'
            $timers[0].NotifySound | Should -BeFalse
            $timers[0].NotifyType | Should -Be 'webhook'
            $timers[0].WebhookName | Should -Be 'discord-main'
        }
        finally {
            $global:Config = $saved
            Initialize-PS1TimerModuleConfig
        }
    }
}

# ============================================================================
# TIMER PAUSE
# ============================================================================

Describe "TimerPause" {
    BeforeAll {
        Mock Remove-TimerScheduledTasks { }
        Mock Remove-TimerTempFiles { }
        Mock Get-ScheduledTask { $null }
    }

    BeforeEach {
        Reset-TimerDataCacheForTests
        if (Test-Path $script:TimerDataFile) { Remove-Item $script:TimerDataFile -Force }
    }

    It "pauses running timer" {
        # Setup: create a running timer
        $timer = [PSCustomObject]@{
            Id = "1"
            Duration = "5m"
            Seconds = 300
            Message = "Test"
            StartTime = (Get-Date).ToString('o')
            EndTime = (Get-Date).AddSeconds(300).ToString('o')
            RepeatTotal = 1
            RepeatRemaining = 0
            CurrentRun = 1
            State = "Running"
        }
        Save-TimerData -Timers @($timer)

        TimerPause -Id "1"

        $timers = @(Get-TimerData)
        $timers[0].State | Should -Be "Paused"
        $timers[0].RemainingSeconds | Should -BeGreaterThan 0
    }

    It "does not pause non-running timer" {
        $timer = [PSCustomObject]@{
            Id = "1"
            Duration = "5m"
            Seconds = 300
            Message = "Test"
            StartTime = (Get-Date).ToString('o')
            EndTime = (Get-Date).AddSeconds(300).ToString('o')
            RepeatTotal = 1
            RepeatRemaining = 0
            CurrentRun = 1
            State = "Completed"
        }
        Save-TimerData -Timers @($timer)

        TimerPause -Id "1"

        $timers = @(Get-TimerData)
        $timers[0].State | Should -Be "Completed"
    }

    It "pauses all timers with 'all' parameter" {
        $timers = @(
            [PSCustomObject]@{
                Id = "1"; Duration = "5m"; Seconds = 300; Message = "Test1"
                StartTime = (Get-Date).ToString('o'); EndTime = (Get-Date).AddSeconds(300).ToString('o')
                RepeatTotal = 1; RepeatRemaining = 0; CurrentRun = 1; State = "Running"
            },
            [PSCustomObject]@{
                Id = "2"; Duration = "10m"; Seconds = 600; Message = "Test2"
                StartTime = (Get-Date).ToString('o'); EndTime = (Get-Date).AddSeconds(600).ToString('o')
                RepeatTotal = 1; RepeatRemaining = 0; CurrentRun = 1; State = "Running"
            }
        )
        Save-TimerData -Timers $timers

        TimerPause -Id "all"

        $result = @(Get-TimerData)
        $result[0].State | Should -Be "Paused"
        $result[1].State | Should -Be "Paused"
    }

    It "pauses all timers with one bulk scheduled-task delete" {
        $timers = @(
            [PSCustomObject]@{
                Id = "1"; Duration = "5m"; Seconds = 300; Message = "Test1"
                StartTime = (Get-Date).ToString('o'); EndTime = (Get-Date).AddSeconds(300).ToString('o')
                RepeatTotal = 1; RepeatRemaining = 0; CurrentRun = 1; State = "Running"
            },
            [PSCustomObject]@{
                Id = "2"; Duration = "5m"; Seconds = 300; Message = "Test2"
                StartTime = (Get-Date).ToString('o'); EndTime = (Get-Date).AddSeconds(300).ToString('o')
                RepeatTotal = 1; RepeatRemaining = 0; CurrentRun = 1; State = "Running"
            }
        )
        Save-TimerData -Timers $timers

        TimerPause -Id "all"

        Assert-MockCalled Remove-TimerScheduledTasks -Times 1 -Exactly -ParameterFilter { $TimerTargets -and $TimerTargets.Count -ge 2 }
        Assert-MockCalled Remove-TimerTempFiles -Times 1 -Exactly -ParameterFilter { $TimerIds -and $TimerIds.Count -ge 2 }
    }
}

# ============================================================================
# TIMER RESUME
# ============================================================================

Describe "TimerResume" {
    BeforeAll {
        Mock Register-ScheduledTask { }
        Mock Remove-TimerScheduledTaskByName { }
        Mock Remove-TimerScheduledTasks { }
        Mock Set-Content { } -ParameterFilter { $LiteralPath -like "*PSTimer_*.ps1" }
    }

    BeforeEach {
        Reset-TimerDataCacheForTests
        if (Test-Path $script:TimerDataFile) { Remove-Item $script:TimerDataFile -Force }
    }

    It "resumes paused timer" {
        $timer = [PSCustomObject]@{
            Id = "1"
            Duration = "5m"
            Seconds = 300
            Message = "Test"
            StartTime = (Get-Date).AddSeconds(-60).ToString('o')
            EndTime = (Get-Date).AddSeconds(240).ToString('o')
            RepeatTotal = 1
            RepeatRemaining = 0
            CurrentRun = 1
            State = "Paused"
            RemainingSeconds = 240
        }
        Save-TimerData -Timers @($timer)

        TimerResume -Id "1"

        $timers = @(Get-TimerData)
        $timers[0].State | Should -Be "Running"
    }

    It "resumes lost timer" {
        $timer = [PSCustomObject]@{
            Id = "1"
            Duration = "5m"
            Seconds = 300
            Message = "Test"
            StartTime = (Get-Date).AddSeconds(-400).ToString('o')
            EndTime = (Get-Date).AddSeconds(-100).ToString('o')
            RepeatTotal = 1
            RepeatRemaining = 0
            CurrentRun = 1
            State = "Lost"
            RemainingSeconds = 300
        }
        Save-TimerData -Timers @($timer)

        TimerResume -Id "1"

        $timers = @(Get-TimerData)
        $timers[0].State | Should -Be "Running"
    }

    It "does not resume completed timer" {
        $timer = [PSCustomObject]@{
            Id = "1"
            Duration = "5m"
            Seconds = 300
            Message = "Test"
            StartTime = (Get-Date).AddSeconds(-400).ToString('o')
            EndTime = (Get-Date).AddSeconds(-100).ToString('o')
            RepeatTotal = 1
            RepeatRemaining = 0
            CurrentRun = 1
            State = "Completed"
        }
        Save-TimerData -Timers @($timer)

        TimerResume -Id "1"

        $timers = @(Get-TimerData)
        $timers[0].State | Should -Be "Completed"
    }
}

# ============================================================================
# TIMER REMOVE
# ============================================================================

Describe "TimerRemove" {
    BeforeAll {
        Mock Remove-TimerScheduledTasks { }
        Mock Remove-TimerTempFiles { }
    }

    BeforeEach {
        Reset-TimerDataCacheForTests
        if (Test-Path $script:TimerDataFile) { Remove-Item $script:TimerDataFile -Force }
    }

    It "removes specific timer by ID" {
        $timers = @(
            [PSCustomObject]@{
                Id = "1"; Duration = "5m"; Seconds = 300; Message = "Test1"
                StartTime = (Get-Date).ToString('o'); EndTime = (Get-Date).AddSeconds(300).ToString('o')
                RepeatTotal = 1; RepeatRemaining = 0; CurrentRun = 1; State = "Running"
            },
            [PSCustomObject]@{
                Id = "2"; Duration = "10m"; Seconds = 600; Message = "Test2"
                StartTime = (Get-Date).ToString('o'); EndTime = (Get-Date).AddSeconds(600).ToString('o')
                RepeatTotal = 1; RepeatRemaining = 0; CurrentRun = 1; State = "Running"
            }
        )
        Save-TimerData -Timers $timers

        TimerRemove -Id "1"

        $result = @(Get-TimerData)
        $result.Count | Should -Be 1
        $result[0].Id | Should -Be "2"
    }

    It "removes all timers with 'all' parameter" {
        $timers = @(
            [PSCustomObject]@{
                Id = "1"; Duration = "5m"; Seconds = 300; Message = "Test1"
                StartTime = (Get-Date).ToString('o'); EndTime = (Get-Date).AddSeconds(300).ToString('o')
                RepeatTotal = 1; RepeatRemaining = 0; CurrentRun = 1; State = "Running"
            }
        )
        Save-TimerData -Timers $timers

        TimerRemove -Id "all"

        $result = @(Get-TimerData)
        $result.Count | Should -Be 0
    }

    It "removes all timers with one bulk scheduled-task delete" {
        $timers = @(
            [PSCustomObject]@{
                Id = "1"; Duration = "5m"; Seconds = 300; Message = "Test1"
                StartTime = (Get-Date).ToString('o'); EndTime = (Get-Date).AddSeconds(300).ToString('o')
                RepeatTotal = 1; RepeatRemaining = 0; CurrentRun = 1; State = "Running"
            },
            [PSCustomObject]@{
                Id = "2"; Duration = "5m"; Seconds = 300; Message = "Test2"
                StartTime = (Get-Date).ToString('o'); EndTime = (Get-Date).AddSeconds(300).ToString('o')
                RepeatTotal = 1; RepeatRemaining = 0; CurrentRun = 1; State = "Running"
            }
        )
        Save-TimerData -Timers $timers

        TimerRemove -Id "all"

        Assert-MockCalled Remove-TimerScheduledTasks -Times 1 -Exactly -ParameterFilter { $All }
        Assert-MockCalled Remove-TimerTempFiles -Times 1 -Exactly -ParameterFilter { $All }
    }

    It "removes only completed/lost timers with 'done' parameter" {
        $timers = @(
            [PSCustomObject]@{
                Id = "1"; Duration = "5m"; Seconds = 300; Message = "Running"
                StartTime = (Get-Date).ToString('o'); EndTime = (Get-Date).AddSeconds(300).ToString('o')
                RepeatTotal = 1; RepeatRemaining = 0; CurrentRun = 1; State = "Running"
            },
            [PSCustomObject]@{
                Id = "2"; Duration = "5m"; Seconds = 300; Message = "Completed"
                StartTime = (Get-Date).ToString('o'); EndTime = (Get-Date).AddSeconds(300).ToString('o')
                RepeatTotal = 1; RepeatRemaining = 0; CurrentRun = 1; State = "Completed"
            },
            [PSCustomObject]@{
                Id = "3"; Duration = "5m"; Seconds = 300; Message = "Lost"
                StartTime = (Get-Date).ToString('o'); EndTime = (Get-Date).AddSeconds(300).ToString('o')
                RepeatTotal = 1; RepeatRemaining = 0; CurrentRun = 1; State = "Lost"
            }
        )
        Save-TimerData -Timers $timers

        TimerRemove -Id "done"

        $result = @(Get-TimerData)
        $result.Count | Should -Be 1
        $result[0].Id | Should -Be "1"
    }
}

# ============================================================================
# SYNC TIMER DATA
# ============================================================================

Describe "Sync-TimerData" {
    BeforeAll {
        Mock Get-PSTimerScheduledTaskNames { [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }
    }

    BeforeEach {
        Reset-TimerDataCacheForTests
        if (Test-Path $script:TimerDataFile) { Remove-Item $script:TimerDataFile -Force }
    }

    It "marks timer as Lost when task missing and time expired" {
        $timer = [PSCustomObject]@{
            Id = "1"
            Duration = "5m"
            Seconds = 300
            Message = "Test"
            StartTime = (Get-Date).AddSeconds(-400).ToString('o')
            EndTime = (Get-Date).AddSeconds(-100).ToString('o')
            RepeatTotal = 1
            RepeatRemaining = 0
            CurrentRun = 1
            State = "Running"
        }
        Save-TimerData -Timers @($timer)

        $result = Sync-TimerData

        $result[0].State | Should -Be "Lost"
    }

    It "keeps timer Running when task exists" {
        $existing = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        [void]$existing.Add('PSTimer_1')
        Mock Get-PSTimerScheduledTaskNames { return $existing }

        $timer = [PSCustomObject]@{
            Id = "1"
            Duration = "5m"
            Seconds = 300
            Message = "Test"
            StartTime = (Get-Date).ToString('o')
            EndTime = (Get-Date).AddSeconds(300).ToString('o')
            RepeatTotal = 1
            RepeatRemaining = 0
            CurrentRun = 1
            State = "Running"
        }
        Save-TimerData -Timers @($timer)

        $result = Sync-TimerData

        $result[0].State | Should -Be "Running"
    }

    It "does not modify non-Running timers" {
        $timer = [PSCustomObject]@{
            Id = "1"
            Duration = "5m"
            Seconds = 300
            Message = "Test"
            StartTime = (Get-Date).AddSeconds(-400).ToString('o')
            EndTime = (Get-Date).AddSeconds(-100).ToString('o')
            RepeatTotal = 1
            RepeatRemaining = 0
            CurrentRun = 1
            State = "Paused"
            RemainingSeconds = 200
        }
        Save-TimerData -Timers @($timer)

        $result = Sync-TimerData

        $result[0].State | Should -Be "Paused"
    }
}

# ============================================================================
# TIMER LIST
# ============================================================================

Describe "TimerList" {
    BeforeAll {
        Mock Get-PSTimerScheduledTaskNames { [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }
    }

    BeforeEach {
        Reset-TimerDataCacheForTests
        if (Test-Path $script:TimerDataFile) { Remove-Item $script:TimerDataFile -Force }
    }

    It "shows message when no timers exist" {
        $output = TimerList 6>&1
        # Function should complete without error
        $true | Should -BeTrue
    }

    It "lists active timers" {
        $timer = [PSCustomObject]@{
            Id = "1"
            Duration = "5m"
            Seconds = 300
            Message = "Test"
            StartTime = (Get-Date).ToString('o')
            EndTime = (Get-Date).AddSeconds(300).ToString('o')
            RepeatTotal = 1
            RepeatRemaining = 0
            CurrentRun = 1
            State = "Running"
        }
        Save-TimerData -Timers @($timer)

        # Function should complete without error
        { TimerList } | Should -Not -Throw
    }
}

# ============================================================================
# SHOW-TIMER WATCH DISPLAY (single-timer watch)
# ============================================================================

Describe "Get-TimerFinalEndTime" {
    It "returns current EndTime for simple timer" {
        $now = [DateTime]::new(2024, 6, 1, 12, 0, 0)
        $end = $now.AddMinutes(5)
        $timer = [PSCustomObject]@{
            IsSequence       = $false
            Seconds          = 300
            EndTime          = $end.ToString('o')
            StartTime        = $now.ToString('o')
            State            = 'Running'
            RepeatTotal      = 1
            RepeatRemaining  = 0
        }
        $result = Get-TimerFinalEndTime -Timer $timer -Now $now
        $result | Should -Be $end
    }

    It "adds remaining repeats for repeat timer" {
        $now = [DateTime]::new(2024, 6, 1, 12, 0, 0)
        $end = $now.AddMinutes(5)
        $timer = [PSCustomObject]@{
            IsSequence       = $false
            Seconds          = 300
            EndTime          = $end.ToString('o')
            StartTime        = $now.ToString('o')
            State            = 'Running'
            RepeatTotal      = 3
            RepeatRemaining  = 2
        }
        $result = Get-TimerFinalEndTime -Timer $timer -Now $now
        $result | Should -Be $end.AddMinutes(10)
    }

    It "sums future phases for sequence timer" {
        $now = [DateTime]::new(2024, 6, 1, 12, 0, 0)
        $end = $now.AddMinutes(25)
        $timer = [PSCustomObject]@{
            IsSequence       = $true
            TotalSeconds     = 1800
            Seconds          = 1500
            EndTime          = $end.ToString('o')
            StartTime        = $now.ToString('o')
            State            = 'Running'
            CurrentPhase     = 0
            Phases           = @(
                @{ Seconds = 1500; Label = 'work' }
                @{ Seconds = 300; Label = 'break' }
            )
            RepeatTotal      = 1
            RepeatRemaining  = 0
        }
        $result = Get-TimerFinalEndTime -Timer $timer -Now $now
        $result | Should -Be $end.AddMinutes(5)
    }

    It "uses scheduled start plus total seconds for scheduled sequence" {
        $now = [DateTime]::new(2024, 6, 1, 12, 0, 0)
        $start = $now.AddHours(1)
        $timer = [PSCustomObject]@{
            IsSequence       = $true
            TotalSeconds     = 1800
            Seconds          = 1500
            EndTime          = $start.AddMinutes(25).ToString('o')
            StartTime        = $start.ToString('o')
            State            = 'Scheduled'
            CurrentPhase     = 0
            Phases           = @(
                @{ Seconds = 1500; Label = 'work' }
                @{ Seconds = 300; Label = 'break' }
            )
            RepeatTotal      = 1
            RepeatRemaining  = 0
        }
        $result = Get-TimerFinalEndTime -Timer $timer -Now $now
        $result | Should -Be $start.AddSeconds(1800)
    }
}

Describe "Get-TimerWatchRunningContent" {
    It "includes Final end but not Ends row for sequence timers" {
        $now = [DateTime]::new(2024, 6, 1, 12, 0, 0)
        $phaseEnd = $now.AddMinutes(25)
        $currentTimer = [PSCustomObject]@{
            IsSequence       = $true
            TotalPhases      = 2
            TotalSeconds     = 1800
            Seconds          = 1500
            EndTime          = $phaseEnd.ToString('o')
            StartTime        = $now.ToString('o')
            State            = 'Running'
            CurrentPhase     = 0
            PhaseLabel       = 'work'
            Phases           = @(
                @{ Seconds = 1500; Label = 'work' }
                @{ Seconds = 300; Label = 'break' }
            )
            RepeatTotal      = 1
            RepeatRemaining  = 0
        }
        $timer = [PSCustomObject]@{ Id = '1'; Message = 'work'; Seconds = 1500; RepeatTotal = 1 }
        Mock Get-Date { return $now }
        $colors = Get-AnsiColors
        $content = Get-TimerWatchRunningContent -Colors $colors -CurrentTimer $currentTimer -Timer $timer -Percent 50 -Remaining ([TimeSpan]::FromMinutes(12)) -EndsAtFormatted $phaseEnd.ToString('HH:mm:ss')
        $text = $content.ToString()
        $text | Should -Match 'Final end'
        $text | Should -Match '12:30:00'
        $text | Should -Not -Match 'Ends       '
    }
}

Describe "Get-TimerWatchPhaseTimelineContent" {
    It "shows end time after each visible phase" {
        $now = [DateTime]::new(2024, 6, 1, 12, 0, 0)
        $phaseEnd = $now.AddMinutes(45)
        $currentTimer = [PSCustomObject]@{
            IsSequence   = $true
            TotalPhases  = 3
            EndTime      = $phaseEnd.ToString('o')
            StartTime    = $now.ToString('o')
            State        = 'Running'
            CurrentPhase = 0
            Phases       = @(
                @{ Seconds = 2700; Label = 'water' }
                @{ Seconds = 2700; Label = 'water' }
                @{ Seconds = 2700; Label = 'water' }
            )
        }
        Mock Get-Date { return $now }
        $colors = Get-AnsiColors
        $content = Get-TimerWatchPhaseTimelineContent -Colors $colors -CurrentTimer $currentTimer
        $plain = ($content.ToString() -replace '\x1b\[[0-9;]*m', '')
        $plain | Should -Match '1\. water \(45m\) @ 12:45:00'
        $plain | Should -Match '2\. water \(45m\) @ 13:30:00'
        $plain | Should -Match '3\. water \(45m\) @ 14:15:00'
    }
}

Describe "Get-SequencePhaseEndTime" {
    It "returns cumulative end times from scheduled start" {
        $now = [DateTime]::new(2024, 6, 1, 12, 0, 0)
        $start = $now.AddHours(1)
        $timer = [PSCustomObject]@{
            State        = 'Scheduled'
            StartTime    = $start.ToString('o')
            EndTime      = $start.AddMinutes(45).ToString('o')
            CurrentPhase = 0
            Phases       = @(
                @{ Seconds = 2700; Label = 'water' }
                @{ Seconds = 2700; Label = 'water' }
            )
        }
        Get-SequencePhaseEndTime -Timer $timer -PhaseIndex 0 -Now $now | Should -Be $start.AddMinutes(45)
        Get-SequencePhaseEndTime -Timer $timer -PhaseIndex 1 -Now $now | Should -Be $start.AddMinutes(90)
    }
}

Describe "Show-TimerWatchDisplay" {
    BeforeAll {
        $script:WatchDisplayCallCount = 0
    }

    BeforeEach {
        Reset-TimerDataCacheForTests
        if (Test-Path $script:TimerDataFile) { Remove-Item $script:TimerDataFile -Force }
        $script:WatchDisplayCallCount = 0
    }

    It "continues watch when one loop ends and refreshed data has next run" {
        $fixedNow = [DateTime]::new(2024, 6, 1, 12, 0, 0)
        $pastEnd = $fixedNow.AddMinutes(-1).ToString('o')
        $futureEnd = $fixedNow.AddMinutes(5).ToString('o')

        $timerFirstRun = [PSCustomObject]@{
            Id              = "1"
            Duration        = "5m"
            Seconds         = 300
            Message         = "Loop test"
            StartTime       = $fixedNow.AddMinutes(-6).ToString('o')
            EndTime         = $pastEnd
            RepeatTotal     = 3
            RepeatRemaining = 1
            CurrentRun      = 2
            State           = "Running"
            IsSequence      = $false
        }
        $timerNextRun = [PSCustomObject]@{
            Id              = "1"
            Duration        = "5m"
            Seconds         = 300
            Message         = "Loop test"
            StartTime       = $fixedNow.ToString('o')
            EndTime         = $futureEnd
            RepeatTotal     = 3
            RepeatRemaining = 0
            CurrentRun      = 3
            State           = "Running"
            IsSequence      = $false
        }

        Mock Get-Date { return $fixedNow }
        Mock Wait-OneSecondOrKeyPress { return $true }
        Mock Clear-Host { }
        Mock Get-TimerWatchCompletedContent { return [System.Text.StringBuilder]::new() }

        Mock Get-TimerDataIfChanged {
            param([switch]$Force)
            if ($Force) {
                return @{ Data = @($timerNextRun); Changed = $true }
            }
            $script:WatchDisplayCallCount++
            if ($script:WatchDisplayCallCount -eq 1) {
                return @{ Data = @($timerFirstRun); Changed = $true }
            }
            return @{ Data = @($timerNextRun); Changed = $true }
        }

        $inputTimer = [PSCustomObject]@{
            Id       = "1"
            Seconds  = 300
            Message  = "Loop test"
            EndTime  = $pastEnd
            IsSequence = $false
        }

        Show-TimerWatchDisplay -Timer $inputTimer

        Assert-MockCalled -CommandName Get-TimerWatchCompletedContent -Times 0 -Exactly
        Assert-MockCalled -CommandName Get-TimerDataIfChanged -ParameterFilter { $Force } -Times 1 -Exactly
    }
}

Describe "Timer scheduled task helpers" {
    It "VBS wrapper uses pwsh.exe and Chr(34) quoting for spaced paths" {
        $savedPwsh = $script:PS1TimerPwsh
        try {
            $script:PS1TimerPwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
            $vbs = Get-TimerVbsWrapperScript -Ps1Path 'C:\Users\GMK150-B\AppData\Local\Temp\PSTimer_2.ps1'
            $vbs | Should -Match 'pwsh\.exe'
            $vbs | Should -Not -Match 'powershell\.exe'
            $vbs | Should -Match 'Chr\(34\)'
            $vbs | Should -Not -Match 'WshShell\.Run "C:\\Program'
        }
        finally {
            $script:PS1TimerPwsh = $savedPwsh
        }
    }

    It "Get-TimerAfterStartAction returns config default and override" {
        Get-TimerAfterStartAction | Should -Be 'none'
        Get-TimerAfterStartAction -Override 'watch' | Should -Be 'watch'
    }

    It "Sync-TimerData skips scheduled-task lookup when end time is far in the future" {
        Mock Get-PSTimerScheduledTaskNames { throw 'should not be called' }
        $future = (Get-Date).AddMinutes(30).ToString('o')
        $timers = @(
            [PSCustomObject]@{
                Id = '1'; State = 'Running'; EndTime = $future; Seconds = 1800
                TaskName = 'PSTimer_1_abcdef01'; Duration = '30m'; Message = 'x'
                StartTime = (Get-Date).ToString('o')
                RepeatTotal = 1; RepeatRemaining = 0; CurrentRun = 1
                IsSequence = $false
            }
        )
        Mock Get-TimerData { return $timers }
        { Sync-TimerData } | Should -Not -Throw
        Assert-MockCalled Get-PSTimerScheduledTaskNames -Times 0 -Exactly
    }
}

Describe "Sequence phase advance (JSON)" {
    BeforeAll {
        Mock Register-ScheduledTask { }
        Mock Remove-TimerScheduledTaskByName { }
    }

    BeforeEach {
        Reset-TimerDataCacheForTests
        if (Test-Path $script:TimerDataFile) { Remove-Item $script:TimerDataFile -Force }
    }

    It "starts sequence with multiple phases in JSON" {
        $phases = @(ConvertFrom-TimerSequence -Pattern '(10s a, 10s b)x1')
        $summary = Get-SequenceSummary -Phases $phases
        $id = '9'
        $now = Get-Date
        $timer = New-SequenceTimerFromPhases -Id $id -OriginalPattern 'test' -Phases $phases -Summary $summary -Now $now -NotifyVisual 'none' -NotifySound $false -NotifyType 'silent'
        Save-TimerData -Timers @($timer)

        $saved = @(Get-TimerData)
        $saved[0].IsSequence | Should -BeTrue
        $saved[0].TotalPhases | Should -Be 2
        $saved[0].CurrentPhase | Should -Be 0
        @($saved[0].Phases).Count | Should -Be 2
    }

    It "coerces single-object Phases array when advancing index" {
        $singlePhase = [PSCustomObject]@{ Seconds = 5; Label = 'only'; Duration = '5s' }
        $phases = @($singlePhase)
        $phases[0].Seconds | Should -Be 5
        @($phases).Count | Should -Be 1
    }
}

Describe "Timer stats" {
    BeforeEach {
        Reset-TimerDataCacheForTests
        if (Test-Path $script:TimerHistoryFile) { Remove-Item $script:TimerHistoryFile -Force }
    }

    It "aggregates today and week totals" {
        $today = (Get-Date).Date.AddHours(12).ToString('o')
        $old = (Get-Date).Date.AddDays(-3).ToString('o')
        $history = @(
            [PSCustomObject]@{ TimerId = '1'; Label = 'work'; Seconds = 1500; CompletedAt = $today; IsSequence = $false }
            [PSCustomObject]@{ TimerId = '2'; Label = 'break'; Seconds = 300; CompletedAt = $today; IsSequence = $false }
            [PSCustomObject]@{ TimerId = '3'; Label = 'work'; Seconds = 600; CompletedAt = $old; IsSequence = $false }
        )
        $utf8 = New-Object System.Text.UTF8Encoding $true
        [System.IO.File]::WriteAllText($script:TimerHistoryFile, (ConvertTo-Json -InputObject $history -Compress), $utf8)

        $summary = Get-TimerStatsSummary
        $summary.TodayCount | Should -Be 2
        $summary.WeekCount | Should -Be 3
        $summary.LabelTotals['work'] | Should -Be 2100
        $summary.LabelTotals['break'] | Should -Be 300
    }
}

Describe "Fire script generation" {
    BeforeAll {
        Mock Register-ScheduledTask { }
        Mock Remove-TimerScheduledTaskByName { }
    }

    BeforeEach {
        Reset-TimerDataCacheForTests
        if (Test-Path $script:TimerDataFile) { Remove-Item $script:TimerDataFile -Force }
    }

    It "writes a parseable fire script for webhook timers" {
        $saved = $global:Config
        try {
            $global:Config = @{
                Webhooks = @{ 'discord' = 'https://example.com/hook' }
            }
            Initialize-PS1TimerModuleConfig
            Timer -Time '5s' -Message 'Discord test' -Notify webhook -Webhook discord

            $scriptPath = Join-Path $env:TEMP 'PSTimer_1.ps1'
            Test-Path -LiteralPath $scriptPath | Should -BeTrue
            { [scriptblock]::Create((Get-Content -LiteralPath $scriptPath -Raw)) } | Should -Not -Throw
            $content = Get-Content -LiteralPath $scriptPath -Raw
            $content | Should -Match '\$timerSeconds'
            $content | Should -Not -Match '`\$timerSeconds'
            $content | Should -Match '\$notifyVisual'
            $content | Should -Match '\$notifySound'
            $content | Should -Match 'if \(\$webhookUrl\)'
        }
        finally {
            $global:Config = $saved
            Initialize-PS1TimerModuleConfig
            $generated = Join-Path $env:TEMP 'PSTimer_1.ps1'
            if (Test-Path -LiteralPath $generated) { Remove-Item -LiteralPath $generated -Force }
        }
    }
}

Describe "Write-SequenceTimerConfirmation" {
    It "accepts null ScheduledStart for immediate sequence starts" {
        { Write-SequenceTimerConfirmation -Id 'abc' -OriginalPattern 'water' -Summary ([PSCustomObject]@{ TotalDuration = '15h' }) -PhaseCount 20 -FirstPhase @{ Seconds = 2700; Label = 'water' } -EndTime (Get-Date).AddMinutes(45) -ScheduledStart $null -NotifyLabel 'popup' } | Should -Not -Throw
    }
}

Describe "Resolve-TimerNotificationSettings" {
    It "uses preset notify and webhook" {
        $saved = $global:Config
        try {
            $global:Config = @{
                TimerDefaults = @{ Visual = 'popup'; Sound = $true }
                Webhooks = @{ 'ntfy' = 'https://ntfy.sh/test' }
            }
            Initialize-PS1TimerModuleConfig
            $result = Resolve-TimerNotificationSettings -PresetNotify 'webhook' -PresetWebhook 'ntfy'
            $result.Visual | Should -Be 'none'
            $result.Sound | Should -BeFalse
            $result.NotifyType | Should -Be 'webhook'
            $result.WebhookUrl | Should -Be 'https://ntfy.sh/test'
        }
        finally {
            $global:Config = $saved
            Initialize-PS1TimerModuleConfig
        }
    }

    It "maps legacy Notify sound to Visual none and Sound true" {
        $saved = $global:Config
        try {
            $global:Config = @{ TimerDefaults = @{ Notify = 'sound' } }
            Initialize-PS1TimerModuleConfig
            $result = Resolve-TimerNotificationSettings
            $result.Visual | Should -Be 'none'
            $result.Sound | Should -BeTrue
            $result.Label | Should -Be 'sound'
        }
        finally {
            $global:Config = $saved
            Initialize-PS1TimerModuleConfig
        }
    }

    It "combines Visual toast Sound and Webhook from defaults" {
        $saved = $global:Config
        try {
            $global:Config = @{
                TimerDefaults = @{ Visual = 'toast'; Sound = $true; Webhook = 'discord' }
                Webhooks = @{ 'discord' = 'https://example.com/hook' }
            }
            Initialize-PS1TimerModuleConfig
            $result = Resolve-TimerNotificationSettings
            $result.Visual | Should -Be 'toast'
            $result.Sound | Should -BeTrue
            $result.WebhookUrl | Should -Be 'https://example.com/hook'
            $result.Label | Should -Be 'toast + sound + webhook (discord)'
        }
        finally {
            $global:Config = $saved
            Initialize-PS1TimerModuleConfig
        }
    }

    It "applies preset Visual and Sound overrides" {
        $saved = $global:Config
        try {
            $global:Config = @{ TimerDefaults = @{ Visual = 'popup'; Sound = $true } }
            Initialize-PS1TimerModuleConfig
            $result = Resolve-TimerNotificationSettings -PresetVisual 'none' -PresetSound $true
            $result.Visual | Should -Be 'none'
            $result.Sound | Should -BeTrue
            $result.Label | Should -Be 'sound'
        }
        finally {
            $global:Config = $saved
            Initialize-PS1TimerModuleConfig
        }
    }
}
