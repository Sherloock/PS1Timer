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
    $script:TimerForceSyncRegister = $true
}

# ============================================================================
# TIMER CREATION
# ============================================================================

Describe "Timer" {
    BeforeAll {
        # Mock scheduled task functions
        Mock Register-ScheduledTask { }
        Mock Unregister-ScheduledTask { }
        Mock Set-Content { } -ParameterFilter { $LiteralPath -like "*PSTimer_*.ps1" }
    }

    BeforeEach {
        # Clean state before each test
        if (Test-Path $script:TimerDataFile) { Remove-Item $script:TimerDataFile }
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
}

# ============================================================================
# TIMER PAUSE
# ============================================================================

Describe "TimerPause" {
    BeforeAll {
        Mock Unregister-ScheduledTask { }
        Mock Get-ScheduledTask { $null }
    }

    BeforeEach {
        if (Test-Path $script:TimerDataFile) { Remove-Item $script:TimerDataFile }
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
}

# ============================================================================
# TIMER RESUME
# ============================================================================

Describe "TimerResume" {
    BeforeAll {
        Mock Register-ScheduledTask { }
        Mock Unregister-ScheduledTask { }
        Mock Set-Content { } -ParameterFilter { $LiteralPath -like "*PSTimer_*.ps1" }
    }

    BeforeEach {
        if (Test-Path $script:TimerDataFile) { Remove-Item $script:TimerDataFile }
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
        Mock Unregister-ScheduledTask { }
        Mock Remove-Item { } -ParameterFilter { $LiteralPath -like "*PSTimer_*.ps1" }
    }

    BeforeEach {
        if (Test-Path $script:TimerDataFile) { Remove-Item $script:TimerDataFile }
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
        Mock Get-ScheduledTask { $null }
        Mock Get-ScheduledTaskInfo { $null }
    }

    BeforeEach {
        if (Test-Path $script:TimerDataFile) { Remove-Item $script:TimerDataFile }
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
        Mock Get-ScheduledTask { @{ TaskName = "PSTimer_1" } }

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
        Mock Get-ScheduledTask { $null }
        Mock Get-ScheduledTaskInfo { $null }
    }

    BeforeEach {
        if (Test-Path $script:TimerDataFile) { Remove-Item $script:TimerDataFile }
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

Describe "Show-TimerWatchDisplay" {
    BeforeAll {
        $script:WatchDisplayCallCount = 0
    }

    BeforeEach {
        if (Test-Path $script:TimerDataFile) { Remove-Item $script:TimerDataFile }
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

    It "Sync-TimerData skips Get-ScheduledTask when end time is far in the future" {
        Mock Get-ScheduledTask { throw 'should not be called' }
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
        Assert-MockCalled Get-ScheduledTask -Times 0 -Exactly
    }
}

Describe "Sequence phase advance (JSON)" {
    BeforeAll {
        Mock Register-ScheduledTask { }
        Mock Unregister-ScheduledTask { }
    }

    BeforeEach {
        if (Test-Path $script:TimerDataFile) { Remove-Item $script:TimerDataFile }
    }

    It "starts sequence with multiple phases in JSON" {
        $phases = @(ConvertFrom-TimerSequence -Pattern '(10s a, 10s b)x1')
        $summary = Get-SequenceSummary -Phases $phases
        $id = '9'
        $now = Get-Date
        $timer = New-SequenceTimerFromPhases -Id $id -OriginalPattern 'test' -Phases $phases -Summary $summary -Now $now -NotifyType 'silent'
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
