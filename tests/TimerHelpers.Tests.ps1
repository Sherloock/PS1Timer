# PS1Timer helper and parser tests

BeforeAll {
    $ModuleRoot = Split-Path -Parent $PSScriptRoot
    . "$PSScriptRoot\PS1Timer.TestBootstrap.ps1" -ModuleRoot $ModuleRoot -TestDrive $TestDrive
}

Describe "ConvertTo-Seconds" {
    It "converts hours" {
        ConvertTo-Seconds "2h" | Should -Be 7200
    }
    It "converts minutes" {
        ConvertTo-Seconds "30m" | Should -Be 1800
    }
    It "converts seconds" {
        ConvertTo-Seconds "45s" | Should -Be 45
    }
    It "converts hours and minutes" {
        ConvertTo-Seconds "1h30m" | Should -Be 5400
    }
    It "converts all units combined" {
        ConvertTo-Seconds "1h30m45s" | Should -Be 5445
    }
    It "converts pure number as seconds" {
        ConvertTo-Seconds "300" | Should -Be 300
    }
    It "returns 0 for invalid input" {
        ConvertTo-Seconds "abc" | Should -Be 0
    }
    It "returns 0 for empty string" {
        ConvertTo-Seconds "" | Should -Be 0
    }
    It "handles large values" {
        ConvertTo-Seconds "24h" | Should -Be 86400
    }
}

Describe "Format-Duration" {
    It "formats hours minutes seconds" {
        Format-Duration -Seconds 5445 | Should -Be "1h 30m 45s"
    }
    It "formats hours and minutes only" {
        Format-Duration -Seconds 5400 | Should -Be "1h 30m"
    }
    It "formats hours only" {
        Format-Duration -Seconds 7200 | Should -Be "2h"
    }
    It "formats minutes only" {
        Format-Duration -Seconds 1800 | Should -Be "30m"
    }
    It "formats seconds only" {
        Format-Duration -Seconds 45 | Should -Be "45s"
    }
    It "formats zero as 0s" {
        Format-Duration -Seconds 0 | Should -Be "0s"
    }
    It "formats minutes and seconds" {
        Format-Duration -Seconds 125 | Should -Be "2m 5s"
    }
}

Describe "New-TimerId" {
    It "returns '1' when no timers exist" {
        if (Test-Path $script:TimerDataFile) { Remove-Item $script:TimerDataFile }
        New-TimerId | Should -Be "1"
    }

    It "returns next sequential ID" {
        $testTimers = @(
            @{ Id = "1"; State = "Completed" },
            @{ Id = "2"; State = "Running" }
        )
        ConvertTo-Json $testTimers | Set-Content $script:TimerDataFile
        New-TimerId | Should -Be "3"
    }

    It "handles gaps in IDs" {
        $testTimers = @(
            @{ Id = "1"; State = "Completed" },
            @{ Id = "5"; State = "Running" }
        )
        ConvertTo-Json $testTimers | Set-Content $script:TimerDataFile
        New-TimerId | Should -Be "6"
    }
}

Describe "Get-TimerData" {
    BeforeEach {
        $script:TimerDataCache = $null
        $script:TimerDataCacheTime = [DateTime]::MinValue
        if (Test-Path $script:TimerDataFile) { Remove-Item $script:TimerDataFile -Force }
    }

    It "returns empty array when file does not exist" {
        if (Test-Path $script:TimerDataFile) { Remove-Item $script:TimerDataFile }
        $result = Get-TimerData
        $result | Should -BeNullOrEmpty
    }

    It "loads timers from JSON file" {
        $testTimers = @(
            @{ Id = "1"; Message = "Test"; State = "Running" }
        )
        ConvertTo-Json $testTimers | Set-Content $script:TimerDataFile
        $result = @(Get-TimerData)
        $result.Count | Should -Be 1
        $result[0].Id | Should -Be "1"
    }

    It "returns empty array for corrupted JSON" {
        "not valid json" | Set-Content $script:TimerDataFile
        $result = Get-TimerData
        $result | Should -BeNullOrEmpty
    }
}

Describe "Save-TimerData" {
    BeforeEach {
        $script:TimerDataCache = $null
        $script:TimerDataCacheTime = [DateTime]::MinValue
        if (Test-Path $script:TimerDataFile) { Remove-Item $script:TimerDataFile -Force }
    }

    It "saves timers to JSON file" {
        $testTimers = @(
            [PSCustomObject]@{
                Id               = "1"
                Duration         = "5m"
                Seconds          = 300
                Message          = "Test"
                StartTime        = (Get-Date).ToString('o')
                EndTime          = (Get-Date).AddSeconds(300).ToString('o')
                RepeatTotal      = 1
                RepeatRemaining  = 0
                CurrentRun       = 1
                State            = "Running"
            }
        )
        Save-TimerData -Timers $testTimers
        Test-Path $script:TimerDataFile | Should -BeTrue
        $loaded = Get-Content $script:TimerDataFile | ConvertFrom-Json
        $loaded.Id | Should -Be "1"
    }

    It "writes empty JSON array when saving no timers" {
        "existing content" | Set-Content $script:TimerDataFile
        Save-TimerData -Timers @()
        Test-Path $script:TimerDataFile | Should -BeTrue
        $loaded = @(Get-TimerData)
        $loaded.Count | Should -Be 0
        (Get-Content -LiteralPath $script:TimerDataFile -Raw).Trim() | Should -Be '[]'
    }
}

Describe "Get-AnsiColors" {
    It "returns hashtable with expected keys" {
        $colors = Get-AnsiColors
        $colors | Should -BeOfType [hashtable]
        $colors.Keys | Should -Contain "Reset"
        $colors.Keys | Should -Contain "Primary"
        $colors.Keys | Should -Contain "Success"
    }

    It "returns ANSI escape sequences" {
        $colors = Get-AnsiColors
        $colors.Reset | Should -Match '\x1b\['
    }

    It "uses Config.Palettes theme colors" {
        $saved = $global:Config
        try {
            $global:Config = @{
                TimerDefaults = @{ Theme = 'custom' }
                Palettes      = @{
                    custom = @{
                        Description  = 'Test palette'
                        Primary      = 'brightcyan'
                        PrimaryMuted = 'cyan'
                        Text         = 'brightwhite'
                        Muted        = 'darkgray'
                        Success      = 'brightgreen'
                        Warning      = 'brightyellow'
                        Danger       = 'brightred'
                        Accent       = 'brightmagenta'
                        Selected     = 'cyan'
                    }
                }
            }
            Initialize-PS1TimerModuleConfig
            $colors = Get-AnsiColors
            $colors.Theme | Should -Be 'custom'
            $colors.Primary | Should -Be "$([char]27)[96m"
        }
        finally {
            $global:Config = $saved
        }
    }
}

Describe "Resolve-TimerPaletteColors" {
    It "converts named colors to escape sequences" {
        $resolved = Resolve-TimerPaletteColors -PaletteEntry @{
            Primary      = 'cyan'
            PrimaryMuted = 'cyan'
            Text         = 'white'
            Muted        = 'darkgray'
            Success      = 'green'
            Warning      = 'yellow'
            Danger       = 'red'
            Accent       = 'magenta'
            Selected     = 'cyan'
        }
        $resolved.Success | Should -Be "$([char]27)[32m"
        $resolved.Selected | Should -Be "$([char]27)[30;46m"
    }
}

Describe "Format-RemainingTime" {
    It "formats positive TimeSpan as HH:MM:SS" {
        $ts = [TimeSpan]::FromSeconds(3661)
        Format-RemainingTime -Remaining $ts | Should -Be "01:01:01"
    }

    It "returns 00:00:00 for negative TimeSpan" {
        Format-RemainingTime -Remaining ([TimeSpan]::FromSeconds(-100)) | Should -Be "00:00:00"
    }

    It "ceilings sub-second remainders to 1 second" {
        Format-RemainingTime -Remaining ([TimeSpan]::FromSeconds(0.6)) | Should -Be "00:00:01"
    }

    It "returns 00:00:00 for zero remainder" {
        Format-RemainingTime -Remaining ([TimeSpan]::Zero) | Should -Be "00:00:00"
    }
}

Describe "Get-TimerStateColor" {
    It "returns Green for Running state" {
        Get-TimerStateColor -State "Running" | Should -Be "Green"
    }

    It "returns ANSI code when -Ansi switch is used" {
        Get-TimerStateColor -State "Running" -Ansi | Should -Match '\x1b\['
    }
}

Describe "Get-TimerProgress" {
    It "returns 100 for Completed timer" {
        Get-TimerProgress -Timer ([PSCustomObject]@{ State = "Completed" }) | Should -Be 100
    }

    It "calculates progress for Paused timer" {
        $timer = [PSCustomObject]@{ State = "Paused"; Seconds = 100; RemainingSeconds = 25 }
        Get-TimerProgress -Timer $timer | Should -Be 75
    }

    It "uses EndTime window for Running timer after resume" {
        $start = [DateTime]::new(2024, 1, 1, 12, 0, 0)
        $end = $start.AddSeconds(88)
        $now = $start.AddSeconds(44)
        Mock Get-Date { return $now }
        $timer = [PSCustomObject]@{
            State     = "Running"
            Seconds   = 100
            StartTime = $start.ToString('o')
            EndTime   = $end.ToString('o')
        }
        Get-TimerProgress -Timer $timer | Should -Be 50
    }
}

Describe "Get-TruncatedMessage" {
    It "truncates long message with ellipsis" {
        $result = Get-TruncatedMessage -Message "This is a very long message" -MaxLength 15
        $result | Should -Be "This is a ve..."
    }
}

Describe "Test-TimerSequence" {
    It "returns true for preset name when presets loaded" {
        $script:TimerPresets['pomodoro'] | Should -Not -BeNullOrEmpty
        Test-TimerSequence -Pattern "pomodoro" | Should -BeTrue
    }

    It "returns false for simple time" {
        Test-TimerSequence -Pattern "25m" | Should -BeFalse
    }
}

Describe "ConvertFrom-TimerSequence" {
    It "expands preset name tabata" {
        $phases = @(ConvertFrom-TimerSequence -Pattern "tabata")
        $phases.Count | Should -Be 16
    }

    It "parses nested groups" {
        $phases = @(ConvertFrom-TimerSequence -Pattern "((25m work, 5m rest)x2)x2")
        $phases.Count | Should -Be 8
    }
}

Describe "Get-SequenceSummary" {
    It "calculates total seconds for pomodoro-short" {
        $phases = ConvertFrom-TimerSequence -Pattern "pomodoro-short"
        $summary = Get-SequenceSummary -Phases $phases
        $summary.TotalSeconds | Should -Be 3600
    }
}

Describe "TimerPresets" {
    $expectedPresets = @(
        'pomodoro', 'pomodoro-short', 'pomodoro-long', '52-17', '90-20',
        'micro-pomodoro', 'eye-20-20-20', 'standup', 'deep-focus-3h', 'power-nap',
        'meditation', 'tabata', 'cooking-pasta', 'cooking-rice', 'lecture',
        'gym-sets', 'two-minute', 'flowtime', 'ultradian'
    )

    It "ships 19 built-in presets" {
        $script:TimerPresets.Keys.Count | Should -Be 22
    }

    It "contains all expected preset keys" {
        foreach ($name in $expectedPresets) {
            ($script:TimerPresets.Keys -contains $name) | Should -BeTrue
        }
    }

    It "each preset has Pattern and Description" {
        foreach ($name in $expectedPresets) {
            $script:TimerPresets[$name].Pattern | Should -Not -BeNullOrEmpty
            $script:TimerPresets[$name].Description | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Module configuration loading" {
    It "loads TimerDefaults from config.example.ps1" {
        $saved = $global:Config
        try {
            $global:Config = @{}
            . (Join-Path $ModuleRoot 'config.example.ps1')
            Initialize-PS1TimerModuleConfig
            $cfg = Get-TimerNotificationConfig
            $cfg.Visual | Should -Be 'none'
            $cfg.Sound | Should -BeTrue
        }
        finally {
            $global:Config = $saved
            Initialize-PS1TimerModuleConfig
        }
    }

    It "resolves SoundFile name to path from config.example.ps1" {
        $saved = $global:Config
        try {
            $global:Config = @{}
            . (Join-Path $ModuleRoot 'config.example.ps1')
            $global:Config.TimerDefaults.SoundFile = 'notify'
            Initialize-PS1TimerModuleConfig
            $cfg = Get-TimerNotificationConfig
            $cfg.SoundFile | Should -Be (Join-Path $env:windir 'Media\notify.wav')
        }
        finally {
            $global:Config = $saved
            Initialize-PS1TimerModuleConfig
        }
    }
}

Describe "ConvertFrom-LegacyNotifyMode" {
    It "maps sound to none visual with sound on" {
        $result = ConvertFrom-LegacyNotifyMode -Notify 'sound'
        $result.Visual | Should -Be 'none'
        $result.Sound | Should -BeTrue
    }

    It "maps silent to none visual with sound off" {
        $result = ConvertFrom-LegacyNotifyMode -Notify 'silent'
        $result.Visual | Should -Be 'none'
        $result.Sound | Should -BeFalse
    }
}

Describe "Get-TimerNotifyChannelsFromTimer" {
    It "falls back to TimerDefaults when notify fields are missing" {
        $saved = $global:Config
        try {
            $global:Config = @{
                TimerDefaults = @{ Visual = 'none'; Sound = $true; Voice = $false }
            }
            Initialize-PS1TimerModuleConfig
            $timer = [PSCustomObject]@{
                Id = '1'
                Message = 'water'
            }
            $channels = Get-TimerNotifyChannelsFromTimer -Timer $timer
            $channels.Visual | Should -Be 'none'
            $channels.Sound | Should -BeTrue
            $channels.Voice | Should -BeFalse
        }
        finally {
            $global:Config = $saved
            Initialize-PS1TimerModuleConfig
        }
    }

    It "honors NotifyVisual none on timer records" {
        $timer = [PSCustomObject]@{
            Id = '1'
            NotifyVisual = 'none'
            NotifySound = $true
        }
        $channels = Get-TimerNotifyChannelsFromTimer -Timer $timer
        $channels.Visual | Should -Be 'none'
        $channels.Sound | Should -BeTrue
    }
}

Describe "Resolve-TimerSoundFilePath" {
    It "resolves named sound from config" {
        $saved = $global:Config
        try {
            $global:Config = @{
                Sounds = @{ notify = 'C:\Windows\Media\notify.wav' }
            }
            Initialize-PS1TimerModuleConfig
            Resolve-TimerSoundFilePath -Name 'notify' | Should -Be 'C:\Windows\Media\notify.wav'
            Resolve-TimerSoundFilePath -Name 'missing' | Should -BeNullOrEmpty
        }
        finally {
            $global:Config = $saved
            Initialize-PS1TimerModuleConfig
        }
    }

    It "passes through existing raw path when not a Sounds key" {
        $saved = $global:Config
        try {
            $global:Config = @{ Sounds = @{ notify = 'C:\Windows\Media\notify.wav' } }
            Initialize-PS1TimerModuleConfig
            $testDriveWav = Join-Path $TestDrive 'custom.wav'
            New-Item -ItemType File -Path $testDriveWav -Force | Out-Null
            Resolve-TimerSoundFilePath -Name $testDriveWav | Should -Be $testDriveWav
        }
        finally {
            $global:Config = $saved
            Initialize-PS1TimerModuleConfig
        }
    }

    It "keeps module snapshot when global Config is replaced" {
        $saved = $global:Config
        try {
            $global:Config = @{
                Sounds = @{ ding = 'C:\Windows\Media\ding.wav' }
            }
            Initialize-PS1TimerModuleConfig
            $global:Config = @{ TimerDefaults = @{ Notify = 'popup' } }

            Resolve-TimerSoundFilePath -Name 'ding' | Should -Be 'C:\Windows\Media\ding.wav'
        }
        finally {
            $global:Config = $saved
            Initialize-PS1TimerModuleConfig
        }
    }
}

Describe "Assert-TimerConfig" {
    It "does not warn when win-critical sound path exists" {
        Mock Test-Path { $true }
        $warnMessages = [System.Collections.Generic.List[string]]::new()
        Mock Write-Warning { param($Message) $warnMessages.Add([string]$Message) }
        $saved = $global:Config
        try {
            $global:Config = @{
                Sounds = @{
                    'win-critical' = (Join-Path $env:windir 'Media\Windows Critical Stop.wav')
                }
            }
            Initialize-PS1TimerModuleConfig
            Assert-TimerConfig
            ($warnMessages | Where-Object { $_ -match "Sounds\['win-critical'\]" }) | Should -BeNullOrEmpty
        }
        finally {
            $global:Config = $saved
            Initialize-PS1TimerModuleConfig
        }
    }

    It "warns when win-critical sound path is missing" {
        Mock Test-Path { $false }
        $warnMessages = [System.Collections.Generic.List[string]]::new()
        Mock Write-Warning { param($Message) $warnMessages.Add([string]$Message) }
        $saved = $global:Config
        try {
            $global:Config = @{
                Sounds = @{
                    'win-critical' = (Join-Path $env:windir 'Media\Windows Critical Stop.wav')
                }
            }
            Initialize-PS1TimerModuleConfig
            Assert-TimerConfig
            ($warnMessages | Where-Object { $_ -match "Sounds\['win-critical'\]" }).Count | Should -BeGreaterThan 0
        }
        finally {
            $global:Config = $saved
            Initialize-PS1TimerModuleConfig
        }
    }
}

Describe "Resolve-TimerWebhookUrl" {
    It "resolves named webhook from config" {
        $saved = $global:Config
        try {
            $global:Config = @{
                Webhooks = @{ 'discord-main' = 'https://example.com/hook' }
            }
            Resolve-TimerWebhookUrl -Name 'discord-main' | Should -Be 'https://example.com/hook'
            Resolve-TimerWebhookUrl -Name 'missing' | Should -BeNullOrEmpty
        }
        finally {
            $global:Config = $saved
        }
    }

    It "keeps module snapshot when $global:Config is replaced" {
        $saved = $global:Config
        try {
            $global:Config = @{
                Webhooks = @{ 'discord-main' = 'https://example.com/hook' }
            }
            Initialize-PS1TimerModuleConfig
            $global:Config = @{ TimerDefaults = @{ Notify = 'popup' } }

            Resolve-TimerWebhookUrl -Name 'discord-main' | Should -Be 'https://example.com/hook'
        }
        finally {
            $global:Config = $saved
            Initialize-PS1TimerModuleConfig
        }
    }
}

Describe "Parse-TimerAtTime" {
    It "parses future HH:mm today" {
        $now = Get-Date '2026-06-05T10:00:00'
        $result = Parse-TimerAtTime -At '14:30' -Now $now
        $result.Hour | Should -Be 14
        $result.Minute | Should -Be 30
    }

    It "returns null for past time today" {
        $now = Get-Date '2026-06-05T15:00:00'
        Parse-TimerAtTime -At '14:30' -Now $now | Should -BeNullOrEmpty
    }

    It "returns null for invalid format" {
        Parse-TimerAtTime -At '2:30pm' | Should -BeNullOrEmpty
    }
}

Describe "Resolve-TimerSpeechText" {
    It "substitutes template tokens" {
        Resolve-TimerSpeechText -TemplateKey 'PhaseStart' -Tokens @{ label = 'work' } | Should -Be 'work'
        Resolve-TimerSpeechText -TemplateKey 'WorkoutStart' -Tokens @{
            description = 'Push day'
            duration    = '35m'
            endTime     = '14:30'
            phaseCount  = '16'
            routine     = 'tabata'
        } | Should -Match 'Push day'
        Resolve-TimerSpeechText -TemplateKey 'WorkoutStart' -Tokens @{
            description = 'Push day'
            duration    = '35m'
            endTime     = '14:30'
            phaseCount  = '16'
            routine     = 'tabata'
        } | Should -Match '14:30'
        Resolve-TimerSpeechText -TemplateKey 'CountdownTick' -Tokens @{ seconds = '3' } | Should -Be '3'
    }
}

Describe "ConvertFrom-TimerSequence BeepAt" {
    It "parses inline -BeepAt on a phase" {
        $phases = @(ConvertFrom-TimerSequence -Pattern "45s 'hold left' -BeepAt 10s, 10s 'switch sides'")
        $phases.Count | Should -Be 2
        $phases[0].Label | Should -Be 'hold left'
        $phases[0].BeepAt | Should -Be @(10)
        $phases[1].Label | Should -Be 'switch sides'
    }
}

Describe "Get-TimerPhaseCueSchedule" {
    It "builds 321 countdown for 20s phase" {
        $cues = Get-TimerPhaseCueSchedule -PhaseSeconds 20 -CountdownMode '321' -PhaseStartText 'work' -IncludePhaseStartAtZero
        $cues.Count | Should -BeGreaterOrEqual 4
        ($cues | Where-Object { $_.Text -eq '3' }).Count | Should -Be 1
    }

    It "skips 10-second warning for short phases" {
        $cues = Get-TimerPhaseCueSchedule -PhaseSeconds 8 -CountdownMode 'both' -IncludePhaseStartAtZero
        ($cues | Where-Object { $_.Text -eq '10' }).Count | Should -Be 0
    }

    It "adds mid-phase beeps at remaining offsets" {
        $cues = Get-TimerPhaseCueSchedule -PhaseSeconds 300 -CountdownMode 'none' -BeepAtSeconds @(180, 60)
        ($cues | Where-Object { $_.CueType -eq 'beep' -and $_.OffsetFromEnd -eq 180 }).Count | Should -Be 1
        ($cues | Where-Object { $_.CueType -eq 'beep' -and $_.OffsetFromEnd -eq 60 }).Count | Should -Be 1
    }

    It "adds end beep 321 before next phase" {
        $cues = Get-TimerPhaseCueSchedule -PhaseSeconds 45 -CountdownMode 'none' -IncludeEndBeep321
        ($cues | Where-Object { $_.CueType -eq 'beep' }).Count | Should -Be 3
        ($cues | Where-Object { $_.OffsetFromEnd -eq 1 }).Count | Should -Be 1
    }
}

Describe "Parse-BeepAtList" {
    It "parses comma-separated duration string" {
        $result = Parse-BeepAtList -InputObject '3m,1m'
        $result | Should -Be @(180, 60)
    }

    It "returns empty for blank input" {
        Parse-BeepAtList -InputObject $null | Should -Be @()
    }
}

Describe "ConvertFrom-WorkoutRoutine" {
    It "expands pattern-only workout" {
        $saved = $global:Config
        try {
            $global:Config = @{
                Workouts = @{
                    'tabata-hiit' = @{
                        Pattern = '(20s work, 10s rest)x2'
                        Countdown = '321'
                    }
                }
            }
            Initialize-PS1TimerModuleConfig
            $phases = @(ConvertFrom-WorkoutRoutine -RoutineName 'tabata-hiit')
            $phases.Count | Should -Be 4
        }
        finally {
            $global:Config = $saved
            Initialize-PS1TimerModuleConfig
        }
    }

    It "expands exercise blocks with work and rest phases" {
        $saved = $global:Config
        try {
            $global:Config = @{
                Workouts = @{
                    'mini' = @{
                        Exercises = @(
                            @{ Name = 'Squat'; Sets = 2; Work = '30s'; Rest = '15s' }
                        )
                    }
                }
            }
            Initialize-PS1TimerModuleConfig
            $phases = @(ConvertFrom-WorkoutRoutine -RoutineName 'mini')
            $phases.Count | Should -Be 3
            $phases[0].PhaseType | Should -Be 'work'
            $phases[0].AnnounceStart | Should -Match 'Squat'
        }
        finally {
            $global:Config = $saved
            Initialize-PS1TimerModuleConfig
        }
    }
}

Describe "Format-TimerNotifyLabel" {
    It "includes voice and countdown in label" {
        Format-TimerNotifyLabel -Visual 'none' -Sound $false -Voice $true -CountdownMode '321' | Should -Be 'voice + countdown (321)'
    }
}
