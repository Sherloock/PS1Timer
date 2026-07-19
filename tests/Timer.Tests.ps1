# Timer Module Tests
# Tests for Timer.ps1 with mocked scheduled tasks

BeforeAll {
    $ModuleRoot = Split-Path -Parent $PSScriptRoot
    . "$PSScriptRoot\PS1Timer.TestBootstrap.ps1" -ModuleRoot $ModuleRoot -TestDrive $TestDrive
}

# ============================================================================
# TIMER CREATION
# ============================================================================

Describe "Timer" {
    BeforeAll {
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

    It "resumes paused simple timer with simple fire script" {
        $timer = [PSCustomObject]@{
            Id               = '2'
            Duration         = '5m'
            Seconds          = 300
            Message          = 'Test'
            StartTime        = (Get-Date).AddSeconds(-60).ToString('o')
            EndTime          = (Get-Date).AddSeconds(240).ToString('o')
            RepeatTotal      = 1
            RepeatRemaining  = 0
            CurrentRun       = 1
            State            = 'Paused'
            RemainingSeconds = 240
            IsSequence       = $false
        }
        Save-TimerData -Timers @($timer)

        TimerResume -Id '2'

        $scriptPath = Join-Path $env:TEMP 'PSTimer_2.ps1'
        try {
            Test-Path -LiteralPath $scriptPath | Should -BeTrue
            $content = Get-Content -LiteralPath $scriptPath -Raw
            $content | Should -Match '\$repeatRemaining'
            $content | Should -Not -Match '\$nextPhaseIdx'
        }
        finally {
            if (Test-Path -LiteralPath $scriptPath) { Remove-Item -LiteralPath $scriptPath -Force }
            $vbsPath = Join-Path $env:TEMP 'PSTimer_2.vbs'
            if (Test-Path -LiteralPath $vbsPath) { Remove-Item -LiteralPath $vbsPath -Force }
        }
    }

    It "resumes paused sequence timer with sequence fire script" {
        $phases = @(
            @{ Seconds = 10; Label = 'a'; Duration = '10s' }
            @{ Seconds = 10; Label = 'b'; Duration = '10s' }
            @{ Seconds = 10; Label = 'c'; Duration = '10s' }
        )
        $timer = [PSCustomObject]@{
            Id               = '3'
            Duration         = '30s'
            Seconds          = 10
            Message          = 'b'
            StartTime        = (Get-Date).AddSeconds(-5).ToString('o')
            EndTime          = (Get-Date).AddSeconds(5).ToString('o')
            RepeatTotal      = 1
            RepeatRemaining  = 0
            CurrentRun       = 1
            State            = 'Paused'
            RemainingSeconds = 120
            IsSequence       = $true
            SequencePattern  = '(10s a, 10s b, 10s c)x1'
            Phases           = $phases
            CurrentPhase     = 1
            TotalPhases      = 3
            PhaseLabel       = 'b'
            TotalSeconds     = 30
            NotifyVisual     = 'none'
            NotifySound      = $false
        }
        Save-TimerData -Timers @($timer)

        TimerResume -Id '3'

        $timers = @(Get-TimerData)
        $timers[0].State | Should -Be 'Running'
        $timers[0].CurrentPhase | Should -Be 1

        $scriptPath = Join-Path $env:TEMP 'PSTimer_3.ps1'
        try {
            Test-Path -LiteralPath $scriptPath | Should -BeTrue
            $content = Get-Content -LiteralPath $scriptPath -Raw
            $content | Should -Match 'if \(-not \$timer\.IsSequence\) \{ exit \}'
            $content | Should -Match '\$nextPhaseIdx'
            $content | Should -Not -Match '\$repeatRemaining -gt 0'
            $transitionPos = $content.IndexOf('$nextTaskName = "PSTimer_${timerId}_')
            $voicePos = $content.IndexOf('System.Speech.Synthesis.SpeechSynthesizer')
            if ($voicePos -lt 0) { $voicePos = $content.IndexOf('Add-Type -AssemblyName System.Speech') }
            $transitionPos | Should -BeGreaterThan 0
            if ($voicePos -ge 0) {
                $transitionPos | Should -BeLessThan $voicePos
            }
        }
        finally {
            if (Test-Path -LiteralPath $scriptPath) { Remove-Item -LiteralPath $scriptPath -Force }
            $vbsPath = Join-Path $env:TEMP 'PSTimer_3.vbs'
            if (Test-Path -LiteralPath $vbsPath) { Remove-Item -LiteralPath $vbsPath -Force }
        }
    }
}

Describe "Start-TimerScheduledJob" {
    BeforeEach {
        Reset-TimerDataCacheForTests
    }

    It "routes sequence timers to Start-SequenceTimerJob" {
        Mock Start-SequenceTimerJob { }
        Mock Start-TimerJob { }

        $timer = [PSCustomObject]@{ Id = '1'; IsSequence = $true }
        Start-TimerScheduledJob -Timer $timer

        Assert-MockCalled Start-SequenceTimerJob -Times 1 -Exactly
        Assert-MockCalled Start-TimerJob -Times 0 -Exactly
    }

    It "routes simple timers to Start-TimerJob" {
        Mock Start-SequenceTimerJob { }
        Mock Start-TimerJob { }

        $timer = [PSCustomObject]@{ Id = '1'; IsSequence = $false }
        Start-TimerScheduledJob -Timer $timer

        Assert-MockCalled Start-TimerJob -Times 1 -Exactly
        Assert-MockCalled Start-SequenceTimerJob -Times 0 -Exactly
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
    BeforeEach {
        Reset-TimerDataCacheForTests
        if (Test-Path $script:TimerDataFile) { Remove-Item $script:TimerDataFile -Force }
    }

    It "marks timer as Lost when task missing and time expired" {
        Set-TimerTestScheduledTaskNamesResultOverride ([System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase))

        $expiredEnd = (Get-Date).AddSeconds(-5).ToString('o')
        $timer = [PSCustomObject]@{
            Id = "1"
            Duration = "5m"
            Seconds = 300
            Message = "Test"
            StartTime = (Get-Date).AddSeconds(-10).ToString('o')
            EndTime = $expiredEnd
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
        Set-TimerTestScheduledTaskNamesResultOverride $existing

        $timer = [PSCustomObject]@{
            Id = "1"
            Duration = "5m"
            Seconds = 300
            Message = "Test"
            StartTime = (Get-Date).ToString('o')
            EndTime = (Get-Date).AddSeconds(1).ToString('o')
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

    It "does not mark sequence timer Lost while awaiting next phase transition" {
        Set-TimerTestScheduledTaskNamesResultOverride ([System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase))

        $phases = @(
            @{ Seconds = 10; Label = 'a'; Duration = '10s' }
            @{ Seconds = 10; Label = 'b'; Duration = '10s' }
            @{ Seconds = 10; Label = 'c'; Duration = '10s' }
            @{ Seconds = 10; Label = 'd'; Duration = '10s' }
        )
        $timer = [PSCustomObject]@{
            Id = 'seq-grace'
            Duration = '40s'
            Seconds = 10
            Message = 'c'
            StartTime = (Get-Date).AddSeconds(-15).ToString('o')
            EndTime = (Get-Date).AddSeconds(-3).ToString('o')
            RepeatTotal = 1
            RepeatRemaining = 0
            CurrentRun = 1
            State = 'Running'
            IsSequence = $true
            Phases = $phases
            CurrentPhase = 2
            TotalPhases = 4
            PhaseLabel = 'c'
            TotalSeconds = 40
        }
        Save-TimerData -Timers @($timer)

        $result = Sync-TimerData

        $result[0].State | Should -Be 'Running'
    }

    It "does not mark timer as Lost when scheduled-task lookup fails" {
        Set-TimerTestScheduledTaskNamesResultOverride $null

        $timer = [PSCustomObject]@{
                Id = "1"
                Duration = "5m"
                Seconds = 300
                Message = "Test"
                StartTime = (Get-Date).AddSeconds(-5).ToString('o')
                EndTime = (Get-Date).AddSeconds(-1).ToString('o')
                RepeatTotal = 1
                RepeatRemaining = 0
                CurrentRun = 1
                State = "Running"
            }
            Save-TimerData -Timers @($timer)

        $result = Sync-TimerData

        $result[0].State | Should -Be "Running"
    }

    It "throttles stale scheduled-task cleanup across rapid Sync-TimerData calls" {
        Mock Remove-StalePSTimerScheduledTasks { return 0 }
        $prevForceSync = $script:TimerForceSyncRegister
        $script:TimerForceSyncRegister = $false
        $script:TimerStaleCleanupLastRun = [DateTime]::MinValue

        try {
            Save-TimerData -Timers @()
            $null = Sync-TimerData
            $null = Sync-TimerData
            Assert-MockCalled Remove-StalePSTimerScheduledTasks -Times 1 -Exactly
        }
        finally {
            $script:TimerForceSyncRegister = $prevForceSync
        }
    }

    It "re-registers missing scheduled task when phase still has time left" {
        Set-TimerTestScheduledTaskNamesResultOverride ([System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase))
        Mock Start-TimerScheduledJob { }
        Mock Invoke-RegisterTimerResumeCues { }

        $futureEnd = (Get-Date).AddMinutes(30).ToString('o')
        $timer = [PSCustomObject]@{
            Id = 'sleep-1'
            Duration = '45m'
            Seconds = 2700
            Message = 'water'
            StartTime = (Get-Date).ToString('o')
            EndTime = $futureEnd
            RepeatTotal = 1
            RepeatRemaining = 0
            CurrentRun = 1
            State = 'Running'
            IsSequence = $true
            TaskName = 'PSTimer_sleep-1_abcdef01'
            CurrentPhase = 0
            TotalPhases = 3
            PhaseLabel = 'water'
            Phases = @(
                @{ Seconds = 2700; Label = 'water'; Duration = '45m' }
                @{ Seconds = 2700; Label = 'water'; Duration = '45m' }
                @{ Seconds = 2700; Label = 'water'; Duration = '45m' }
            )
        }
        Save-TimerData -Timers @($timer)

        $result = Sync-TimerData

        $result[0].State | Should -Be 'Running'
        Assert-MockCalled Start-TimerScheduledJob -Times 1 -Exactly
        Assert-MockCalled Invoke-RegisterTimerResumeCues -Times 1 -Exactly
    }

    It "does not mark long-overdue sequence Lost when recovery advances phase" {
        Set-TimerTestScheduledTaskNamesResultOverride ([System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase))
        Mock Repair-TimerScheduledTaskIfMissing { return $true }

        $phases = @(
            @{ Seconds = 10; Label = 'a'; Duration = '10s' }
            @{ Seconds = 10; Label = 'b'; Duration = '10s' }
            @{ Seconds = 10; Label = 'c'; Duration = '10s' }
        )
        $timer = [PSCustomObject]@{
            Id = 'sleep-seq'
            Duration = '30s'
            Seconds = 10
            Message = 'a'
            StartTime = (Get-Date).AddMinutes(-5).ToString('o')
            EndTime = (Get-Date).AddSeconds(-15).ToString('o')
            RepeatTotal = 1
            RepeatRemaining = 0
            CurrentRun = 1
            State = 'Running'
            IsSequence = $true
            Phases = $phases
            CurrentPhase = 0
            TotalPhases = 3
            PhaseLabel = 'a'
            TotalSeconds = 30
            TaskName = 'PSTimer_sleep-seq_deadbeef'
        }
        Save-TimerData -Timers @($timer)

        $result = Sync-TimerData

        $result[0].State | Should -Be 'Running'
        [int]$result[0].CurrentPhase | Should -Be 1
    }

    It "Remove-StalePSTimerScheduledTasks skips cleanup when timer read returns empty but file has data" {
        $utf8 = New-Object System.Text.UTF8Encoding $true
        [System.IO.File]::WriteAllText($script:TimerDataFile, '[{"Id":"1","State":"Running","TaskName":"PSTimer_1_abc"}]', $utf8)

        $existing = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        [void]$existing.Add('PSTimer_1_abc')
        [void]$existing.Add('PSTimer_9_orphan')
        Set-TimerTestScheduledTaskNamesResultOverride $existing

        Mock Get-TimerData { return @() }
        Mock Remove-TimerScheduledTaskByName { }

        $removed = Remove-StalePSTimerScheduledTasks

        $removed | Should -Be 0
        Assert-MockCalled Remove-TimerScheduledTaskByName -Times 0 -Exactly
    }

    It "Remove-StalePSTimerScheduledTasks keeps referenced cue tasks" {
        $timer = [PSCustomObject]@{
            Id = 'cue-1'
            State = 'Running'
            TaskName = 'PSTimer_cue-1_main01'
            CueTaskNames = @('PSTimer_cue-1_cue_abcd1234')
        }
        Save-TimerData -Timers @($timer)

        $existing = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        [void]$existing.Add('PSTimer_cue-1_main01')
        [void]$existing.Add('PSTimer_cue-1_cue_abcd1234')
        [void]$existing.Add('PSTimer_orphan_old')
        Set-TimerTestScheduledTaskNamesResultOverride $existing

        Mock Remove-TimerScheduledTaskByName { }

        $removed = Remove-StalePSTimerScheduledTasks

        $removed | Should -Be 1
        Assert-MockCalled Remove-TimerScheduledTaskByName -ParameterFilter { $TaskName -eq 'PSTimer_orphan_old' } -Times 1 -Exactly
        Assert-MockCalled Remove-TimerScheduledTaskByName -ParameterFilter { $TaskName -eq 'PSTimer_cue-1_cue_abcd1234' } -Times 0 -Exactly
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

    It "includes Notify row with sound and webhook label" {
        $now = [DateTime]::new(2024, 6, 1, 12, 0, 0)
        $endTime = $now.AddMinutes(25)
        $currentTimer = [PSCustomObject]@{
            IsSequence    = $false
            Seconds       = 1500
            EndTime       = $endTime.ToString('o')
            StartTime     = $now.ToString('o')
            State         = 'Running'
            Message       = 'Focus'
            RepeatTotal   = 1
            RepeatRemaining = 0
            NotifyVisual  = 'none'
            NotifySound   = $true
            WebhookName   = 'timer'
        }
        $timer = [PSCustomObject]@{ Id = '1'; Message = 'Focus'; Seconds = 1500; RepeatTotal = 1 }
        Mock Get-Date { return $now }
        $colors = Get-AnsiColors
        $content = Get-TimerWatchRunningContent -Colors $colors -CurrentTimer $currentTimer -Timer $timer -Percent 50 -Remaining ([TimeSpan]::FromMinutes(12)) -EndsAtFormatted $endTime.ToString('HH:mm:ss')
        $plain = ($content.ToString() -replace '\x1b\[[0-9;]*m', '')
        $plain | Should -Match 'Notify'
        $plain | Should -Match 'sound \+ webhook \(timer\)'
    }

    It "includes Notify row with silent label" {
        $now = [DateTime]::new(2024, 6, 1, 12, 0, 0)
        $endTime = $now.AddMinutes(5)
        $currentTimer = [PSCustomObject]@{
            IsSequence    = $false
            Seconds       = 300
            EndTime       = $endTime.ToString('o')
            StartTime     = $now.ToString('o')
            State         = 'Running'
            Message       = 'Quiet'
            RepeatTotal   = 1
            RepeatRemaining = 0
            NotifyVisual  = 'none'
            NotifySound   = $false
        }
        $timer = [PSCustomObject]@{ Id = '2'; Message = 'Quiet'; Seconds = 300; RepeatTotal = 1 }
        Mock Get-Date { return $now }
        $colors = Get-AnsiColors
        $content = Get-TimerWatchRunningContent -Colors $colors -CurrentTimer $currentTimer -Timer $timer -Percent 10 -Remaining ([TimeSpan]::FromMinutes(4)) -EndsAtFormatted $endTime.ToString('HH:mm:ss')
        $plain = ($content.ToString() -replace '\x1b\[[0-9;]*m', '')
        $plain | Should -Match 'Notify'
        $plain | Should -Match 'silent'
    }
}

Describe "Get-TimerWatchCompletedContent" {
    It "includes Notify row when timer is provided" {
        $endTime = [DateTime]::new(2024, 6, 1, 12, 25, 0)
        $timer = [PSCustomObject]@{
            NotifyVisual = 'none'
            NotifySound  = $true
            WebhookName  = 'timer'
        }
        $colors = Get-AnsiColors
        $content = Get-TimerWatchCompletedContent -Colors $colors -Message 'Focus' -TotalSeconds 1500 -EndTime $endTime -Timer $timer
        $plain = ($content.ToString() -replace '\x1b\[[0-9;]*m', '')
        $plain | Should -Match 'Notify'
        $plain | Should -Match 'sound \+ webhook \(timer\)'
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

Describe "Timer presets and sequence limits" {
    BeforeEach {
        Reset-TimerDataCacheForTests
        if (Test-Path $script:TimerDataFile) { Remove-Item $script:TimerDataFile -Force }
    }

    It "starts simple repeating timer from Time/Repeat preset" {
        $presetKey = 'water-test'
        $savedPreset = $null
        if ($script:TimerPresets.ContainsKey($presetKey)) {
            $savedPreset = $script:TimerPresets[$presetKey]
        }
        try {
            $script:TimerPresets[$presetKey] = @{
                Time        = '45m'
                Message     = 'water'
                Repeat      = 100
                Description = 'test preset'
            }
            Timer -Time $presetKey -NoSound
            $timers = @(Get-TimerData)
            $timers.Count | Should -Be 1
            $timers[0].IsSequence | Should -BeFalse
            $timers[0].RepeatTotal | Should -Be 100
            $timers[0].Message | Should -Be 'water'
            $timers[0].Seconds | Should -Be 2700
        }
        finally {
            if ($null -ne $savedPreset) {
                $script:TimerPresets[$presetKey] = $savedPreset
            }
            else {
                $script:TimerPresets.Remove($presetKey)
            }
        }
    }

    It "rejects sequence patterns above MaxSequencePhases" {
        { ConvertFrom-TimerSequence -Pattern '(1s tick)x501' } | Should -Throw '*maximum is 500*'
    }

    It "Get-TimerFinalEndTime uses uniform fast path for repeating phases" {
        $phases = @(ConvertFrom-TimerSequence -Pattern '(10s a, 10s b)x2')
        $timer = [PSCustomObject]@{
            IsSequence   = $true
            State        = 'Running'
            StartTime    = (Get-Date).AddMinutes(-5).ToString('o')
            EndTime      = (Get-Date).AddMinutes(1).ToString('o')
            CurrentPhase = 1
            Phases       = $phases
            TotalSeconds = 40
            Seconds      = 10
        }
        $result = Get-TimerFinalEndTime -Timer $timer
        $expected = [DateTime]::Parse($timer.EndTime).AddSeconds(20)
        $result.ToString('o') | Should -Be $expected.ToString('o')
    }

    It "Sync-CatchUpUniformSequencePhase advances overdue uniform sequences" {
        Mock Repair-TimerScheduledTaskIfMissing { return $true }
        $phases = @()
        for ($i = 0; $i -lt 10; $i++) {
            $phases += [PSCustomObject]@{ Seconds = 60; Label = 'water'; Duration = '1m' }
        }
        $timer = [PSCustomObject]@{
            Id           = 'catchup-1'
            IsSequence   = $true
            State        = 'Running'
            StartTime    = (Get-Date).AddHours(-3).ToString('o')
            EndTime      = (Get-Date).AddHours(-2).ToString('o')
            CurrentPhase = 0
            TotalPhases  = 10
            PhaseLabel   = 'water'
            Message      = 'water'
            Seconds      = 60
            Phases       = $phases
            TaskName     = 'PSTimer_catchup-1_abc'
        }
        $now = Get-Date
        $changed = Sync-CatchUpUniformSequencePhase -Timer $timer -Now $now
        $changed | Should -BeTrue
        [int]$timer.CurrentPhase | Should -BeGreaterThan 0
        ([DateTime]::Parse($timer.EndTime) -gt $now) | Should -BeTrue
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

        $script:WatchInputCalls = 0
        Mock Get-Date { return $fixedNow }
        Mock Wait-TimerWatchInput {
            $script:WatchInputCalls++
            if ($script:WatchInputCalls -lt 25) { return @{ Action = 'tick' } }
            return @{ Action = 'exit' }
        }
        Mock Sync-TimerData { return @($timerFirstRun) }
        Mock Clear-Host { }
        Mock Get-TimerWatchCompletedContent { return [System.Text.StringBuilder]::new() }
        Mock Start-Sleep { }

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

    It "shows DONE immediately for straight completion without polling" {
        $fixedNow = [DateTime]::new(2024, 6, 1, 12, 0, 0)
        $pastEnd = $fixedNow.AddSeconds(-1).ToString('o')

        $runningTimer = [PSCustomObject]@{
            Id              = "1"
            Duration        = "5s"
            Seconds         = 5
            Message         = "Time is up!"
            StartTime       = $fixedNow.AddSeconds(-6).ToString('o')
            EndTime         = $pastEnd
            RepeatTotal     = 1
            RepeatRemaining = 0
            CurrentRun      = 1
            State           = "Running"
            IsSequence      = $false
        }

        Mock Get-Date { return $fixedNow }
        Mock Wait-TimerWatchInput { return @{ Action = 'exit' } }
        Mock Sync-TimerData { return @($runningTimer) }
        Mock Clear-Host { }
        Mock Get-TimerWatchCompletedContent { return [System.Text.StringBuilder]::new() }
        Mock Start-Sleep { }

        Mock Get-TimerDataIfChanged {
            return @{ Data = @($runningTimer); Changed = $true }
        }

        $inputTimer = [PSCustomObject]@{
            Id         = "1"
            Seconds    = 5
            Message    = "Time is up!"
            EndTime    = $pastEnd
            IsSequence = $false
        }

        Show-TimerWatchDisplay -Timer $inputTimer

        Assert-MockCalled -CommandName Get-TimerWatchCompletedContent -Times 1 -Exactly
        Assert-MockCalled -CommandName Get-TimerDataIfChanged -ParameterFilter { $Force } -Times 0 -Exactly
        Assert-MockCalled -CommandName Start-Sleep -Times 0 -Exactly
    }

    It "exits poll early when refreshed timer is Completed" {
        $fixedNow = [DateTime]::new(2024, 6, 1, 12, 0, 0)
        $pastEnd = $fixedNow.AddSeconds(-1).ToString('o')

        $timerLastRun = [PSCustomObject]@{
            Id              = "1"
            Duration        = "5s"
            Seconds         = 5
            Message         = "Time is up!"
            StartTime       = $fixedNow.AddSeconds(-6).ToString('o')
            EndTime         = $pastEnd
            RepeatTotal     = 2
            RepeatRemaining = 1
            CurrentRun      = 1
            State           = "Running"
            IsSequence      = $false
        }
        $timerCompleted = [PSCustomObject]@{
            Id              = "1"
            Duration        = "5s"
            Seconds         = 5
            Message         = "Time is up!"
            StartTime       = $timerLastRun.StartTime
            EndTime         = $pastEnd
            RepeatTotal     = 2
            RepeatRemaining = 0
            CurrentRun      = 2
            State           = "Completed"
            IsSequence      = $false
        }

        Mock Get-Date { return $fixedNow }
        Mock Wait-TimerWatchInput { return @{ Action = 'tick' } }
        Mock Sync-TimerData { return @($timerLastRun) }
        Mock Clear-Host { }
        Mock Get-TimerWatchCompletedContent { return [System.Text.StringBuilder]::new() }
        Mock Start-Sleep { }

        Mock Get-TimerDataIfChanged {
            param([switch]$Force)
            if ($Force) {
                return @{ Data = @($timerCompleted); Changed = $true }
            }
            return @{ Data = @($timerLastRun); Changed = $true }
        }

        $inputTimer = [PSCustomObject]@{
            Id         = "1"
            Seconds    = 5
            Message    = "Time is up!"
            EndTime    = $pastEnd
            IsSequence = $false
        }

        Show-TimerWatchDisplay -Timer $inputTimer

        Assert-MockCalled -CommandName Get-TimerWatchCompletedContent -Times 1 -Exactly
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

    It "Write-TimerVbsLauncherFile writes ASCII without BOM" {
        $savedPwsh = $script:PS1TimerPwsh
        try {
            $script:PS1TimerPwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
            $ps1Path = Join-Path $TestDrive 'PSTimer_cue_test.ps1'
            $vbsPath = Join-Path $TestDrive 'PSTimer_cue_test.vbs'
            Set-Content -LiteralPath $ps1Path -Value '# test' -Encoding Ascii

            Write-TimerVbsLauncherFile -VbsPath $vbsPath -Ps1Path $ps1Path

            Test-Path -LiteralPath $vbsPath | Should -BeTrue
            $bytes = [System.IO.File]::ReadAllBytes($vbsPath)
            $bytes[0..2] | Should -Not -Be @(0xEF, 0xBB, 0xBF)
            $content = Get-Content -LiteralPath $vbsPath -Raw
            $content | Should -Match 'Chr\(34\)'
            $content | Should -Match 'PSTimer_cue_test\.ps1'
        }
        finally {
            $script:PS1TimerPwsh = $savedPwsh
        }
    }

    It "Register-TimerCueTask writes ASCII cue VBS launcher" {
        $savedPwsh = $script:PS1TimerPwsh
        try {
            $script:PS1TimerPwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
            Mock Register-TimerScheduledTask { return $true }

            $cueName = 'PSTimer_99_cue_testabcd'
            $ps1Path = Join-Path $env:TEMP "$cueName.ps1"
            $vbsPath = Join-Path $env:TEMP "$cueName.vbs"
            Set-Content -LiteralPath $ps1Path -Value '# cue' -Encoding Ascii

            Register-TimerCueTask -CueTaskName $cueName -TriggerTime (Get-Date).AddMinutes(5) -ScriptPath $ps1Path

            Test-Path -LiteralPath $vbsPath | Should -BeTrue
            $bytes = [System.IO.File]::ReadAllBytes($vbsPath)
            if ($bytes.Count -ge 3) {
                $bytes[0..2] | Should -Not -Be @(0xEF, 0xBB, 0xBF)
            }
            $content = Get-Content -LiteralPath $vbsPath -Raw
            $content | Should -Match 'Chr\(34\)'
        }
        finally {
            $script:PS1TimerPwsh = $savedPwsh
            Remove-Item -LiteralPath $ps1Path -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $vbsPath -Force -ErrorAction SilentlyContinue
        }
    }

    It "Get-TimerAfterStartAction returns config default and override" {
        Get-TimerAfterStartAction | Should -Be 'none'
        Get-TimerAfterStartAction -Override 'watch' | Should -Be 'watch'
    }

    It "Get-SequenceTimerIntroSpeechText returns workout intro only" {
        $saved = $global:Config
        try {
            $global:Config = @{
                TimerDefaults = @{ Visual = 'none'; Sound = $false; Voice = $true }
                VoiceTemplates = @{
                    WorkoutStart = 'Starting {description}, {duration}'
                    PhaseStart   = '{label}'
                }
                Workouts = @{
                    'test-routine' = @{ Description = 'Test session' }
                }
            }
            Initialize-PS1TimerModuleConfig
            $summary = [PSCustomObject]@{ TotalDuration = '5m'; TotalSeconds = 300 }
            $firstPhase = [PSCustomObject]@{ Label = 'Warm up'; AnnounceStart = 'Begin warm up' }
            $intro = Get-SequenceTimerIntroSpeechText -IsWorkout -WorkoutRoutine 'test-routine' -FirstPhase $firstPhase -StartTime (Get-Date) -Summary $summary -Phases @($firstPhase)
            $intro | Should -Match 'Test session'
            $intro | Should -Not -Match 'Begin warm up'

            $texts = Get-SequenceTimerStartSpeechTexts -IsWorkout -WorkoutRoutine 'test-routine' -FirstPhase $firstPhase -StartTime (Get-Date) -Summary $summary -Phases @($firstPhase)
            $texts.Count | Should -Be 1
            $texts[0] | Should -Match 'Test session'
        }
        finally {
            $global:Config = $saved
            Initialize-PS1TimerModuleConfig
        }
    }

    It "Sync-TimerData verifies scheduled task when phase has time left after sleep" {
        $existing = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        [void]$existing.Add('PSTimer_1_abcdef01')
        Set-TimerTestScheduledTaskNamesResultOverride $existing
        Mock Start-TimerScheduledJob { }

        $future = (Get-Date).AddMinutes(30).ToString('o')
        $timer = [PSCustomObject]@{
            Id = '1'; State = 'Running'; EndTime = $future; Seconds = 1800
            TaskName = 'PSTimer_1_abcdef01'; Duration = '30m'; Message = 'x'
            StartTime = (Get-Date).ToString('o')
            RepeatTotal = 1; RepeatRemaining = 0; CurrentRun = 1
            IsSequence = $false
        }
        Save-TimerData -Timers @($timer)

        $result = Sync-TimerData

        $result[0].State | Should -Be 'Running'
        Assert-MockCalled Start-TimerScheduledJob -Times 0 -Exactly
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

    It "repeat fire script preserves notify fields across JSON updates" {
        $saved = $global:Config
        try {
            $global:Config = @{
                TimerDefaults = @{ Visual = 'none'; Sound = $true; Webhook = 'timer' }
                Webhooks = @{ 'timer' = 'https://example.com/hook' }
            }
            Initialize-PS1TimerModuleConfig
            Timer -Time '5s' -Message 'water' -Repeat 3

            $scriptPath = Join-Path $env:TEMP 'PSTimer_1.ps1'
            $content = Get-Content -LiteralPath $scriptPath -Raw
            $content | Should -Match '\$notifyProps'
            $content | Should -Match 'NotifyVisual'
            $content | Should -Match '\$notifyVisual = ''none'''
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

    It "applies preset Voice and Countdown overrides" {
        $saved = $global:Config
        try {
            $global:Config = @{ TimerDefaults = @{ Visual = 'none'; Sound = $false; Voice = $false; Countdown = 'none' } }
            Initialize-PS1TimerModuleConfig
            $result = Resolve-TimerNotificationSettings -PresetVoice $true -PresetCountdown '321'
            $result.Voice | Should -BeTrue
            $result.Countdown | Should -Be '321'
            $result.Label | Should -Be 'voice + countdown (321)'
        }
        finally {
            $global:Config = $saved
            Initialize-PS1TimerModuleConfig
        }
    }
}

Describe "Get-TimerFireScriptVoiceBlock" {
    It "returns empty when Voice is false" {
        Get-TimerFireScriptVoiceBlock -Voice $false | Should -Be ''
    }

    It "includes System.Speech when Voice is true" {
        $block = Get-TimerFireScriptVoiceBlock -Voice $true -TextExpr '$announceText'
        $block | Should -Match 'System\.Speech'
        $block | Should -Match '\$announceText'
    }
}

Describe "Write-TimerCueRegistrarFile" {
    It "does not schedule duplicate phase-start cues" {
        $path = Write-TimerCueRegistrarFile -TimerId '99' -VoiceName 'Test Voice' -VoiceRate 0 -VoiceVolume 100
        $content = Get-Content -LiteralPath $path -Raw
        $content | Should -Not -Match "CueType\s*=\s*'start'"
        $content | Should -Not -Match '\$startText'
    }

    It "embeds ASCII VBS write for cue launchers" {
        $path = Write-TimerCueRegistrarFile -TimerId '99' -VoiceName 'Test Voice' -VoiceRate 0 -VoiceVolume 100
        $content = Get-Content -LiteralPath $path -Raw
        $content | Should -Match '\[System\.Text\.Encoding\]::ASCII'
        $content | Should -Match 'Chr\(34\)'
        $content | Should -Not -Match 'WriteAllText\(\`\$cueVbs.*\`\$utf8\)'
    }
}

Describe "Write-TimerSpeechQueueScriptFile" {
    It "writes a hidden-process speech script with all queued lines" {
        $path = Write-TimerSpeechQueueScriptFile -Texts @('Session intro', 'First phase') -VoiceName 'Test Voice' -VoiceRate -1 -VoiceVolume 90
        $path | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $path | Should -BeTrue
        $content = Get-Content -LiteralPath $path -Raw
        $content | Should -Match 'System\.Speech'
        $content | Should -Match 'Session intro'
        $content | Should -Match 'First phase'
        $content | Should -Match 'Test Voice'
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

Describe "Get-TimerWatchOptimisticNextPhaseDisplay" {
    It "predicts the next sequence phase for watch UI" {
        $timer = [PSCustomObject]@{
            Id           = '1'
            IsSequence   = $true
            CurrentPhase = 0
            TotalPhases  = 3
            TotalSeconds = 120
            Phases       = @(
                [PSCustomObject]@{ Label = 'phase one'; Seconds = 30 }
                [PSCustomObject]@{ Label = 'phase two'; Seconds = 45 }
                [PSCustomObject]@{ Label = 'phase three'; Seconds = 45 }
            )
        }
        $previousEnd = [DateTime]'2026-06-05T10:00:30'
        $now = [DateTime]'2026-06-05T10:00:31'

        $result = Get-TimerWatchOptimisticNextPhaseDisplay -Timer $timer -PreviousEndTime $previousEnd -Now $now

        $result.DisplayTimer.CurrentPhase | Should -Be 1
        $result.DisplayTimer.PhaseLabel | Should -Be 'phase two'
        $result.DisplayTimer.Seconds | Should -Be 45
        $result.EndTime | Should -Be $now.AddSeconds(45)
    }
}

Describe "Timer-Workout" {
    BeforeAll {
        Mock Register-ScheduledTask { }
        Mock Unregister-ScheduledTask { }
        Mock Start-Job { }
    }

    BeforeEach {
        Reset-TimerDataCacheForTests
        if (Test-Path $script:TimerDataFile) { Remove-Item $script:TimerDataFile -Force }
    }

    It "starts workout timer with IsWorkout flag" {
        $saved = $global:Config
        try {
            $global:Config = @{
                TimerDefaults = @{ Visual = 'none'; Sound = $false; Voice = $false; Countdown = '321' }
                Workouts = @{
                    'tabata-hiit' = @{
                        Pattern = '(20s work, 10s rest)x2'
                        Voice = $true
                        Countdown = '321'
                    }
                }
            }
            Initialize-PS1TimerModuleConfig
            Mock Invoke-TimerSpeech { }
            Mock Invoke-TimerSpeechQueueAsync { }
            Mock Invoke-TimerPhaseCueRegistration { }
            Mock Write-TimerCueRegistrarFile { return "$TestDrive/registrar.ps1" }

            Timer-Workout -Routine 'tabata-hiit'

            $timers = @(Get-TimerData)
            $timers.Count | Should -Be 1
            $timers[0].IsWorkout | Should -BeTrue
            $timers[0].WorkoutRoutine | Should -Be 'tabata-hiit'
            $timers[0].NotifyVoice | Should -BeTrue
        }
        finally {
            $global:Config = $saved
            Initialize-PS1TimerModuleConfig
            if (Test-Path $script:TimerDataFile) { Remove-Item $script:TimerDataFile -Force }
        }
    }

    It "speaks intro before starting workout timer when voice is enabled" {
        $saved = $global:Config
        try {
            $global:Config = @{
                TimerDefaults = @{ Visual = 'none'; Sound = $false; Voice = $false; Countdown = '321'; AfterStart = 'watch' }
                VoiceTemplates = @{ WorkoutStart = 'Go'; PhaseStart = '{label}' }
                Workouts = @{
                    'tabata-hiit' = @{
                        Pattern = '(20s work, 10s rest)x2'
                        Voice = $true
                        Countdown = '321'
                    }
                }
            }
            Initialize-PS1TimerModuleConfig
            Mock Invoke-TimerSpeechQueueAsync { }
            Mock Invoke-TimerSpeechQueue { }
            Mock Invoke-TimerPhaseCueRegistration { }
            Mock Write-TimerCueRegistrarFile { return "$TestDrive/registrar.ps1" }
            Mock Invoke-TimerAfterStart { }

            Timer-Workout -Routine 'tabata-hiit'

            Assert-MockCalled Invoke-TimerSpeechQueue -Times 1 -Exactly
            Assert-MockCalled Invoke-TimerSpeechQueueAsync -Times 0 -Exactly
            Assert-MockCalled Invoke-TimerAfterStart -Times 1 -Exactly
        }
        finally {
            $global:Config = $saved
            Initialize-PS1TimerModuleConfig
            if (Test-Path $script:TimerDataFile) { Remove-Item $script:TimerDataFile -Force }
        }
    }

    It "starts workout via t workout without explicit -Countdown" {
        $saved = $global:Config
        try {
            $global:Config = @{
                TimerDefaults = @{ Visual = 'none'; Sound = $true; Voice = $false; Countdown = 'none'; Webhook = 'timer' }
                Workouts = @{
                    'gyors-nyujtas' = @{
                        Pattern   = "45s 'stretch left', 45s 'stretch right'"
                        Voice     = $true
                        Sound     = $false
                        Visual    = 'none'
                        Countdown = 'none'
                    }
                }
            }
            Initialize-PS1TimerModuleConfig
            Mock Invoke-TimerSpeech { }
            Mock Invoke-TimerSpeechQueueAsync { }
            Mock Invoke-TimerPhaseCueRegistration { }
            Mock Write-TimerCueRegistrarFile { return "$TestDrive/registrar.ps1" }

            Timer -Time workout -Message 'gyors-nyujtas'

            $timers = @(Get-TimerData)
            $timers.Count | Should -Be 1
            $timers[0].IsWorkout | Should -BeTrue
            $timers[0].WorkoutRoutine | Should -Be 'gyors-nyujtas'
            $timers[0].CountdownMode | Should -Be 'none'
            $timers[0].NotifyVoice | Should -BeTrue
            $timers[0].NotifySound | Should -BeFalse
        }
        finally {
            $global:Config = $saved
            Initialize-PS1TimerModuleConfig
            if (Test-Path $script:TimerDataFile) { Remove-Item $script:TimerDataFile -Force }
        }
    }
}
