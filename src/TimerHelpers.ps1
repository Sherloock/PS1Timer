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
        'White'      = $c.White
        'Yellow'     = $c.Yellow
        'Green'      = $c.Green
        'Red'        = $c.Red
        'Cyan'       = $c.Cyan
        'Magenta'    = $c.Magenta
        'Gray'       = $c.Gray
        'DarkGray'   = $c.Dim
        'DarkYellow' = $c.Yellow
    }

    [Console]::CursorVisible = $false
    $prevRenderedLines = 0

    try {
        while ($true) {
            $sb = [System.Text.StringBuilder]::new()

            [void]$sb.AppendLine("")
            if ($Title) {
                [void]$sb.AppendLine("$($c.Cyan)  $Title$($c.Reset)")
                [void]$sb.AppendLine("$($c.DarkCyan)  $('-' * $Title.Length)$($c.Reset)")
            }
            [void]$sb.AppendLine("")

            for ($i = 0; $i -lt $optionCount; $i++) {
                $opt = $Options[$i]
                $isSelected = ($i -eq $selectedIndex)
                $baseColorCode = if ($opt.Color -and $colorMap[$opt.Color]) { $colorMap[$opt.Color] } else { $c.White }

                if ($isSelected) {
                    [void]$sb.AppendLine("$($c.Cyan)  $selector $($c.Reset)$($c.InvertCyan)$($opt.Label)$($c.Reset)")
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
            [void]$sb.AppendLine("$($c.Yellow)  [Up/Down]$($c.Dim) navigate  $($c.Green)[Enter]$($c.Dim) select$cancelText$($c.Reset)")

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
