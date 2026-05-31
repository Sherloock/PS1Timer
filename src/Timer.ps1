# Timer module (merged for faster profile load)
# Generated from core\Timer\*.ps1 in dependency order

# region Timer-Data.ps1
# Timer module - Data persistence and management

# Timer data file path (shared across timer functions)
$script:TimerDataFile = Join-Path $env:TEMP "ps-timers.json"
# Cache for watch mode optimization
$script:TimerDataCache = $null
$script:TimerDataCacheTime = [DateTime]::MinValue

function Get-TimerData {
    <#
    .SYNOPSIS
        Loads timer metadata from JSON file.
    #>
    if (Test-Path -LiteralPath $script:TimerDataFile) {
        try {
            $content = Get-Content -LiteralPath $script:TimerDataFile -Raw -ErrorAction Stop
            if ($content) {
                $data = $content | ConvertFrom-Json
                # Handle nested value structures from ConvertTo-Json
                $result = @()
                foreach ($item in $data) {
                    if ($item.PSObject.Properties.Name -contains 'Id') {
                        $result += $item
                    }
                }
                return $result
            }
        }
        catch {
            # File corrupted or empty, return empty array
        }
    }
    return @()
}

function Get-TimerDataIfChanged {
    <#
    .SYNOPSIS
        Returns timer data only if the JSON file was modified since last read.
    .DESCRIPTION
        Optimized for watch mode - avoids unnecessary file reads by checking
        the file's LastWriteTime against a cached timestamp.
    .PARAMETER Force
        If set, always reads the file regardless of modification time.
    .RETURNS
        Hashtable with Keys: Data (array), Changed (bool)
    #>
    param([switch]$Force)

    if (-not (Test-Path -LiteralPath $script:TimerDataFile)) {
        $script:TimerDataCache = @()
        $script:TimerDataCacheTime = [DateTime]::MinValue
        return @{ Data = @(); Changed = $true }
    }

    $fileInfo = Get-Item -LiteralPath $script:TimerDataFile -ErrorAction SilentlyContinue
    if (-not $fileInfo) {
        return @{ Data = @(); Changed = $false }
    }

    $lastWrite = $fileInfo.LastWriteTime

    # Check if file was modified since last cache
    if (-not $Force -and $script:TimerDataCache -ne $null -and $lastWrite -le $script:TimerDataCacheTime) {
        return @{ Data = $script:TimerDataCache; Changed = $false }
    }

    # File changed or no cache - read fresh data
    $script:TimerDataCache = @(Get-TimerData)
    $script:TimerDataCacheTime = $lastWrite

    return @{ Data = $script:TimerDataCache; Changed = $true }
}

function Save-TimerData {
    <#
    .SYNOPSIS
        Saves timer metadata to JSON file.
    #>
    param([array]$Timers)

    if ($Timers.Count -eq 0) {
        if (Test-Path -LiteralPath $script:TimerDataFile) {
            Remove-Item -LiteralPath $script:TimerDataFile -Force
        }
        return
    }

    # Flatten and clean the array before saving
    $clean = @()
    foreach ($t in $Timers) {
        if ($t.PSObject.Properties.Name -contains 'Id') {
            $obj = [PSCustomObject]@{
                Id               = $t.Id
                Duration         = $t.Duration
                Seconds          = [int]$t.Seconds
                Message          = $t.Message
                StartTime        = $t.StartTime
                EndTime          = $t.EndTime
                RepeatTotal      = [int]$t.RepeatTotal
                RepeatRemaining  = [int]$t.RepeatRemaining
                CurrentRun       = [int]$t.CurrentRun
                State            = $t.State
                RemainingSeconds = if ($t.RemainingSeconds) { [int]$t.RemainingSeconds } else { $null }
                IsSequence       = if ($t.IsSequence) { $true } else { $false }
                TaskName         = $t.TaskName
            }

            # Add sequence-specific fields if present
            if ($t.IsSequence) {
                $obj | Add-Member -NotePropertyName 'SequencePattern' -NotePropertyValue $t.SequencePattern
                $obj | Add-Member -NotePropertyName 'Phases' -NotePropertyValue $t.Phases
                $obj | Add-Member -NotePropertyName 'CurrentPhase' -NotePropertyValue ([int]$t.CurrentPhase)
                $obj | Add-Member -NotePropertyName 'TotalPhases' -NotePropertyValue ([int]$t.TotalPhases)
                $obj | Add-Member -NotePropertyName 'PhaseLabel' -NotePropertyValue $t.PhaseLabel
                $obj | Add-Member -NotePropertyName 'TotalSeconds' -NotePropertyValue ([int]$t.TotalSeconds)
            }

            $clean += $obj
        }
    }

    ConvertTo-Json -InputObject $clean -Depth 10 | Set-Content -LiteralPath $script:TimerDataFile -Force
}

function Sync-TimerData {
    <#
    .SYNOPSIS
        Syncs timer data with actual scheduled task states.
    .DESCRIPTION
        Checks if scheduled tasks exist for running timers.
        Only marks as Lost if task is missing AND end time has passed.
    #>
    $timers = @(Get-TimerData)
    $changed = $false

    foreach ($timer in $timers) {
        if ($timer.State -ne 'Running') { continue }

        $taskName = Get-TimerTaskName -Timer $timer
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

        if ($task) {
            # Task exists - timer is still active, check if it ran
            $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
            if ($taskInfo -and $taskInfo.LastRunTime -and $taskInfo.LastRunTime -gt [DateTime]::MinValue) {
                # Task has run - the script should have updated the JSON
                # Re-read to get any changes made by the scheduled task
                $freshTimers = @(Get-TimerData)
                $freshTimer = $freshTimers | Where-Object { $_.Id -eq $timer.Id }
                if ($freshTimer -and $freshTimer.State -ne $timer.State) {
                    return $freshTimers  # Return updated data
                }
            }
            # Task exists and hasn't run yet - timer is valid
        }
        else {
            # Task not found - check if timer should have ended
            try {
                $endTime = [DateTime]::Parse($timer.EndTime)
                $remaining = [int]($endTime - (Get-Date)).TotalSeconds

                if ($remaining -le 0) {
                    # Timer expired without task - mark as lost
                    $timer.State = 'Lost'
                    # Save 0 remaining (cycle expired)
                    $timer | Add-Member -NotePropertyName 'RemainingSeconds' -NotePropertyValue 0 -Force
                    $changed = $true
                }
                # Otherwise, task might still be scheduling - give it a moment
                # If still no task after end time, mark as lost with remaining time
            }
            catch {
                # Invalid EndTime format - mark as lost
                $timer.State = 'Lost'
                $timer | Add-Member -NotePropertyName 'RemainingSeconds' -NotePropertyValue $timer.Seconds -Force
                $changed = $true
            }
        }
    }

    if ($changed) {
        Save-TimerData -Timers $timers
    }

    return $timers
}

function New-TimerTaskName {
    <#
    .SYNOPSIS
        Generates a unique scheduled task name for a timer phase/run.
    #>
    param([string]$TimerId)

    $suffix = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    return "PSTimer_${TimerId}_${suffix}"
}

function Get-TimerTaskName {
    <#
    .SYNOPSIS
        Returns the currently tracked scheduled task name for a timer.
    #>
    param([PSCustomObject]$Timer)

    if ($Timer.PSObject.Properties.Name -contains 'TaskName' -and -not [string]::IsNullOrWhiteSpace($Timer.TaskName)) {
        return $Timer.TaskName
    }

    return "PSTimer_$($Timer.Id)"
}

function New-TimerId {
    <#
    .SYNOPSIS
        Generates a sequential timer ID (1, 2, 3, ...).
    #>
    $timers = @(Get-TimerData)
    if ($timers.Count -eq 0) {
        return "1"
    }

    # Find highest numeric ID
    $maxId = 0
    foreach ($t in $timers) {
        if ($t.Id -match '^\d+$') {
            $num = [int]$t.Id
            if ($num -gt $maxId) { $maxId = $num }
        }
    }

    return [string]($maxId + 1)
}

function Get-TimerForWatch {
    <#
    .SYNOPSIS
        Resolves which timer to watch: by Id, single active, or picker. Returns timer or error info.
    #>
    param(
        [array]$Timers,
        [string]$Id
    )
    $active = @($Timers | Where-Object { $_.State -eq 'Running' })
    if ($active.Count -eq 0) {
        return @{ Error = 'NoActive' }
    }
    if ([string]::IsNullOrEmpty($Id)) {
        if ($active.Count -eq 1) {
            return @{ Timer = $active[0] }
        }
        $options = Get-TimerPickerOptions -Timers $active -FilterState 'Running' -ShowRemaining
        $selectedId = Show-MenuPicker -Title "SELECT TIMER TO WATCH" -Options $options -AllowCancel
        if (-not $selectedId) { return @{ Error = 'Cancelled' } }
        $t = $active | Where-Object { $_.Id -eq $selectedId }
        return @{ Timer = $t }
    }
    $t = $Timers | Where-Object { $_.Id -eq $Id }
    if (-not $t) {
        return @{ Error = 'NotFound'; Id = $Id }
    }
    if ($t.State -ne 'Running') {
        return @{ Error = 'NotRunning'; Id = $Id; State = $t.State }
    }
    return @{ Timer = $t }
}

function Get-TruncatedMessage {
    <#
    .SYNOPSIS
        Truncates a message to a maximum length with ellipsis.
    #>
    param(
        [string]$Message,
        [int]$MaxLength = 20
    )

    if ($Message.Length -gt $MaxLength) {
        return $Message.Substring(0, $MaxLength - 3) + "..."
    }
    return $Message
}

function Get-TimerPickerOptions {
    <#
    .SYNOPSIS
        Builds options array for Show-MenuPicker from timer list.
    #>
    param(
        [array]$Timers,
        [string]$FilterState,
        [switch]$ShowRemaining,
        [switch]$IncludeAllOption,
        [switch]$IncludeDoneOption,
        [string]$AllOptionLabel,
        [string]$AllOptionColor = 'Yellow'
    )

    $options = @()

    # Filter timers if state specified
    $filteredTimers = $Timers
    if ($FilterState) {
        $filteredTimers = @($Timers | Where-Object { $_.State -eq $FilterState })
    }

    # Build individual timer options
    foreach ($t in $filteredTimers) {
        $color = Get-TimerStateColor -State $t.State

        # Build label
        if ($ShowRemaining) {
            if ($t.State -eq 'Running') {
                $remaining = ([DateTime]::Parse($t.EndTime) - (Get-Date))
                $remainingStr = Format-RemainingTime -Remaining $remaining
                $label = "[$($t.Id)] $($t.Message) - $remainingStr remaining"
            }
            elseif ($t.State -eq 'Paused') {
                $remaining = if ($t.RemainingSeconds) { $t.RemainingSeconds } else { $t.Seconds }
                $remainingStr = Format-Duration -Seconds $remaining
                $label = "[$($t.Id)] $($t.Message) - $remainingStr remaining"
            }
            else {
                $label = "[$($t.Id)] $($t.Message) ($($t.State))"
            }
        }
        else {
            $label = "[$($t.Id)] $($t.Message) ($($t.State))"
        }

        $options += @{
            Id    = $t.Id
            Label = $label
            Color = $color
        }
    }

    # Add "done" option if requested
    if ($IncludeDoneOption) {
        $doneCount = @($Timers | Where-Object { $_.State -eq 'Completed' -or $_.State -eq 'Lost' }).Count
        if ($doneCount -gt 0) {
            $options += @{
                Id    = 'done'
                Label = "Remove all finished ($doneCount completed/lost)"
                Color = 'Cyan'
            }
        }
    }

    # Add "all" option if requested and multiple timers exist
    if ($IncludeAllOption -and $filteredTimers.Count -gt 1) {
        $label = if ($AllOptionLabel) { $AllOptionLabel } else { "All ($($filteredTimers.Count) total)" }
        $options += @{
            Id    = 'all'
            Label = $label
            Color = $AllOptionColor
        }
    }

    return $options
}
# endregion Timer-Data.ps1

# region Timer-Display.ps1
# Timer module - Display and formatting helpers

function Get-AnsiColors {
    <#
    .SYNOPSIS
        Returns a hashtable of ANSI color escape codes for console output.
    #>
    $esc = [char]27
    return @{
        Esc        = $esc
        Reset      = "$esc[0m"
        Bold       = "$esc[1m"
        Dim        = "$esc[2m"
        Cyan       = "$esc[36m"
        DarkCyan   = "$esc[36m"
        Green      = "$esc[32m"
        Yellow     = "$esc[33m"
        Red        = "$esc[31m"
        Magenta    = "$esc[35m"
        White      = "$esc[97m"
        Gray       = "$esc[90m"
        InvertCyan = "$esc[30;46m"
    }
}

function Format-RemainingTime {
    <#
    .SYNOPSIS
        Formats a TimeSpan as HH:MM:SS string.
    #>
    param([TimeSpan]$Remaining)

    if ($Remaining.TotalSeconds -lt 0) {
        return "00:00:00"
    }
    return "{0:D2}:{1:D2}:{2:D2}" -f [int]$Remaining.Hours, $Remaining.Minutes, $Remaining.Seconds
}

function Get-TimerStateColor {
    <#
    .SYNOPSIS
        Returns the display color for a timer state.
    .PARAMETER State
        The timer state (Running, Paused, Completed, Lost).
    .PARAMETER Ansi
        If set, returns ANSI escape code instead of color name.
    #>
    param(
        [string]$State,
        [switch]$Ansi
    )

    $colorName = switch ($State) {
        'Running'   { 'Green' }
        'Completed' { 'DarkGray' }
        'Paused'    { 'Yellow' }
        'Lost'      { 'Red' }
        default     { 'Gray' }
    }

    if ($Ansi) {
        $colors = Get-AnsiColors
        $result = switch ($colorName) {
            'Green'    { $colors.Green }
            'DarkGray' { $colors.Gray }
            'Yellow'   { $colors.Yellow }
            'Red'      { $colors.Red }
            default    { $colors.Gray }
        }
        return $result
    }

    return $colorName
}

function Get-TimerProgress {
    <#
    .SYNOPSIS
        Calculates the progress percentage for a timer.
    #>
    param([PSCustomObject]$Timer)

    if ($Timer.State -eq 'Completed') {
        return [double]100
    }

    if ($Timer.State -eq 'Paused') {
        # Calculate progress based on remaining seconds
        $remaining = if ($Timer.RemainingSeconds) { $Timer.RemainingSeconds } else { $Timer.Seconds }
        $elapsed = $Timer.Seconds - $remaining
        $percent = [math]::Min(100, [math]::Max(0, ($elapsed / $Timer.Seconds) * 100))
        return [double]$percent
    }

    if ($Timer.State -ne 'Running') {
        return [double]-1
    }

    $now = Get-Date
    $startTime = [DateTime]::Parse($Timer.StartTime)
    $elapsed = ($now - $startTime).TotalSeconds

    $percent = ([double]$elapsed / $Timer.Seconds) * 100
    $percent = [math]::Min(100.0, [math]::Max(0.0, $percent))

    return $percent
}

function Test-TimerIsActiveDisplay {
    <#
    .SYNOPSIS
        Returns whether the timer state should show remaining time and ends-at.
    #>
    param([string]$State)
    return ($State -eq 'Running' -or $State -eq 'Paused' -or $State -eq 'Lost')
}

function Get-TimerListRowColorsForState {
    <#
    .SYNOPSIS
        Returns remainingColor and endsColor for a timer state.
    #>
    param([string]$State)
    if ($State -eq 'Running') {
        return @{ RemainingColor = 'Yellow'; EndsColor = 'Green' }
    }
    if ($State -eq 'Lost') {
        return @{ RemainingColor = 'DarkRed'; EndsColor = 'DarkGray' }
    }
    if ($State -eq 'Paused') {
        return @{ RemainingColor = 'DarkYellow'; EndsColor = 'DarkGray' }
    }
    return @{ RemainingColor = 'DarkGray'; EndsColor = 'DarkGray' }
}

function Get-TimerListRowDisplayData {
    <#
    .SYNOPSIS
        Computes all display values for one timer list row.
    #>
    param(
        [PSCustomObject]$Timer,
        [DateTime]$Now
    )
    $endTime = [DateTime]::Parse($Timer.EndTime)
    $remaining = $endTime - $Now
    $remainingStr = Format-RemainingTime -Remaining $remaining
    $stateColor = Get-TimerStateColor -State $Timer.State

    if ($Timer.IsSequence) {
        $phaseNum = [int]$Timer.CurrentPhase + 1
        $repeatStr = "$phaseNum/$($Timer.TotalPhases)"
    }
    elseif ($Timer.RepeatTotal -gt 1) {
        $repeatStr = "$($Timer.CurrentRun)/$($Timer.RepeatTotal)"
    }
    else {
        $repeatStr = "-"
    }

    $msgSource = if ($Timer.IsSequence) { $Timer.PhaseLabel } else { $Timer.Message }
    $msgDisplay = Get-TruncatedMessage -Message $msgSource -MaxLength 20
    $durationStr = if ($Timer.IsSequence) { Format-Duration -Seconds $Timer.TotalSeconds } else { Format-Duration -Seconds $Timer.Seconds }

    $percent = Get-TimerProgress -Timer $Timer
    $progressStr = if ($percent -ge 0) { "{0:N0}%" -f $percent } else { "-" }

    $showActive = Test-TimerIsActiveDisplay -State $Timer.State
    if ($showActive) {
        if ($Timer.State -eq 'Running') {
            $endsAtStr = $endTime.ToString('HH:mm:ss')
        }
        else {
            $savedRemaining = if ($Timer.RemainingSeconds -and $Timer.RemainingSeconds -gt 0) { $Timer.RemainingSeconds } else { $Timer.Seconds }
            $remainingStr = Format-RemainingTime -Remaining ([TimeSpan]::FromSeconds($savedRemaining))
            $projectedEnd = $Now.AddSeconds($savedRemaining)
            $endsAtStr = $projectedEnd.ToString('HH:mm:ss')
            $elapsed = $Timer.Seconds - $savedRemaining
            $percent = if ($Timer.Seconds -gt 0) { ($elapsed / $Timer.Seconds) * 100 } else { 0 }
            $progressStr = "{0:N0}%" -f $percent
        }
        $colors = Get-TimerListRowColorsForState -State $Timer.State
        $remainingColor = $colors.RemainingColor
        $endsColor = $colors.EndsColor
    }
    else {
        $remainingStr = "-"
        $endsAtStr = "-"
        $remainingColor = 'DarkGray'
        $endsColor = 'DarkGray'
    }

    return @{
        RemainingStr   = $remainingStr
        ProgressStr   = $progressStr
        EndsAtStr     = $endsAtStr
        StateColor    = $stateColor
        RepeatStr     = $repeatStr
        MsgDisplay   = $msgDisplay
        DurationStr   = $durationStr
        ShowActive    = $showActive
        RemainingColor = $remainingColor
        EndsColor     = $endsColor
        PhaseColor    = if ($Timer.IsSequence) { 'Cyan' } else { 'Magenta' }
    }
}

function Get-TimerListWatchRowLine {
    <#
    .SYNOPSIS
        Builds one ANSI-colored line for the watch list display.
    #>
    param(
        [PSCustomObject]$Timer,
        [DateTime]$Now,
        [hashtable]$Colors,
        [hashtable]$ColWidths
    )
    $row = Get-TimerListRowDisplayData -Timer $Timer -Now $Now
    $stateColor = Get-TimerStateColor -State $Timer.State -Ansi
    $phaseColor = if ($Timer.IsSequence) { $Colors.Cyan } else { $Colors.Magenta }
    $id = $ColWidths.Id; $st = $ColWidths.State; $dur = $ColWidths.Duration
    $rem = $ColWidths.Remaining; $prog = $ColWidths.Progress; $end = $ColWidths.EndsAt; $ph = $ColWidths.Phase
    return "  $($Colors.Cyan){0,-$id}$($Colors.Reset)${stateColor}{1,-$st}$($Colors.Reset)$($Colors.White){2,-$dur}$($Colors.Reset)$($Colors.Yellow){3,-$rem}$($Colors.Reset)$($Colors.Green){4,-$prog}$($Colors.Reset)$($Colors.Green){5,-$end}$($Colors.Reset)${phaseColor}{6,-$ph}$($Colors.Reset)$($Colors.Gray){7}$($Colors.Reset)" -f $Timer.Id, $Timer.State, $row.DurationStr, $row.RemainingStr, $row.ProgressStr, $row.EndsAtStr, $row.RepeatStr, $row.MsgDisplay
}

function Wait-OneSecondOrKeyPress {
    <#
    .SYNOPSIS
        Waits until 1 second has elapsed since stopwatch start, or user presses a key.
    .RETURNS
        $true if key was pressed (caller should exit), $false to continue loop.
    #>
    param([System.Diagnostics.Stopwatch]$Stopwatch)
    $remainingMs = 1000 - $Stopwatch.ElapsedMilliseconds
    while ($remainingMs -gt 0) {
        if ([Console]::KeyAvailable) {
            [Console]::ReadKey($true) | Out-Null
            return $true
        }
        $sleepMs = [math]::Min(50, $remainingMs)
        Start-Sleep -Milliseconds $sleepMs
        $remainingMs = 1000 - $Stopwatch.ElapsedMilliseconds
    }
    return $false
}

function Get-TimerWatchCompletedContent {
    <#
    .SYNOPSIS
        Builds content for completed timer watch display.
    #>
    param(
        [hashtable]$Colors,
        [string]$Message,
        [int]$TotalSeconds,
        [DateTime]$EndTime
    )
    $barFull = [char]0x2588
    $barWidth = 40
    $fullBar = [string]$barFull * $barWidth
    $durStr = Format-Duration -Seconds $TotalSeconds
    $endStr = $EndTime.ToString('HH:mm:ss')
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine($Colors.Green + $Colors.Bold + "  TIMER COMPLETED!" + $Colors.Reset)
    [void]$sb.AppendLine($Colors.Cyan + "  ==================" + $Colors.Reset)
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine($Colors.Gray + "  Message:  " + $Colors.White + $Message + $Colors.Reset)
    [void]$sb.AppendLine($Colors.Gray + "  Duration: " + $Colors.White + $durStr + $Colors.Reset)
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("  " + $Colors.Green + $fullBar + $Colors.Reset + " " + $Colors.Bold + "100%" + $Colors.Reset)
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine($Colors.Green + "  Finished at " + $endStr + $Colors.Reset)
    [void]$sb.AppendLine("")
    return $sb
}

function Get-TimerWatchRunningContent {
    <#
    .SYNOPSIS
        Builds content for running timer watch display.
    #>
    param(
        [hashtable]$Colors,
        [PSCustomObject]$CurrentTimer,
        [PSCustomObject]$Timer,
        [double]$Percent,
        [TimeSpan]$Remaining,
        [string]$EndsAtFormatted
    )
    $barFull = [char]0x2588
    $barEmpty = [char]0x2591
    $barWidth = 40
    $filledCount = [int][math]::Floor(($Percent / 100) * $barWidth)
    $emptyCount = [int]($barWidth - $filledCount)
    $filledBar = [string]$barFull * $filledCount
    $emptyBar = [string]$barEmpty * $emptyCount
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $percentStr = $Percent.ToString("0.00", $inv) + "%"
    $remainingStr = Format-RemainingTime -Remaining $Remaining
    $c = $Colors
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("")
    $timerId = $Timer.Id
    if ($CurrentTimer.IsSequence) {
        $phaseNum = [int]$CurrentTimer.CurrentPhase + 1
        $phaseLabel = $CurrentTimer.PhaseLabel
        $seqTotal = Format-Duration -Seconds $CurrentTimer.TotalSeconds
        $seqPhaseDur = Format-Duration -Seconds $CurrentTimer.Seconds
        [void]$sb.AppendLine($c.Cyan + $c.Bold + "  SEQUENCE WATCH " + $c.White + "[" + $timerId + "]" + $c.Reset)
        [void]$sb.AppendLine($c.Cyan + "  =====================" + $c.Reset)
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine($c.Gray + "  Pattern:  " + $c.White + $CurrentTimer.SequencePattern + $c.Reset)
        [void]$sb.AppendLine($c.Gray + "  Total:    " + $c.White + $seqTotal + $c.Reset)
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine($c.Cyan + $c.Bold + "  Phase " + $phaseNum + "/" + $CurrentTimer.TotalPhases + ": " + $phaseLabel + $c.Reset)
        [void]$sb.AppendLine($c.Gray + "  Duration: " + $c.White + $seqPhaseDur + $c.Reset)
        [void]$sb.AppendLine($c.Gray + "  Ends at:  " + $c.Yellow + $EndsAtFormatted + $c.Reset)
    }
    else {
        [void]$sb.AppendLine($c.Cyan + $c.Bold + "  TIMER WATCH " + $c.White + "[" + $timerId + "]" + $c.Reset)
        [void]$sb.AppendLine($c.Cyan + "  ===================" + $c.Reset)
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine($c.Gray + "  Message:  " + $c.White + $Timer.Message + $c.Reset)
        $msgDur = Format-Duration -Seconds $Timer.Seconds
        [void]$sb.AppendLine($c.Gray + "  Duration: " + $c.White + $msgDur + $c.Reset)
        [void]$sb.AppendLine($c.Gray + "  Ends at:  " + $c.Yellow + $EndsAtFormatted + $c.Reset)
        if ($Timer.RepeatTotal -gt 1) {
            $repStr = $CurrentTimer.CurrentRun.ToString() + "/" + $Timer.RepeatTotal.ToString()
            [void]$sb.AppendLine($c.Gray + "  Repeat:   " + $c.White + $repStr + $c.Reset)
        }
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("  " + $c.Green + $filledBar + $c.Gray + $emptyBar + $c.Reset + " " + $c.Bold + $percentStr + $c.Reset)
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine($c.Yellow + $c.Bold + "  Remaining: " + $remainingStr + $c.Reset)
    return $sb
}

function Get-TimerWatchPhaseTimelineContent {
    <#
    .SYNOPSIS
        Builds phase timeline content for sequence timer watch.
    #>
    param(
        [hashtable]$Colors,
        [PSCustomObject]$CurrentTimer
    )
    if (-not $CurrentTimer.IsSequence -or -not $CurrentTimer.Phases) {
        return $null
    }
    $c = $Colors
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine($c.DarkCyan + "  Phases:" + $c.Reset)
    $phases = $CurrentTimer.Phases
    $maxShow = [math]::Min(6, $phases.Count)
    $startIdx = [math]::Max(0, [int]$CurrentTimer.CurrentPhase - 2)
    $endIdx = [math]::Min($phases.Count - 1, $startIdx + $maxShow - 1)
    for ($i = $startIdx; $i -le $endIdx; $i++) {
        $phase = $phases[$i]
        $pNum = $i + 1
        $marker = if ($i -eq [int]$CurrentTimer.CurrentPhase) { $c.Cyan + ">" } else { " " }
        $pColor = if ($i -lt [int]$CurrentTimer.CurrentPhase) { $c.Dim } elseif ($i -eq [int]$CurrentTimer.CurrentPhase) { $c.White } else { $c.Gray }
        $checkMark = if ($i -lt [int]$CurrentTimer.CurrentPhase) { $c.Green + "[OK]" } else { "    " }
        $phaseDur = Format-Duration -Seconds $phase.Seconds
        $line = "  " + $marker + " " + $checkMark + " " + $pColor + $pNum + ". " + $phase.Label + " (" + $phaseDur + ")" + $c.Reset
        [void]$sb.AppendLine($line)
    }
    if ($endIdx -lt $phases.Count - 1) {
        $moreCount = $phases.Count - $endIdx - 1
        $moreLine = $c.Dim + "    ... " + $moreCount + " more phases" + $c.Reset
        [void]$sb.AppendLine($moreLine)
    }
    return $sb
}
# endregion Timer-Display.ps1

# region Timer-Notifications.ps1
# Timer module - Notification system
# Provides multiple notification methods: popup, toast, sound, silent

function Get-TimerNotificationConfig {
    <#
    .SYNOPSIS
        Gets the notification configuration from global config.
    .DESCRIPTION
        Returns notification settings with defaults if not configured.
    #>
    $defaults = @{
        Notify = 'popup'      # popup, toast, sound, silent
        SoundFile = $null     # Path to custom sound file
    }
    
    if ($global:Config -and $global:Config.TimerDefaults) {
        $config = $global:Config.TimerDefaults
        if ($config.Notify) { $defaults.Notify = $config.Notify }
        if ($config.SoundFile) { $defaults.SoundFile = $config.SoundFile }
    }
    
    return $defaults
}

function Show-TimerNotification {
    <#
    .SYNOPSIS
        Shows a timer notification using the configured method.
    .PARAMETER Type
        Notification type: popup, toast, sound, silent
    .PARAMETER Title
        Notification title
    .PARAMETER Message
        Main message
    .PARAMETER Body
        Additional body lines (array)
    .PARAMETER SoundFile
        Optional custom sound file path
    #>
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('popup', 'toast', 'sound', 'silent')]
        [string]$Type,
        
        [Parameter(Mandatory=$true)]
        [string]$Title,
        
        [string]$Message = '',
        
        [array]$Body = @(),
        
        [string]$SoundFile = $null
    )
    
    # Always play sound first (unless silent)
    if ($Type -ne 'silent') {
        Play-TimerSound -Type $Type -SoundFile $SoundFile
    }
    
    # Then show visual notification (unless sound-only mode)
    switch ($Type) {
        'popup' {
            Show-TimerPopup -Title $Title -Body $Body
        }
        'toast' {
            Show-TimerToast -Title $Title -Message $Message -Body $Body
        }
        'sound' {
            # Sound only, no visual notification
        }
        'silent' {
            # Nothing at all
        }
    }
}

function Show-TimerPopup {
    <#
    .SYNOPSIS
        Shows a Windows popup dialog (original behavior).
    .PARAMETER Title
        Popup title
    .PARAMETER Body
        Body lines to display
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Title,
        
        [array]$Body = @()
    )
    
    $popup = New-Object -ComObject WScript.Shell
    $text = $Body -join [char]10
    if ([string]::IsNullOrEmpty($text)) {
        $text = $Title
    }
    $popup.Popup($text, 0, $Title, 64) | Out-Null
}

function Show-TimerToast {
    <#
    .SYNOPSIS
        Shows a Windows 10/11 toast notification using Windows Forms balloon tip.
    .DESCRIPTION
        Uses System.Windows.Forms.NotifyIcon to show a balloon tip notification.
        This works reliably in scheduled tasks and doesn't require Windows Runtime.
    .PARAMETER Title
        Toast title
    .PARAMETER Message
        Main message
    .PARAMETER Body
        Additional lines
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Title,
        
        [string]$Message = '',
        
        [array]$Body = @()
    )
    
    try {
        # Load Windows Forms assembly
        Add-Type -AssemblyName System.Windows.Forms | Out-Null
        
        # Build the balloon tip text
        $contentParts = @()
        if ($Message) { $contentParts += $Message }
        if ($Body.Count -gt 0) { $contentParts += ($Body -join " | ") }
        $balloonText = $contentParts -join "`n"
        if ([string]::IsNullOrEmpty($balloonText)) {
            $balloonText = $Title
        }
        # Truncate if too long (balloon tips have limits)
        if ($balloonText.Length -gt 250) {
            $balloonText = $balloonText.Substring(0, 247) + "..."
        }
        
        # Create a hidden form and notify icon
        $form = New-Object System.Windows.Forms.Form
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
        $form.ShowInTaskbar = $false
        $form.Visible = $false
        
        $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
        $notifyIcon.Icon = [System.Drawing.SystemIcons]::Information
        $notifyIcon.BalloonTipTitle = $Title
        $notifyIcon.BalloonTipText = $balloonText
        $notifyIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
        $notifyIcon.Visible = $true
        
        # Show the balloon tip (timeout in milliseconds, max 30000)
        $notifyIcon.ShowBalloonTip(10000)
        
        # Keep icon alive for a moment then cleanup
        Start-Sleep -Milliseconds 11000
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
        $form.Dispose()
    }
    catch {
        # Fall back to popup if toast fails
        Show-TimerPopup -Title $Title -Body $Body
    }
}

function Play-TimerSound {
    <#
    .SYNOPSIS
        Plays the timer sound (beep or custom file).
    .PARAMETER Type
        Notification type affecting sound choice
    .PARAMETER SoundFile
        Optional custom sound file
    #>
    param(
        [string]$Type = 'popup',
        [string]$SoundFile = $null
    )
    
    if ($SoundFile -and (Test-Path -LiteralPath $SoundFile)) {
        # Play custom sound file
        try {
            $player = New-Object System.Media.SoundPlayer $SoundFile
            $player.PlaySync()
        }
        catch {
            # Fall back to beep
            [console]::beep(440, 500)
        }
    }
    else {
        # Default console beep with variation based on type
        switch ($Type) {
            'toast' { [console]::beep(523, 300) }
            'sound' { 
                [console]::beep(440, 200)
                Start-Sleep -Milliseconds 100
                [console]::beep(523, 400)
            }
            default { [console]::beep(440, 500) }
        }
    }
}

function Get-TimerNotificationType {
    <#
    .SYNOPSIS
        Resolves the notification type from various sources.
    .DESCRIPTION
        Priority: Per-timer override > Config default > 'popup'
    .PARAMETER Override
        Per-timer override value
    #>
    param([string]$Override = $null)
    
    $validTypes = @('popup', 'toast', 'sound', 'silent')
    
    # Check override first
    if ($Override -and $validTypes -contains $Override.ToLower()) {
        return $Override.ToLower()
    }
    
    # Check config
    $config = Get-TimerNotificationConfig
    if ($config.Notify -and $validTypes -contains $config.Notify.ToLower()) {
        return $config.Notify.ToLower()
    }
    
    # Default
    return 'popup'
}

function Show-TimerNotificationHelp {
    <#
    .SYNOPSIS
        Shows notification options help.
    #>
    Write-Host ""
    Write-Host "  NOTIFICATION OPTIONS" -ForegroundColor Cyan
    Write-Host "  ===================" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "  You can customize how timer notifications appear:" -ForegroundColor White
    Write-Host ""
    Write-Host "  Per-timer flag:" -ForegroundColor Yellow
    Write-Host "    t 25m " -ForegroundColor Gray -NoNewline
    Write-Host "-Notify toast" -ForegroundColor Green -NoNewline
    Write-Host "     # Use toast for this timer" -ForegroundColor DarkGray
    Write-Host "    t 30m -Notify sound          # Sound only" -ForegroundColor DarkGray
    Write-Host "    t 25m -Notify silent         # No notification" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Notification Types:" -ForegroundColor Yellow
    Write-Host "    popup    " -ForegroundColor Green -NoNewline
    Write-Host "Modal dialog (default, blocks until OK)" -ForegroundColor White
    Write-Host "    toast    " -ForegroundColor Green -NoNewline
    Write-Host "Windows balloon tip (non-blocking, system tray)" -ForegroundColor White
    Write-Host "    sound    " -ForegroundColor Green -NoNewline
    Write-Host "Play sound only, no popup" -ForegroundColor White
    Write-Host "    silent   " -ForegroundColor Green -NoNewline
    Write-Host "No notification at all" -ForegroundColor White
    Write-Host ""
    Write-Host "  Default Configuration (config.ps1):" -ForegroundColor Yellow
    Write-Host "    TimerDefaults = @{" -ForegroundColor Gray
    Write-Host "        Notify = 'toast'" -ForegroundColor Gray
    Write-Host "        SoundFile = 'C:\\path\\to\\sound.wav'  # Optional" -ForegroundColor Gray
    Write-Host "    }" -ForegroundColor Gray
    Write-Host ""
}
# endregion Timer-Notifications.ps1

# region Timer-Job.ps1
# Timer module - Windows Scheduled Tasks integration

function Start-TimerJob {
    <#
    .SYNOPSIS
        Internal function to start a timer using Windows Scheduled Task.
    .DESCRIPTION
        Uses Scheduled Tasks instead of PowerShell jobs so timers survive terminal closure.
    #>
    param(
        [PSCustomObject]$Timer,
        [string]$Notify = 'popup'
    )

    $taskName = if ($Timer.PSObject.Properties.Name -contains 'TaskName' -and -not [string]::IsNullOrWhiteSpace($Timer.TaskName)) {
        $Timer.TaskName
    } else {
        New-TimerTaskName -TimerId $Timer.Id
    }
    $dataFile = Join-Path $env:TEMP "ps-timers.json"

    # Calculate trigger time
    $triggerTime = (Get-Date).AddSeconds($Timer.Seconds)

    # Build the notification script that runs when timer fires
    $script = @"
`$timerId = '$($Timer.Id)'
`$message = '$($Timer.Message -replace "'", "''")'
`$duration = '$($Timer.Duration)'
`$repeatTotal = $($Timer.RepeatTotal)
`$currentRun = $($Timer.CurrentRun)
`$timerSeconds = $($Timer.Seconds)
`$dataFile = '$dataFile'
`$logFile = "`$env:TEMP\PSTimer_`$timerId.log"
`$notifyType = '$Notify'
`$currentTaskName = '$taskName'

try {
    # Sound notification (if not silent)
    if (`$notifyType -ne 'silent') {
        try { [console]::beep(440, 500) } catch { }
    }

    # Update timer data FIRST (before popup, so tl shows correct state)
    if (Test-Path -LiteralPath `$dataFile) {
        `$jsonContent = Get-Content -LiteralPath `$dataFile -Raw -ErrorAction Stop
        `$parsed = `$jsonContent | ConvertFrom-Json

        # Ensure we have an array
        `$timers = @()
        if (`$parsed -is [array]) {
            `$timers = @(`$parsed)
        } else {
            `$timers = @(`$parsed)
        }

        # Find timer by ID (compare as strings)
        `$timerIndex = -1
        for (`$i = 0; `$i -lt `$timers.Count; `$i++) {
            if ([string]`$timers[`$i].Id -eq [string]`$timerId) {
                `$timerIndex = `$i
                break
            }
        }

        if (`$timerIndex -ge 0) {
            `$timer = `$timers[`$timerIndex]
            `$repeatRemaining = [int]`$timer.RepeatRemaining

            if (`$repeatRemaining -gt 0) {
                # More repeats to go - schedule next run
                `$newRepeatRemaining = `$repeatRemaining - 1
                `$newCurrentRun = [int]`$timer.RepeatTotal - `$newRepeatRemaining
                `$newStart = (Get-Date).ToString('o')
                `$newEnd = (Get-Date).AddSeconds(`$timerSeconds).ToString('o')
                `$nextTaskName = "PSTimer_`$timerId_`$([Guid]::NewGuid().ToString('N').Substring(0, 8))"

                # Create updated timer object
                `$updatedTimer = [PSCustomObject]@{
                    Id              = `$timer.Id
                    Duration        = `$timer.Duration
                    Seconds         = [int]`$timer.Seconds
                    Message         = `$timer.Message
                    StartTime       = `$newStart
                    EndTime         = `$newEnd
                    RepeatTotal     = [int]`$timer.RepeatTotal
                    RepeatRemaining = `$newRepeatRemaining
                    CurrentRun      = `$newCurrentRun
                    State           = 'Running'
                    RemainingSeconds = `$null
                    TaskName        = `$nextTaskName
                }
                `$timers[`$timerIndex] = `$updatedTimer

                # Save BEFORE scheduling next task
                ConvertTo-Json -InputObject `$timers -Depth 10 | Set-Content -LiteralPath `$dataFile -Force

                # Schedule next run (completely hidden - uses existing VBS wrapper)
                `$nextTrigger = (Get-Date).AddSeconds(`$timerSeconds)
                `$vbsPath = "`$env:TEMP\PSTimer_`$timerId.vbs"
                `$nextAction = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument `"`$vbsPath`"
                `$nextTriggerObj = New-ScheduledTaskTrigger -Once -At `$nextTrigger
                `$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Hidden

                `$registered = `$false
                try {
                    Register-ScheduledTask -TaskName `$nextTaskName -Action `$nextAction -Trigger `$nextTriggerObj -Settings `$settings -Force -ErrorAction Stop | Out-Null
                    `$registered = `$true
                } catch {
                    try {
                        Register-ScheduledTask -TaskName `$nextTaskName -Action `$nextAction -Trigger `$nextTriggerObj -Settings `$settings -Force -ErrorAction Stop | Out-Null
                        `$registered = `$true
                    } catch {
                        "`$(Get-Date -Format 'o') ERROR re-registering task: `$(`$_.Exception.Message)" | Add-Content -LiteralPath `$logFile -Force
                    }
                }

                `$currentRun = `$newCurrentRun
            } else {
                # All done - create completed timer
                `$updatedTimer = [PSCustomObject]@{
                    Id              = `$timer.Id
                    Duration        = `$timer.Duration
                    Seconds         = [int]`$timer.Seconds
                    Message         = `$timer.Message
                    StartTime       = `$timer.StartTime
                    EndTime         = `$timer.EndTime
                    RepeatTotal     = [int]`$timer.RepeatTotal
                    RepeatRemaining = 0
                    CurrentRun      = [int]`$timer.RepeatTotal
                    State           = 'Completed'
                    RemainingSeconds = `$null
                    TaskName        = `$null
                }
                `$timers[`$timerIndex] = `$updatedTimer

                ConvertTo-Json -InputObject `$timers -Depth 10 | Set-Content -LiteralPath `$dataFile -Force

                Unregister-ScheduledTask -TaskName `$currentTaskName -Confirm:`$false -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath "`$env:TEMP\PSTimer_`$timerId.ps1" -Force -ErrorAction SilentlyContinue
            }
        }
    }
} catch {
    "`$(Get-Date -Format 'o') ERROR: `$(`$_.Exception.Message)" | Add-Content -LiteralPath `$logFile -Force
}

# Show notification (after state update, so it can block without affecting tl display)
`$endStr = (Get-Date).ToString('HH:mm:ss')
`$body = @("Timer #`$timerId completed!", "", "Duration: `$duration", "Finished: `$endStr")
if (`$repeatTotal -gt 1) { `$body += "Run:      `$currentRun of `$repeatTotal" }

# Use notification type
switch (`$notifyType) {
    'toast' {
        try {
            # Use Windows Forms balloon tip - works reliably in scheduled tasks
            Add-Type -AssemblyName System.Windows.Forms | Out-Null
            `$balloonText = "Timer #`$timerId finished at `$endStr"
            `$form = New-Object System.Windows.Forms.Form
            `$form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
            `$form.ShowInTaskbar = `$false
            `$form.Visible = `$false
            `$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
            `$notifyIcon.Icon = [System.Drawing.SystemIcons]::Information
            `$notifyIcon.BalloonTipTitle = `$message
            `$notifyIcon.BalloonTipText = `$balloonText
            `$notifyIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
            `$notifyIcon.Visible = `$true
            `$notifyIcon.ShowBalloonTip(10000)
            Start-Sleep -Milliseconds 11000
            `$notifyIcon.Visible = `$false
            `$notifyIcon.Dispose()
            `$form.Dispose()
        } catch {
            # Fallback to popup
            `$popup = New-Object -ComObject WScript.Shell
            `$popup.Popup((`$body -join [char]10), 0, `$message, 64) | Out-Null
        }
    }
    'sound' {
        # Sound only, already played above
    }
    'silent' {
        # No notification at all
    }
    default {
        # Popup (default/original behavior)
        `$popup = New-Object -ComObject WScript.Shell
        `$popup.Popup((`$body -join [char]10), 0, `$message, 64) | Out-Null
    }
}
"@

    # Write script to temp file (scheduled tasks work better with script files)
    $scriptPath = Join-Path $env:TEMP "PSTimer_$($Timer.Id).ps1"
    $script | Set-Content -LiteralPath $scriptPath -Force -Encoding UTF8

    # Create VBS wrapper for truly invisible execution
    $vbsPath = Join-Path $env:TEMP "PSTimer_$($Timer.Id).vbs"
    $vbsScript = 'Set WshShell = CreateObject("WScript.Shell")' + [char]13 + [char]10 + `
        'WshShell.Run "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""' + $scriptPath + '""", 0, False' + [char]13 + [char]10 + `
        'Set WshShell = Nothing'
    $vbsScript | Set-Content -LiteralPath $vbsPath -Force -Encoding Ascii

    # Remove any existing task with same name
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

    # Create scheduled task (completely hidden - uses VBS wrapper)
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbsPath`""
    $trigger = New-ScheduledTaskTrigger -Once -At $triggerTime
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Hidden

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
    $Timer | Add-Member -NotePropertyName 'TaskName' -NotePropertyValue $taskName -Force
}

function Stop-TimerTask {
    <#
    .SYNOPSIS
        Stops and unregisters a timer's scheduled task.
    #>
    param(
        [int]$TimerId,
        [string]$TaskName
    )

    if (-not $TaskName) {
        $TaskName = "PSTimer_$TimerId"
    }

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Get-ScheduledTask -TaskName "PSTimer_${TimerId}_*" -ErrorAction SilentlyContinue |
        Where-Object { $null -ne $_ -and $_.PSObject.Properties.Name -contains 'TaskName' -and -not [string]::IsNullOrWhiteSpace($_.TaskName) } |
        ForEach-Object { Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue }

    # Also clean up the script files
    $scriptPath = Join-Path $env:TEMP "PSTimer_$TimerId.ps1"
    $vbsPath = Join-Path $env:TEMP "PSTimer_$TimerId.vbs"
    Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $vbsPath -Force -ErrorAction SilentlyContinue
}
# endregion Timer-Job.ps1

# region Timer-Operations.ps1
# Timer module - Timer operations (pause, resume, remove)

function Get-TimerResumeSeconds {
    <#
    .SYNOPSIS
        Returns the number of seconds to use when resuming a timer (from RemainingSeconds or full duration).
    #>
    param([PSCustomObject]$Timer)
    if ($Timer.RemainingSeconds -and $Timer.RemainingSeconds -gt 0) {
        return $Timer.RemainingSeconds
    }
    return $Timer.Seconds
}

function Invoke-PauseTimersBulk {
    <#
    .SYNOPSIS
        Pauses all running timers in the given array. Updates objects and saves. Returns count paused.
    #>
    param([array]$Timers)
    $count = 0
    foreach ($t in $Timers) {
        if ($t.State -ne 'Running') { continue }
        Stop-TimerTask -TimerId $t.Id -TaskName (Get-TimerTaskName -Timer $t)
        $endTime = [DateTime]::Parse($t.EndTime)
        $remaining = [int]($endTime - (Get-Date)).TotalSeconds
        if ($remaining -lt 0) { $remaining = 0 }
        $t | Add-Member -NotePropertyName 'RemainingSeconds' -NotePropertyValue $remaining -Force
        $t.State = 'Paused'
        $count++
    }
    Save-TimerData -Timers $Timers
    return $count
}

function Invoke-PauseSingleTimer {
    param([array]$Timers, [string]$Id)
    $timer = $Timers | Where-Object { $_.Id -eq $Id }
    if (-not $timer) { return $false }
    if ($timer.State -ne 'Running') { return $null }
    Stop-TimerTask -TimerId $Id -TaskName (Get-TimerTaskName -Timer $timer)
    $endTime = [DateTime]::Parse($timer.EndTime)
    $remaining = [int]($endTime - (Get-Date)).TotalSeconds
    if ($remaining -lt 0) { $remaining = 0 }
    $timer | Add-Member -NotePropertyName 'RemainingSeconds' -NotePropertyValue $remaining -Force
    $timer.State = 'Paused'
    Save-TimerData -Timers $Timers
    return $remaining
}

function Invoke-ResumeTimersBulk {
    param([array]$Timers)
    $count = 0
    foreach ($t in $Timers) {
        if ($t.State -ne 'Paused' -and $t.State -ne 'Lost') { continue }
        $seconds = Get-TimerResumeSeconds -Timer $t
        if ($seconds -le 0) {
            $t.State = 'Completed'
            continue
        }
        $now = Get-Date
        $t.StartTime = $now.ToString('o')
        $t.EndTime = $now.AddSeconds($seconds).ToString('o')
        $t.State = 'Running'
        $t | Add-Member -NotePropertyName 'RemainingSeconds' -NotePropertyValue $null -Force
        $t | Add-Member -NotePropertyName 'TaskName' -NotePropertyValue (New-TimerTaskName -TimerId $t.Id) -Force
        Start-TimerJob -Timer ([PSCustomObject]@{
            Id = $t.Id; Seconds = $seconds; Message = $t.Message; Duration = Format-Duration -Seconds $t.Seconds
            StartTime = $t.StartTime; RepeatTotal = $t.RepeatTotal; CurrentRun = $t.CurrentRun; TaskName = $t.TaskName
        })
        $count++
    }
    Save-TimerData -Timers $Timers
    return $count
}

function Invoke-ResumeSingleTimer {
    param([array]$Timers, [string]$Id)
    $timer = $Timers | Where-Object { $_.Id -eq $Id }
    if (-not $timer) { return @{ Found = $false } }
    if ($timer.State -ne 'Paused' -and $timer.State -ne 'Lost') { return @{ Found = $true; CanResume = $false } }
    $isLost = ($timer.State -eq 'Lost')
    $seconds = Get-TimerResumeSeconds -Timer $timer
    if ($seconds -le 0) {
        $timer.State = 'Completed'
        Save-TimerData -Timers $Timers
        return @{ Found = $true; CanResume = $false; NoTime = $true }
    }
    $now = Get-Date
    $newEndTime = $now.AddSeconds($seconds)
    $timer.StartTime = $now.ToString('o')
    $timer.EndTime = $newEndTime.ToString('o')
    $timer.State = 'Running'
    $timer | Add-Member -NotePropertyName 'RemainingSeconds' -NotePropertyValue $null -Force
    $timer | Add-Member -NotePropertyName 'TaskName' -NotePropertyValue (New-TimerTaskName -TimerId $timer.Id) -Force
    Start-TimerJob -Timer ([PSCustomObject]@{
        Id = $timer.Id; Seconds = $seconds; Message = $timer.Message; Duration = Format-Duration -Seconds $timer.Seconds
        StartTime = $timer.StartTime; RepeatTotal = $timer.RepeatTotal; CurrentRun = $timer.CurrentRun; TaskName = $timer.TaskName
    })
    Save-TimerData -Timers $Timers
    return @{ Found = $true; CanResume = $true; IsLost = $isLost; NewEndTime = $newEndTime }
}

function Invoke-RemoveTimersBulk {
    param([array]$Timers, [string]$Mode)
    if ($Mode -eq 'all') {
        foreach ($t in $Timers) { Stop-TimerTask -TimerId $t.Id -TaskName (Get-TimerTaskName -Timer $t) }
        Save-TimerData -Timers @()
        return $Timers.Count
    }
    $toKeep = @()
    $removed = 0
    foreach ($t in $Timers) {
        if ($t.State -eq 'Completed' -or $t.State -eq 'Lost') {
            Stop-TimerTask -TimerId $t.Id -TaskName (Get-TimerTaskName -Timer $t)
            $removed++
        }
        else { $toKeep += $t }
    }
    Save-TimerData -Timers $toKeep
    return $removed
}

function Invoke-RemoveSingleTimer {
    param([array]$Timers, [string]$Id)
    $timer = $Timers | Where-Object { $_.Id -eq $Id }
    if (-not $timer) { return $false }
    Stop-TimerTask -TimerId $Id -TaskName (Get-TimerTaskName -Timer $timer)
    $newList = @($Timers | Where-Object { $_.Id -ne $Id })
    Save-TimerData -Timers $newList
    return $true
}
# endregion Timer-Operations.ps1

# region Timer-Sequence.ps1
# Timer module - Sequence timer parsing and handling

# Timer presets - built-ins from config/presets.ps1, optional user overrides in config.ps1
if (-not $script:BuiltInTimerPresets) {
    throw 'PS1Timer: BuiltInTimerPresets not initialized. Load config/presets.ps1 before Timer.ps1.'
}
if ($global:Config -and $global:Config.TimerPresets) {
    $script:TimerPresets = @{} + $script:BuiltInTimerPresets
    foreach ($key in $global:Config.TimerPresets.Keys) {
        $script:TimerPresets[$key] = $global:Config.TimerPresets[$key]
    }
}
else {
    $script:TimerPresets = $script:BuiltInTimerPresets
}

function Test-TimerSequence {
    <#
    .SYNOPSIS
        Checks if a string is a timer sequence pattern (contains grouping or comma).
    #>
    param([string]$Pattern)

    # Check for preset name first
    if ($script:TimerPresets.ContainsKey($Pattern)) {
        return $true
    }

    # Check for sequence syntax: parentheses, comma separators, or xN multiplier
    if ($Pattern -match '\(' -or $Pattern -match ',' -or $Pattern -match '\)x\d+') {
        return $true
    }

    return $false
}

function ConvertFrom-TimerSequence {
    <#
    .SYNOPSIS
        Parses a timer sequence string into structured phase data.
    #>
    param([string]$Pattern)

    # Resolve preset if applicable
    if ($script:TimerPresets.ContainsKey($Pattern)) {
        $Pattern = $script:TimerPresets[$Pattern].Pattern
    }

    # Tokenize the pattern
    $tokens = @()
    $i = 0
    $len = $Pattern.Length

    while ($i -lt $len) {
        $char = $Pattern[$i]

        # Skip whitespace
        if ($char -match '\s') {
            $i++
            continue
        }

        # Parentheses
        if ($char -eq '(') {
            $tokens += @{ Type = 'LPAREN'; Value = '(' }
            $i++
            continue
        }
        if ($char -eq ')') {
            $tokens += @{ Type = 'RPAREN'; Value = ')' }
            $i++
            continue
        }

        # Comma
        if ($char -eq ',') {
            $tokens += @{ Type = 'COMMA'; Value = ',' }
            $i++
            continue
        }

        # Multiplier (xN)
        if ($char -eq 'x' -and $i + 1 -lt $len -and $Pattern[$i + 1] -match '\d') {
            $numStr = ''
            $i++  # Skip 'x'
            while ($i -lt $len -and $Pattern[$i] -match '\d') {
                $numStr += $Pattern[$i]
                $i++
            }
            $tokens += @{ Type = 'MULT'; Value = [int]$numStr }
            continue
        }

        # Quoted string (label)
        if ($char -eq "'" -or $char -eq '"') {
            $quote = $char
            $str = ''
            $i++  # Skip opening quote
            while ($i -lt $len -and $Pattern[$i] -ne $quote) {
                $str += $Pattern[$i]
                $i++
            }
            $i++  # Skip closing quote
            $tokens += @{ Type = 'LABEL'; Value = $str }
            continue
        }

        # Duration (e.g., 25m, 1h30m, 90s)
        if ($char -match '\d') {
            $durStr = ''
            while ($i -lt $len -and $Pattern[$i] -match '[\dhms]') {
                $durStr += $Pattern[$i]
                $i++
            }
            $tokens += @{ Type = 'DURATION'; Value = $durStr }
            continue
        }

        # Word (unquoted label)
        if ($char -match '[a-zA-Z]') {
            $word = ''
            while ($i -lt $len -and $Pattern[$i] -match '[a-zA-Z0-9_-]') {
                $word += $Pattern[$i]
                $i++
            }
            $tokens += @{ Type = 'LABEL'; Value = $word }
            continue
        }

        # Unknown character, skip
        $i++
    }

    # Parse tokens into AST
    $ast = ParseSequence -Tokens $tokens -Index ([ref]0)

    # Expand AST into flat phase list
    $phases = Expand-TimerSequence -Ast $ast

    return $phases
}

function ParseSequence {
    <#
    .SYNOPSIS
        Internal recursive parser for sequence tokens.
    #>
    param(
        [array]$Tokens,
        [ref]$Index
    )

    $items = @()

    while ($Index.Value -lt $Tokens.Count) {
        $token = $Tokens[$Index.Value]

        if ($token.Type -eq 'LPAREN') {
            # Start of group
            $Index.Value++
            $groupItems = ParseSequence -Tokens $Tokens -Index $Index

            # Check for multiplier after closing paren
            $mult = 1
            if ($Index.Value -lt $Tokens.Count -and $Tokens[$Index.Value].Type -eq 'MULT') {
                $mult = $Tokens[$Index.Value].Value
                $Index.Value++
            }

            $items += @{
                Type     = 'GROUP'
                Items    = $groupItems
                Multiply = $mult
            }
        }
        elseif ($token.Type -eq 'RPAREN') {
            # End of group
            $Index.Value++
            break
        }
        elseif ($token.Type -eq 'COMMA') {
            # Separator, skip
            $Index.Value++
        }
        elseif ($token.Type -eq 'DURATION') {
            # Single phase
            $seconds = ConvertTo-Seconds -Time $token.Value
            $label = "Timer"
            $Index.Value++

            # Check for label
            if ($Index.Value -lt $Tokens.Count -and $Tokens[$Index.Value].Type -eq 'LABEL') {
                $label = $Tokens[$Index.Value].Value
                $Index.Value++
            }

            $items += @{
                Type    = 'PHASE'
                Seconds = $seconds
                Label   = $label
                Duration = $token.Value
            }
        }
        else {
            # Skip unknown
            $Index.Value++
        }
    }

    return $items
}

function Expand-TimerSequence {
    <#
    .SYNOPSIS
        Expands AST into flat phase list with loop metadata.
    #>
    param(
        [array]$Ast,
        [string]$ParentLoopId = '',
        [int]$ParentIteration = 1,
        [int]$ParentTotal = 1
    )

    $phases = @()
    $groupCounter = 0

    foreach ($item in $Ast) {
        if ($item.Type -eq 'PHASE') {
            $phases += [PSCustomObject]@{
                Seconds       = $item.Seconds
                Label         = $item.Label
                Duration      = $item.Duration
                LoopId        = $ParentLoopId
                LoopIteration = $ParentIteration
                LoopTotal     = $ParentTotal
            }
        }
        elseif ($item.Type -eq 'GROUP') {
            $groupCounter++
            $loopId = if ($ParentLoopId) { "${ParentLoopId}.${groupCounter}" } else { [string]$groupCounter }

            for ($iter = 1; $iter -le $item.Multiply; $iter++) {
                $expanded = Expand-TimerSequence -Ast $item.Items -ParentLoopId $loopId -ParentIteration $iter -ParentTotal $item.Multiply
                $phases += $expanded
            }
        }
    }

    return $phases
}

function Get-SequenceSummary {
    <#
    .SYNOPSIS
        Returns summary information about a timer sequence.
    #>
    param([array]$Phases)

    $totalSeconds = 0
    foreach ($p in $Phases) {
        $totalSeconds += $p.Seconds
    }

    # Build description from unique labels
    $labelCounts = @{}
    foreach ($p in $Phases) {
        if (-not $labelCounts.ContainsKey($p.Label)) {
            $labelCounts[$p.Label] = 0
        }
        $labelCounts[$p.Label]++
    }

    $descParts = @()
    foreach ($label in $labelCounts.Keys) {
        $count = $labelCounts[$label]
        if ($count -gt 1) {
            $descParts += "${count}x $label"
        }
        else {
            $descParts += $label
        }
    }

    return [PSCustomObject]@{
        TotalSeconds  = $totalSeconds
        TotalDuration = Format-Duration -Seconds $totalSeconds
        PhaseCount    = $Phases.Count
        Description   = $descParts -join ', '
    }
}

function New-SequenceTimerFromPhases {
    <#
    .SYNOPSIS
        Builds the sequence timer object and phases data from parsed phases.
    #>
    param(
        [string]$Id,
        [string]$OriginalPattern,
        [array]$Phases,
        [object]$Summary,
        [DateTime]$Now,
        [string]$NotifyType = 'popup'
    )
    $firstPhase = $Phases[0]
    $endTime = $Now.AddSeconds($firstPhase.Seconds)
    $phasesData = @()
    foreach ($p in $Phases) {
        $phasesData += @{
            Seconds       = $p.Seconds
            Label         = $p.Label
            Duration      = $p.Duration
            LoopId        = $p.LoopId
            LoopIteration = $p.LoopIteration
            LoopTotal     = $p.LoopTotal
        }
    }
    $phaseCount = $Phases.Count
    $totalSecs = $Summary.TotalSeconds
    $timer = [PSCustomObject]@{
        Id              = $Id
        Duration        = $Summary.TotalDuration
        Seconds         = $firstPhase.Seconds
        Message         = $firstPhase.Label
        StartTime       = $Now.ToString('o')
        EndTime         = $endTime.ToString('o')
        RepeatTotal     = 1
        RepeatRemaining = 0
        CurrentRun      = 1
        State           = 'Running'
        IsSequence      = $true
        SequencePattern = $OriginalPattern
        Phases          = $phasesData
        CurrentPhase    = 0
        TotalPhases     = $phaseCount
        PhaseLabel      = $firstPhase.Label
        TotalSeconds    = $totalSecs
        NotifyType      = $NotifyType
        TaskName        = New-TimerTaskName -TimerId $Id
    }
    return $timer
}

function Write-SequenceTimerConfirmation {
    <#
    .SYNOPSIS
        Displays confirmation message for started sequence timer.
    #>
    param(
        [string]$Id,
        [string]$OriginalPattern,
        [object]$Summary,
        [int]$PhaseCount,
        [object]$FirstPhase,
        [DateTime]$EndTime
    )
    Write-Host ""
    Write-Host "  Sequence started " -ForegroundColor Green -NoNewline
    Write-Host "[$Id]" -ForegroundColor Cyan
    Write-Host "  Pattern:  " -ForegroundColor Gray -NoNewline
    Write-Host $OriginalPattern -ForegroundColor White
    Write-Host "  Total:    " -ForegroundColor Gray -NoNewline
    Write-Host "$($Summary.TotalDuration) ($PhaseCount phases)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Current phase:" -ForegroundColor DarkGray
    Write-Host "  [1/$PhaseCount] " -ForegroundColor Magenta -NoNewline
    Write-Host $FirstPhase.Label -ForegroundColor Cyan -NoNewline
    Write-Host " - $(Format-Duration -Seconds $FirstPhase.Seconds)" -ForegroundColor White
    Write-Host "  Ends at:  " -ForegroundColor Gray -NoNewline
    Write-Host $EndTime.ToString('HH:mm:ss') -ForegroundColor Yellow
    Write-Host ""
}

function Start-SequenceTimerJob {
    <#
    .SYNOPSIS
        Starts a sequence timer phase using Windows Scheduled Task.
    #>
    param([PSCustomObject]$Timer)

    $taskName = if ($Timer.PSObject.Properties.Name -contains 'TaskName' -and -not [string]::IsNullOrWhiteSpace($Timer.TaskName)) {
        $Timer.TaskName
    } else {
        New-TimerTaskName -TimerId $Timer.Id
    }
    $dataFile = Join-Path $env:TEMP "ps-timers.json"
    $notifyType = if ($Timer.NotifyType) { $Timer.NotifyType } else { 'popup' }

    # Calculate trigger time for current phase
    $triggerTime = (Get-Date).AddSeconds($Timer.Seconds)

    # Build the notification script using here-string
    $script = @"
`$timerId = '$($Timer.Id)'
`$dataFile = '$dataFile'
`$notifyType = '$notifyType'
`$currentTaskName = '$taskName'
`$logFile = "`$env:TEMP\PSTimer_`$timerId.log"

try {

# Read current timer state from JSON
if (-not (Test-Path -LiteralPath `$dataFile)) { exit }
`$jsonContent = Get-Content -LiteralPath `$dataFile -Raw -ErrorAction SilentlyContinue
`$parsed = `$jsonContent | ConvertFrom-Json
`$timers = New-Object System.Collections.ArrayList
`$parsed | ForEach-Object { [void]`$timers.Add(`$_) }
`$timer = `$timers | Where-Object { `$_.Id -eq `$timerId }

if (-not `$timer -or -not `$timer.IsSequence) { exit }

`$currentPhase = [int]`$timer.CurrentPhase
`$totalPhases = [int]`$timer.TotalPhases
`$phaseLabel = `$timer.PhaseLabel

# Sound notification (if not silent)
if (`$notifyType -ne 'silent') {
    try {
        if (`$currentPhase -eq `$totalPhases - 1) {
            [console]::beep(523, 200); [console]::beep(659, 200); [console]::beep(784, 400)
        } else {
            [console]::beep(440, 300)
        }
    } catch { }
}

`$nextPhaseIdx = `$currentPhase + 1

if (`$nextPhaseIdx -lt `$totalPhases) {
    # More phases to go
    `$phases = `$timer.Phases
    `$nextPhase = `$phases[`$nextPhaseIdx]
    `$nextSeconds = [int]`$nextPhase.Seconds
    `$nextLabel = `$nextPhase.Label
    `$nextTaskName = "PSTimer_`$timerId_`$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
    
    `$timer.CurrentPhase = `$nextPhaseIdx
    `$timer.PhaseLabel = `$nextLabel
    `$timer.Seconds = `$nextSeconds
    `$timer.Message = `$nextLabel
    `$timer.StartTime = (Get-Date).ToString('o')
    `$timer.EndTime = (Get-Date).AddSeconds(`$nextSeconds).ToString('o')
    `$timer.State = 'Running'
    `$timer.TaskName = `$nextTaskName
    
    # Save JSON BEFORE scheduling next task so state is persisted even if Register fails
    ConvertTo-Json -InputObject `$timers -Depth 10 | Set-Content -LiteralPath `$dataFile -Force

    # Schedule next phase (completely hidden - uses existing VBS wrapper)
    `$nextTrigger = (Get-Date).AddSeconds(`$nextSeconds)
    `$vbsPath = "`$env:TEMP\PSTimer_`$timerId.vbs"
    `$nextAction = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument `"`$vbsPath`"
    `$nextTriggerObj = New-ScheduledTaskTrigger -Once -At `$nextTrigger
    `$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Hidden

    `$registered = `$false
    try {
        Register-ScheduledTask -TaskName `$nextTaskName -Action `$nextAction -Trigger `$nextTriggerObj -Settings `$settings -Force -ErrorAction Stop | Out-Null
        `$registered = `$true
    } catch {
        try {
            Register-ScheduledTask -TaskName `$nextTaskName -Action `$nextAction -Trigger `$nextTriggerObj -Settings `$settings -Force -ErrorAction Stop | Out-Null
            `$registered = `$true
        } catch {
            "`$(Get-Date -Format 'o') ERROR re-registering task: `$(`$_.Exception.Message)" | Add-Content -LiteralPath `$logFile -Force
        }
    }
} else {
    # All phases done
    `$timer.State = 'Completed'
    `$timer.CurrentPhase = `$totalPhases
    `$timer.TaskName = `$null

    ConvertTo-Json -InputObject `$timers -Depth 10 | Set-Content -LiteralPath `$dataFile -Force

    Unregister-ScheduledTask -TaskName `$currentTaskName -Confirm:`$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "`$env:TEMP\PSTimer_`$timerId.ps1" -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "`$env:TEMP\PSTimer_`$timerId.vbs" -Force -ErrorAction SilentlyContinue
}

} catch {
    "`$(Get-Date -Format 'o') ERROR: `$(`$_.Exception.Message)" | Add-Content -LiteralPath `$logFile -Force
}

# Show notification
`$phaseNum = `$currentPhase + 1
`$endStr = (Get-Date).ToString('HH:mm:ss')
if (`$currentPhase -eq `$totalPhases - 1) {
    `$body = @("Sequence completed!", "", "All `$totalPhases phases done", "Finished: `$endStr")
    `$title = "Sequence Complete!"
} else {
    `$nextPhaseNum = `$phaseNum + 1
    `$body = @("Phase `$phaseNum/`$totalPhases done: `$phaseLabel", "", "Next: Phase `$nextPhaseNum", "Time: `$endStr")
    `$title = "Phase Complete"
}

# Use notification type
switch (`$notifyType) {
    'toast' {
        try {
            Add-Type -AssemblyName System.Windows.Forms | Out-Null
            `$balloonText = if (`$currentPhase -eq `$totalPhases - 1) { "All `$totalPhases phases finished at `$endStr" } else { "Phase `$phaseNum done, starting `$nextPhaseNum at `$endStr" }
            `$form = New-Object System.Windows.Forms.Form
            `$form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
            `$form.ShowInTaskbar = `$false
            `$form.Visible = `$false
            `$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
            `$notifyIcon.Icon = [System.Drawing.SystemIcons]::Information
            `$notifyIcon.BalloonTipTitle = `$title
            `$notifyIcon.BalloonTipText = `$balloonText
            `$notifyIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
            `$notifyIcon.Visible = `$true
            `$notifyIcon.ShowBalloonTip(10000)
            Start-Sleep -Milliseconds 11000
            `$notifyIcon.Visible = `$false
            `$notifyIcon.Dispose()
            `$form.Dispose()
        } catch {
            `$popup = New-Object -ComObject WScript.Shell
            `$popup.Popup((`$body -join [char]10), 0, `$title, 64) | Out-Null
        }
    }
    'sound' { }
    'silent' { }
    default {
        `$popup = New-Object -ComObject WScript.Shell
        `$popup.Popup((`$body -join [char]10), 0, `$title, 64) | Out-Null
    }
}
"@

    # Write script to temp file
    $scriptPath = Join-Path $env:TEMP "PSTimer_$($Timer.Id).ps1"
    $script | Set-Content -LiteralPath $scriptPath -Force -Encoding UTF8

    # Create VBS wrapper for truly invisible execution
    $vbsPath = Join-Path $env:TEMP "PSTimer_$($Timer.Id).vbs"
    $vbsScript = 'Set WshShell = CreateObject("WScript.Shell")' + [char]13 + [char]10 + `
        'WshShell.Run "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""' + $scriptPath + '""", 0, False' + [char]13 + [char]10 + `
        'Set WshShell = Nothing'
    $vbsScript | Set-Content -LiteralPath $vbsPath -Force -Encoding Ascii

    # Remove any existing task with same name
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

    # Create scheduled task (completely hidden - uses VBS wrapper)
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbsPath`""
    $trigger = New-ScheduledTaskTrigger -Once -At $triggerTime
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Hidden

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
    $Timer | Add-Member -NotePropertyName 'TaskName' -NotePropertyValue $taskName -Force
}
# endregion Timer-Sequence.ps1

# region Timer-Main.ps1
# Timer module - Main user-facing functions

function Show-TimerHelp {
    <#
    .SYNOPSIS
        Shows timer commands help dashboard.
    #>
    Write-HelpMenu -Title "TIMER COMMANDS" -Commands @(
        @{ Name='Timer <time>'; Alias='T'; Params='[msg] [repeat] [-Notify type]'; Desc='Start a timer (simple or sequence pattern)' }
        @{ Name='Timer-Presets'; Alias='TPRE'; Params=''; Desc='Pick from preset sequences (Pomodoro, etc.)' }
        @{ Name='Timer-List'; Alias='TL'; Params='[-a] [-w]'; Desc='List active timers (-a all, -w live watch)' }
        @{ Name='Timer-Watch'; Alias='TW'; Params='[id]'; Desc='Watch timer with progress bar (picker if no id)' }
        @{ Name='Timer-Pause'; Alias='TP'; Params='[id|all]'; Desc='Pause timer (picker if no id)' }
        @{ Name='Timer-Resume'; Alias='TR'; Params='[id|all]'; Desc='Resume paused timer (picker if no id)' }
        @{ Name='Timer-Remove'; Alias='TD'; Params='[id|done|all]'; Desc='Remove timer (picker if no id)' }
    ) -Sections @(
        @{
            Title = ''
            Lines = @(
                @{ Type='text'; Label='  Time formats: '; Value='1h30m, 25m, 90s, 1h20m30s' }
                @{ Type='raw'; Text='' }
                @{ Type='raw'; Text='  Simple examples:' }
                @{ Type='example'; Code='t 25m                      '; Comment='# 25 min timer' }
                @{ Type='example'; Code='t 30m Water                '; Comment='# With message' }
                @{ Type='example'; Code="t 1h30m 'Stand up' 4       "; Comment='# Repeat 4x' }
            )
        }
        @{
            Title = 'SEQUENCE TIMERS'
            Lines = @(
                @{ Type='text'; Label='  Syntax: '; Value='(duration label, duration label)xN' }
                @{ Type='raw'; Text='' }
                @{ Type='raw'; Text='  Sequence examples:' }
                @{ Type='example'; Code='t pomodoro                 '; Comment='# Use preset' }
                @{ Type='example'; Code='t "(25m work, 5m rest)x4" '; Comment='# 4 cycles' }
                @{ Type='raw'; Text='    t "(50m focus, 10m break)x3, 30m ''long break''"' ; Color='Gray' }
                @{ Type='raw'; Text='' }
                @{ Type='text'; Label='  Presets: '; Value='pomodoro, pomodoro-short, pomodoro-long, 52-17, 90-20' }
            )
        }
        @{
            Title = 'NOTIFICATION OPTIONS'
            Underline = '===================='
            Lines = @(
                @{ Type='text'; Label='  Per-timer: '; Value='t 25m -Notify toast'; LabelColor='Yellow'; ValueColor='Gray' }
                @{ Type='raw'; Text='' }
                @{ Type='raw'; Text='  Types: popup | toast | sound | silent'; Color='Green' }
                @{ Type='raw'; Text='' }
                @{ Type='raw'; Text='  popup  Modal dialog (default, blocks until OK)' }
                @{ Type='raw'; Text='  toast  Windows toast notification (non-blocking)' }
                @{ Type='raw'; Text='  sound  Sound only, no visual notification' }
                @{ Type='raw'; Text='  silent No notification at all' }
                @{ Type='raw'; Text='' }
                @{ Type='raw'; Text='  Default: Set in config.ps1 -> TimerDefaults.Notify' }
            )
        }
    )
}

function Timer {
    <#
    .SYNOPSIS
        Starts a background timer with optional repeat. Use tl to view all timers.
    .PARAMETER Time
        Duration (e.g., 1h20m, 90s), sequence pattern (e.g., "(25m work, 5m rest)x4"),
        or preset name (e.g., "pomodoro"). Omit to see help.
    .PARAMETER Message
        Optional message to show when time is up (ignored for sequences).
    .PARAMETER Repeat
        Number of times to repeat the timer (e.g., -r 3 repeats 3 times total).
    .PARAMETER Notify
        Notification type: popup (default), toast, sound, silent.
        Override default in config.ps1 TimerDefaults.Notify.
    .EXAMPLE
        t 25m
        t 30m Water
        t 1h30m 'Stand up' 4
        t pomodoro
        t "(25m work, 5m rest)x4"
        t 25m -Notify toast
        t 30m 'Drink water' -Notify sound
    #>
    param(
        [Parameter(Position=0)][string]$Time,
        [Parameter(Position=1)][Alias('m')][string]$Message = "Time is up!",
        [Parameter(Position=2)][Alias('r')][int]$Repeat = 1,
        [ValidateSet('popup', 'toast', 'sound', 'silent')]
        [string]$Notify = $null
    )

    # Show help if no time provided
    if ([string]::IsNullOrEmpty($Time)) {
        Show-TimerHelp
        return
    }

    # Check if this is a sequence pattern or preset
    if (Test-TimerSequence -Pattern $Time) {
        Start-SequenceTimer -Pattern $Time -Notify $Notify
        return
    }

    # Simple timer mode
    $seconds = ConvertTo-Seconds -Time $Time

    if ($seconds -le 0) {
        Write-Host "Invalid time format. Use 1h20m, 90s, etc." -ForegroundColor Red
        return
    }

    if ($Repeat -lt 1) { $Repeat = 1 }

    # Generate unique ID
    $id = New-TimerId
    $now = Get-Date
    $endTime = $now.AddSeconds($seconds)

    # Determine notification type
    $notificationType = Get-TimerNotificationType -Override $Notify
    
    # Create timer metadata
    $timer = [PSCustomObject]@{
        Id              = $id
        Duration        = $Time
        Seconds         = $seconds
        Message         = $Message
        StartTime       = $now.ToString('o')
        EndTime         = $endTime.ToString('o')
        RepeatTotal     = $Repeat
        RepeatRemaining = $Repeat - 1
        CurrentRun      = 1
        State           = 'Running'
        IsSequence      = $false
        NotifyType      = $notificationType
        TaskName        = New-TimerTaskName -TimerId $id
    }

    # Save to data file
    $timers = @(Get-TimerData)
    $timers += $timer
    Save-TimerData -Timers $timers

    # Start the job
    Start-TimerJob -Timer $timer -Notify $notificationType

    # Display confirmation
    Write-Host ""
    Write-Host "  Timer started " -ForegroundColor Green -NoNewline
    Write-Host "[$id]" -ForegroundColor Cyan
    Write-Host "  Duration: " -ForegroundColor Gray -NoNewline
    Write-Host (Format-Duration -Seconds $seconds) -ForegroundColor White
    Write-Host "  Ends at:  " -ForegroundColor Gray -NoNewline
    Write-Host $endTime.ToString('HH:mm:ss') -ForegroundColor Yellow
    if ($Repeat -gt 1) {
        Write-Host "  Repeats:  " -ForegroundColor Gray -NoNewline
        Write-Host "$Repeat times" -ForegroundColor Magenta
    }
    Write-Host "  Message:  " -ForegroundColor Gray -NoNewline
    Write-Host $Message -ForegroundColor White
    Write-Host "  Notify:   " -ForegroundColor Gray -NoNewline
    Write-Host $notificationType -ForegroundColor Green
    Write-Host ""
}

function Start-SequenceTimer {
    <#
    .SYNOPSIS
        Starts a sequence-based timer (Pomodoro-style).
    .PARAMETER Pattern
        Sequence pattern string or preset name.
    .PARAMETER Notify
        Notification type: popup (default), toast, sound, silent.
    #>
    param(
        [string]$Pattern,
        [string]$Notify = $null
    )

    $originalPattern = $Pattern
    if ($script:TimerPresets.ContainsKey($Pattern)) {
        $Pattern = $script:TimerPresets[$Pattern].Pattern
    }

    try {
        $phases = @(ConvertFrom-TimerSequence -Pattern $Pattern)
    }
    catch {
        Write-Host "`n  Invalid sequence pattern: $Pattern" -ForegroundColor Red
        Write-Host "  Example: (25m work, 5m rest)x4, 30m break`n" -ForegroundColor DarkGray
        return
    }

    if ($phases.Count -eq 0) {
        Write-Host "`n  No phases found in pattern: $Pattern" -ForegroundColor Red
        return
    }

    $summary = Get-SequenceSummary -Phases $phases
    $id = New-TimerId
    $now = Get-Date
    $notificationType = Get-TimerNotificationType -Override $Notify
    $timer = New-SequenceTimerFromPhases -Id $id -OriginalPattern $originalPattern -Phases $phases -Summary $summary -Now $now -NotifyType $notificationType

    $timers = @(Get-TimerData)
    $timers += $timer
    Save-TimerData -Timers $timers
    Start-SequenceTimerJob -Timer $timer

    $firstPhase = $phases[0]
    $endTime = $now.AddSeconds($firstPhase.Seconds)
    Write-SequenceTimerConfirmation -Id $id -OriginalPattern $originalPattern -Summary $summary -PhaseCount $phases.Count -FirstPhase $firstPhase -EndTime $endTime
}

function Timer-List {
    <#
    .SYNOPSIS
        Shows all background timers with detailed status.
    .PARAMETER All
        Include completed/stopped timers in the list.
    .PARAMETER Watch
        Live-updating display with countdown. Press any key to exit.
    #>
    param(
        [Alias('a')][switch]$All,
        [Alias('w')][switch]$Watch
    )

    if ($Watch) {
        Show-TimerListWatch -All:$All
        return
    }

    Show-TimerListOnce -All:$All -ShowCommands
}

function Show-TimerListOnce {
    <#
    .SYNOPSIS
        Internal function to display timer list once.
    #>
    param(
        [switch]$All,
        [switch]$ShowCommands
    )

    $timers = @(Sync-TimerData)

    if ($timers.Count -eq 0) {
        Write-Host "`n  No timers found." -ForegroundColor Gray
        Write-Host "  Use 't <time>' to create one.`n" -ForegroundColor DarkGray
        return $false
    }

    # Filter if not showing all
    if (-not $All) {
        $timers = @($timers | Where-Object { $_.State -eq 'Running' -or $_.State -eq 'Paused' })
    }

    if ($timers.Count -eq 0) {
        Write-Host "`n  No active timers." -ForegroundColor Gray
        Write-Host "  Use 'Timer-List -a' to see all timers.`n" -ForegroundColor DarkGray
        return $false
    }

    # Count by state
    $running = @($timers | Where-Object { $_.State -eq 'Running' }).Count
    $paused = @($timers | Where-Object { $_.State -eq 'Paused' }).Count

    Write-Host ""
    Write-Host "  BACKGROUND TIMERS " -ForegroundColor Cyan -NoNewline
    Write-Host "($running running" -ForegroundColor Green -NoNewline
    if ($paused -gt 0) {
        Write-Host ", $paused paused" -ForegroundColor Yellow -NoNewline
    }
    Write-Host ")" -ForegroundColor Gray
    Write-Host "  =================" -ForegroundColor DarkCyan
    Write-Host ""

    # Column widths
    $colId = 5
    $colState = 10
    $colDuration = 11
    $colRemaining = 11
    $colProgress = 8
    $colEndsAt = 10
    $colPhase = 8

    # Header
    Write-Host "  " -NoNewline
    Write-Host ("{0,-$colId}" -f "ID") -ForegroundColor DarkGray -NoNewline
    Write-Host ("{0,-$colState}" -f "STATE") -ForegroundColor DarkGray -NoNewline
    Write-Host ("{0,-$colDuration}" -f "DURATION") -ForegroundColor DarkGray -NoNewline
    Write-Host ("{0,-$colRemaining}" -f "REMAINING") -ForegroundColor DarkGray -NoNewline
    Write-Host ("{0,-$colProgress}" -f "PROG") -ForegroundColor DarkGray -NoNewline
    Write-Host ("{0,-$colEndsAt}" -f "ENDS AT") -ForegroundColor DarkGray -NoNewline
    Write-Host ("{0,-$colPhase}" -f "PHASE") -ForegroundColor DarkGray -NoNewline
    Write-Host "MESSAGE" -ForegroundColor DarkGray
    Write-Host ("  " + ("-" * 83)) -ForegroundColor DarkGray

    $now = Get-Date
    foreach ($t in $timers) {
        $row = Get-TimerListRowDisplayData -Timer $t -Now $now
        Write-Host "  " -NoNewline
        Write-Host ("{0,-$colId}" -f $t.Id) -ForegroundColor Cyan -NoNewline
        Write-Host ("{0,-$colState}" -f $t.State) -ForegroundColor $row.StateColor -NoNewline
        Write-Host ("{0,-$colDuration}" -f $row.DurationStr) -ForegroundColor White -NoNewline
        Write-Host ("{0,-$colRemaining}" -f $row.RemainingStr) -ForegroundColor $row.RemainingColor -NoNewline
        Write-Host ("{0,-$colProgress}" -f $row.ProgressStr) -ForegroundColor $row.RemainingColor -NoNewline
        Write-Host ("{0,-$colEndsAt}" -f $row.EndsAtStr) -ForegroundColor $row.EndsColor -NoNewline
        Write-Host ("{0,-$colPhase}" -f $row.RepeatStr) -ForegroundColor $row.PhaseColor -NoNewline
        Write-Host $row.MsgDisplay -ForegroundColor Gray
    }

    Write-Host ""

    if ($ShowCommands) {
        Write-Host "  Pause " -ForegroundColor DarkGray -NoNewline
        Write-Host "tp <id>" -ForegroundColor White -NoNewline
        Write-Host " | Resume " -ForegroundColor DarkGray -NoNewline
        Write-Host "tr <id>" -ForegroundColor White -NoNewline
        Write-Host " | Delete " -ForegroundColor DarkGray -NoNewline
        Write-Host "td <id>" -ForegroundColor White -NoNewline
        Write-Host " | Watch " -ForegroundColor DarkGray -NoNewline
        Write-Host "tl -w" -ForegroundColor White
        Write-Host ""
    }

    return $true
}

function Show-TimerListWatch {
    <#
    .SYNOPSIS
        Live-updating timer list display. Press any key to exit.
    #>
    param(
        [switch]$All
    )

    $c = Get-AnsiColors
    [Console]::CursorVisible = $false
    $sw = [System.Diagnostics.Stopwatch]::new()

    try {
        $timers = @(Get-TimerData)

        while ($true) {
            $sw.Restart()
            $now = Get-Date

            $cacheResult = Get-TimerDataIfChanged
            if ($cacheResult.Changed) {
                $timers = @($cacheResult.Data)
            }

            $displayTimers = $timers
            if (-not $All) {
                $displayTimers = @($timers | Where-Object { $_.State -eq 'Running' -or $_.State -eq 'Paused' })
            }

            $sb = [System.Text.StringBuilder]::new()

            if ($displayTimers.Count -eq 0) {
                # Poll for next run: scheduled task may need a moment to write updated JSON (same as tw)
                $foundNextRun = $false
                $pollMs = @(500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000)
                foreach ($delay in $pollMs) {
                    Start-Sleep -Milliseconds $delay
                    $refresh = Get-TimerDataIfChanged -Force
                    $refreshedActive = @($refresh.Data | Where-Object { $_.State -eq 'Running' -or $_.State -eq 'Paused' })
                    if ($refreshedActive.Count -gt 0) {
                        $timers = @($refresh.Data)
                        $displayTimers = $refreshedActive
                        $foundNextRun = $true
                        break
                    }
                }
                if (-not $foundNextRun) {
                    [void]$sb.AppendLine("")
                    [void]$sb.AppendLine("$($c.Gray)  No active timers.$($c.Reset)")
                    Clear-Host
                    [Console]::Write($sb.ToString())
                    break
                }
            }

            $running = @($displayTimers | Where-Object { $_.State -eq 'Running' }).Count
            $paused = @($displayTimers | Where-Object { $_.State -eq 'Paused' }).Count

            [void]$sb.AppendLine("")
            $pausedPart = if ($paused -gt 0) { "$($c.Yellow), $paused paused$($c.Reset)" } else { "" }
            [void]$sb.AppendLine("$($c.Cyan)  BACKGROUND TIMERS $($c.Green)($running running${pausedPart}$($c.Green))$($c.Reset)")
            [void]$sb.AppendLine("$($c.DarkCyan)  =====================$($c.Reset)")
            [void]$sb.AppendLine("")

            $colWidths = @{ Id = 5; State = 10; Duration = 11; Remaining = 11; Progress = 8; EndsAt = 10; Phase = 8 }
            $hdr = "  {0,-5}{1,-10}{2,-11}{3,-11}{4,-8}{5,-10}{6,-8}MESSAGE" -f "ID", "STATE", "DURATION", "REMAINING", "PROG", "ENDS AT", "PHASE"
            [void]$sb.AppendLine("$($c.Gray)$hdr$($c.Reset)")
            [void]$sb.AppendLine("$($c.Gray)  $("-" * 83)$($c.Reset)")
            foreach ($t in $displayTimers) {
                [void]$sb.AppendLine((Get-TimerListWatchRowLine -Timer $t -Now $now -Colors $c -ColWidths $colWidths))
            }
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("$($c.Gray)  Press any key to exit watch mode...$($c.Reset)")
            Clear-Host
            [Console]::Write($sb.ToString())
            if (Wait-OneSecondOrKeyPress -Stopwatch $sw) {
                Write-Host ""
                return
            }
        }
    }
    finally {
        [Console]::CursorVisible = $true
    }
}

function Timer-Presets {
    <#
    .SYNOPSIS
        Shows interactive preset picker for common timer sequences.
    #>
    $options = @()
    foreach ($name in $script:TimerPresets.Keys | Sort-Object) {
        $preset = $script:TimerPresets[$name]
        $phases = ConvertFrom-TimerSequence -Pattern $preset.Pattern
        $summary = Get-SequenceSummary -Phases $phases

        $options += @{
            Id          = $name
            Label       = "$name - $($summary.TotalDuration) total ($($summary.PhaseCount) phases)"
            Description = $preset.Description
            Color       = 'White'
        }
    }

    $options += @{
        Id    = '_custom'
        Label = "[Enter custom sequence...]"
        Color = 'Cyan'
    }

    $selectedId = Show-MenuPicker -Title "SELECT TIMER PRESET" -Options $options -AllowCancel

    if (-not $selectedId) {
        return
    }

    if ($selectedId -eq '_custom') {
        Write-Host ""
        Write-Host "  Enter sequence pattern:" -ForegroundColor Cyan
        Write-Host "  Example: (25m work, 5m rest)x4, 30m break" -ForegroundColor DarkGray
        Write-Host ""
        $pattern = Read-Host "  Pattern"
        if ([string]::IsNullOrWhiteSpace($pattern)) {
            return
        }
        Timer -Time $pattern
    }
    else {
        Timer -Time $selectedId
    }
}

function Timer-Watch {
    <#
    .SYNOPSIS
        Watch a specific timer with live countdown and progress bar.
    .PARAMETER Id
        The timer ID to watch. If omitted and only one active timer exists, watches that one.
    #>
    param(
        [Parameter(Position=0)][string]$Id
    )

    $timers = @(Sync-TimerData)
    $result = Get-TimerForWatch -Timers $timers -Id $Id
    if ($result.Error) {
        if ($result.Error -eq 'NoActive') {
            Write-Host "`n  No active timers to watch." -ForegroundColor Gray
            Write-Host "  Use 't <time>' to create one.`n" -ForegroundColor DarkGray
        }
        elseif ($result.Error -eq 'NotFound') {
            Write-Host "`n  Timer '$($result.Id)' not found.`n" -ForegroundColor Red
        }
        elseif ($result.Error -eq 'NotRunning') {
            Write-Host "`n  Timer '$($result.Id)' is not running (state: $($result.State)).`n" -ForegroundColor Yellow
        }
        return
    }
    Show-TimerWatchDisplay -Timer $result.Timer
}

function Show-TimerWatchDisplay {
    <#
    .SYNOPSIS
        Internal function to display live timer watch with progress bar.
    #>
    param([PSCustomObject]$Timer)

    $c = Get-AnsiColors
    try { [Console]::CursorVisible = $false } catch { }
    $sw = [System.Diagnostics.Stopwatch]::new()

    try {
        $totalSeconds = $Timer.Seconds
        $endTime = [DateTime]::Parse($Timer.EndTime)
        $currentTimer = $Timer

        while ($true) {
            $sw.Restart()
            $now = Get-Date

            $cacheResult = Get-TimerDataIfChanged
            if ($cacheResult.Changed) {
                $currentTimer = $cacheResult.Data | Where-Object { $_.Id -eq $Timer.Id }
                if ($currentTimer -and $currentTimer.EndTime) {
                    $endTime = [DateTime]::Parse($currentTimer.EndTime)
                }
            }

            if (-not $currentTimer -or $currentTimer.State -ne 'Running') {
                Clear-Host
                Write-Host ""
                Write-Host "  Timer [$($Timer.Id)] is no longer running." -ForegroundColor Yellow
                Write-Host ""
                break
            }

            $remaining = $endTime - $now
            $remainingSeconds = [math]::Max(0, $remaining.TotalSeconds)
            $percent = Get-TimerProgress -Timer $currentTimer

            if ($remainingSeconds -le 0) {
                # Poll for next run/phase: scheduled task runs in separate process and may need several seconds to write updated JSON
                $foundNextRun = $false
                $pollMs = @(500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000)
                foreach ($delay in $pollMs) {
                    Start-Sleep -Milliseconds $delay
                    $refresh = Get-TimerDataIfChanged -Force
                    $refreshed = @($refresh.Data | Where-Object { [string]$_.Id -eq [string]$Timer.Id })[0]
                    if ($refreshed -and $refreshed.State -eq 'Running' -and $refreshed.EndTime) {
                        $refreshedEnd = [DateTime]::Parse($refreshed.EndTime)
                        if ($refreshedEnd -gt $now) {
                            $currentTimer = $refreshed
                            $endTime = $refreshedEnd
                            $totalSeconds = if ($refreshed.IsSequence) { $refreshed.TotalSeconds } else { $refreshed.Seconds }
                            $foundNextRun = $true
                            break
                        }
                    }
                }
                if ($foundNextRun) { continue }
                # Truly completed or stopped: show completed and exit
                $msg = if ($currentTimer) { if ($currentTimer.IsSequence) { $currentTimer.PhaseLabel } else { $currentTimer.Message } } else { $Timer.Message }
                $secs = if ($currentTimer) { if ($currentTimer.IsSequence) { $currentTimer.Seconds } else { $currentTimer.Seconds } } else { $totalSeconds }
                Clear-Host
                $sb = Get-TimerWatchCompletedContent -Colors $c -Message $msg -TotalSeconds $secs -EndTime $endTime
                [Console]::Write($sb.ToString())
                break
            }

            $endsAtStr = $endTime.ToString('HH:mm:ss')
            $sb = Get-TimerWatchRunningContent -Colors $c -CurrentTimer $currentTimer -Timer $Timer -Percent $percent -Remaining $remaining -EndsAtFormatted $endsAtStr
            $phaseSb = Get-TimerWatchPhaseTimelineContent -Colors $c -CurrentTimer $currentTimer
            if ($phaseSb) {
                [void]$sb.Append($phaseSb.ToString())
            }
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("$($c.Dim)  Press any key to exit watch mode...$($c.Reset)")
            Clear-Host
            [Console]::Write($sb.ToString())
            if (Wait-OneSecondOrKeyPress -Stopwatch $sw) {
                Write-Host ""
                return
            }
        }
    }
    finally {
        try { [Console]::CursorVisible = $true } catch { }
    }
}

function Timer-Pause {
    <#
    .SYNOPSIS
        Pauses a background timer. Shows picker if no ID specified.
    .PARAMETER Id
        The timer ID to pause. Use 'all' to pause all. Omit for picker.
    #>
    param(
        [Parameter(Position=0)][string]$Id
    )

    $timers = @(Get-TimerData)
    if ($timers.Count -eq 0) {
        Write-Host "`n  No timers to pause.`n" -ForegroundColor Gray
        return
    }

    if ([string]::IsNullOrEmpty($Id)) {
        $runningTimers = @($timers | Where-Object { $_.State -eq 'Running' })
        if ($runningTimers.Count -eq 0) {
            Write-Host "`n  No running timers to pause.`n" -ForegroundColor Gray
            return
        }
        $options = Get-TimerPickerOptions -Timers $runningTimers -FilterState 'Running' -ShowRemaining -IncludeAllOption -AllOptionLabel "Pause ALL running timers ($($runningTimers.Count) total)" -AllOptionColor 'Yellow'
        $selectedId = Show-MenuPicker -Title "SELECT TIMER TO PAUSE" -Options $options -AllowCancel
        if (-not $selectedId) { return }
        $Id = $selectedId
        $timers = @(Get-TimerData)
    }

    if ($Id -eq 'all') {
        $count = Invoke-PauseTimersBulk -Timers $timers
        Write-Host "`n  Paused $count timer(s).`n" -ForegroundColor Yellow
    }
    else {
        $remaining = Invoke-PauseSingleTimer -Timers $timers -Id $Id
        if ($remaining -eq $false) {
            Write-Host "`n  Timer '$Id' not found.`n" -ForegroundColor Red
        }
        elseif ($null -eq $remaining) {
            Write-Host "`n  Timer '$Id' is not running.`n" -ForegroundColor Yellow
        }
        else {
            Write-Host "`n  Timer " -ForegroundColor Yellow -NoNewline
            Write-Host "[$Id]" -ForegroundColor Cyan -NoNewline
            Write-Host " paused. " -ForegroundColor Yellow -NoNewline
            Write-Host "($(Format-Duration -Seconds $remaining) remaining)`n" -ForegroundColor Gray
        }
    }
}

function Timer-Resume {
    <#
    .SYNOPSIS
        Resumes a paused or lost timer. Shows picker if no ID specified.
    #>
    param(
        [Parameter(Position=0)][string]$Id
    )

    $timers = @(Get-TimerData)
    if ($timers.Count -eq 0) {
        Write-Host "`n  No timers to resume.`n" -ForegroundColor Gray
        return
    }

    if ([string]::IsNullOrEmpty($Id)) {
        $resumableTimers = @($timers | Where-Object { $_.State -eq 'Paused' -or $_.State -eq 'Lost' })
        if ($resumableTimers.Count -eq 0) {
            Write-Host "`n  No paused or lost timers to resume.`n" -ForegroundColor Gray
            return
        }
        $options = Get-TimerPickerOptions -Timers $resumableTimers -ShowRemaining -IncludeAllOption -AllOptionLabel "Resume ALL resumable timers ($($resumableTimers.Count) total)" -AllOptionColor 'Green'
        $selectedId = Show-MenuPicker -Title "SELECT TIMER TO RESUME" -Options $options -AllowCancel
        if (-not $selectedId) { return }
        $Id = $selectedId
        $timers = @(Get-TimerData)
    }

    if ($Id -eq 'all') {
        $count = Invoke-ResumeTimersBulk -Timers $timers
        Write-Host "`n  Resumed $count timer(s).`n" -ForegroundColor Green
    }
    else {
        $result = Invoke-ResumeSingleTimer -Timers $timers -Id $Id
        if (-not $result.Found) {
            Write-Host "`n  Timer '$Id' not found.`n" -ForegroundColor Red
        }
        elseif ($result.NoTime) {
            Write-Host "`n  Timer '$Id' has no time remaining.`n" -ForegroundColor Yellow
        }
        elseif (-not $result.CanResume) {
            Write-Host "`n  Timer '$Id' cannot be resumed.`n" -ForegroundColor Yellow
        }
        else {
            $action = if ($result.IsLost) { "restarted" } else { "resumed" }
            Write-Host "`n  Timer " -ForegroundColor Green -NoNewline
            Write-Host "[$Id]" -ForegroundColor Cyan -NoNewline
            Write-Host " $action. " -ForegroundColor Green -NoNewline
            Write-Host "Ends at $($result.NewEndTime.ToString('HH:mm:ss'))`n" -ForegroundColor Yellow
        }
    }
}

function Timer-Remove {
    <#
    .SYNOPSIS
        Removes a timer from the list by ID, or clears all finished timers.
    .PARAMETER Id
        The timer ID to remove. Use 'all' to remove all, 'done' to remove completed/stopped only.
    #>
    param(
        [Parameter(Position=0)][string]$Id
    )

    $timers = @(Get-TimerData)
    if ($timers.Count -eq 0) {
        Write-Host "`n  No timers to remove.`n" -ForegroundColor Gray
        return
    }

    if ([string]::IsNullOrEmpty($Id)) {
        $timers = @(Sync-TimerData)
        if ($timers.Count -eq 0) {
            Write-Host "`n  No timers to remove.`n" -ForegroundColor Gray
            return
        }
        $options = Get-TimerPickerOptions -Timers $timers -IncludeDoneOption -IncludeAllOption -AllOptionLabel "Remove ALL timers ($($timers.Count) total)" -AllOptionColor 'Red'
        if ($timers.Count -eq 1) {
            $options += @{ Id = 'all'; Label = "Remove ALL timers ($($timers.Count) total)"; Color = 'Red' }
        }
        $selectedId = Show-MenuPicker -Title "SELECT TIMER TO REMOVE" -Options $options -AllowCancel
        if (-not $selectedId) { return }
        $Id = $selectedId
        $timers = @(Get-TimerData)
    }

    if ($Id -eq 'all') {
        Invoke-RemoveTimersBulk -Timers $timers -Mode 'all' | Out-Null
        Write-Host "`n  All timers removed.`n" -ForegroundColor Yellow
    }
    elseif ($Id -eq 'done') {
        $removed = Invoke-RemoveTimersBulk -Timers $timers -Mode 'done'
        Write-Host "`n  Removed $removed finished timer(s).`n" -ForegroundColor Yellow
    }
    else {
        $removed = Invoke-RemoveSingleTimer -Timers $timers -Id $Id
        if (-not $removed) {
            Write-Host "`n  Timer '$Id' not found.`n" -ForegroundColor Red
        }
        else {
            Write-Host "`n  Timer " -ForegroundColor Yellow -NoNewline
            Write-Host "[$Id]" -ForegroundColor Cyan -NoNewline
            Write-Host " removed.`n" -ForegroundColor Yellow
        }
    }
}

# Backward-compatible wrappers (legacy names)
function TimerList { Timer-List @args }
function TimerWatch { Timer-Watch @args }
function TimerPause { Timer-Pause @args }
function TimerResume { Timer-Resume @args }
function TimerRemove { Timer-Remove @args }
function TimerPresets { Timer-Presets @args }

# endregion Timer-Main.ps1

# region Timer-Aliases.ps1
# Timer module - Aliases
# These aliases provide quick access to timer commands

Set-Alias -Name t -Value Timer -Scope Global
Set-Alias -Name tl -Value Timer-List -Scope Global
Set-Alias -Name tw -Value Timer-Watch -Scope Global
Set-Alias -Name tp -Value Timer-Pause -Scope Global
Set-Alias -Name tr -Value Timer-Resume -Scope Global
Set-Alias -Name td -Value Timer-Remove -Scope Global
Set-Alias -Name tpre -Value Timer-Presets -Scope Global
# endregion Timer-Aliases.ps1

