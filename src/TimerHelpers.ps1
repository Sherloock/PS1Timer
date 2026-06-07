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
    TimerDefaults = @{}
    Webhooks      = @{}
    Palettes      = $null
}

function Initialize-PS1TimerModuleConfig {
    <#
    .SYNOPSIS
        Snapshots timer config at module import so other toolkits cannot overwrite Webhooks via $global:Config.
    #>
    $script:PS1TimerModuleConfig = @{
        TimerDefaults = @{}
        Webhooks      = @{}
        Palettes      = $null
    }

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
    if ($global:Config.Palettes) {
        $script:PS1TimerModuleConfig.Palettes = $global:Config.Palettes
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

function Get-PS1TimerModulePalettes {
    if ($script:PS1TimerModuleConfig.Palettes) {
        return $script:PS1TimerModuleConfig.Palettes
    }
    if ($global:Config -and $global:Config.Palettes) {
        return $global:Config.Palettes
    }
    return $null
}

function Assert-TimerConfig {
    <#
    .SYNOPSIS
        Validates $global:Config after load; warns on invalid values without throwing.
    #>
    if (-not $global:Config) { return }

    $validNotify = @('popup', 'toast', 'sound', 'silent', 'webhook')
    $validAfterStart = @('none', 'watch', 'list')
    $paletteSource = if ($global:Config.Palettes) { $global:Config.Palettes } else { Get-DefaultTimerPalettes }
    $validThemes = @($paletteSource.Keys | ForEach-Object { "$_".ToLower() }) | Select-Object -Unique
    $requiredPaletteSlots = Get-TimerSemanticPaletteSlots

    if ($global:Config.TimerDefaults) {
        $td = $global:Config.TimerDefaults

        if ($td.Notify -and ($validNotify -notcontains $td.Notify.ToLower())) {
            Write-Warning "PS1Timer: TimerDefaults.Notify '$($td.Notify)' is invalid. Use: $($validNotify -join ', ')"
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

        if ($td.SoundFile -and -not (Test-Path -LiteralPath $td.SoundFile)) {
            Write-Warning "PS1Timer: SoundFile not found: $($td.SoundFile)"
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
            if ($preset.Webhook -and -not (Resolve-TimerWebhookUrl -Name $preset.Webhook)) {
                Write-Warning "PS1Timer: Presets['$presetName'].Webhook '$($preset.Webhook)' not found in Config.Webhooks."
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
