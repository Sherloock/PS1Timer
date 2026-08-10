# Shared helpers for PS1Timer (time parsing, menus, help rendering)

function ConvertTo-Seconds {
    <#
    .SYNOPSIS
        Converts time string (1h20m, 90s, etc.) to seconds.
    #>
    param([string]$Time)

    $seconds = 0
    if ($Time -match '(\d+)h') { $seconds += [int]$matches[1] * 3600 }
    if ($Time -match '(\d+)m') { $seconds += [int]$matches[1] * 60 }
    if ($Time -match '(\d+)s') { $seconds += [int]$matches[1] }
    if ($Time -match '^\d+$') { $seconds = [int]$Time }

    return $seconds
}

function Format-Duration {
    <#
    .SYNOPSIS
        Formats seconds into readable duration (1h 20m 30s).
    #>
    param([int]$Seconds)

    $h = [math]::Floor($Seconds / 3600)
    $m = [math]::Floor(($Seconds % 3600) / 60)
    $s = $Seconds % 60

    $parts = @()
    if ($h -gt 0) { $parts += "${h}h" }
    if ($m -gt 0) { $parts += "${m}m" }
    if ($s -gt 0 -or $parts.Count -eq 0) { $parts += "${s}s" }

    return $parts -join ' '
}

function Show-MenuPicker {
    <#
    .SYNOPSIS
        Shows an interactive menu picker with arrow key navigation.
    #>
    param(
        [string]$Title,
        [array]$Options,
        [switch]$AllowCancel,
        [switch]$NoClear
    )

    if ($Options.Count -eq 0) {
        return $null
    }

    $selectedIndex = 0
    $optionCount = $Options.Count
    $selector = [char]0x25B6
    $c = Get-AnsiColors

    $colorMap = @{
        'White'      = $c.Text
        'Yellow'     = $c.Warning
        'Green'      = $c.Success
        'Red'        = $c.Danger
        'Cyan'       = $c.Primary
        'Magenta'    = $c.Accent
        'Gray'       = $c.Muted
        'DarkGray'   = $c.Dim
        'DarkYellow' = $c.Warning
    }

    [Console]::CursorVisible = $false
    $prevRenderedLines = 0

    try {
        while ($true) {
            $sb = [System.Text.StringBuilder]::new()

            [void]$sb.AppendLine("")
            if ($Title) {
                [void]$sb.AppendLine("$($c.Primary)  $Title$($c.Reset)")
                [void]$sb.AppendLine("$($c.PrimaryMuted)  $('-' * $Title.Length)$($c.Reset)")
            }
            [void]$sb.AppendLine("")

            for ($i = 0; $i -lt $optionCount; $i++) {
                $opt = $Options[$i]
                $isSelected = ($i -eq $selectedIndex)
                $baseColorCode = if ($opt.Color -and $colorMap[$opt.Color]) { $colorMap[$opt.Color] } else { $c.Text }

                if ($isSelected) {
                    [void]$sb.AppendLine("$($c.Primary)  $selector $($c.Reset)$($c.Selected)$($opt.Label)$($c.Reset)")
                    if ($opt.Description) {
                        [void]$sb.AppendLine("      $($c.Dim)$($opt.Description)$($c.Reset)")
                    }
                }
                else {
                    [void]$sb.AppendLine("    ${baseColorCode}$($opt.Label)$($c.Reset)")
                }
            }

            [void]$sb.AppendLine("")
            $cancelText = if ($AllowCancel) { ", Esc=cancel" } else { "" }
            [void]$sb.AppendLine("$($c.Warning)  [Up/Down]$($c.Dim) navigate  $($c.Success)[Enter]$($c.Dim) select$cancelText$($c.Reset)")

            if ($NoClear) {
                $esc = [char]27
                if ($prevRenderedLines -gt 0) {
                    [Console]::Write("$esc[$($prevRenderedLines)A$esc[J")
                }
                $text = $sb.ToString()
                [Console]::Write($text)
                $prevRenderedLines = ($text -split "`r?`n").Count
            }
            else {
                Clear-Host
                [Console]::Write($sb.ToString())
            }

            $key = [Console]::ReadKey($true)

            switch ($key.Key) {
                'UpArrow' {
                    if ($selectedIndex -gt 0) { $selectedIndex-- }
                    else { $selectedIndex = $optionCount - 1 }
                }
                'DownArrow' {
                    if ($selectedIndex -lt $optionCount - 1) { $selectedIndex++ }
                    else { $selectedIndex = 0 }
                }
                'Enter' {
                    if (-not $NoClear) { Clear-Host }
                    return $Options[$selectedIndex].Id
                }
                'Escape' {
                    if ($AllowCancel) {
                        if (-not $NoClear) { Clear-Host }
                        return $null
                    }
                }
            }
        }
    }
    finally {
        [Console]::CursorVisible = $true
    }
}

function Write-HelpMenu {
    <#
    .SYNOPSIS
        Renders a standardized help menu with customizable colors.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,
        [Parameter(Mandatory = $true)]
        [array]$Commands,
        [array]$Sections = @(),
        [hashtable]$Colors = @{}
    )

    $palette = @{
        Title       = 'Cyan'
        TitleLine   = 'DarkCyan'
        CmdName     = 'Yellow'
        Alias       = 'DarkYellow'
        Params      = 'Gray'
        Desc        = 'DarkGray'
        Section     = 'Cyan'
        SectionLine = 'DarkCyan'
        Label       = 'DarkGray'
        Value       = 'White'
        Code        = 'Gray'
        Comment     = 'DarkGray'
        Accent      = 'Green'
    }
    foreach ($key in $Colors.Keys) {
        $palette[$key] = $Colors[$key]
    }

    Write-Host ""
    Write-Host ("  {0}" -f $Title) -ForegroundColor $palette.Title
    Write-Host ("  {0}" -f ('=' * $Title.Length)) -ForegroundColor $palette.TitleLine
    Write-Host ""

    foreach ($cmd in $Commands) {
        Write-Host "  " -NoNewline
        Write-Host $cmd.Name -ForegroundColor $palette.CmdName -NoNewline
        if ($cmd.Alias) {
            Write-Host (" ({0})" -f $cmd.Alias) -ForegroundColor $palette.Alias -NoNewline
        }
        if ($cmd.Params) {
            Write-Host (" {0}" -f $cmd.Params) -ForegroundColor $palette.Params
        }
        else {
            Write-Host ""
        }
        if ($cmd.Desc) {
            Write-Host ("      {0}" -f $cmd.Desc) -ForegroundColor $palette.Desc
        }
        Write-Host ""
    }

    foreach ($section in $Sections) {
        if ($section.Title) {
            Write-Host ("  {0}" -f $section.Title) -ForegroundColor $palette.Section
            $underline = if ($section.Underline) { $section.Underline } else { ('-' * $section.Title.Length) }
            Write-Host ("  {0}" -f $underline) -ForegroundColor $palette.SectionLine
            Write-Host ""
        }

        foreach ($line in $section.Lines) {
            if ($line -is [string]) {
                Write-Host $line -ForegroundColor $palette.Label
                continue
            }

            if ($line.Type -eq 'text') {
                $labelColor = if ($line.LabelColor) { $line.LabelColor } else { $palette.Label }
                $valueColor = if ($line.ValueColor) { $line.ValueColor } else { $palette.Value }
                Write-Host ("  {0}" -f $line.Label) -ForegroundColor $labelColor -NoNewline
                if ($line.Value) {
                    Write-Host $line.Value -ForegroundColor $valueColor
                }
                else {
                    Write-Host ""
                }
                continue
            }

            if ($line.Type -eq 'example') {
                $codeColor = if ($line.CodeColor) { $line.CodeColor } else { $palette.Code }
                $commentColor = if ($line.CommentColor) { $line.CommentColor } else { $palette.Comment }
                Write-Host ("    {0}" -f $line.Code) -ForegroundColor $codeColor -NoNewline
                if ($line.Comment) {
                    Write-Host $line.Comment -ForegroundColor $commentColor
                }
                else {
                    Write-Host ""
                }
                continue
            }

            if ($line.Type -eq 'raw') {
                $rawColor = if ($line.Color) { $line.Color } else { $palette.Label }
                Write-Host $line.Text -ForegroundColor $rawColor
            }
        }
        Write-Host ""
    }
}

function Get-TimerSemanticPaletteSlots {
    return @('Primary', 'PrimaryMuted', 'Text', 'Muted', 'Success', 'Warning', 'Danger', 'Accent', 'Selected')
}

function Get-TimerNamedColorSgrMap {
    return @{
        black         = 30
        red           = 31
        green         = 32
        yellow        = 33
        blue          = 34
        magenta       = 35
        cyan          = 36
        white         = 37
        gray          = 90
        darkgray      = 90
        brightblack   = 90
        brightred     = 91
        brightgreen   = 92
        brightyellow  = 93
        brightblue    = 94
        brightmagenta = 95
        brightcyan    = 96
        brightwhite   = 97
    }
}

function Get-TimerNamedColorBackgroundSgrMap {
    return @{
        black         = 40
        red           = 41
        green         = 42
        yellow        = 43
        blue          = 44
        magenta       = 45
        cyan          = 46
        white         = 47
        gray          = 100
        darkgray      = 100
        brightblack   = 100
        brightred     = 41
        brightgreen   = 42
        brightyellow  = 43
        brightblue    = 44
        brightmagenta = 45
        brightcyan    = 46
        brightwhite   = 47
    }
}

function Get-DefaultTimerPalettes {
    <#
    .SYNOPSIS
        Built-in palette definitions when Config.Palettes is missing (legacy config.ps1).
    #>
    return @{
        default = @{
            Description  = 'Balanced colors for everyday use'
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
        minimal = @{
            Description  = 'Low-contrast gray palette for busy or dim screens'
            Primary      = 'darkgray'
            PrimaryMuted = 'darkgray'
            Text         = 'white'
            Muted        = 'darkgray'
            Success      = 'white'
            Warning      = 'darkgray'
            Danger       = 'darkgray'
            Accent       = 'darkgray'
            Selected     = 'darkgray'
        }
        vibrant = @{
            Description  = 'Bright colors for high-contrast displays'
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
        monochrome = @{
            Description  = 'White and gray only — no hue'
            Primary      = 'white'
            PrimaryMuted = 'darkgray'
            Text         = 'brightwhite'
            Muted        = 'darkgray'
            Success      = 'white'
            Warning      = 'darkgray'
            Danger       = 'white'
            Accent       = 'darkgray'
            Selected     = 'darkgray'
        }
    }
}

function ConvertTo-TimerAnsiForeground {
    param(
        [char]$Esc,
        [string]$ColorName
    )

    if ([string]::IsNullOrWhiteSpace($ColorName)) { return '' }

    $normalized = $ColorName.Trim().ToLower() -replace '\s+', ''
    if ($normalized.StartsWith($Esc)) { return $ColorName }

    $map = Get-TimerNamedColorSgrMap
    if (-not $map.ContainsKey($normalized)) { return $ColorName }

    return "$Esc[$($map[$normalized])m"
}

function ConvertTo-TimerAnsiSelected {
    param(
        [char]$Esc,
        [string]$ColorName
    )

    if ([string]::IsNullOrWhiteSpace($ColorName)) { return '' }

    $normalized = $ColorName.Trim().ToLower() -replace '\s+', ''
    $bgMap = Get-TimerNamedColorBackgroundSgrMap
    if (-not $bgMap.ContainsKey($normalized)) { return ConvertTo-TimerAnsiForeground -Esc $Esc -ColorName $ColorName }

    return "$Esc[30;$($bgMap[$normalized])m"
}

function Test-TimerNamedColor {
    param([string]$ColorName)

    if ([string]::IsNullOrWhiteSpace($ColorName)) { return $false }
    $normalized = $ColorName.Trim().ToLower() -replace '\s+', ''
    return (Get-TimerNamedColorSgrMap).ContainsKey($normalized)
}

function Resolve-TimerPaletteColors {
    <#
    .SYNOPSIS
        Converts a Config.Palettes entry (semantic roles + named colors) to ANSI escape strings.
    #>
    param([hashtable]$PaletteEntry)

    $esc = [char]27
    $resolved = @{}
    foreach ($slot in (Get-TimerSemanticPaletteSlots)) {
        if ($slot -eq 'Selected') {
            $resolved[$slot] = ConvertTo-TimerAnsiSelected -Esc $esc -ColorName $PaletteEntry[$slot]
        }
        else {
            $resolved[$slot] = ConvertTo-TimerAnsiForeground -Esc $esc -ColorName $PaletteEntry[$slot]
        }
    }
    return $resolved
}

$script:PS1TimerModuleConfig = @{
    TimerDefaults   = @{}
    Webhooks        = @{}
    Sounds          = @{}
    Palettes        = $null
    VoiceTemplates  = $null
    Workouts        = $null
}
# Resolved ANSI palette cache — watch loops resolve colors every second per row
$script:TimerAnsiColorsCache = $null
$script:TimerAnsiColorsCacheTheme = $null
$script:TimerAnsiColorsCachePalettes = $null

function Clear-TimerAnsiColorsCache {
    $script:TimerAnsiColorsCache = $null
    $script:TimerAnsiColorsCacheTheme = $null
    $script:TimerAnsiColorsCachePalettes = $null
}

function Initialize-PS1TimerModuleConfig {
    <#
    .SYNOPSIS
        Snapshots timer config at module import so other toolkits cannot overwrite Webhooks via $global:Config.
    #>
    $script:PS1TimerModuleConfig = @{
        TimerDefaults  = @{}
        Webhooks       = @{}
        Sounds         = @{}
        Palettes       = $null
        VoiceTemplates = $null
        Workouts       = $null
    }
    Clear-TimerAnsiColorsCache

    if (-not $global:Config) { return }

    if ($global:Config.TimerDefaults) {
        foreach ($key in $global:Config.TimerDefaults.Keys) {
            $script:PS1TimerModuleConfig.TimerDefaults[$key] = $global:Config.TimerDefaults[$key]
        }
    }
    if ($global:Config.Webhooks) {
        foreach ($key in $global:Config.Webhooks.Keys) {
            $script:PS1TimerModuleConfig.Webhooks[$key] = $global:Config.Webhooks[$key]
        }
    }
    if ($global:Config.Sounds) {
        foreach ($key in $global:Config.Sounds.Keys) {
            $script:PS1TimerModuleConfig.Sounds[$key] = $global:Config.Sounds[$key]
        }
    }
    if ($global:Config.Palettes) {
        $script:PS1TimerModuleConfig.Palettes = $global:Config.Palettes
    }
    if ($global:Config.VoiceTemplates) {
        $script:PS1TimerModuleConfig.VoiceTemplates = $global:Config.VoiceTemplates
    }
    if ($global:Config.Workouts) {
        $script:PS1TimerModuleConfig.Workouts = $global:Config.Workouts
    }
}

function Get-PS1TimerModuleTimerDefaults {
    if ($script:PS1TimerModuleConfig.TimerDefaults.Count -gt 0) {
        return $script:PS1TimerModuleConfig.TimerDefaults
    }
    if ($global:Config -and $global:Config.TimerDefaults) {
        return $global:Config.TimerDefaults
    }
    return @{}
}

function Get-PS1TimerModuleWebhooks {
    if ($script:PS1TimerModuleConfig.Webhooks.Count -gt 0) {
        return $script:PS1TimerModuleConfig.Webhooks
    }
    if ($global:Config -and $global:Config.Webhooks) {
        return $global:Config.Webhooks
    }
    return @{}
}

function Get-PS1TimerModuleSounds {
    if ($script:PS1TimerModuleConfig.Sounds.Count -gt 0) {
        return $script:PS1TimerModuleConfig.Sounds
    }
    if ($global:Config -and $global:Config.Sounds) {
        return $global:Config.Sounds
    }
    return @{}
}

function Get-PS1TimerModulePalettes {
    if ($script:PS1TimerModuleConfig.Palettes) {
        return $script:PS1TimerModuleConfig.Palettes
    }
    if ($global:Config -and $global:Config.Palettes) {
        return $global:Config.Palettes
    }
    return $null
}

function Get-PS1TimerModuleVoiceTemplates {
    if ($script:PS1TimerModuleConfig.VoiceTemplates) {
        return $script:PS1TimerModuleConfig.VoiceTemplates
    }
    if ($global:Config -and $global:Config.VoiceTemplates) {
        return $global:Config.VoiceTemplates
    }
    return Get-DefaultTimerVoiceTemplates
}

function Get-PS1TimerModuleWorkouts {
    if ($script:PS1TimerModuleConfig.Workouts) {
        return $script:PS1TimerModuleConfig.Workouts
    }
    if ($global:Config -and $global:Config.Workouts) {
        return $global:Config.Workouts
    }
    return @{}
}

function ConvertFrom-LegacyNotifyMode {
    <#
    .SYNOPSIS
        Maps legacy Notify enum to composable Visual/Sound channels.
    #>
    param([string]$Notify)

    switch ($Notify.ToLower()) {
        'toast'   { return @{ Visual = 'toast'; Sound = $true } }
        'sound'   { return @{ Visual = 'none'; Sound = $true } }
        'silent'  { return @{ Visual = 'none'; Sound = $false } }
        'webhook' { return @{ Visual = 'none'; Sound = $false } }
        default   { return @{ Visual = 'popup'; Sound = $true } }
    }
}

function Get-TimerModuleNotifyFallback {
    <#
    .SYNOPSIS
        Reads module TimerDefaults notify channels without calling Get-TimerNotificationConfig.
    #>
    $config = Get-PS1TimerModuleTimerDefaults
    if (-not $config -or $config.Count -eq 0) {
        return @{ Visual = 'popup'; Sound = $true; Voice = $false }
    }

    $hasVisual = $config.ContainsKey('Visual') -and -not [string]::IsNullOrWhiteSpace([string]$config.Visual)
    $hasSound = $config.ContainsKey('Sound')
    $hasVoice = $config.ContainsKey('Voice')

    if ($hasVisual -or $hasSound -or $hasVoice) {
        return @{
            Visual = if ($hasVisual) { "$($config.Visual)".ToLower() } else { 'popup' }
            Sound  = if ($hasSound) { [bool]$config.Sound } else { $true }
            Voice  = if ($hasVoice) { [bool]$config.Voice } else { $false }
        }
    }

    if ($config.Notify) {
        $legacy = ConvertFrom-LegacyNotifyMode -Notify $config.Notify
        return @{ Visual = $legacy.Visual; Sound = $legacy.Sound; Voice = $false }
    }

    return @{ Visual = 'popup'; Sound = $true; Voice = $false }
}

function Get-TimerNotifyChannelsFromSource {
    <#
    .SYNOPSIS
        Reads Visual/Sound/Voice from a config or preset hashtable, with legacy Notify fallback.
    #>
    param([hashtable]$Source)

    $defaults = Get-TimerModuleNotifyFallback

    if (-not $Source) {
        return $defaults
    }

    $hasVisual = $Source.ContainsKey('Visual') -and -not [string]::IsNullOrWhiteSpace([string]$Source.Visual)
    $hasSound = $Source.ContainsKey('Sound')
    $hasVoice = $Source.ContainsKey('Voice')

    if ($hasVisual -or $hasSound -or $hasVoice) {
        $visual = if ($hasVisual) { "$($Source.Visual)".ToLower() } else { $defaults.Visual }
        $sound = if ($hasSound) { [bool]$Source.Sound } else { $defaults.Sound }
        $voice = if ($hasVoice) { [bool]$Source.Voice } else { $defaults.Voice }
        return @{ Visual = $visual; Sound = $sound; Voice = $voice }
    }

    if ($Source.Notify) {
        $legacy = ConvertFrom-LegacyNotifyMode -Notify $Source.Notify
        return @{ Visual = $legacy.Visual; Sound = $legacy.Sound; Voice = $false }
    }

    return $defaults
}

function Get-TimerNotifyChannelsFromTimer {
    <#
    .SYNOPSIS
        Resolves Visual/Sound/Voice from a timer object (new fields or legacy NotifyType).
    #>
    param([PSCustomObject]$Timer)

    $defaults = Get-TimerModuleNotifyFallback
    $props = $Timer.PSObject.Properties

    if ($null -ne $props['NotifyVisual']) {
        $visual = if (-not [string]::IsNullOrWhiteSpace([string]$Timer.NotifyVisual)) {
            "$($Timer.NotifyVisual)".ToLower()
        } else {
            $defaults.Visual
        }
        $sound = if ($null -ne $props['NotifySound']) { [bool]$Timer.NotifySound } else { $defaults.Sound }
        $voice = if ($null -ne $props['NotifyVoice']) { [bool]$Timer.NotifyVoice } else { $defaults.Voice }
        return @{ Visual = $visual; Sound = $sound; Voice = $voice }
    }

    if ($null -ne $props['NotifyType'] -and $Timer.NotifyType) {
        $legacy = ConvertFrom-LegacyNotifyMode -Notify $Timer.NotifyType
        return @{ Visual = $legacy.Visual; Sound = $legacy.Sound; Voice = $false }
    }

    return $defaults
}

function Get-TimerFireScriptPreserveNotifyFieldsBlock {
    <#
    .SYNOPSIS
        PowerShell snippet embedded in simple repeat fire scripts to keep notify settings in JSON.
        Inserted via $(...) into the fire-script here-string; do not backtick-escape variables here.
    #>
    return @'
                $notifyProps = @('NotifyVisual', 'NotifySound', 'NotifyVoice', 'NotifyType', 'WebhookName', 'VoiceName', 'VoiceRate', 'VoiceVolume', 'CountdownMode')
                foreach ($np in $notifyProps) {
                    if ($timer.PSObject.Properties.Name -contains $np -and $null -ne $timer.$np) {
                        $updatedTimer | Add-Member -NotePropertyName $np -NotePropertyValue $timer.$np -Force
                    }
                }
                if ($timer.PSObject.Properties.Name -contains 'BeepAt' -and $timer.BeepAt) {
                    $updatedTimer | Add-Member -NotePropertyName 'BeepAt' -NotePropertyValue @($timer.BeepAt) -Force
                }
'@
}

function Format-TimerNotifyLabel {
    <#
    .SYNOPSIS
        Builds a human-readable notify summary for confirmation output.
    #>
    param(
        [string]$Visual,
        [bool]$Sound,
        [string]$WebhookName = $null,
        [bool]$Voice = $false,
        [string]$CountdownMode = $null,
        [array]$BeepAt = $null
    )

    $parts = @()
    if ($Visual -and $Visual -ne 'none') { $parts += $Visual }
    if ($Sound) { $parts += 'sound' }
    if ($Voice) { $parts += 'voice' }
    if (-not [string]::IsNullOrWhiteSpace($WebhookName)) { $parts += "webhook ($WebhookName)" }
    if ($CountdownMode -and $CountdownMode -ne 'none') { $parts += "countdown ($CountdownMode)" }
    if ($BeepAt -and @($BeepAt).Count -gt 0) {
        $parts += "beep at $(@($BeepAt) -join ',')"
    }
    if ($parts.Count -eq 0) { return 'silent' }
    return ($parts -join ' + ')
}

function Parse-BeepAtList {
    <#
    .SYNOPSIS
        Parses -BeepAt values into seconds-before-end offsets (descending, unique).
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()]$InputObject
    )

    if ($null -eq $InputObject) { return @() }

    $items = [System.Collections.Generic.List[string]]::new()
    if ($InputObject -is [string]) {
        foreach ($part in ($InputObject -split ',')) {
            $trimmed = $part.Trim()
            if ($trimmed) { [void]$items.Add($trimmed) }
        }
    }
    elseif ($InputObject -is [array]) {
        foreach ($part in $InputObject) {
            $trimmed = [string]$part
            if ($trimmed) { [void]$items.Add($trimmed) }
        }
    }
    else {
        $trimmed = [string]$InputObject
        if ($trimmed) { [void]$items.Add($trimmed) }
    }

    $seconds = [System.Collections.Generic.List[int]]::new()
    foreach ($item in $items) {
        $value = ConvertTo-Seconds -Time $item
        if ($value -gt 0) {
            [void]$seconds.Add([int]$value)
        }
    }

    return @($seconds | Sort-Object -Descending -Unique)
}

function Test-PS1TimerTestMode {
    <#
    .SYNOPSIS
        True when Pester or automation runs PS1Timer tests (suppresses UI/TTS/watch).
    #>
    return [bool]$script:PS1TimerTestMode -or $env:PS1TIMER_TEST -eq '1'
}

function Get-TimerTestScriptGuard {
    <#
    .SYNOPSIS
        Prepended to generated fire/cue scripts during tests so accidental task runs exit silently.
    #>
    if (-not (Test-PS1TimerTestMode)) { return '' }
    return "exit  # PS1Timer: test-mode fire script`r`n"
}

function Assert-TimerConfig {
    <#
    .SYNOPSIS
        Validates $global:Config after load; warns on invalid values without throwing.
    #>
    if (-not $global:Config) { return }

    $validNotify = @('popup', 'toast', 'sound', 'silent', 'webhook')
    $validVisual = @('popup', 'toast', 'none')
    $validAfterStart = @('none', 'watch', 'list')
    $paletteSource = if ($global:Config.Palettes) { $global:Config.Palettes } else { Get-DefaultTimerPalettes }
    $validThemes = @($paletteSource.Keys | ForEach-Object { "$_".ToLower() }) | Select-Object -Unique
    $requiredPaletteSlots = Get-TimerSemanticPaletteSlots

    if ($global:Config.TimerDefaults) {
        $td = $global:Config.TimerDefaults

        if ($td.Notify -and ($validNotify -notcontains $td.Notify.ToLower())) {
            Write-Warning "PS1Timer: TimerDefaults.Notify '$($td.Notify)' is invalid. Use: $($validNotify -join ', ')"
        }
        elseif ($td.Notify) {
            Write-Warning 'PS1Timer: TimerDefaults.Notify is deprecated. Use Visual, Sound, and Webhook instead.'
        }

        if ($td.Visual -and ($validVisual -notcontains $td.Visual.ToLower())) {
            Write-Warning "PS1Timer: TimerDefaults.Visual '$($td.Visual)' is invalid. Use: $($validVisual -join ', ')"
        }

        if ($td.AfterStart -and ($validAfterStart -notcontains $td.AfterStart)) {
            Write-Warning "PS1Timer: TimerDefaults.AfterStart '$($td.AfterStart)' is invalid. Use: $($validAfterStart -join ', ')"
        }

        if ($td.Theme -and ($validThemes -notcontains $td.Theme.ToLower())) {
            Write-Warning "PS1Timer: TimerDefaults.Theme '$($td.Theme)' not found in Config.Palettes. Available: $($validThemes -join ', ')"
        }

        if ($td.Notify -eq 'webhook' -or $td.Webhook) {
            $name = $td.Webhook
            if ([string]::IsNullOrWhiteSpace($name)) {
                if ($td.Notify -eq 'webhook') {
                    Write-Warning 'PS1Timer: TimerDefaults.Notify is webhook but TimerDefaults.Webhook name is not set.'
                }
            }
            elseif (-not (Resolve-TimerWebhookUrl -Name $name)) {
                Write-Warning "PS1Timer: Webhook '$name' not found in Config.Webhooks."
            }
        }

        if ($td.SoundFile) {
            $resolvedSound = Resolve-TimerSoundFilePath -Name $td.SoundFile
            if (-not $resolvedSound) {
                Write-Warning "PS1Timer: SoundFile '$($td.SoundFile)' not found in Config.Sounds and is not a valid path."
            }
            elseif (-not (Test-Path -LiteralPath $resolvedSound)) {
                Write-Warning "PS1Timer: SoundFile resolved path not found: $resolvedSound"
            }
        }

        if ($td.VoiceRate -ne $null) {
            $rate = [int]$td.VoiceRate
            if ($rate -lt -10 -or $rate -gt 10) {
                Write-Warning "PS1Timer: TimerDefaults.VoiceRate must be between -10 and 10."
            }
        }

        if ($td.VoiceVolume -ne $null) {
            $vol = [int]$td.VoiceVolume
            if ($vol -lt 0 -or $vol -gt 100) {
                Write-Warning "PS1Timer: TimerDefaults.VoiceVolume must be between 0 and 100."
            }
        }

        $validCountdown = @('none', '321', '10', 'both')
        if ($td.Countdown -and ($validCountdown -notcontains $td.Countdown.ToLower())) {
            Write-Warning "PS1Timer: TimerDefaults.Countdown '$($td.Countdown)' is invalid. Use: $($validCountdown -join ', ')"
        }
    }

    $sounds = Get-PS1TimerModuleSounds
    if ($sounds) {
        foreach ($key in $sounds.Keys) {
            $path = $sounds[$key]
            if ([string]::IsNullOrWhiteSpace($path)) {
                Write-Warning "PS1Timer: Sounds['$key'] is empty."
                continue
            }
            if (-not (Test-Path -LiteralPath $path)) {
                Write-Warning "PS1Timer: Sounds['$key'] path not found: $path"
            }
        }
    }

    if ($global:Config.Webhooks) {
        foreach ($key in $global:Config.Webhooks.Keys) {
            $url = $global:Config.Webhooks[$key]
            if ([string]::IsNullOrWhiteSpace($url)) {
                Write-Warning "PS1Timer: Webhooks['$key'] is empty."
                continue
            }
            $uri = $null
            if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri)) {
                Write-Warning "PS1Timer: Webhooks['$key'] is not a valid URL."
            }
        }
    }

    if (-not $global:Config.Palettes) {
        Write-Warning 'PS1Timer: Config.Palettes is missing. Copy the Palettes block from config.example.ps1. Using built-in defaults.'
    }
    elseif ($global:Config.Palettes) {
        foreach ($paletteName in $global:Config.Palettes.Keys) {
            $palette = $global:Config.Palettes[$paletteName]
            foreach ($slot in $requiredPaletteSlots) {
                if (-not $palette.ContainsKey($slot) -or $null -eq $palette[$slot]) {
                    Write-Warning "PS1Timer: Palettes['$paletteName'] is missing required role '$slot'."
                    continue
                }
                if (-not (Test-TimerNamedColor -ColorName $palette[$slot])) {
                    Write-Warning "PS1Timer: Palettes['$paletteName'].$slot '$($palette[$slot])' is not a recognized color name."
                }
            }
        }
    }

    if ($global:Config.Presets) {
        foreach ($presetName in $global:Config.Presets.Keys) {
            $preset = $global:Config.Presets[$presetName]
            if ($preset.Notify -and ($validNotify -notcontains $preset.Notify.ToLower())) {
                Write-Warning "PS1Timer: Presets['$presetName'].Notify '$($preset.Notify)' is invalid."
            }
            if ($preset.Visual -and ($validVisual -notcontains $preset.Visual.ToLower())) {
                Write-Warning "PS1Timer: Presets['$presetName'].Visual '$($preset.Visual)' is invalid."
            }
            if ($preset.Webhook -and -not (Resolve-TimerWebhookUrl -Name $preset.Webhook)) {
                Write-Warning "PS1Timer: Presets['$presetName'].Webhook '$($preset.Webhook)' not found in Config.Webhooks."
            }
            if ($preset.Countdown) {
                $validCountdown = @('none', '321', '10', 'both')
                if ($validCountdown -notcontains $preset.Countdown.ToLower()) {
                    Write-Warning "PS1Timer: Presets['$presetName'].Countdown '$($preset.Countdown)' is invalid."
                }
            }
        }
    }

    if ($global:Config.Workouts) {
        foreach ($workoutName in $global:Config.Workouts.Keys) {
            $workout = $global:Config.Workouts[$workoutName]
            if ($workout.Countdown) {
                $validCountdown = @('none', '321', '10', 'both')
                if ($validCountdown -notcontains $workout.Countdown.ToLower()) {
                    Write-Warning "PS1Timer: Workouts['$workoutName'].Countdown '$($workout.Countdown)' is invalid."
                }
            }
        }
    }
}

function Resolve-TimerWebhookUrl {
    <#
    .SYNOPSIS
        Resolves a named webhook from Config.Webhooks to its URL.
    #>
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $webhooks = Get-PS1TimerModuleWebhooks
    if (-not $webhooks -or $webhooks.Count -eq 0) { return $null }
    if ($webhooks.ContainsKey($Name)) {
        return [string]$webhooks[$Name]
    }

    return $null
}

function Resolve-TimerSoundFilePath {
    <#
    .SYNOPSIS
        Resolves a named sound from Config.Sounds to a .wav path, or returns an existing file path.
    #>
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }

    $sounds = Get-PS1TimerModuleSounds
    if ($sounds -and $sounds.ContainsKey($Name)) {
        return [string]$sounds[$Name]
    }

    if (Test-Path -LiteralPath $Name) {
        return $Name
    }

    return $null
}

function Get-DefaultTimerVoiceTemplates {
    return @{
        PhaseStart      = '{label}'
        PhaseEnd        = '{next}'
        WorkoutStart    = 'Starting {description}. {duration}, {phaseCount} phases. Ends at {endTime}.'
        WorkoutComplete = 'Workout complete. Well done.'
        CountdownTick   = '{seconds}'
        CountdownGo     = 'Go'
        RoundComplete   = 'Round {round} complete'
    }
}

function Get-TimerVoiceConfig {
    $defaults = Get-PS1TimerModuleTimerDefaults
    return @{
        Voice       = if ($defaults.ContainsKey('Voice')) { [bool]$defaults.Voice } else { $false }
        VoiceRate   = if ($defaults.VoiceRate -ne $null) { [int]$defaults.VoiceRate } else { 0 }
        VoiceName   = if ($defaults.VoiceName) { [string]$defaults.VoiceName } else { $null }
        VoiceVolume = if ($defaults.VoiceVolume -ne $null) { [int]$defaults.VoiceVolume } else { 100 }
        Countdown   = if ($defaults.Countdown) { [string]$defaults.Countdown } else { 'none' }
    }
}

function Get-TimerInstalledVoices {
    try {
        Add-Type -AssemblyName System.Speech
        $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $voices = @($synth.GetInstalledVoices() | ForEach-Object { $_.VoiceInfo.Name })
        $synth.Dispose()
        return $voices
    }
    catch {
        Write-Warning "PS1Timer: Could not list installed voices: $($_.Exception.Message)"
        return @()
    }
}

function Resolve-TimerSpeechText {
    <#
    .SYNOPSIS
        Applies voice templates and token substitution for spoken announcements.
    #>
    param(
        [ValidateSet('PhaseStart', 'PhaseEnd', 'WorkoutStart', 'WorkoutComplete', 'CountdownTick', 'CountdownGo', 'RoundComplete')]
        [string]$TemplateKey,
        [hashtable]$Tokens = @{}
    )

    $templates = Get-PS1TimerModuleVoiceTemplates
    $template = if ($templates -and $templates.ContainsKey($TemplateKey)) {
        [string]$templates[$TemplateKey]
    }
    else {
        (Get-DefaultTimerVoiceTemplates)[$TemplateKey]
    }

    if ([string]::IsNullOrWhiteSpace($template)) { return '' }

    $result = $template
    foreach ($key in $Tokens.Keys) {
        $value = if ($null -eq $Tokens[$key]) { '' } else { [string]$Tokens[$key] }
        $result = $result -replace [regex]::Escape("{$key}"), $value
    }
    $result = $result -replace '\{[a-zA-Z]+\}', ''
    return $result.Trim()
}

function Get-TimerPhaseCueSchedule {
    <#
    .SYNOPSIS
        Builds phase cue offsets (seconds before phase end) for voice and beep cues.
    #>
    param(
        [Parameter(Mandatory)][int]$PhaseSeconds,
        [ValidateSet('none', '321', '10', 'both')]
        [string]$CountdownMode = 'none',
        [string]$PhaseStartText = $null,
        [switch]$IncludePhaseStartAtZero,
        [int[]]$BeepAtSeconds = @(),
        [switch]$IncludeEndBeep321
    )

    $cues = [System.Collections.Generic.List[object]]::new()
    $beepOffsets = [System.Collections.Generic.HashSet[int]]::new()

    if ($PhaseSeconds -le 0) {
        return @()
    }

    if ($IncludePhaseStartAtZero -and -not [string]::IsNullOrWhiteSpace($PhaseStartText)) {
        $cues.Add([PSCustomObject]@{
            OffsetFromEnd = $PhaseSeconds
            Text          = $PhaseStartText
            CueType       = 'start'
        })
    }

    if ($CountdownMode -ne 'none') {
        $modes = if ($CountdownMode -eq 'both') { @('10', '321') } else { @($CountdownMode) }
        foreach ($mode in $modes) {
            if ($mode -eq '10' -and $PhaseSeconds -ge 10) {
                $cues.Add([PSCustomObject]@{
                    OffsetFromEnd = 10
                    Text          = Resolve-TimerSpeechText -TemplateKey 'CountdownTick' -Tokens @{ seconds = '10' }
                    CueType       = 'countdown'
                })
            }
            if ($mode -eq '321') {
                $maxTick = [Math]::Min(3, $PhaseSeconds)
                for ($i = $maxTick; $i -ge 1; $i--) {
                    $cues.Add([PSCustomObject]@{
                        OffsetFromEnd = $i
                        Text          = Resolve-TimerSpeechText -TemplateKey 'CountdownTick' -Tokens @{ seconds = [string]$i }
                        CueType       = 'countdown'
                    })
                }
            }
        }
    }

    foreach ($offset in @($BeepAtSeconds)) {
        if ($offset -gt 0 -and $offset -le $PhaseSeconds) {
            [void]$beepOffsets.Add([int]$offset)
        }
    }

    if ($IncludeEndBeep321) {
        $maxTick = [Math]::Min(3, $PhaseSeconds)
        for ($i = $maxTick; $i -ge 1; $i--) {
            [void]$beepOffsets.Add($i)
        }
    }

    foreach ($offset in ($beepOffsets | Sort-Object -Descending)) {
        $cues.Add([PSCustomObject]@{
            OffsetFromEnd = $offset
            Text          = $null
            CueType       = 'beep'
        })
    }

    return @($cues | Sort-Object -Property OffsetFromEnd -Descending)
}

function ConvertFrom-WorkoutRoutine {
    <#
    .SYNOPSIS
        Expands a named workout routine into flat sequence phases with coaching metadata.
    #>
    param(
        [Parameter(Mandatory)][string]$RoutineName,
        [string]$CountdownMode = $null
    )

    $workouts = Get-PS1TimerModuleWorkouts
    if (-not $workouts -or -not $workouts.ContainsKey($RoutineName)) {
        throw "Workout routine '$RoutineName' not found in Config.Workouts."
    }

    $routine = $workouts[$RoutineName]
    $countdown = if ($CountdownMode) { $CountdownMode } elseif ($routine.Countdown) { [string]$routine.Countdown } else { (Get-TimerVoiceConfig).Countdown }

    if ($routine.Pattern) {
        $phases = @(ConvertFrom-TimerSequence -Pattern $routine.Pattern)
        foreach ($p in $phases) {
            $p | Add-Member -NotePropertyName 'Countdown' -NotePropertyValue $countdown -Force
            if (-not $p.AnnounceStart) {
                $p | Add-Member -NotePropertyName 'AnnounceStart' -NotePropertyValue $p.Label -Force
            }
        }
        return $phases
    }

    $phases = [System.Collections.Generic.List[object]]::new()

    if ($routine.Warmup) {
        $warmupPhases = @(ConvertFrom-TimerSequence -Pattern $routine.Warmup)
        foreach ($p in $warmupPhases) {
            $p | Add-Member -NotePropertyName 'PhaseType' -NotePropertyValue 'warmup' -Force
            $p | Add-Member -NotePropertyName 'Countdown' -NotePropertyValue 'none' -Force
            $p | Add-Member -NotePropertyName 'AnnounceStart' -NotePropertyValue $p.Label -Force
            $phases.Add($p)
        }
    }

    $exercises = @($routine.Exercises)
    for ($exIdx = 0; $exIdx -lt $exercises.Count; $exIdx++) {
        $ex = $exercises[$exIdx]
        $name = [string]$ex.Name
        $sets = if ($ex.Sets) { [int]$ex.Sets } else { 1 }
        $workDur = if ($ex.Work) { [string]$ex.Work } else { '45s' }
        $restDur = if ($ex.Rest) { [string]$ex.Rest } else { '60s' }
        $workSeconds = ConvertTo-Seconds -Time $workDur
        $restSeconds = ConvertTo-Seconds -Time $restDur

        for ($setNum = 1; $setNum -le $sets; $setNum++) {
            $workLabel = if ($sets -gt 1) { "$name, set $setNum" } else { $name }
            $phases.Add([PSCustomObject]@{
                Seconds       = $workSeconds
                Label         = $workLabel
                Duration      = $workDur
                LoopId        = "ex$($exIdx + 1)"
                LoopIteration = $setNum
                LoopTotal     = $sets
                PhaseType     = 'work'
                ExerciseName  = $name
                SetNumber     = $setNum
                SetTotal      = $sets
                Countdown     = $countdown
                AnnounceStart = $workLabel
                AnnounceEnd   = 'Rest'
            })
            if ($setNum -lt $sets -or $exIdx -lt ($exercises.Count - 1)) {
                $phases.Add([PSCustomObject]@{
                    Seconds       = $restSeconds
                    Label         = 'rest'
                    Duration      = $restDur
                    LoopId        = "ex$($exIdx + 1)"
                    LoopIteration = $setNum
                    LoopTotal     = $sets
                    PhaseType     = 'rest'
                    ExerciseName  = $name
                    SetNumber     = $setNum
                    SetTotal      = $sets
                    Countdown     = 'none'
                    AnnounceStart = 'Rest'
                    AnnounceEnd   = if ($setNum -lt $sets) { "$name, set $($setNum + 1)" } else { $name }
                })
            }
        }

        if ($routine.BetweenExercises -and $exIdx -lt ($exercises.Count - 1)) {
            $betweenSeconds = ConvertTo-Seconds -Time $routine.BetweenExercises
            if ($betweenSeconds -gt 0) {
                $phases.Add([PSCustomObject]@{
                    Seconds       = $betweenSeconds
                    Label         = 'transition'
                    Duration      = $routine.BetweenExercises
                    LoopId        = ''
                    LoopIteration = 1
                    LoopTotal     = 1
                    PhaseType     = 'transition'
                    Countdown     = 'none'
                    AnnounceStart = 'Next exercise'
                    AnnounceEnd   = $exercises[$exIdx + 1].Name
                })
            }
        }
    }

    if ($routine.Cooldown) {
        $cooldownPhases = @(ConvertFrom-TimerSequence -Pattern $routine.Cooldown)
        foreach ($p in $cooldownPhases) {
            $p | Add-Member -NotePropertyName 'PhaseType' -NotePropertyValue 'cooldown' -Force
            $p | Add-Member -NotePropertyName 'Countdown' -NotePropertyValue 'none' -Force
            $p | Add-Member -NotePropertyName 'AnnounceStart' -NotePropertyValue $p.Label -Force
            $phases.Add($p)
        }
    }

    return @($phases)
}

function Get-WorkoutPickerOptions {
    $workouts = Get-PS1TimerModuleWorkouts
    if (-not $workouts -or $workouts.Count -eq 0) { return @() }

    $options = [System.Collections.Generic.List[object]]::new()
    foreach ($key in ($workouts.Keys | Sort-Object)) {
        $w = $workouts[$key]
        $desc = if ($w.Description) { [string]$w.Description } else { $key }
        $options.Add(@{
            Id          = $key
            Label       = $key
            Description = $desc
            Color       = 'Cyan'
        })
    }
    return $options.ToArray()
}

function Parse-TimerAtTime {
    <#
    .SYNOPSIS
        Parses HH:mm (24h) into today's DateTime, or $null if invalid/past.
    #>
    param(
        [string]$At,
        [DateTime]$Now = (Get-Date)
    )

    if ([string]::IsNullOrWhiteSpace($At)) { return $null }
    if ($At -notmatch '^(\d{1,2}):(\d{2})$') { return $null }

    $hour = [int]$matches[1]
    $minute = [int]$matches[2]
    if ($hour -gt 23 -or $minute -gt 59) { return $null }

    $scheduled = [DateTime]::new($Now.Year, $Now.Month, $Now.Day, $hour, $minute, 0)
    if ($scheduled -le $Now) { return $null }

    return $scheduled
}
