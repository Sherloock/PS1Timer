# Timer module (merged for faster profile load)
# Generated from core\Timer\*.ps1 in dependency order

# region Timer-Data.ps1
# Timer module - Data persistence and management

# Timer data file path (shared across timer functions)
$script:TimerDataFile = Join-Path $env:TEMP "ps-timers.json"
$script:TimerHistoryFile = Join-Path $env:TEMP "ps-timer-history.json"
# Cache for watch mode optimization
$script:TimerDataCache = $null
$script:TimerDataCacheTime = [DateTime]::MinValue
$script:PS1TimerPwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
# Tests set $true so Register-ScheduledTask mocks apply in-process
$script:TimerForceSyncRegister = $false
# Cached PSTimer_* scheduled task names (avoids repeated COM/CIM enumeration)
$script:TimerTaskNameCache = $null
$script:TimerTaskNameCacheTime = [DateTime]::MinValue
$script:TimerTaskNameCacheTtlSeconds = 2

function Get-TimerData {
    <#
    .SYNOPSIS
        Loads timer metadata from JSON file (uses file-change cache).
    #>
    param([switch]$Force)

    $data = (Get-TimerDataIfChanged -Force:$Force).Data
    if ($null -eq $data) {
        return @()
    }
    if ($data -isnot [System.Array]) {
        return @($data)
    }
    return [object[]]$data
}

function Read-TimerDataFromFile {
    <#
    .SYNOPSIS
        Reads and parses ps-timers.json from disk.
    #>
    if (-not (Test-Path -LiteralPath $script:TimerDataFile)) {
        return @()
    }

    try {
        $content = [System.IO.File]::ReadAllText($script:TimerDataFile)
        if ([string]::IsNullOrWhiteSpace($content)) {
            return @()
        }

        $data = $content | ConvertFrom-Json
        if ($null -eq $data) {
            return @()
        }
        if ($data -is [System.Array]) {
            if ($data.Count -eq 0) {
                return @()
            }
            return @($data)
        }
        if ($null -ne $data.PSObject.Properties['Id']) {
            return @($data)
        }
    }
    catch {
        # File corrupted or empty
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
    if (-not $fileInfo -or $fileInfo.Length -eq 0) {
        $script:TimerDataCache = @()
        $script:TimerDataCacheTime = if ($fileInfo) { $fileInfo.LastWriteTime } else { [DateTime]::MinValue }
        return @{ Data = @(); Changed = $true }
    }

    $lastWrite = $fileInfo.LastWriteTime

    # Check if file was modified since last cache
    if (-not $Force -and $script:TimerDataCache -ne $null -and $lastWrite -le $script:TimerDataCacheTime) {
        return @{ Data = $script:TimerDataCache; Changed = $false }
    }

    # File changed or no cache - read fresh data
    $script:TimerDataCache = @(Read-TimerDataFromFile)
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
        $utf8Bom = New-Object System.Text.UTF8Encoding $true
        [System.IO.File]::WriteAllText($script:TimerDataFile, '[]', $utf8Bom)
        $script:TimerDataCache = @()
        $fileInfo = Get-Item -LiteralPath $script:TimerDataFile -ErrorAction SilentlyContinue
        $script:TimerDataCacheTime = if ($fileInfo) { $fileInfo.LastWriteTime } else { Get-Date }
        return
    }

    # Flatten and clean the array before saving
    $clean = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $Timers) {
        if ($null -ne $t -and $null -ne $t.PSObject.Properties['Id']) {
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
            if ($t.PSObject.Properties.Name -contains 'NotifyType' -and $t.NotifyType) {
                $obj | Add-Member -NotePropertyName 'NotifyType' -NotePropertyValue $t.NotifyType
            }
            if ($t.PSObject.Properties.Name -contains 'WebhookName' -and $t.WebhookName) {
                $obj | Add-Member -NotePropertyName 'WebhookName' -NotePropertyValue $t.WebhookName
            }

            if ($t.IsSequence) {
                $obj | Add-Member -NotePropertyName 'SequencePattern' -NotePropertyValue $t.SequencePattern
                $obj | Add-Member -NotePropertyName 'Phases' -NotePropertyValue $t.Phases
                $obj | Add-Member -NotePropertyName 'CurrentPhase' -NotePropertyValue ([int]$t.CurrentPhase)
                $obj | Add-Member -NotePropertyName 'TotalPhases' -NotePropertyValue ([int]$t.TotalPhases)
                $obj | Add-Member -NotePropertyName 'PhaseLabel' -NotePropertyValue $t.PhaseLabel
                $obj | Add-Member -NotePropertyName 'TotalSeconds' -NotePropertyValue ([int]$t.TotalSeconds)
            }

            $clean.Add($obj)
        }
    }

    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($script:TimerDataFile, (ConvertTo-Json -InputObject $clean -Depth 10 -Compress), $utf8Bom)
    $script:TimerDataCache = @($clean)
    $fileInfo = Get-Item -LiteralPath $script:TimerDataFile -ErrorAction SilentlyContinue
    $script:TimerDataCacheTime = if ($fileInfo) { $fileInfo.LastWriteTime } else { Get-Date }
}

function Invoke-TimerFireScriptRecovery {
    <#
    .SYNOPSIS
        Runs the timer fire script when a scheduled task failed to complete the timer.
    #>
    param([PSCustomObject]$Timer)

    $scriptPath = Join-Path $env:TEMP "PSTimer_$($Timer.Id).ps1"
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        return $false
    }

    $log = Join-Path $env:TEMP "PSTimer_$($Timer.Id).log"
    try {
        $null = [scriptblock]::Create((Get-Content -LiteralPath $scriptPath -Raw))
    }
    catch {
        "$(Get-Date -Format 'o') WARN fire script parse, regenerating: $($_.Exception.Message)" | Add-Content -LiteralPath $log -Force
        if ($Timer.IsSequence) {
            Start-SequenceTimerJob -Timer $Timer
        }
        else {
            $webhookUrl = if ($Timer.WebhookName) { Resolve-TimerWebhookUrl -Name $Timer.WebhookName } else { $null }
            $notify = if ($Timer.NotifyType) { $Timer.NotifyType } else { 'popup' }
            Start-TimerJob -Timer $Timer -Notify $notify -WebhookUrl $webhookUrl
        }
        try {
            $null = [scriptblock]::Create((Get-Content -LiteralPath $scriptPath -Raw))
        }
        catch {
            "$(Get-Date -Format 'o') ERROR fire script still invalid: $($_.Exception.Message)" | Add-Content -LiteralPath $log -Force
            return $false
        }
    }

    try {
        & $scriptPath
        return $true
    }
    catch {
        "$(Get-Date -Format 'o') ERROR fire script recovery: $($_.Exception.Message)" | Add-Content -LiteralPath $log -Force
        return $false
    }
}

function Remove-StalePSTimerScheduledTasks {
    <#
    .SYNOPSIS
        Deletes PSTimer_* tasks that are not referenced by any timer record.
    #>
    $activeNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($t in @(Get-TimerData)) {
        if ($t.TaskName) { [void]$activeNames.Add([string]$t.TaskName) }
    }

    $existing = Get-PSTimerScheduledTaskNames -ForceRefresh
    if ($null -eq $existing) { return 0 }

    $removed = 0
    foreach ($name in $existing) {
        if ($activeNames.Contains($name)) { continue }
        Remove-TimerScheduledTaskByName -TaskName $name
        $removed++
    }

    if ($removed -gt 0) {
        Clear-TimerScheduledTaskNameCache
    }

    return $removed
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
    $now = Get-Date
    $taskNames = $null

    foreach ($timer in $timers) {
        if ($timer.State -ne 'Running' -and $timer.State -ne 'Scheduled') { continue }

        try {
            $endTime = [DateTime]::Parse($timer.EndTime)
            $remaining = [int]($endTime - $now).TotalSeconds
        }
        catch {
            $timer.State = 'Lost'
            $timer | Add-Member -NotePropertyName 'RemainingSeconds' -NotePropertyValue $timer.Seconds -Force
            $changed = $true
            continue
        }

        if ($remaining -le -10) {
            $null = Invoke-TimerFireScriptRecovery -Timer $timer
            $refreshed = Find-TimerById -Timers @(Get-TimerData -Force) -Id $timer.Id
            if ($refreshed -and $refreshed.State -ne $timer.State) {
                $timer.State = $refreshed.State
                $changed = $true
            }
            if ($timer.State -ne 'Running' -and $timer.State -ne 'Scheduled') {
                continue
            }
        }

        # Trust JSON while the phase still has time left (avoids scheduler lookup per timer)
        if ($remaining -gt 2) { continue }

        $taskName = Get-TimerTaskName -Timer $timer
        if ($null -eq $taskNames) {
            $taskNames = Get-PSTimerScheduledTaskNames
        }

        if ($null -ne $taskNames -and $taskNames.Contains($taskName)) {
            continue
        }

        if ($remaining -le 0) {
            $timer.State = 'Lost'
            $timer | Add-Member -NotePropertyName 'RemainingSeconds' -NotePropertyValue 0 -Force
            $changed = $true
        }
    }

    if ($changed) {
        Save-TimerData -Timers $timers
        $timers = @(Get-TimerData -Force)
    }

    if (-not $script:TimerForceSyncRegister) {
        $null = Remove-StalePSTimerScheduledTasks
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

    if ($null -ne $Timer.PSObject.Properties['TaskName'] -and -not [string]::IsNullOrWhiteSpace($Timer.TaskName)) {
        return $Timer.TaskName
    }

    return "PSTimer_$($Timer.Id)"
}

function Find-TimerById {
    <#
    .SYNOPSIS
        Finds a timer in an array by id (linear scan, no pipeline).
    #>
    param(
        [array]$Timers,
        [string]$Id
    )

    foreach ($t in $Timers) {
        if ([string]$t.Id -eq [string]$Id) {
            return $t
        }
    }

    return $null
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
    $active = @($Timers | Where-Object { $_.State -eq 'Running' -or $_.State -eq 'Scheduled' })
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
    if ($t.State -ne 'Running' -and $t.State -ne 'Scheduled') {
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
    $theme = 'default'
    if ($global:Config -and $global:Config.TimerDefaults -and $global:Config.TimerDefaults.Theme) {
        $theme = $global:Config.TimerDefaults.Theme.ToLower()
    }

    $palettes = if ($global:Config -and $global:Config.Palettes) {
        $global:Config.Palettes
    } else {
        Get-DefaultTimerPalettes
    }

    $paletteEntry = if ($palettes.ContainsKey($theme)) { $palettes[$theme] } else { $palettes['default'] }
    if (-not $paletteEntry) {
        $paletteEntry = (Get-DefaultTimerPalettes)['default']
    }
    $palette = Resolve-TimerPaletteColors -PaletteEntry $paletteEntry
    return @{
        Esc          = $esc
        Reset        = "$esc[0m"
        Bold         = "$esc[1m"
        Dim          = "$esc[2m"
        Primary      = $palette.Primary
        PrimaryMuted = $palette.PrimaryMuted
        Text         = $palette.Text
        Muted        = $palette.Muted
        Success      = $palette.Success
        Warning      = $palette.Warning
        Danger       = $palette.Danger
        Accent       = $palette.Accent
        Selected     = $palette.Selected
        Theme        = $theme
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
        'Scheduled' { 'Cyan' }
        'Completed' { 'DarkGray' }
        'Paused'    { 'Yellow' }
        'Lost'      { 'Red' }
        default     { 'Gray' }
    }

    if ($Ansi) {
        $colors = Get-AnsiColors
        $result = switch ($colorName) {
            'Green'    { $colors.Success }
            'Cyan'     { $colors.Primary }
            'DarkGray' { $colors.Muted }
            'Yellow'   { $colors.Warning }
            'Red'      { $colors.Danger }
            default    { $colors.Muted }
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

    if ($Timer.State -eq 'Scheduled') {
        $now = Get-Date
        $startTime = [DateTime]::Parse($Timer.StartTime)
        $endTime = [DateTime]::Parse($Timer.EndTime)
        if ($now -lt $startTime) { return [double]0 }
        if ($now -ge $endTime) { return [double]100 }
        $elapsed = ($now - $startTime).TotalSeconds
        $total = ($endTime - $startTime).TotalSeconds
        if ($total -le 0) { return [double]0 }
        return [math]::Min(100.0, [math]::Max(0.0, ($elapsed / $total) * 100))
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

function Get-TimerFinalEndTime {
    <#
    .SYNOPSIS
        Returns when the timer fully completes (all phases or repeats), not just the current run/phase.
    #>
    param(
        [PSCustomObject]$Timer,
        [DateTime]$Now = (Get-Date)
    )

    if ($Timer.IsSequence) {
        $startTime = [DateTime]::Parse($Timer.StartTime)
        if ($Timer.State -eq 'Scheduled' -and $Now -lt $startTime) {
            return $startTime.AddSeconds([int]$Timer.TotalSeconds)
        }

        $endTime = [DateTime]::Parse($Timer.EndTime)
        $futureSeconds = 0
        if ($Timer.Phases) {
            $currentPhase = [int]$Timer.CurrentPhase
            for ($i = $currentPhase + 1; $i -lt $Timer.Phases.Count; $i++) {
                $futureSeconds += [int]$Timer.Phases[$i].Seconds
            }
        }
        return $endTime.AddSeconds($futureSeconds)
    }

    $runSeconds = [int]$Timer.Seconds
    $repeatRemaining = if ($null -ne $Timer.RepeatRemaining) { [int]$Timer.RepeatRemaining } else { 0 }
    $repeatTotal = if ($Timer.RepeatTotal -gt 0) { [int]$Timer.RepeatTotal } else { 1 }

    if ($Timer.State -eq 'Scheduled') {
        $startTime = [DateTime]::Parse($Timer.StartTime)
        if ($Now -lt $startTime) {
            return $startTime.AddSeconds($runSeconds * $repeatTotal)
        }
    }

    $endTime = [DateTime]::Parse($Timer.EndTime)
    return $endTime.AddSeconds($repeatRemaining * $runSeconds)
}

function Get-SequencePhaseEndTime {
    <#
    .SYNOPSIS
        Returns when a sequence phase ends (by phase index).
    #>
    param(
        [PSCustomObject]$Timer,
        [int]$PhaseIndex,
        [DateTime]$Now = (Get-Date)
    )

    if (-not $Timer.Phases -or $PhaseIndex -lt 0 -or $PhaseIndex -ge $Timer.Phases.Count) {
        return $null
    }

    $currentPhase = [int]$Timer.CurrentPhase
    $startTime = [DateTime]::Parse($Timer.StartTime)
    $endTime = [DateTime]::Parse($Timer.EndTime)

    if ($Timer.State -eq 'Scheduled' -and $Now -lt $startTime) {
        $elapsed = 0
        for ($i = 0; $i -le $PhaseIndex; $i++) {
            $elapsed += [int]$Timer.Phases[$i].Seconds
        }
        return $startTime.AddSeconds($elapsed)
    }

    if ($PhaseIndex -eq $currentPhase) {
        return $endTime
    }
    if ($PhaseIndex -gt $currentPhase) {
        $futureSeconds = 0
        for ($i = $currentPhase + 1; $i -le $PhaseIndex; $i++) {
            $futureSeconds += [int]$Timer.Phases[$i].Seconds
        }
        return $endTime.AddSeconds($futureSeconds)
    }

    $pastSeconds = 0
    for ($i = $PhaseIndex + 1; $i -lt $currentPhase; $i++) {
        $pastSeconds += [int]$Timer.Phases[$i].Seconds
    }
    return $startTime.AddSeconds(-$pastSeconds)
}

function Test-TimerIsActiveDisplay {
    <#
    .SYNOPSIS
        Returns whether the timer state should show remaining time and ends-at.
    #>
    param([string]$State)
    return ($State -eq 'Running' -or $State -eq 'Scheduled' -or $State -eq 'Paused' -or $State -eq 'Lost')
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
    if ($State -eq 'Scheduled') {
        return @{ RemainingColor = 'Cyan'; EndsColor = 'Cyan' }
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
        if ($Timer.State -eq 'Scheduled') {
            $startTime = [DateTime]::Parse($Timer.StartTime)
            if ($Now -lt $startTime) {
                $untilStart = $startTime - $Now
                $remainingStr = 'in ' + (Format-RemainingTime -Remaining $untilStart)
                $endsAtStr = $startTime.ToString('HH:mm:ss')
                $progressStr = 'wait'
            }
            else {
                $endsAtStr = $endTime.ToString('HH:mm:ss')
            }
        }
        elseif ($Timer.State -eq 'Running') {
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
    $phaseColor = if ($Timer.IsSequence) { $Colors.Primary } else { $Colors.Accent }
    $id = $ColWidths.Id; $st = $ColWidths.State; $dur = $ColWidths.Duration
    $rem = $ColWidths.Remaining; $prog = $ColWidths.Progress; $end = $ColWidths.EndsAt; $ph = $ColWidths.Phase
    return "  $($Colors.Primary){0,-$id}$($Colors.Reset)${stateColor}{1,-$st}$($Colors.Reset)$($Colors.Text){2,-$dur}$($Colors.Reset)$($Colors.Warning){3,-$rem}$($Colors.Reset)$($Colors.Success){4,-$prog}$($Colors.Reset)$($Colors.Success){5,-$end}$($Colors.Reset)${phaseColor}{6,-$ph}$($Colors.Reset)$($Colors.Muted){7}$($Colors.Reset)" -f $Timer.Id, $Timer.State, $row.DurationStr, $row.RemainingStr, $row.ProgressStr, $row.EndsAtStr, $row.RepeatStr, $row.MsgDisplay
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

function Format-TimerWatchRow {
    <#
    .SYNOPSIS
        Formats a left-aligned label/value row for watch display.
    #>
    param(
        [hashtable]$Colors,
        [string]$Label,
        [string]$Value,
        [string]$ValueAnsi = $null
    )
    $valueCode = if ($ValueAnsi) { $ValueAnsi } else { $Colors.Text }
    return '  ' + $Colors.Dim + ($Label.PadRight(11)) + $Colors.Reset + $valueCode + $Value + $Colors.Reset
}

function Get-TimerWatchSeparator {
    param(
        [hashtable]$Colors,
        [int]$Width = 40
    )
    return '  ' + $Colors.Dim + ('-' * $Width) + $Colors.Reset
}

function Get-TimerWatchProgressBar {
    param(
        [hashtable]$Colors,
        [double]$Percent,
        [int]$Width = 32,
        [switch]$Waiting
    )
    $barFull = [char]0x2588
    $barEmpty = [char]0x2591
    if ($Waiting) {
        $filled = ''
        $empty = [string]$barEmpty * $Width
        $pct = 'wait'
        $barColor = $Colors.Primary
    }
    else {
        $filledCount = [int][math]::Floor(($Percent / 100) * $Width)
        $emptyCount = [int]($Width - $filledCount)
        $filled = [string]$barFull * $filledCount
        $empty = [string]$barEmpty * $emptyCount
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        $pct = $Percent.ToString('0', $inv) + '%'
        $barColor = Get-TimerProgressBarColor -Colors $Colors -Percent $Percent
    }
    return '  ' + $barColor + $filled + $Colors.Dim + $empty + $Colors.Reset + '  ' + $Colors.Bold + $pct + $Colors.Reset
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
    $durStr = Format-Duration -Seconds $TotalSeconds
    $endStr = $EndTime.ToString('HH:mm:ss')
    $c = $Colors
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('  ' + $c.Success + $c.Bold + 'DONE' + $c.Reset)
    [void]$sb.AppendLine((Get-TimerWatchSeparator -Colors $c))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine((Format-TimerWatchRow -Colors $c -Label 'Message' -Value $Message))
    [void]$sb.AppendLine((Format-TimerWatchRow -Colors $c -Label 'Duration' -Value $durStr))
    [void]$sb.AppendLine((Format-TimerWatchRow -Colors $c -Label 'Finished' -Value $endStr -ValueAnsi $c.Success))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine((Get-TimerWatchProgressBar -Colors $c -Percent 100))
    [void]$sb.AppendLine('')
    return $sb
}

function Get-TimerProgressBarColor {
    param(
        [hashtable]$Colors,
        [double]$Percent
    )
    $remainingPct = 100 - $Percent
    if ($remainingPct -le 10) { return $Colors.Danger }
    if ($remainingPct -le 25) { return $Colors.Warning }
    return $Colors.Success
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
    $remainingStr = Format-RemainingTime -Remaining $Remaining
    $waiting = $false
    $c = $Colors
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('')
    $timerId = $Timer.Id

    $titleLabel = if ($CurrentTimer.IsSequence) { 'SEQUENCE' } else { 'TIMER' }
    [void]$sb.AppendLine('  ' + $c.Primary + $c.Bold + "$titleLabel [$timerId]" + $c.Reset)
    [void]$sb.AppendLine((Get-TimerWatchSeparator -Colors $c))
    [void]$sb.AppendLine('')

    if ($CurrentTimer.IsSequence) {
        $phaseNum = [int]$CurrentTimer.CurrentPhase + 1
        $phaseTitle = "Phase $phaseNum of $($CurrentTimer.TotalPhases)"
        [void]$sb.AppendLine((Format-TimerWatchRow -Colors $c -Label 'Phase' -Value $phaseTitle -ValueAnsi ($c.Text + $c.Bold)))
        [void]$sb.AppendLine((Format-TimerWatchRow -Colors $c -Label 'Label' -Value $CurrentTimer.PhaseLabel))
        $phaseDur = Format-Duration -Seconds $CurrentTimer.Seconds
        [void]$sb.AppendLine((Format-TimerWatchRow -Colors $c -Label 'This phase' -Value $phaseDur))
    }
    else {
        [void]$sb.AppendLine((Format-TimerWatchRow -Colors $c -Label 'Message' -Value $Timer.Message -ValueAnsi ($c.Text + $c.Bold)))
        $msgDur = Format-Duration -Seconds $Timer.Seconds
        [void]$sb.AppendLine((Format-TimerWatchRow -Colors $c -Label 'Duration' -Value $msgDur))
        if ($Timer.RepeatTotal -gt 1) {
            $repStr = "$($CurrentTimer.CurrentRun) of $($Timer.RepeatTotal)"
            [void]$sb.AppendLine((Format-TimerWatchRow -Colors $c -Label 'Repeat' -Value $repStr -ValueAnsi $c.Accent))
        }
    }

    $showFinalEnd = $CurrentTimer.IsSequence -or ([int]$CurrentTimer.RepeatTotal -gt 1)
    $now = Get-Date

    if ($CurrentTimer.State -eq 'Scheduled') {
        $startTime = [DateTime]::Parse($CurrentTimer.StartTime)
        if ($now -lt $startTime) {
            $remainingStr = Format-RemainingTime -Remaining ($startTime - $now)
            $waiting = $true
            [void]$sb.AppendLine((Format-TimerWatchRow -Colors $c -Label 'Starts' -Value $startTime.ToString('HH:mm:ss') -ValueAnsi $c.Primary))
            [void]$sb.AppendLine((Format-TimerWatchRow -Colors $c -Label 'Countdown' -Value $remainingStr -ValueAnsi ($c.Warning + $c.Bold)))
            if ($showFinalEnd) {
                $finalEndStr = (Get-TimerFinalEndTime -Timer $CurrentTimer -Now $now).ToString('HH:mm:ss')
                [void]$sb.AppendLine((Format-TimerWatchRow -Colors $c -Label 'Final end' -Value $finalEndStr -ValueAnsi $c.Accent))
            }
        }
    }

    if (-not $waiting) {
        if (-not $CurrentTimer.IsSequence) {
            [void]$sb.AppendLine((Format-TimerWatchRow -Colors $c -Label 'Ends' -Value $EndsAtFormatted -ValueAnsi $c.Warning))
        }
        [void]$sb.AppendLine((Format-TimerWatchRow -Colors $c -Label 'Remaining' -Value $remainingStr -ValueAnsi ($c.Warning + $c.Bold)))
        if ($CurrentTimer.IsSequence) {
            $finalEndStr = (Get-TimerFinalEndTime -Timer $CurrentTimer -Now $now).ToString('HH:mm:ss')
            [void]$sb.AppendLine((Format-TimerWatchRow -Colors $c -Label 'Final end' -Value $finalEndStr -ValueAnsi $c.Accent))
        }
        elseif ($showFinalEnd) {
            $finalEndStr = (Get-TimerFinalEndTime -Timer $CurrentTimer -Now $now).ToString('HH:mm:ss')
            if ($finalEndStr -ne $EndsAtFormatted) {
                [void]$sb.AppendLine((Format-TimerWatchRow -Colors $c -Label 'Final end' -Value $finalEndStr -ValueAnsi $c.Accent))
            }
        }
    }

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine((Get-TimerWatchProgressBar -Colors $c -Percent $Percent -Waiting:$waiting))
    [void]$sb.AppendLine('')

    if ($CurrentTimer.IsSequence) {
        $seqTotal = Format-Duration -Seconds $CurrentTimer.TotalSeconds
        [void]$sb.AppendLine((Format-TimerWatchRow -Colors $c -Label 'Seq. total' -Value $seqTotal -ValueAnsi $c.Primary))
        [void]$sb.AppendLine('')
    }

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
    [void]$sb.AppendLine((Get-TimerWatchSeparator -Colors $c))
    [void]$sb.AppendLine('  ' + $c.Primary + 'Phases' + $c.Reset)
    $phases = $CurrentTimer.Phases
    $maxShow = [math]::Min(5, $phases.Count)
    $startIdx = [math]::Max(0, [int]$CurrentTimer.CurrentPhase - 1)
    $endIdx = [math]::Min($phases.Count - 1, $startIdx + $maxShow - 1)
    $now = Get-Date
    for ($i = $startIdx; $i -le $endIdx; $i++) {
        $phase = $phases[$i]
        $pNum = $i + 1
        $phaseDur = Format-Duration -Seconds $phase.Seconds
        $isCurrent = ($i -eq [int]$CurrentTimer.CurrentPhase)
        $isDone = ($i -lt [int]$CurrentTimer.CurrentPhase)

        if ($isDone) {
            $prefix = $c.Success + '  [x] '
            $textColor = $c.Dim
            $endColor = $c.Dim
        }
        elseif ($isCurrent) {
            $prefix = $c.Warning + '  > '
            $textColor = $c.Text + $c.Bold
            $endColor = $c.Warning
        }
        else {
            $prefix = $c.Dim + '    '
            $textColor = $c.Dim
            $endColor = $c.Muted
        }

        $phaseEnd = Get-SequencePhaseEndTime -Timer $CurrentTimer -PhaseIndex $i -Now $now
        $endSuffix = if ($phaseEnd) { $endColor + ' @ ' + $phaseEnd.ToString('HH:mm:ss') + $c.Reset } else { '' }
        $line = $prefix + $textColor + "$pNum. $($phase.Label) ($phaseDur)" + $c.Reset + $endSuffix
        [void]$sb.AppendLine($line)
    }
    if ($endIdx -lt $phases.Count - 1) {
        $moreCount = $phases.Count - $endIdx - 1
        [void]$sb.AppendLine('  ' + $c.Dim + "... $moreCount more" + $c.Reset)
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
        Notify    = 'popup'
        Webhook   = $null
        SoundFile = $null
    }

    if ($global:Config -and $global:Config.TimerDefaults) {
        $config = $global:Config.TimerDefaults
        if ($config.Notify) { $defaults.Notify = $config.Notify }
        if ($config.Webhook) { $defaults.Webhook = $config.Webhook }
        if ($config.SoundFile) { $defaults.SoundFile = $config.SoundFile }
    }

    return $defaults
}

function Resolve-TimerNotificationSettings {
    <#
    .SYNOPSIS
        Resolves notify type and named webhook for a new timer.
    #>
    param(
        [string]$NotifyOverride = $null,
        [string]$WebhookOverride = $null,
        [string]$PresetNotify = $null,
        [string]$PresetWebhook = $null
    )

    $validTypes = @('popup', 'toast', 'sound', 'silent', 'webhook')
    $notify = $null
    $webhookName = $null

    if ($NotifyOverride -and ($validTypes -contains $NotifyOverride.ToLower())) {
        $notify = $NotifyOverride.ToLower()
    }
    elseif ($PresetNotify -and ($validTypes -contains $PresetNotify.ToLower())) {
        $notify = $PresetNotify.ToLower()
    }
    else {
        $config = Get-TimerNotificationConfig
        if ($config.Notify -and ($validTypes -contains $config.Notify.ToLower())) {
            $notify = $config.Notify.ToLower()
        }
        else {
            $notify = 'popup'
        }
    }

    if ($WebhookOverride) {
        $webhookName = $WebhookOverride
    }
    elseif ($PresetWebhook) {
        $webhookName = $PresetWebhook
    }
    else {
        $config = Get-TimerNotificationConfig
        $webhookName = $config.Webhook
    }

    $webhookUrl = $null
    if ($notify -eq 'webhook') {
        $webhookUrl = Resolve-TimerWebhookUrl -Name $webhookName
        if (-not $webhookUrl) {
            Write-Warning "PS1Timer: webhook notify requires a valid -Webhook name (configured in Config.Webhooks)."
            $notify = 'popup'
        }
    }

    return @{
        NotifyType  = $notify
        WebhookName = $webhookName
        WebhookUrl  = $webhookUrl
    }
}

function Get-TimerFireScriptWebhookBlock {
    <#
    .SYNOPSIS
        PowerShell switch branch for webhook notifications in fire scripts.
    #>
    param([string]$WebhookUrl)
    if ([string]::IsNullOrWhiteSpace($WebhookUrl)) { return "    'webhook' { }" }
    $escapedUrl = $WebhookUrl -replace "'", "''"
    return @"
    'webhook' {
        try {
            `$payload = @{ content = (`$body -join ' | ') } | ConvertTo-Json -Compress
            Invoke-RestMethod -Uri '$escapedUrl' -Method Post -Body `$payload -ContentType 'application/json' -TimeoutSec 15 | Out-Null
        } catch {
            "`$(Get-Date -Format 'o') ERROR webhook: `$(`$_.Exception.Message)" | Add-Content -LiteralPath `$logFile -Force
        }
    }
"@
}

function Get-TimerFireScriptHistoryBlock {
    <#
    .SYNOPSIS
        PowerShell block appended to fire scripts to record completion history.
    #>
    param(
        [string]$TimerIdExpr,
        [string]$LabelExpr,
        [string]$SecondsExpr,
        [string]$IsSequenceExpr
    )
    return @"

try {
    `$historyFile = Join-Path `$env:TEMP 'ps-timer-history.json'
    `$entry = [PSCustomObject]@{
        TimerId     = $TimerIdExpr
        Label       = $LabelExpr
        Seconds     = [int]$SecondsExpr
        CompletedAt = (Get-Date).ToString('o')
        IsSequence  = [bool]$IsSequenceExpr
    }
    `$history = @()
    if (Test-Path -LiteralPath `$historyFile) {
        `$raw = Get-Content -LiteralPath `$historyFile -Raw -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace(`$raw)) {
            `$parsed = `$raw | ConvertFrom-Json
            if (`$parsed -is [array]) { `$history = @(`$parsed) } elseif (`$parsed) { `$history = @(`$parsed) }
        }
    }
    `$history += `$entry
    `$utf8Hist = New-Object System.Text.UTF8Encoding `$true
    [System.IO.File]::WriteAllText(`$historyFile, (ConvertTo-Json -InputObject `$history -Depth 5 -Compress), `$utf8Hist)
} catch { }
"@
}

function Get-TimerAfterStartAction {
    <#
    .SYNOPSIS
        Resolves AfterStart behavior from config or per-command override.
    #>
    param([string]$Override = $null)

    $valid = @('none', 'watch', 'list')
    if ($Override -and ($valid -contains $Override)) {
        return $Override
    }
    if ($global:Config -and $global:Config.TimerDefaults -and $global:Config.TimerDefaults.AfterStart) {
        $configured = $global:Config.TimerDefaults.AfterStart
        if ($valid -contains $configured) {
            return $configured
        }
    }
    return 'none'
}

function Invoke-TimerAfterStart {
    <#
    .SYNOPSIS
        Runs configured post-start UI (watch new timer or live list).
    #>
    param(
        [Parameter(Mandatory)][string]$TimerId,
        [string]$AfterStart = $null
    )

    switch (Get-TimerAfterStartAction -Override $AfterStart) {
        'watch' { Timer-Watch -Id $TimerId }
        'list'  { Timer-List -Watch }
    }
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
        [ValidateSet('popup', 'toast', 'sound', 'silent', 'webhook')]
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
        'webhook' {
            # Webhook is handled in scheduled-task fire scripts
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

    $settings = Resolve-TimerNotificationSettings -NotifyOverride $Override
    return $settings.NotifyType
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
    Write-Host "    t 25m -Notify webhook -Webhook discord-main" -ForegroundColor DarkGray
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
    Write-Host "    webhook  " -ForegroundColor Green -NoNewline
    Write-Host "POST to named URL from Config.Webhooks" -ForegroundColor White
    Write-Host ""
    Write-Host "  Default Configuration (config.ps1):" -ForegroundColor Yellow
    Write-Host "    TimerDefaults = @{" -ForegroundColor Gray
    Write-Host "        Notify = 'toast'" -ForegroundColor Gray
    Write-Host "        Webhook = 'discord-main'  # When Notify = webhook" -ForegroundColor Gray
    Write-Host "        SoundFile = 'C:\\path\\to\\sound.wav'  # Optional" -ForegroundColor Gray
    Write-Host "    }" -ForegroundColor Gray
    Write-Host "    Webhooks = @{ 'discord-main' = 'https://...' }" -ForegroundColor Gray
    Write-Host ""
}
# endregion Timer-Notifications.ps1

# region Timer-Job.ps1
# Timer module - Windows Scheduled Tasks integration

function Get-TimerVbsWrapperScript {
    <#
    .SYNOPSIS
        Builds a VBS launcher that runs a .ps1 file via pwsh (hidden).
    .DESCRIPTION
        Uses Chr(34) quoting so paths with spaces (e.g. Program Files) compile in VBScript.
    #>
    param([Parameter(Mandatory)][string]$Ps1Path)

    $pwsh = $script:PS1TimerPwsh.Replace('"', '""')
    $ps1 = $Ps1Path.Replace('"', '""')
    $args = ' -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File '
    return (
        'Set WshShell = CreateObject("WScript.Shell")' + [char]13 + [char]10 +
        'WshShell.Run Chr(34) & "' + $pwsh + '" & Chr(34) & "' + $args + '" & Chr(34) & "' + $ps1 + '" & Chr(34), 0, False' + [char]13 + [char]10 +
        'Set WshShell = Nothing'
    )
}

function Write-TimerFireScriptFile {
    param(
        [Parameter(Mandatory)][string]$TimerId,
        [Parameter(Mandatory)][string]$ScriptBody
    )
    $scriptPath = Join-Path $env:TEMP "PSTimer_$TimerId.ps1"
    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($scriptPath, $ScriptBody, $utf8Bom)
    return $scriptPath
}

function Write-TimerVbsWrapperFile {
    param([Parameter(Mandatory)][string]$TimerId)
    $scriptPath = Join-Path $env:TEMP "PSTimer_$TimerId.ps1"
    $vbsPath = Join-Path $env:TEMP "PSTimer_$TimerId.vbs"
    $vbsScript = Get-TimerVbsWrapperScript -Ps1Path $scriptPath
    $vbsScript | Set-Content -LiteralPath $vbsPath -Force -Encoding Ascii
    return $vbsPath
}

function Register-TimerScheduledTask {
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][datetime]$TriggerTime,
        [Parameter(Mandatory)][string]$VbsPath,
        [string]$TimerId = $null
    )

    Remove-TimerScheduledTaskByName -TaskName $TaskName

    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$VbsPath`""
    $trigger = New-ScheduledTaskTrigger -Once -At $TriggerTime
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Hidden

    try {
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        if ($TimerId) {
            $log = Join-Path $env:TEMP "PSTimer_$TimerId.log"
            "$(Get-Date -Format 'o') ERROR register task '$TaskName': $($_.Exception.Message)" | Add-Content -LiteralPath $log -Force
            Set-TimerRegistrationFailed -TimerId $TimerId
        }
        return $false
    }
}

function Set-TimerRegistrationFailed {
    param([Parameter(Mandatory)][string]$TimerId)

    $timers = @(Get-TimerData)
    $timer = Find-TimerById -Timers $timers -Id $TimerId
    if (-not $timer) { return }

    if ($timer.State -eq 'Running') {
        try {
            $remaining = [int]([DateTime]::Parse($timer.EndTime) - (Get-Date)).TotalSeconds
            if ($remaining -lt 0) { $remaining = [int]$timer.Seconds }
        }
        catch {
            $remaining = [int]$timer.Seconds
        }
        $timer.State = 'Paused'
        $timer | Add-Member -NotePropertyName 'RemainingSeconds' -NotePropertyValue $remaining -Force
        $timer.TaskName = $null
        Save-TimerData -Timers $timers
    }
}

function Register-TimerScheduledTaskAsync {
    param(
        [Parameter(Mandatory)][string]$TimerId,
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][datetime]$TriggerTime,
        [Parameter(Mandatory)][string]$VbsPath
    )

    if ($script:TimerForceSyncRegister) {
        $null = Register-TimerScheduledTask -TaskName $TaskName -TriggerTime $TriggerTime -VbsPath $VbsPath -TimerId $TimerId
        return
    }

    $null = Start-Job -Name "PSTimerReg_$TaskName" -ScriptBlock {
        param($tn, $trig, $vbs, $tid, $dataFile)
        $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`""
        $triggerObj = New-ScheduledTaskTrigger -Once -At $trig
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Hidden
        try {
            & schtasks.exe /Delete /F /TN $tn 2>$null | Out-Null
            Register-ScheduledTask -TaskName $tn -Action $action -Trigger $triggerObj -Settings $settings -Force -ErrorAction Stop | Out-Null
        }
        catch {
            $log = Join-Path $env:TEMP "PSTimer_$tid.log"
            "$(Get-Date -Format 'o') ERROR register task '$tn': $($_.Exception.Message)" | Add-Content -LiteralPath $log -Force
            if (Test-Path -LiteralPath $dataFile) {
                try {
                    $parsed = Get-Content -LiteralPath $dataFile -Raw | ConvertFrom-Json
                    $list = @()
                    if ($parsed -is [array]) { $list = @($parsed) } else { $list = @($parsed) }
                    foreach ($t in $list) {
                        if ([string]$t.Id -ne [string]$tid) { continue }
                        if ($t.State -ne 'Running') { break }
                        $rem = 0
                        try { $rem = [int]([DateTime]::Parse($t.EndTime) - (Get-Date)).TotalSeconds } catch { $rem = [int]$t.Seconds }
                        if ($rem -lt 0) { $rem = [int]$t.Seconds }
                        $t.State = 'Paused'
                        $t | Add-Member -NotePropertyName 'RemainingSeconds' -NotePropertyValue $rem -Force
                        $t.TaskName = $null
                        break
                    }
                    $utf8Bom = New-Object System.Text.UTF8Encoding $true
                    [System.IO.File]::WriteAllText($dataFile, (ConvertTo-Json -InputObject $list -Depth 10), $utf8Bom)
                }
                catch { }
            }
        }
    } -ArgumentList $TaskName, $TriggerTime, $VbsPath, $TimerId, $script:TimerDataFile | Out-Null
}

function Start-TimerJob {
    <#
    .SYNOPSIS
        Internal function to start a timer using Windows Scheduled Task.
    .DESCRIPTION
        Uses Scheduled Tasks instead of PowerShell jobs so timers survive terminal closure.
    #>
    param(
        [PSCustomObject]$Timer,
        [string]$Notify = 'popup',
        [string]$WebhookUrl = $null
    )

    $taskName = if ($Timer.PSObject.Properties.Name -contains 'TaskName' -and -not [string]::IsNullOrWhiteSpace($Timer.TaskName)) {
        $Timer.TaskName
    } else {
        New-TimerTaskName -TimerId $Timer.Id
    }
    $dataFile = Join-Path $env:TEMP "ps-timers.json"

    if ($Notify -eq 'webhook' -and -not $WebhookUrl -and $Timer.WebhookName) {
        $WebhookUrl = Resolve-TimerWebhookUrl -Name $Timer.WebhookName
    }

    $triggerTime = if ($Timer.State -eq 'Scheduled') {
        [DateTime]::Parse($Timer.EndTime)
    } else {
        (Get-Date).AddSeconds($Timer.Seconds)
    }

    $webhookBlock = Get-TimerFireScriptWebhookBlock -WebhookUrl $WebhookUrl
    $historyBlock = Get-TimerFireScriptHistoryBlock -TimerIdExpr '$timerId' -LabelExpr '$message' -SecondsExpr '$timerSeconds' -IsSequenceExpr '$false'

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
    if (`$notifyType -notin @('silent', 'webhook')) {
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
$webhookBlock
    default {
        # Popup (default/original behavior)
        `$popup = New-Object -ComObject WScript.Shell
        `$popup.Popup((`$body -join [char]10), 0, `$message, 64) | Out-Null
    }
}
$historyBlock
"@

    $null = Write-TimerFireScriptFile -TimerId $Timer.Id -ScriptBody $script
    $vbsPath = Write-TimerVbsWrapperFile -TimerId $Timer.Id

    Register-TimerScheduledTaskAsync -TimerId $Timer.Id -TaskName $taskName -TriggerTime $triggerTime -VbsPath $vbsPath
    $Timer | Add-Member -NotePropertyName 'TaskName' -NotePropertyValue $taskName -Force
}

function Clear-TimerScheduledTaskNameCache {
    $script:TimerTaskNameCache = $null
    $script:TimerTaskNameCacheTime = [DateTime]::MinValue
}

function Get-PSTimerScheduledTaskNames {
    <#
    .SYNOPSIS
        Returns cached set of existing PSTimer_* scheduled task names (one COM enumeration per TTL).
    #>
    param([switch]$ForceRefresh)

    $now = Get-Date
    if (-not $ForceRefresh -and $null -ne $script:TimerTaskNameCache -and ($now - $script:TimerTaskNameCacheTime).TotalSeconds -lt $script:TimerTaskNameCacheTtlSeconds) {
        return $script:TimerTaskNameCache
    }

    $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $service = $null
    $folder = $null
    $tasks = $null

    try {
        $service = New-Object -ComObject Schedule.Service
        $service.Connect()
        $folder = $service.GetFolder('\')
        $tasks = $folder.GetTasks(1)

        for ($i = 1; $i -le $tasks.Count; $i++) {
            $name = $tasks.Item($i).Name
            if ($name -like 'PSTimer_*') {
                [void]$names.Add($name)
            }
        }
    }
    catch {
        Write-Warning "PS1Timer: Could not list scheduled tasks: $($_.Exception.Message)"
        return $names
    }
    finally {
        if ($tasks) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($tasks) | Out-Null }
        if ($folder) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($folder) | Out-Null }
        if ($service) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($service) | Out-Null }
    }

    $script:TimerTaskNameCache = $names
    $script:TimerTaskNameCacheTime = $now
    return $names
}

function Remove-TimerScheduledTaskByName {
    <#
    .SYNOPSIS
        Deletes one scheduled task by name via COM (no full task enumeration).
    #>
    param([Parameter(Mandatory)][string]$TaskName)

    if ([string]::IsNullOrWhiteSpace($TaskName)) { return }

    $service = $null
    $folder = $null
    try {
        $service = New-Object -ComObject Schedule.Service
        $service.Connect()
        $folder = $service.GetFolder('\')
        $folder.DeleteTask($TaskName, 0)
        Clear-TimerScheduledTaskNameCache
    }
    catch {
        # Task may already be gone
    }
    finally {
        if ($folder) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($folder) | Out-Null }
        if ($service) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($service) | Out-Null }
    }
}

function Add-TimerScheduledTaskDeleteCandidates {
    <#
    .SYNOPSIS
        Adds scheduled task names to delete for one timer (explicit name + optional id sweep).
    #>
    param(
        [System.Collections.Generic.HashSet[string]]$DeleteSet,
        [System.Collections.Generic.IEnumerable[string]]$ExistingNames,
        [string]$TimerId,
        [string]$TaskName
    )

    $legacyName = "PSTimer_$TimerId"
    if (-not [string]::IsNullOrWhiteSpace($TaskName)) {
        [void]$DeleteSet.Add($TaskName)
    }

    $sweepById = [string]::IsNullOrWhiteSpace($TaskName) -or ($TaskName -eq $legacyName)
    if (-not $sweepById) {
        return
    }

    foreach ($name in $ExistingNames) {
        if ($name -eq $legacyName -or $name -like "PSTimer_${TimerId}_*") {
            [void]$DeleteSet.Add($name)
        }
    }
}

function Remove-TimerScheduledTasks {
    <#
    .SYNOPSIS
        Removes PSTimer scheduled tasks via Task Scheduler COM (one connect, one enumeration).
    .PARAMETER All
        Delete every task whose name starts with PSTimer_.
    .PARAMETER TimerTargets
        Per-timer targets: Id and optional TaskName (sweep PSTimer_{Id}_* when name is legacy or empty).
    .PARAMETER Names
        Explicit task names to delete (with optional TimerId sweep).
    .PARAMETER TimerId
        Timer id for legacy-name sweep when used with Names.
    #>
    param(
        [switch]$All,
        [array]$TimerTargets,
        [string[]]$Names,
        [string]$TimerId
    )

    $failed = [System.Collections.Generic.List[string]]::new()
    $deleteSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    # Fast path: explicit names only, no per-id sweep (single pause/remove of suffixed task name)
    if (-not $All -and (-not $TimerTargets -or $TimerTargets.Count -eq 0) -and $Names -and $Names.Count -gt 0 -and [string]::IsNullOrWhiteSpace($TimerId)) {
        foreach ($n in $Names) {
            if ([string]::IsNullOrWhiteSpace($n)) { continue }
            try {
                Remove-TimerScheduledTaskByName -TaskName $n
            }
            catch {
                $failed.Add($n)
            }
        }
        if ($failed.Count -gt 0) {
            Write-Warning "PS1Timer: Failed to remove scheduled task(s): $($failed -join ', ')"
        }
        return
    }

    $service = $null
    $folder = $null
    $tasks = $null

    try {
        $service = New-Object -ComObject Schedule.Service
        $service.Connect()
        $folder = $service.GetFolder('\')
        $tasks = $folder.GetTasks(1)

        $existing = [System.Collections.Generic.List[string]]::new()
        for ($i = 1; $i -le $tasks.Count; $i++) {
            $existing.Add($tasks.Item($i).Name)
        }

        if ($All) {
            foreach ($name in $existing) {
                if ($name -like 'PSTimer_*') {
                    [void]$deleteSet.Add($name)
                }
            }
        }
        elseif ($TimerTargets -and $TimerTargets.Count -gt 0) {
            foreach ($target in $TimerTargets) {
                $id = [string]$target.Id
                $taskName = if ($target.TaskName) { [string]$target.TaskName } else { $null }
                Add-TimerScheduledTaskDeleteCandidates -DeleteSet $deleteSet -ExistingNames $existing -TimerId $id -TaskName $taskName
            }
        }
        else {
            if ($Names) {
                foreach ($n in $Names) {
                    if (-not [string]::IsNullOrWhiteSpace($n)) {
                        [void]$deleteSet.Add($n)
                    }
                }
            }
            if ($TimerId) {
                Add-TimerScheduledTaskDeleteCandidates -DeleteSet $deleteSet -ExistingNames $existing -TimerId $TimerId -TaskName $Names[0]
            }
        }

        foreach ($name in $deleteSet) {
            try {
                $folder.DeleteTask($name, 0)
            }
            catch {
                $failed.Add($name)
            }
        }
    }
    catch {
        Write-Warning "PS1Timer: Could not connect to Task Scheduler: $($_.Exception.Message)"
        return
    }
    finally {
        if ($tasks) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($tasks) | Out-Null }
        if ($folder) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($folder) | Out-Null }
        if ($service) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($service) | Out-Null }
    }

    if ($failed.Count -gt 0) {
        Write-Warning "PS1Timer: Failed to remove scheduled task(s): $($failed -join ', ')"
    }

    Clear-TimerScheduledTaskNameCache
}

function Remove-TimerTempFiles {
    <#
    .SYNOPSIS
        Removes PSTimer script/vbs files from TEMP.
    #>
    param(
        [switch]$All,
        [string[]]$TimerIds
    )

    if ($All) {
        Get-ChildItem -Path $env:TEMP -Filter 'PSTimer_*.ps1' -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
        Get-ChildItem -Path $env:TEMP -Filter 'PSTimer_*.vbs' -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
        return
    }

    foreach ($id in $TimerIds) {
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $scriptPath = Join-Path $env:TEMP "PSTimer_$id.ps1"
        $vbsPath = Join-Path $env:TEMP "PSTimer_$id.vbs"
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $vbsPath -Force -ErrorAction SilentlyContinue
    }
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

    $id = [string]$TimerId
    if (-not $TaskName) {
        $TaskName = "PSTimer_$id"
    }

    if ($TaskName -eq "PSTimer_$id") {
        Remove-TimerScheduledTasks -TimerId $id -Names @($TaskName)
    }
    else {
        Remove-TimerScheduledTasks -Names @($TaskName)
    }
    Remove-TimerTempFiles -TimerIds @($id)
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
    $targets = [System.Collections.Generic.List[object]]::new()
    $pausedIds = [System.Collections.Generic.List[string]]::new()
    $now = Get-Date

    foreach ($t in $Timers) {
        if ($t.State -ne 'Running') { continue }
        $targets.Add(@{
            Id       = [string]$t.Id
            TaskName = Get-TimerTaskName -Timer $t
        })
        $pausedIds.Add([string]$t.Id)
        $endTime = [DateTime]::Parse($t.EndTime)
        $remaining = [int]($endTime - $now).TotalSeconds
        if ($remaining -lt 0) { $remaining = 0 }
        $t | Add-Member -NotePropertyName 'RemainingSeconds' -NotePropertyValue $remaining -Force
        $t.State = 'Paused'
        $count++
    }

    if ($count -gt 0) {
        Remove-TimerScheduledTasks -TimerTargets $targets.ToArray()
        Remove-TimerTempFiles -TimerIds $pausedIds.ToArray()
        Save-TimerData -Timers $Timers
    }

    return $count
}

function Invoke-PauseSingleTimer {
    param([array]$Timers, [string]$Id)
    $timer = Find-TimerById -Timers $Timers -Id $Id
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
    $timer = Find-TimerById -Timers $Timers -Id $Id
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
        Remove-TimerScheduledTasks -All
        Remove-TimerTempFiles -All
        Save-TimerData -Timers @()
        return $Timers.Count
    }
    $toKeep = @()
    $removed = 0
    $targets = [System.Collections.Generic.List[object]]::new()
    $removedIds = [System.Collections.Generic.List[string]]::new()
    foreach ($t in $Timers) {
        if ($t.State -eq 'Completed' -or $t.State -eq 'Lost') {
            $targets.Add(@{
                Id       = [string]$t.Id
                TaskName = Get-TimerTaskName -Timer $t
            })
            $removedIds.Add([string]$t.Id)
            $removed++
        }
        else { $toKeep += $t }
    }
    if ($targets.Count -gt 0) {
        Remove-TimerScheduledTasks -TimerTargets $targets.ToArray()
        Remove-TimerTempFiles -TimerIds $removedIds.ToArray()
    }
    Save-TimerData -Timers $toKeep
    return $removed
}

function Invoke-RemoveSingleTimer {
    param([array]$Timers, [string]$Id)
    $timer = Find-TimerById -Timers $Timers -Id $Id
    if (-not $timer) { return $false }
    Stop-TimerTask -TimerId $Id -TaskName (Get-TimerTaskName -Timer $timer)
    $newList = @($Timers | Where-Object { $_.Id -ne $Id })
    Save-TimerData -Timers $newList
    return $true
}
# endregion Timer-Operations.ps1

# region Timer-Sequence.ps1
# Timer module - Sequence timer parsing and handling

# Timer presets — loaded from Config.Presets (config.example.ps1 or config.ps1)
$script:TimerPresets = @{}
$presetSource = $null
if ($global:Config -and $global:Config.Presets) {
    $presetSource = $global:Config.Presets
}
elseif ($global:Config -and $global:Config.TimerPresets) {
    Write-Warning 'PS1Timer: Config.TimerPresets is deprecated; use Config.Presets instead.'
    $presetSource = $global:Config.TimerPresets
}
if ($presetSource) {
    foreach ($presetKey in $presetSource.Keys) {
        $script:TimerPresets[$presetKey] = $presetSource[$presetKey]
    }
}
if ($script:TimerPresets.Count -eq 0) {
    throw 'PS1Timer: Config.Presets is empty. Check config.example.ps1 or config.ps1.'
}

function Test-TimerSequence {
    <#
    .SYNOPSIS
        Checks if a string is a timer sequence pattern (contains grouping or comma).
    #>
    param([string]$Pattern)

    # Check for preset name first
    if ($script:TimerPresets.Keys -contains $Pattern) {
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
    if (($script:TimerPresets.Keys -contains $Pattern)) {
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
        [string]$NotifyType = 'popup',
        [string]$WebhookName = $null
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
        WebhookName     = $WebhookName
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
        [DateTime]$EndTime,
        [DateTime]$ScheduledStart = $null,
        [string]$NotifyLabel = $null,
        [string]$WebhookName = $null
    )
    Write-Host ""
    if ($ScheduledStart) {
        Write-Host "  Sequence scheduled " -ForegroundColor Green -NoNewline
    }
    else {
        Write-Host "  Sequence started " -ForegroundColor Green -NoNewline
    }
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
    if ($ScheduledStart) {
        Write-Host "  Starts:   " -ForegroundColor Gray -NoNewline
        Write-Host $ScheduledStart.ToString('HH:mm:ss') -ForegroundColor Cyan
    }
    Write-Host "  Ends at:  " -ForegroundColor Gray -NoNewline
    Write-Host $EndTime.ToString('HH:mm:ss') -ForegroundColor Yellow
    if ($NotifyLabel) {
        $label = $NotifyLabel
        if ($NotifyLabel -eq 'webhook' -and $WebhookName) { $label += " ($WebhookName)" }
        Write-Host "  Notify:   " -ForegroundColor Gray -NoNewline
        Write-Host $label -ForegroundColor Green
    }
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
    $webhookUrl = $null
    if ($notifyType -eq 'webhook' -and $Timer.WebhookName) {
        $webhookUrl = Resolve-TimerWebhookUrl -Name $Timer.WebhookName
    }

    $triggerTime = if ($Timer.State -eq 'Scheduled') {
        [DateTime]::Parse($Timer.EndTime)
    } else {
        (Get-Date).AddSeconds($Timer.Seconds)
    }

    $webhookBlock = Get-TimerFireScriptWebhookBlock -WebhookUrl $webhookUrl
    $historyBlock = Get-TimerFireScriptHistoryBlock -TimerIdExpr '$timerId' -LabelExpr '$phaseLabel' -SecondsExpr '$timer.Seconds' -IsSequenceExpr '$true'

    # Build the notification script using here-string
    $script = @"
`$timerId = '$($Timer.Id)'
`$dataFile = '$dataFile'
`$notifyType = '$notifyType'
`$logFile = "`$env:TEMP\PSTimer_`$timerId.log"
`$utf8Bom = New-Object System.Text.UTF8Encoding `$true

function Write-TimerDataFile {
    param([array]`$Items)
    [System.IO.File]::WriteAllText(`$dataFile, (ConvertTo-Json -InputObject `$Items -Depth 10), `$utf8Bom)
}

try {

if (-not (Test-Path -LiteralPath `$dataFile)) { exit }
`$jsonContent = Get-Content -LiteralPath `$dataFile -Raw -ErrorAction Stop
`$parsed = `$jsonContent | ConvertFrom-Json
`$timers = @()
if (`$parsed -is [array]) { `$timers = @(`$parsed) } else { `$timers = @(`$parsed) }

`$timerIndex = -1
for (`$i = 0; `$i -lt `$timers.Count; `$i++) {
    if ([string]`$timers[`$i].Id -eq [string]`$timerId) { `$timerIndex = `$i; break }
}
if (`$timerIndex -lt 0) { exit }
`$timer = `$timers[`$timerIndex]
if (-not `$timer.IsSequence) { exit }

`$currentTaskName = `$timer.TaskName
`$currentPhase = [int]`$timer.CurrentPhase
`$totalPhases = [int]`$timer.TotalPhases
`$phaseLabel = `$timer.PhaseLabel

if (`$notifyType -notin @('silent', 'webhook')) {
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
    `$phases = @(`$timer.Phases)
    if (`$nextPhaseIdx -ge `$phases.Count) {
        "`$(Get-Date -Format 'o') ERROR invalid phase index `$nextPhaseIdx (count=`$(`$phases.Count))" | Add-Content -LiteralPath `$logFile -Force
        `$timer.State = 'Lost'
        `$timer.TaskName = `$null
        Write-TimerDataFile -Items `$timers
    } else {
        `$nextPhase = `$phases[`$nextPhaseIdx]
        `$nextSeconds = [int]`$nextPhase.Seconds
        `$nextLabel = `$nextPhase.Label
        `$nextTaskName = "PSTimer_`$timerId_`$([Guid]::NewGuid().ToString('N').Substring(0, 8))"

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

        if (`$registered) {
            `$timer.CurrentPhase = `$nextPhaseIdx
            `$timer.PhaseLabel = `$nextLabel
            `$timer.Seconds = `$nextSeconds
            `$timer.Message = `$nextLabel
            `$timer.StartTime = (Get-Date).ToString('o')
            `$timer.EndTime = (Get-Date).AddSeconds(`$nextSeconds).ToString('o')
            `$timer.State = 'Running'
            `$timer.TaskName = `$nextTaskName
            Write-TimerDataFile -Items `$timers
            if (`$currentTaskName) {
                Unregister-ScheduledTask -TaskName `$currentTaskName -Confirm:`$false -ErrorAction SilentlyContinue
            }
        } else {
            `$timer.State = 'Paused'
            `$timer | Add-Member -NotePropertyName 'RemainingSeconds' -NotePropertyValue `$nextSeconds -Force
            `$timer.TaskName = `$null
            Write-TimerDataFile -Items `$timers
        }
    }
} else {
    `$timer.State = 'Completed'
    `$timer.CurrentPhase = `$totalPhases
    `$timer.TaskName = `$null
    Write-TimerDataFile -Items `$timers

    if (`$currentTaskName) {
        Unregister-ScheduledTask -TaskName `$currentTaskName -Confirm:`$false -ErrorAction SilentlyContinue
    }
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
$webhookBlock
    default {
        `$popup = New-Object -ComObject WScript.Shell
        `$popup.Popup((`$body -join [char]10), 0, `$title, 64) | Out-Null
    }
}
$historyBlock
"@

    $null = Write-TimerFireScriptFile -TimerId $Timer.Id -ScriptBody $script
    $vbsPath = Write-TimerVbsWrapperFile -TimerId $Timer.Id

    Register-TimerScheduledTaskAsync -TimerId $Timer.Id -TaskName $taskName -TriggerTime $triggerTime -VbsPath $vbsPath
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
        @{ Name='Timer <time>'; Alias='T'; Params='[msg] [repeat] [-Notify] [-Webhook] [-At]'; Desc='Start a timer (simple or sequence pattern)' }
        @{ Name='Timer-Stats'; Alias='TS'; Params=''; Desc='Show timer completion history (today/week)' }
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
                @{ Type='text'; Label='  Per-timer: '; Value='t 25m -Notify webhook -Webhook discord-main'; LabelColor='Yellow'; ValueColor='Gray' }
                @{ Type='raw'; Text='' }
                @{ Type='raw'; Text='  Types: popup | toast | sound | silent | webhook'; Color='Green' }
                @{ Type='raw'; Text='' }
                @{ Type='raw'; Text='  popup  Modal dialog (default, blocks until OK)' }
                @{ Type='raw'; Text='  toast  Windows toast notification (non-blocking)' }
                @{ Type='raw'; Text='  sound  Sound only, no visual notification' }
                @{ Type='raw'; Text='  silent No notification at all' }
                @{ Type='raw'; Text='' }
                @{ Type='raw'; Text='  Default: config.example.ps1 or config.ps1 -> TimerDefaults.Notify' }
                @{ Type='raw'; Text='' }
                @{ Type='raw'; Text='  After start: TimerDefaults.AfterStart = none | watch | list' }
                @{ Type='raw'; Text='    none  confirmation only  |  watch  tw <id>  |  list  tl -w' }
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
        Notification type: popup (default), toast, sound, silent, webhook.
        Override default in config.ps1 / config.example.ps1 TimerDefaults.Notify.
    .PARAMETER Webhook
        Named webhook from Config.Webhooks (e.g. discord-main). Used with -Notify webhook.
    .PARAMETER At
        Schedule start at HH:mm today (24h). Timer runs from that time.
    .PARAMETER AfterStart
        After start: none, watch (tw), list (tl -w). Overrides TimerDefaults.AfterStart.
    .EXAMPLE
        t 25m
        t 30m Water
        t 1h30m 'Stand up' 4
        t pomodoro
        t "(25m work, 5m rest)x4"
        t 25m -Notify toast
        t 25m -Notify webhook -Webhook discord-main
        t 25m work -At "14:30"
    #>
    param(
        [Parameter(Position=0)][string]$Time,
        [Parameter(Position=1)][Alias('m')][string]$Message = "Time is up!",
        [Parameter(Position=2)][Alias('r')][int]$Repeat = 1,
        [ValidateSet('popup', 'toast', 'sound', 'silent', 'webhook')]
        [string]$Notify = $null,
        [string]$Webhook = $null,
        [string]$At = $null,
        [ValidateSet('none', 'watch', 'list')]
        [string]$AfterStart = $null
    )

    # Show help if no time provided
    if ([string]::IsNullOrEmpty($Time)) {
        Show-TimerHelp
        return
    }

    # Check if this is a sequence pattern or preset
    if (Test-TimerSequence -Pattern $Time) {
        Start-SequenceTimer -Pattern $Time -Notify $Notify -Webhook $Webhook -At $At -AfterStart $AfterStart
        return
    }

    # Simple timer mode
    $seconds = ConvertTo-Seconds -Time $Time

    if ($seconds -le 0) {
        Write-Host "Invalid time format. Use 1h20m, 90s, etc." -ForegroundColor Red
        return
    }

    if ($Repeat -lt 1) { $Repeat = 1 }

    $scheduledStart = $null
    if ($At) {
        $scheduledStart = Parse-TimerAtTime -At $At
        if (-not $scheduledStart) {
            Write-Host "Invalid -At time. Use HH:mm in the future today (e.g. 14:30)." -ForegroundColor Red
            return
        }
    }

    $id = New-TimerId
    $now = Get-Date
    $startTime = if ($scheduledStart) { $scheduledStart } else { $now }
    $endTime = $startTime.AddSeconds($seconds)
    $timerState = if ($scheduledStart) { 'Scheduled' } else { 'Running' }

    $notifySettings = Resolve-TimerNotificationSettings -NotifyOverride $Notify -WebhookOverride $Webhook

    $timer = [PSCustomObject]@{
        Id              = $id
        Duration        = $Time
        Seconds         = $seconds
        Message         = $Message
        StartTime       = $startTime.ToString('o')
        EndTime         = $endTime.ToString('o')
        RepeatTotal     = $Repeat
        RepeatRemaining = $Repeat - 1
        CurrentRun      = 1
        State           = $timerState
        IsSequence      = $false
        NotifyType      = $notifySettings.NotifyType
        WebhookName     = $notifySettings.WebhookName
        TaskName        = New-TimerTaskName -TimerId $id
    }

    $timers = @(Get-TimerData)
    $timers += $timer
    Save-TimerData -Timers $timers

    Start-TimerJob -Timer $timer -Notify $notifySettings.NotifyType -WebhookUrl $notifySettings.WebhookUrl

    Write-Host ""
    if ($timerState -eq 'Scheduled') {
        Write-Host "  Timer scheduled " -ForegroundColor Green -NoNewline
    }
    else {
        Write-Host "  Timer started " -ForegroundColor Green -NoNewline
    }
    Write-Host "[$id]" -ForegroundColor Cyan
    Write-Host "  Duration: " -ForegroundColor Gray -NoNewline
    Write-Host (Format-Duration -Seconds $seconds) -ForegroundColor White
    if ($timerState -eq 'Scheduled') {
        Write-Host "  Starts:   " -ForegroundColor Gray -NoNewline
        Write-Host $startTime.ToString('HH:mm:ss') -ForegroundColor Cyan
    }
    Write-Host "  Ends at:  " -ForegroundColor Gray -NoNewline
    Write-Host $endTime.ToString('HH:mm:ss') -ForegroundColor Yellow
    if ($Repeat -gt 1) {
        Write-Host "  Repeats:  " -ForegroundColor Gray -NoNewline
        Write-Host "$Repeat times" -ForegroundColor Magenta
    }
    Write-Host "  Message:  " -ForegroundColor Gray -NoNewline
    Write-Host $Message -ForegroundColor White
    Write-Host "  Notify:   " -ForegroundColor Gray -NoNewline
    $notifyLabel = $notifySettings.NotifyType
    if ($notifySettings.NotifyType -eq 'webhook' -and $notifySettings.WebhookName) {
        $notifyLabel += " ($($notifySettings.WebhookName))"
    }
    Write-Host $notifyLabel -ForegroundColor Green
    Write-Host ""

    Invoke-TimerAfterStart -TimerId $id -AfterStart $AfterStart
}

function Start-SequenceTimer {
    <#
    .SYNOPSIS
        Starts a sequence-based timer (Pomodoro-style).
    .PARAMETER Pattern
        Sequence pattern string or preset name.
    .PARAMETER Notify
        Notification type: popup (default), toast, sound, silent, webhook.
    .PARAMETER Webhook
        Named webhook from Config.Webhooks when using -Notify webhook.
    .PARAMETER At
        Schedule sequence start at HH:mm today (24h).
    .PARAMETER AfterStart
        After start: none, watch (tw), list (tl -w). Overrides TimerDefaults.AfterStart.
    #>
    param(
        [string]$Pattern,
        [string]$Notify = $null,
        [string]$Webhook = $null,
        [string]$At = $null,
        [string]$AfterStart = $null
    )

    $originalPattern = $Pattern
    $presetNotify = $null
    $presetWebhook = $null
    if (($script:TimerPresets.Keys -contains $Pattern)) {
        $preset = $script:TimerPresets[$Pattern]
        $Pattern = $preset.Pattern
        if ($preset.Notify) { $presetNotify = $preset.Notify }
        if ($preset.Webhook) { $presetWebhook = $preset.Webhook }
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

    $scheduledStart = $null
    if ($At) {
        $scheduledStart = Parse-TimerAtTime -At $At
        if (-not $scheduledStart) {
            Write-Host "Invalid -At time. Use HH:mm in the future today (e.g. 14:30)." -ForegroundColor Red
            return
        }
    }

    $notifySettings = Resolve-TimerNotificationSettings -NotifyOverride $Notify -WebhookOverride $Webhook -PresetNotify $presetNotify -PresetWebhook $presetWebhook
    $startTime = if ($scheduledStart) { $scheduledStart } else { $now }
    $timerState = if ($scheduledStart) { 'Scheduled' } else { 'Running' }

    $timer = New-SequenceTimerFromPhases -Id $id -OriginalPattern $originalPattern -Phases $phases -Summary $summary -Now $startTime -NotifyType $notifySettings.NotifyType -WebhookName $notifySettings.WebhookName
    $timer.State = $timerState
    $firstPhase = $phases[0]
    $timer.EndTime = $startTime.AddSeconds($firstPhase.Seconds).ToString('o')

    $timers = @(Get-TimerData)
    $timers += $timer
    Save-TimerData -Timers $timers
    Start-SequenceTimerJob -Timer $timer

    $endTime = [DateTime]::Parse($timer.EndTime)
    Write-SequenceTimerConfirmation -Id $id -OriginalPattern $originalPattern -Summary $summary -PhaseCount $phases.Count -FirstPhase $firstPhase -EndTime $endTime -ScheduledStart $scheduledStart -NotifyLabel $notifySettings.NotifyType -WebhookName $notifySettings.WebhookName

    Invoke-TimerAfterStart -TimerId $id -AfterStart $AfterStart
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
        $timers = @($timers | Where-Object { $_.State -eq 'Running' -or $_.State -eq 'Scheduled' -or $_.State -eq 'Paused' })
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
                $displayTimers = @($timers | Where-Object { $_.State -eq 'Running' -or $_.State -eq 'Scheduled' -or $_.State -eq 'Paused' })
            }

            $sb = [System.Text.StringBuilder]::new()

            if ($displayTimers.Count -eq 0) {
                # Poll for next run: scheduled task may need a moment to write updated JSON (same as tw)
                $foundNextRun = $false
                $pollMs = @(500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000)
                foreach ($delay in $pollMs) {
                    Start-Sleep -Milliseconds $delay
                    $refresh = Get-TimerDataIfChanged -Force
                    $refreshedActive = @($refresh.Data | Where-Object { $_.State -eq 'Running' -or $_.State -eq 'Scheduled' -or $_.State -eq 'Paused' })
                    if ($refreshedActive.Count -gt 0) {
                        $timers = @($refresh.Data)
                        $displayTimers = $refreshedActive
                        $foundNextRun = $true
                        break
                    }
                }
                if (-not $foundNextRun) {
                    [void]$sb.AppendLine("")
                    [void]$sb.AppendLine("$($c.Muted)  No active timers.$($c.Reset)")
                    Clear-Host
                    [Console]::Write($sb.ToString())
                    break
                }
            }

            $running = @($displayTimers | Where-Object { $_.State -eq 'Running' }).Count
            $paused = @($displayTimers | Where-Object { $_.State -eq 'Paused' }).Count

            [void]$sb.AppendLine("")
            $pausedPart = if ($paused -gt 0) { "$($c.Warning), $paused paused$($c.Reset)" } else { "" }
            [void]$sb.AppendLine("$($c.Primary)  BACKGROUND TIMERS $($c.Success)($running running${pausedPart}$($c.Success))$($c.Reset)")
            [void]$sb.AppendLine("$($c.PrimaryMuted)  =====================$($c.Reset)")
            [void]$sb.AppendLine("")

            $colWidths = @{ Id = 5; State = 10; Duration = 11; Remaining = 11; Progress = 8; EndsAt = 10; Phase = 8 }
            $hdr = "  {0,-5}{1,-10}{2,-11}{3,-11}{4,-8}{5,-10}{6,-8}MESSAGE" -f "ID", "STATE", "DURATION", "REMAINING", "PROG", "ENDS AT", "PHASE"
            [void]$sb.AppendLine("$($c.Muted)$hdr$($c.Reset)")
            [void]$sb.AppendLine("$($c.Muted)  $("-" * 83)$($c.Reset)")
            foreach ($t in $displayTimers) {
                [void]$sb.AppendLine((Get-TimerListWatchRowLine -Timer $t -Now $now -Colors $c -ColWidths $colWidths))
            }
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("$($c.Muted)  Press any key to exit watch mode...$($c.Reset)")
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

            if (-not $currentTimer -or ($currentTimer.State -ne 'Running' -and $currentTimer.State -ne 'Scheduled')) {
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

function Get-TimerHistory {
    <#
    .SYNOPSIS
        Loads timer completion history from JSON file.
    #>
    if (-not (Test-Path -LiteralPath $script:TimerHistoryFile)) {
        return @()
    }

    try {
        $content = [System.IO.File]::ReadAllText($script:TimerHistoryFile)
        if ([string]::IsNullOrWhiteSpace($content)) { return @() }
        $data = $content | ConvertFrom-Json
        if ($null -eq $data) { return @() }
        if ($data -is [System.Array]) { return @($data) }
        return @($data)
    }
    catch {
        return @()
    }
}

function Get-TimerStatsSummary {
    <#
    .SYNOPSIS
        Aggregates history into today/week totals and per-label breakdown.
    #>
    param([array]$History = @(Get-TimerHistory))

    $now = Get-Date
    $todayStart = $now.Date
    $weekStart = $todayStart.AddDays(-6)

    $todaySeconds = 0
    $weekSeconds = 0
    $todayCount = 0
    $weekCount = 0
    $labelTotals = @{}

    foreach ($entry in $History) {
        if (-not $entry.CompletedAt) { continue }
        try {
            $completed = [DateTime]::Parse($entry.CompletedAt)
        }
        catch { continue }

        $secs = [int]$entry.Seconds
        if ($completed -ge $weekStart) {
            $weekSeconds += $secs
            $weekCount++
        }
        if ($completed.Date -eq $todayStart) {
            $todaySeconds += $secs
            $todayCount++
        }

        $label = if ($entry.Label) { [string]$entry.Label } else { 'timer' }
        if (-not $labelTotals.ContainsKey($label)) { $labelTotals[$label] = 0 }
        $labelTotals[$label] += $secs
    }

    return @{
        TodaySeconds = $todaySeconds
        TodayCount   = $todayCount
        WeekSeconds  = $weekSeconds
        WeekCount    = $weekCount
        LabelTotals  = $labelTotals
    }
}

function Timer-Stats {
    <#
    .SYNOPSIS
        Shows timer completion history summary (today, week, labels).
    #>
    $summary = Get-TimerStatsSummary
    $c = Get-AnsiColors

    Write-Host ""
    Write-Host "$($c.Primary)  TIMER STATS$($c.Reset)"
    Write-Host "$($c.PrimaryMuted)  ===========$($c.Reset)"
    Write-Host ""

    if ($summary.WeekCount -eq 0) {
        Write-Host "$($c.Muted)  No completed timer history yet.$($c.Reset)"
        Write-Host "$($c.Dim)  History is recorded when timers finish.$($c.Reset)"
        Write-Host ""
        return
    }

    Write-Host "$($c.Muted)  TODAY  $($c.Text)$(Format-Duration -Seconds $summary.TodaySeconds)$($c.Muted)  ($($summary.TodayCount) completions)$($c.Reset)"
    Write-Host "$($c.Muted)  WEEK   $($c.Text)$(Format-Duration -Seconds $summary.WeekSeconds)$($c.Muted)  ($($summary.WeekCount) completions)$($c.Reset)"
    Write-Host ""

    if ($summary.LabelTotals.Count -gt 0) {
        Write-Host "$($c.Muted)  LABELS$($c.Reset)"
        foreach ($label in ($summary.LabelTotals.Keys | Sort-Object)) {
            $dur = Format-Duration -Seconds $summary.LabelTotals[$label]
            Write-Host "    $($c.Primary)$label$($c.Reset)  $($c.Text)$dur$($c.Reset)"
        }
        Write-Host ""
    }
}

# Backward-compatible wrappers (legacy names)
function TimerList { Timer-List @args }
function TimerWatch { Timer-Watch @args }
function TimerPause { Timer-Pause @args }
function TimerResume { Timer-Resume @args }
function TimerRemove { Timer-Remove @args }
function TimerPresets { Timer-Presets @args }
function TimerStats { Timer-Stats @args }

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
Set-Alias -Name ts -Value Timer-Stats -Scope Global
# endregion Timer-Aliases.ps1

