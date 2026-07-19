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
$script:PS1TimerTestMode = $false
# Cached PSTimer_* scheduled task names (avoids repeated COM/CIM enumeration)
$script:TimerTaskNameCache = $null
$script:TimerTaskNameCacheTime = [DateTime]::MinValue
$script:TimerTaskNameCacheTtlSeconds = 2
$script:TimerStaleCleanupLastRun = [DateTime]::MinValue
$script:TimerStaleCleanupIntervalSeconds = 5
$script:TimerDataMutexName = 'Global\PS1Timer_ps-timers_json'
$script:TimerDataFileLockTimeoutMs = 8000
$script:TimerDataFileIoRetryCount = 8
$script:TimerDataFileIoRetryDelayMs = 50
$script:MaxSequencePhases = 500
if ($global:Config -and $global:Config.MaxSequencePhases) {
    $script:MaxSequencePhases = [int]$global:Config.MaxSequencePhases
}

function Test-TimerSimpleRepeatingPreset {
    <#
    .SYNOPSIS
        True when a preset defines a simple repeating timer (Time + Repeat, no sequence Pattern).
    #>
    param($Preset)

    if (-not $Preset) { return $false }
    if (-not $Preset.Time) { return $false }
    if ($Preset.Pattern) { return $false }
    if ($Preset.Repeat -and [int]$Preset.Repeat -ge 1) { return $true }
    return $false
}

function Get-TimerPresetNotifyOverrides {
    param($Preset)

    $result = @{
        Notify    = $null
        Visual    = $null
        Sound     = $null
        Voice     = $null
        Webhook   = $null
        Countdown = $null
    }
    if (-not $Preset) { return $result }

    if ($Preset.Notify) { $result.Notify = $Preset.Notify }
    if ($Preset.Visual) { $result.Visual = $Preset.Visual }
    if ($Preset.ContainsKey('Sound')) { $result.Sound = [bool]$Preset.Sound }
    if ($Preset.ContainsKey('Voice')) { $result.Voice = [bool]$Preset.Voice }
    if ($Preset.Webhook) { $result.Webhook = $Preset.Webhook }
    if ($Preset.Countdown) { $result.Countdown = [string]$Preset.Countdown }
    return $result
}

function Test-TimerUniformPhaseSeconds {
    <#
    .SYNOPSIS
        True when every phase from an index through the end uses the same duration.
    #>
    param(
        [PSCustomObject]$Timer,
        [int]$FromPhaseIndex = -1
    )

    if (-not $Timer.Phases -or $Timer.Phases.Count -eq 0) { return $false }

    $startIndex = if ($FromPhaseIndex -ge 0) { $FromPhaseIndex } else { [int]$Timer.CurrentPhase }
    if ($startIndex -lt 0 -or $startIndex -ge $Timer.Phases.Count) { return $false }

    $referenceSeconds = [int]$Timer.Phases[$startIndex].Seconds
    for ($i = $startIndex; $i -lt $Timer.Phases.Count; $i++) {
        if ([int]$Timer.Phases[$i].Seconds -ne $referenceSeconds) {
            return $false
        }
    }
    return $true
}

function Sync-CatchUpUniformSequencePhase {
    <#
    .SYNOPSIS
        Fast-forwards uniform sequences that are overdue by multiple phase durations.
    #>
    param(
        [PSCustomObject]$Timer,
        [DateTime]$Now
    )

    if (-not $Timer.IsSequence) { return $false }

    $remaining = Get-TimerRemainingSeconds -Timer $Timer -Now $Now
    if ($null -eq $remaining -or $remaining -gt 0) { return $false }

    $phaseSeconds = [int]$Timer.Seconds
    if ($phaseSeconds -le 0) { return $false }
    if (-not (Test-TimerUniformPhaseSeconds -Timer $Timer)) { return $false }

    $totalPhases = if ($Timer.PSObject.Properties.Name -contains 'TotalPhases') { [int]$Timer.TotalPhases } else { @($Timer.Phases).Count }
    $currentPhase = [int]$Timer.CurrentPhase
    if ($currentPhase -ge ($totalPhases - 1)) { return $false }

    $elapsedSincePhaseEnd = [math]::Abs([int]$remaining)
    $phasesToAdvance = [math]::Floor($elapsedSincePhaseEnd / $phaseSeconds)
    if ($phasesToAdvance -lt 1) { return $false }

    $newPhase = [math]::Min($currentPhase + $phasesToAdvance, $totalPhases - 1)
    if ($newPhase -le $currentPhase) { return $false }

    $phase = $Timer.Phases[$newPhase]
    $offsetInPhase = $elapsedSincePhaseEnd % $phaseSeconds
    $secondsLeftInPhase = if ($offsetInPhase -eq 0) { $phaseSeconds } else { $phaseSeconds - $offsetInPhase }

    $Timer.CurrentPhase = $newPhase
    $Timer.PhaseLabel = [string]$phase.Label
    $Timer.Message = [string]$phase.Label
    $Timer.Seconds = $phaseSeconds
    $Timer.StartTime = $Now.ToString('o')
    $Timer.EndTime = $Now.AddSeconds($secondsLeftInPhase).ToString('o')
    $Timer.State = 'Running'
    $Timer | Add-Member -NotePropertyName 'RemainingSeconds' -NotePropertyValue $null -Force

    if ($Timer.PSObject.Properties.Name -contains 'TaskName') {
        $null = Repair-TimerScheduledTaskIfMissing -Timer $Timer
    }

    return $true
}

function Get-TimerEmbeddedDataFileIoScript {
    <#
    .SYNOPSIS
        PowerShell source embedded in scheduled-task fire scripts for safe JSON writes.
    #>
    return @'
function Write-TimerDataFileAtomic {
    param(
        [Parameter(Mandatory)][string]$DataFile,
        [Parameter(Mandatory)][string]$Content
    )
    $mutexName = 'Global\PS1Timer_ps-timers_json'
    $utf8Bom = [System.Text.UTF8Encoding]::new($true)
    $attempt = 0
    while ($attempt -lt 8) {
        $attempt++
        $mutex = $null
        $acquired = $false
        try {
            $mutex = [System.Threading.Mutex]::new($false, $mutexName)
            $acquired = $mutex.WaitOne(8000)
            if (-not $acquired) {
                throw [System.IO.IOException]::new('Timed out waiting for timer data file lock.')
            }
            $tmpPath = "$DataFile.$([Guid]::NewGuid().ToString('N')).tmp"
            try {
                [System.IO.File]::WriteAllText($tmpPath, $Content, $utf8Bom)
                [System.IO.File]::Move($tmpPath, $DataFile, $true)
            }
            finally {
                if (Test-Path -LiteralPath $tmpPath) {
                    Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue
                }
            }
            return
        }
        catch [System.IO.IOException] {
            if ($attempt -ge 8) { throw }
            Start-Sleep -Milliseconds (50 * $attempt)
        }
        catch [System.UnauthorizedAccessException] {
            if ($attempt -ge 8) { throw }
            Start-Sleep -Milliseconds (50 * $attempt)
        }
        finally {
            if ($mutex) {
                if ($acquired) {
                    try { $mutex.ReleaseMutex() } catch { }
                }
                $mutex.Dispose()
            }
        }
    }
}
'@
}

function Invoke-WithTimerDataFileLock {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [int]$TimeoutMs = $script:TimerDataFileLockTimeoutMs
    )

    $mutex = $null
    $acquired = $false
    try {
        $mutex = [System.Threading.Mutex]::new($false, $script:TimerDataMutexName)
        $acquired = $mutex.WaitOne($TimeoutMs)
        if (-not $acquired) {
            throw [System.IO.IOException]::new("Timed out waiting for timer data file lock ($script:TimerDataMutexName).")
        }
        return & $Action
    }
    finally {
        if ($mutex) {
            if ($acquired) {
                try { $mutex.ReleaseMutex() } catch { }
            }
            $mutex.Dispose()
        }
    }
}

function Write-TimerDataFileContent {
    param(
        [Parameter(Mandatory)][string]$Content,
        [string]$Path = $script:TimerDataFile
    )

    $utf8Bom = [System.Text.UTF8Encoding]::new($true)
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }

    $tmpPath = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText($tmpPath, $Content, $utf8Bom)
        [System.IO.File]::Move($tmpPath, $Path, $true)
    }
    catch {
        if (Test-Path -LiteralPath $tmpPath) {
            Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Invoke-TimerDataFileIo {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [int]$RetryCount = $script:TimerDataFileIoRetryCount,
        [int]$RetryDelayMs = $script:TimerDataFileIoRetryDelayMs
    )

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            return Invoke-WithTimerDataFileLock -Action $Action
        }
        catch [System.IO.IOException] {
            if ($attempt -ge $RetryCount) { throw }
            Start-Sleep -Milliseconds ($RetryDelayMs * $attempt)
        }
        catch [System.UnauthorizedAccessException] {
            if ($attempt -ge $RetryCount) { throw }
            Start-Sleep -Milliseconds ($RetryDelayMs * $attempt)
        }
    }
}

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
        $content = Invoke-TimerDataFileIo -Action {
            [System.IO.File]::ReadAllText($script:TimerDataFile)
        }
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
        Invoke-TimerDataFileIo -Action {
            Write-TimerDataFileContent -Content '[]'
        } | Out-Null
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
            if ($t.PSObject.Properties.Name -contains 'NotifyVisual') {
                $obj | Add-Member -NotePropertyName 'NotifyVisual' -NotePropertyValue ([string]$t.NotifyVisual)
            }
            if ($t.PSObject.Properties.Name -contains 'NotifySound') {
                $obj | Add-Member -NotePropertyName 'NotifySound' -NotePropertyValue ([bool]$t.NotifySound)
            }
            if ($t.PSObject.Properties.Name -contains 'NotifyVoice') {
                $obj | Add-Member -NotePropertyName 'NotifyVoice' -NotePropertyValue ([bool]$t.NotifyVoice)
            }
            if ($t.PSObject.Properties.Name -contains 'NotifyType' -and $t.NotifyType) {
                $obj | Add-Member -NotePropertyName 'NotifyType' -NotePropertyValue $t.NotifyType
            }
            if ($t.PSObject.Properties.Name -contains 'WebhookName' -and $t.WebhookName) {
                $obj | Add-Member -NotePropertyName 'WebhookName' -NotePropertyValue $t.WebhookName
            }
            if ($t.PSObject.Properties.Name -contains 'VoiceName' -and $t.VoiceName) {
                $obj | Add-Member -NotePropertyName 'VoiceName' -NotePropertyValue $t.VoiceName
            }
            if ($t.PSObject.Properties.Name -contains 'VoiceRate') {
                $obj | Add-Member -NotePropertyName 'VoiceRate' -NotePropertyValue ([int]$t.VoiceRate)
            }
            if ($t.PSObject.Properties.Name -contains 'VoiceVolume') {
                $obj | Add-Member -NotePropertyName 'VoiceVolume' -NotePropertyValue ([int]$t.VoiceVolume)
            }
            if ($t.PSObject.Properties.Name -contains 'CountdownMode' -and $t.CountdownMode) {
                $obj | Add-Member -NotePropertyName 'CountdownMode' -NotePropertyValue $t.CountdownMode
            }
            if ($t.PSObject.Properties.Name -contains 'CueTaskNames' -and $t.CueTaskNames) {
                $obj | Add-Member -NotePropertyName 'CueTaskNames' -NotePropertyValue @($t.CueTaskNames)
            }
            if ($t.PSObject.Properties.Name -contains 'BeepAt' -and $t.BeepAt) {
                $obj | Add-Member -NotePropertyName 'BeepAt' -NotePropertyValue @($t.BeepAt | ForEach-Object { [int]$_ })
            }
            if ($t.PSObject.Properties.Name -contains 'IsWorkout') {
                $obj | Add-Member -NotePropertyName 'IsWorkout' -NotePropertyValue ([bool]$t.IsWorkout)
            }
            if ($t.PSObject.Properties.Name -contains 'WorkoutRoutine' -and $t.WorkoutRoutine) {
                $obj | Add-Member -NotePropertyName 'WorkoutRoutine' -NotePropertyValue $t.WorkoutRoutine
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

    $json = ConvertTo-Json -InputObject $clean -Depth 12 -Compress
    Invoke-TimerDataFileIo -Action {
        Write-TimerDataFileContent -Content $json
    } | Out-Null
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
        Start-TimerScheduledJob -Timer $Timer
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

function Get-TimerRemainingSeconds {
    param(
        [PSCustomObject]$Timer,
        [DateTime]$Now = (Get-Date)
    )

    if (-not $Timer.EndTime) { return $null }
    try {
        return [int]([DateTime]::Parse($Timer.EndTime) - $Now).TotalSeconds
    }
    catch {
        return $null
    }
}

function Copy-SyncTimerFieldsFromRefreshed {
    param(
        [PSCustomObject]$Timer,
        [PSCustomObject]$Refreshed
    )

    foreach ($prop in @('State', 'EndTime', 'StartTime', 'CurrentPhase', 'PhaseLabel', 'Seconds', 'Message', 'TaskName', 'RepeatRemaining', 'CurrentRun')) {
        if ($Refreshed.PSObject.Properties.Name -contains $prop) {
            $Timer.$prop = $Refreshed.$prop
        }
    }
}

function Merge-SyncTimerChanges {
    <#
    .SYNOPSIS
        Merges in-memory sync edits into a fresh JSON read so concurrent updates are not clobbered.
    #>
    param(
        [array]$Timers,
        [System.Collections.Generic.HashSet[string]]$ModifiedIds
    )

    if ($null -eq $ModifiedIds -or $ModifiedIds.Count -eq 0) {
        return $Timers
    }

    $fresh = @(Get-TimerData -Force)
    if ($fresh.Count -eq 0) {
        return $Timers
    }

    $editedById = @{}
    foreach ($t in $Timers) {
        if ($ModifiedIds.Contains([string]$t.Id)) {
            $editedById[[string]$t.Id] = $t
        }
    }

    $merged = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $fresh) {
        $id = [string]$t.Id
        if ($editedById.ContainsKey($id)) {
            $merged.Add($editedById[$id])
        }
        else {
            $merged.Add($t)
        }
    }

    return $merged.ToArray()
}

function Repair-TimerScheduledTaskIfMissing {
    <#
    .SYNOPSIS
        Re-registers the fire script and scheduled task when JSON says Running but the task is gone.
    #>
    param(
        [PSCustomObject]$Timer,
        [System.Collections.Generic.HashSet[string]]$TaskNames
    )

    $taskName = Get-TimerTaskName -Timer $Timer
    if ([string]::IsNullOrWhiteSpace($taskName)) {
        $taskName = New-TimerTaskName -TimerId $Timer.Id
        $Timer | Add-Member -NotePropertyName 'TaskName' -NotePropertyValue $taskName -Force
    }

    if ($null -ne $TaskNames -and $TaskNames.Contains($taskName)) {
        return $false
    }

    Start-TimerScheduledJob -Timer $Timer
    Invoke-RegisterTimerResumeCues -Timer $Timer

    if ($null -ne $TaskNames) {
        [void]$TaskNames.Add($taskName)
        if ($Timer.PSObject.Properties.Name -contains 'TaskName' -and $Timer.TaskName) {
            [void]$TaskNames.Add([string]$Timer.TaskName)
        }
        if ($Timer.PSObject.Properties.Name -contains 'CueTaskNames' -and $Timer.CueTaskNames) {
            foreach ($cue in @($Timer.CueTaskNames)) {
                if (-not [string]::IsNullOrWhiteSpace($cue)) {
                    [void]$TaskNames.Add([string]$cue)
                }
            }
        }
    }

    return $true
}

function Add-TimerActiveScheduledTaskNames {
    param(
        [System.Collections.Generic.HashSet[string]]$ActiveNames,
        [PSCustomObject]$Timer
    )

    if ($Timer.TaskName) {
        [void]$ActiveNames.Add([string]$Timer.TaskName)
    }
    if ($Timer.PSObject.Properties.Name -contains 'CueTaskNames' -and $Timer.CueTaskNames) {
        foreach ($cue in @($Timer.CueTaskNames)) {
            if (-not [string]::IsNullOrWhiteSpace($cue)) {
                [void]$ActiveNames.Add([string]$cue)
            }
        }
    }
}

function Remove-StalePSTimerScheduledTasks {
    <#
    .SYNOPSIS
        Deletes PSTimer_* tasks that are not referenced by any timer record.
    #>
    $timers = @(Get-TimerData)
    if ($timers.Count -eq 0 -and (Test-Path -LiteralPath $script:TimerDataFile)) {
        $fileInfo = Get-Item -LiteralPath $script:TimerDataFile -ErrorAction SilentlyContinue
        if ($fileInfo -and $fileInfo.Length -gt 2) {
            return 0
        }
    }

    $activeNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($t in $timers) {
        Add-TimerActiveScheduledTaskNames -ActiveNames $activeNames -Timer $t
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
        Re-registers missing tasks while a phase still has time left (e.g. after sleep).
    #>
    $timers = @(Get-TimerData)
    $changed = $false
    $modifiedIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $now = Get-Date
    $taskNames = $null

    foreach ($timer in $timers) {
        if ($timer.State -ne 'Running' -and $timer.State -ne 'Scheduled') { continue }

        $remaining = Get-TimerRemainingSeconds -Timer $timer -Now $now
        if ($null -eq $remaining) {
            $timer.State = 'Lost'
            $timer | Add-Member -NotePropertyName 'RemainingSeconds' -NotePropertyValue $timer.Seconds -Force
            $changed = $true
            [void]$modifiedIds.Add([string]$timer.Id)
            continue
        }

        if ($remaining -le 0 -and $timer.IsSequence) {
            if (Sync-CatchUpUniformSequencePhase -Timer $timer -Now $now) {
                $changed = $true
                [void]$modifiedIds.Add([string]$timer.Id)
                continue
            }
        }

        if ($remaining -le -10) {
            $null = Invoke-TimerFireScriptRecovery -Timer $timer
            $refreshed = Find-TimerById -Timers @(Get-TimerData -Force) -Id $timer.Id
            if ($refreshed) {
                if ($refreshed.State -ne $timer.State) {
                    $timer.State = $refreshed.State
                    $changed = $true
                    [void]$modifiedIds.Add([string]$timer.Id)
                }
                Copy-SyncTimerFieldsFromRefreshed -Timer $timer -Refreshed $refreshed
                $remaining = Get-TimerRemainingSeconds -Timer $timer -Now $now
            }
            if ($timer.State -ne 'Running' -and $timer.State -ne 'Scheduled') {
                continue
            }
        }

        if ($null -eq $taskNames) {
            $taskNames = Get-PSTimerScheduledTaskNames
        }

        if ($null -ne $taskNames) {
            $taskName = Get-TimerTaskName -Timer $timer
            $taskExists = $taskNames.Contains($taskName)

            if ($remaining -gt 0 -and -not $taskExists) {
                if (Repair-TimerScheduledTaskIfMissing -Timer $timer -TaskNames $taskNames) {
                    $changed = $true
                    [void]$modifiedIds.Add([string]$timer.Id)
                    $taskExists = $true
                }
            }

            if ($remaining -gt 2 -and $taskExists) {
                continue
            }

            if ($taskExists) {
                continue
            }
        }
        elseif ($remaining -gt 2) {
            continue
        }

        if ($remaining -le 0) {
            if ($null -eq $taskNames) {
                continue
            }

            if (Test-TimerWatchAwaitingContinuation -Timer $timer) {
                $refreshed = Find-TimerById -Timers @(Get-TimerData -Force) -Id $timer.Id
                if ($refreshed) {
                    if ($refreshed.State -eq 'Completed') {
                        $timer.State = 'Completed'
                        if ($refreshed.PSObject.Properties.Name -contains 'TaskName') {
                            $timer.TaskName = $refreshed.TaskName
                        }
                        $changed = $true
                        [void]$modifiedIds.Add([string]$timer.Id)
                        continue
                    }
                    if ($refreshed.State -in @('Running', 'Scheduled') -and $refreshed.EndTime) {
                        try {
                            $newEnd = [DateTime]::Parse($refreshed.EndTime)
                            $phaseAdvanced = $timer.IsSequence -and ($null -ne $refreshed.CurrentPhase) -and ([int]$refreshed.CurrentPhase -gt [int]$timer.CurrentPhase)
                            if ($newEnd -gt $now -or $phaseAdvanced) {
                                Copy-SyncTimerFieldsFromRefreshed -Timer $timer -Refreshed $refreshed
                                $changed = $true
                                [void]$modifiedIds.Add([string]$timer.Id)
                                continue
                            }
                        }
                        catch { }
                    }
                }

                $remaining = Get-TimerRemainingSeconds -Timer $timer -Now $now
                if ($null -ne $remaining -and $remaining -gt 0) {
                    if ($null -ne $taskNames) {
                        $null = Repair-TimerScheduledTaskIfMissing -Timer $timer -TaskNames $taskNames
                    }
                    $changed = $true
                    [void]$modifiedIds.Add([string]$timer.Id)
                    continue
                }

                # Fire script may still be speaking; avoid Lost until transition finishes
                if ($null -ne $remaining -and $remaining -gt -30) {
                    continue
                }
            }

            $timer.State = 'Lost'
            $timer | Add-Member -NotePropertyName 'RemainingSeconds' -NotePropertyValue 0 -Force
            $changed = $true
            [void]$modifiedIds.Add([string]$timer.Id)
        }
    }

    if ($changed) {
        try {
            $toSave = Merge-SyncTimerChanges -Timers $timers -ModifiedIds $modifiedIds
            Save-TimerData -Timers $toSave
            $timers = @(Get-TimerData -Force)
        }
        catch {
            # Another console may be writing ps-timers.json at the same time; retry next loop.
        }
    }

    if (-not $script:TimerForceSyncRegister) {
        if (((Get-Date) - $script:TimerStaleCleanupLastRun).TotalSeconds -ge $script:TimerStaleCleanupIntervalSeconds) {
            $null = Remove-StalePSTimerScheduledTasks
            $script:TimerStaleCleanupLastRun = Get-Date
        }
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
    $active = @($Timers | Where-Object { $_.State -in @('Running', 'Scheduled', 'Paused') })
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
    if ($t.State -ne 'Running' -and $t.State -ne 'Scheduled' -and $t.State -ne 'Paused') {
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
    $timerDefaults = Get-PS1TimerModuleTimerDefaults
    if ($timerDefaults.Theme) {
        $theme = $timerDefaults.Theme.ToLower()
    }

    $palettes = Get-PS1TimerModulePalettes
    if (-not $palettes) {
        $palettes = Get-DefaultTimerPalettes
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
    $totalSecs = [math]::Ceiling($Remaining.TotalSeconds)
    if ($totalSecs -le 0) {
        return "00:00:00"
    }
    $hours = [int][math]::Floor($totalSecs / 3600)
    $mins = [int][math]::Floor(($totalSecs % 3600) / 60)
    $secs = [int]($totalSecs % 60)
    return "{0:D2}:{1:D2}:{2:D2}" -f $hours, $mins, $secs
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
    if ($Timer.EndTime) {
        $endTime = [DateTime]::Parse($Timer.EndTime)
        if ($now -ge $endTime) { return [double]100 }
        $total = ($endTime - $startTime).TotalSeconds
        if ($total -le 0) { return [double]100 }
        $elapsed = ($now - $startTime).TotalSeconds
        return [math]::Min(100.0, [math]::Max(0.0, ($elapsed / $total) * 100))
    }

    $elapsed = ($now - $startTime).TotalSeconds
    $percent = ([double]$elapsed / $Timer.Seconds) * 100
    return [math]::Min(100.0, [math]::Max(0.0, $percent))
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
            $remainingPhaseCount = $Timer.Phases.Count - $currentPhase - 1
            if ($remainingPhaseCount -gt 0) {
                if (Test-TimerUniformPhaseSeconds -Timer $Timer -FromPhaseIndex $currentPhase) {
                    $futureSeconds = $remainingPhaseCount * [int]$Timer.Phases[$currentPhase].Seconds
                }
                else {
                    for ($i = $currentPhase + 1; $i -lt $Timer.Phases.Count; $i++) {
                        $futureSeconds += [int]$Timer.Phases[$i].Seconds
                    }
                }
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

function Get-TimerWatchActiveTimers {
    param([array]$Timers)
    return @($Timers | Where-Object { $_.State -in @('Running', 'Paused', 'Scheduled') } | Sort-Object { [int]$_.Id })
}

function Get-TimerWatchFooterText {
    param(
        [hashtable]$Colors,
        [switch]$ShowHelp
    )
    if ($ShowHelp) {
        return @(
            "$($Colors.Dim)  Esc exit  |  Space pause/resume  |  Up/Down timer$($Colors.Reset)"
            "$($Colors.Dim)  Right next phase  |  Left restart/prev(<=3s)  |  ? help$($Colors.Reset)"
        ) -join [Environment]::NewLine
    }
    return "$($Colors.Dim)  Esc exit  |  Space pause  |  Up/Down timer  |  Left/Right phase  |  ? help$($Colors.Reset)"
}

function Wait-TimerWatchInput {
    param([System.Diagnostics.Stopwatch]$Stopwatch)
    $remainingMs = 1000 - $Stopwatch.ElapsedMilliseconds
    while ($remainingMs -gt 0) {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'Escape' { return @{ Action = 'exit' } }
                'Spacebar' { return @{ Action = 'togglePause' } }
                'UpArrow' { return @{ Action = 'prevTimer' } }
                'DownArrow' { return @{ Action = 'nextTimer' } }
                'RightArrow' { return @{ Action = 'nextPhase' } }
                'LeftArrow' { return @{ Action = 'prevPhase' } }
                'Oem2' { return @{ Action = 'toggleHelp' } }
                default {
                    if ($key.KeyChar -eq '?') { return @{ Action = 'toggleHelp' } }
                }
            }
            continue
        }
        $sleepMs = [math]::Min(50, $remainingMs)
        Start-Sleep -Milliseconds $sleepMs
        $remainingMs = 1000 - $Stopwatch.ElapsedMilliseconds
    }
    return @{ Action = 'tick' }
}

function Invoke-TimerSequencePhaseJump {
    <#
    .SYNOPSIS
        Jumps a sequence timer to another phase or restarts the current phase.
    #>
    param(
        [Parameter(Mandatory)][string]$TimerId,
        [ValidateSet('next', 'restart', 'prevOrRestart')]
        [string]$Direction
    )

    $timers = @(Get-TimerData)
    $timer = Find-TimerById -Timers $timers -Id $TimerId
    if (-not $timer -or -not $timer.IsSequence) { return $false }

    $phases = @($timer.Phases)
    if ($phases.Count -eq 0) { return $false }

    $currentPhase = [int]$timer.CurrentPhase
    $targetPhase = $currentPhase

    switch ($Direction) {
        'next' {
            if ($currentPhase -ge ($phases.Count - 1)) { return $false }
            $targetPhase = $currentPhase + 1
        }
        'restart' {
            $targetPhase = $currentPhase
        }
        'prevOrRestart' {
            $phaseStart = [DateTime]::Parse($timer.StartTime)
            $elapsed = ((Get-Date) - $phaseStart).TotalSeconds
            if ($elapsed -le 3 -and $currentPhase -gt 0) {
                $targetPhase = $currentPhase - 1
            }
            else {
                $targetPhase = $currentPhase
            }
        }
    }

    Unregister-TimerCueTasks -Timer $timer
    Stop-TimerTask -TimerId $TimerId -TaskName (Get-TimerTaskName -Timer $timer)

    $phase = $phases[$targetPhase]
    $seconds = [int]$phase.Seconds
    $now = Get-Date
    $timer.CurrentPhase = $targetPhase
    $timer.PhaseLabel = [string]$phase.Label
    $timer.Seconds = $seconds
    $timer.Message = [string]$phase.Label
    $timer.StartTime = $now.ToString('o')
    $timer.EndTime = $now.AddSeconds($seconds).ToString('o')
    $timer.State = 'Running'
    $timer | Add-Member -NotePropertyName 'RemainingSeconds' -NotePropertyValue $null -Force
    $timer | Add-Member -NotePropertyName 'TaskName' -NotePropertyValue (New-TimerTaskName -TimerId $timer.Id) -Force

    Save-TimerData -Timers $timers
    Start-TimerScheduledJob -Timer $timer
    Invoke-RegisterTimerResumeCues -Timer $timer
    return $true
}

function Switch-TimerWatchTarget {
    param(
        [array]$ActiveTimers,
        [string]$CurrentId,
        [ValidateSet('up', 'down')]
        [string]$Direction
    )
    if ($ActiveTimers.Count -le 1) { return $CurrentId }
    $ids = @($ActiveTimers | ForEach-Object { [string]$_.Id })
    $idx = [array]::IndexOf($ids, [string]$CurrentId)
    if ($idx -lt 0) { return [string]$ActiveTimers[0].Id }
    if ($Direction -eq 'up') {
        $idx = if ($idx -le 0) { $ids.Count - 1 } else { $idx - 1 }
    }
    else {
        $idx = if ($idx -ge ($ids.Count - 1)) { 0 } else { $idx + 1 }
    }
    return $ids[$idx]
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

function Get-TimerWatchNotifyLabel {
    <#
    .SYNOPSIS
        Builds notify summary for timer watch display.
    #>
    param([PSCustomObject]$Timer)

    $channels = Get-TimerNotifyChannelsFromTimer -Timer $Timer
    $webhookName = if ($Timer.PSObject.Properties.Name -contains 'WebhookName') { $Timer.WebhookName } else { $null }
    $voice = if ($channels.Voice) { $true } else { $false }
    return Format-TimerNotifyLabel -Visual $channels.Visual -Sound $channels.Sound -WebhookName $webhookName -Voice $voice -CountdownMode $(if ($Timer.PSObject.Properties.Name -contains 'CountdownMode') { $Timer.CountdownMode } else { $null })
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
        [DateTime]$EndTime,
        [PSCustomObject]$Timer = $null
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
    if ($Timer) {
        $notifyLabel = Get-TimerWatchNotifyLabel -Timer $Timer
        [void]$sb.AppendLine((Format-TimerWatchRow -Colors $c -Label 'Notify' -Value $notifyLabel -ValueAnsi $c.Success))
    }
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
        [string]$EndsAtFormatted,
        [switch]$Finishing
    )
    $remainingStr = if ($Finishing) { 'Finishing...' } else { Format-RemainingTime -Remaining $Remaining }
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

    $notifyLabel = Get-TimerWatchNotifyLabel -Timer $CurrentTimer
    [void]$sb.AppendLine((Format-TimerWatchRow -Colors $c -Label 'Notify' -Value $notifyLabel -ValueAnsi $c.Success))

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
        Returns composable Visual/Sound/Webhook settings with legacy Notify fallback.
    #>
    $config = Get-PS1TimerModuleTimerDefaults
    $channels = Get-TimerNotifyChannelsFromSource -Source $config

    return @{
        Visual      = $channels.Visual
        Sound       = $channels.Sound
        Voice       = $channels.Voice
        Webhook     = if ($config.Webhook) { $config.Webhook } else { $null }
        SoundFile = if ($config.SoundFile) { Resolve-TimerSoundFilePath -Name $config.SoundFile } else { $null }
        Notify    = if ($config.Notify) { $config.Notify } else { $null }
        VoiceRate = if ($config.VoiceRate -ne $null) { [int]$config.VoiceRate } else { 0 }
        VoiceName = if ($config.VoiceName) { [string]$config.VoiceName } else { $null }
        VoiceVolume = if ($config.VoiceVolume -ne $null) { [int]$config.VoiceVolume } else { 100 }
        Countdown = if ($config.Countdown) { [string]$config.Countdown } else { 'none' }
    }
}

function Resolve-TimerNotificationSettings {
    <#
    .SYNOPSIS
        Resolves composable notify channels and optional webhook for a new timer.
    #>
    param(
        [string]$NotifyOverride = $null,
        [string]$VisualOverride = $null,
        $SoundOverride = $null,
        [string]$WebhookOverride = $null,
        $VoiceOverride = $null,
        [string]$VoiceNameOverride = $null,
        [string]$CountdownOverride = $null,
        [string]$PresetNotify = $null,
        [string]$PresetVisual = $null,
        $PresetSound = $null,
        $PresetVoice = $null,
        [string]$PresetWebhook = $null,
        [string]$PresetCountdown = $null
    )

    $validLegacy = @('popup', 'toast', 'sound', 'silent', 'webhook')
    $validVisual = @('popup', 'toast', 'none')
    $validCountdown = @('none', '321', '10', 'both')
    $defaults = Get-TimerNotificationConfig
    $visual = $defaults.Visual
    $sound = $defaults.Sound
    $voice = $defaults.Voice
    $webhookName = $defaults.Webhook
    $voiceName = $defaults.VoiceName
    $voiceRate = $defaults.VoiceRate
    $voiceVolume = $defaults.VoiceVolume
    $countdown = $defaults.Countdown
    $legacyWebhookOnly = $false

    if ($NotifyOverride -and ($validLegacy -contains $NotifyOverride.ToLower())) {
        $legacy = ConvertFrom-LegacyNotifyMode -Notify $NotifyOverride
        $visual = $legacy.Visual
        $sound = $legacy.Sound
        $legacyWebhookOnly = ($NotifyOverride.ToLower() -eq 'webhook')
        $webhookName = $null
        if ($WebhookOverride) { $webhookName = $WebhookOverride }
        elseif ($legacyWebhookOnly) { $webhookName = $defaults.Webhook }
    }
    else {
        if ($PresetNotify -and ($validLegacy -contains $PresetNotify.ToLower())) {
            $legacy = ConvertFrom-LegacyNotifyMode -Notify $PresetNotify
            $visual = $legacy.Visual
            $sound = $legacy.Sound
            if ($PresetNotify.ToLower() -eq 'webhook') {
                $legacyWebhookOnly = $true
                $webhookName = if ($PresetWebhook) { $PresetWebhook } else { $defaults.Webhook }
            }
        }
        else {
            if ($PresetVisual -and ($validVisual -contains $PresetVisual.ToLower())) {
                $visual = $PresetVisual.ToLower()
            }
            if ($null -ne $PresetSound) { $sound = [bool]$PresetSound }
            if ($null -ne $PresetVoice) { $voice = [bool]$PresetVoice }
            if ($PresetWebhook) { $webhookName = $PresetWebhook }
            if ($PresetCountdown -and ($validCountdown -contains $PresetCountdown.ToLower())) {
                $countdown = $PresetCountdown.ToLower()
            }
        }

        if ($VisualOverride -and ($validVisual -contains $VisualOverride.ToLower())) {
            $visual = $VisualOverride.ToLower()
        }
        if ($null -ne $SoundOverride) { $sound = [bool]$SoundOverride }
        if ($null -ne $VoiceOverride) { $voice = [bool]$VoiceOverride }
        if ($WebhookOverride) { $webhookName = $WebhookOverride }
        if ($VoiceNameOverride) { $voiceName = $VoiceNameOverride }
        if ($CountdownOverride -and ($validCountdown -contains $CountdownOverride.ToLower())) {
            $countdown = $CountdownOverride.ToLower()
        }
    }

    $webhookUrl = $null
    if (-not [string]::IsNullOrWhiteSpace($webhookName)) {
        $webhookUrl = Resolve-TimerWebhookUrl -Name $webhookName
        if (-not $webhookUrl) {
            Write-Warning "PS1Timer: Webhook '$webhookName' not found in Config.Webhooks."
            if ($legacyWebhookOnly) {
                $visual = 'popup'
                $sound = $true
            }
            $webhookName = $null
        }
    }

    $label = Format-TimerNotifyLabel -Visual $visual -Sound $sound -WebhookName $webhookName -Voice $voice -CountdownMode $countdown
    $legacyNotify = if (-not $sound -and -not $voice -and $visual -eq 'none' -and -not $webhookUrl) {
        'silent'
    }
    elseif (-not $sound -and -not $voice -and $visual -eq 'none' -and $webhookUrl) {
        'webhook'
    }
    elseif (($sound -or $voice) -and $visual -eq 'none' -and -not $webhookUrl) {
        'sound'
    }
    else {
        $visual
    }

    return @{
        Visual      = $visual
        Sound       = $sound
        Voice       = $voice
        WebhookName = $webhookName
        WebhookUrl  = $webhookUrl
        SoundFile   = $defaults.SoundFile
        Label       = $label
        NotifyType  = $legacyNotify
        VoiceName   = $voiceName
        VoiceRate   = $voiceRate
        VoiceVolume = $voiceVolume
        Countdown   = $countdown
    }
}

function Get-TimerFireScriptSoundBlock {
    <#
    .SYNOPSIS
        PowerShell block for sound in timer fire scripts.
    #>
    param(
        [bool]$Sound = $true,
        [string]$SoundFile = $null,
        [ValidateSet('simple', 'sequence')]
        [string]$Mode = 'simple'
    )

    if (-not $Sound) { return '' }

    if ($SoundFile) {
        $escapedSound = $SoundFile -replace "'", "''"
        return @"
if (`$notifySound) {
    try {
        if (Test-Path -LiteralPath '$escapedSound') {
            `$player = New-Object System.Media.SoundPlayer '$escapedSound'
            `$player.PlaySync()
        } else {
            [console]::beep(440, 500)
        }
    } catch {
        try { [console]::beep(440, 500) } catch { }
    }
}
"@
    }

    if ($Mode -eq 'sequence') {
        return @"
if (`$notifySound) {
    try {
        if (`$currentPhase -eq `$totalPhases - 1) {
            [console]::beep(523, 200); [console]::beep(659, 200); [console]::beep(784, 400)
        } else {
            [console]::beep(440, 300)
        }
    } catch { }
}
"@
    }

    return @"
if (`$notifySound) {
    try { [console]::beep(440, 500) } catch { }
}
"@
}

function Get-TimerFireScriptVoiceBlock {
    <#
    .SYNOPSIS
        PowerShell block for TTS in timer fire scripts.
    #>
    param(
        [bool]$Voice = $false,
        [string]$TextExpr = '$announceText',
        [string]$VoiceName = $null,
        [int]$VoiceRate = 0,
        [int]$VoiceVolume = 100
    )

    if (-not $Voice) { return '' }

    $voiceNameBlock = if ($VoiceName) {
        $escaped = $VoiceName -replace "'", "''"
        "`$s.SelectVoice('$escaped') | Out-Null"
    } else { '' }

    return @"
if (`$notifyVoice -and -not [string]::IsNullOrWhiteSpace($TextExpr)) {
    try {
        Add-Type -AssemblyName System.Speech
        `$s = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $voiceNameBlock
        `$s.Rate = $VoiceRate
        `$s.Volume = $VoiceVolume
        `$s.Speak($TextExpr)
        `$s.Dispose()
    } catch {
        try { [console]::beep(440, 300) } catch { }
    }
}
"@
}

function Invoke-TimerSpeech {
    <#
    .SYNOPSIS
        Speaks text using Windows TTS (interactive/immediate use).
    #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [string]$VoiceName = $null,
        [int]$VoiceRate = 0,
        [int]$VoiceVolume = 100
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    if (Test-PS1TimerTestMode) { return }

    try {
        Add-Type -AssemblyName System.Speech
        $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
        if ($VoiceName) { $synth.SelectVoice($VoiceName) | Out-Null }
        $synth.Rate = $VoiceRate
        $synth.Volume = $VoiceVolume
        $synth.Speak($Text)
        $synth.Dispose()
    }
    catch {
        Write-Warning "PS1Timer: Voice failed: $($_.Exception.Message)"
        try { [console]::beep(440, 300) } catch { }
    }
}

function Get-TimerPhaseAnnounceStartText {
    param([object]$Phase)

    if (-not $Phase) { return '' }
    if ($Phase.PSObject.Properties.Name -contains 'AnnounceStart' -and $Phase.AnnounceStart) {
        return [string]$Phase.AnnounceStart
    }
    if ($Phase.Label) {
        return [string]$Phase.Label
    }
    return ''
}

function Get-SequenceTimerIntroSpeechText {
    <#
    .SYNOPSIS
        Builds the spoken session intro before the first phase clock starts.
    #>
    param(
        [switch]$IsWorkout,
        [string]$WorkoutRoutine = $null,
        [object]$FirstPhase,
        [DateTime]$StartTime,
        [object]$Summary,
        [array]$Phases
    )

    if ($IsWorkout -and $WorkoutRoutine) {
        $workoutDesc = $WorkoutRoutine
        $workouts = Get-PS1TimerModuleWorkouts
        if ($workouts -and $workouts.ContainsKey($WorkoutRoutine) -and $workouts[$WorkoutRoutine].Description) {
            $workoutDesc = [string]$workouts[$WorkoutRoutine].Description
        }
        $finalEndTime = $StartTime.AddSeconds($Summary.TotalSeconds)
        return Resolve-TimerSpeechText -TemplateKey 'WorkoutStart' -Tokens @{
            routine     = $WorkoutRoutine
            description = $workoutDesc
            duration    = $Summary.TotalDuration
            endTime     = $finalEndTime.ToString('HH:mm:ss')
            phaseCount  = [string]$Phases.Count
        }
    }

    return Resolve-TimerSpeechText -TemplateKey 'PhaseStart' -Tokens @{ label = $FirstPhase.Label }
}

function Get-SequenceTimerStartSpeechTexts {
    <#
    .SYNOPSIS
        Builds spoken intro lines for a newly started sequence or workout timer.
    #>
    param(
        [switch]$IsWorkout,
        [string]$WorkoutRoutine = $null,
        [object]$FirstPhase,
        [DateTime]$StartTime,
        [object]$Summary,
        [array]$Phases
    )

    $intro = Get-SequenceTimerIntroSpeechText -IsWorkout:$IsWorkout -WorkoutRoutine $WorkoutRoutine -FirstPhase $FirstPhase -StartTime $StartTime -Summary $Summary -Phases $Phases
    if ([string]::IsNullOrWhiteSpace($intro)) { return @() }
    return ,@($intro)
}

function Invoke-TimerSpeechQueue {
    param(
        [Parameter(Mandatory)][string[]]$Texts,
        [string]$VoiceName = $null,
        [int]$VoiceRate = 0,
        [int]$VoiceVolume = 100
    )

    foreach ($text in $Texts) {
        Invoke-TimerSpeech -Text $text -VoiceName $VoiceName -VoiceRate $VoiceRate -VoiceVolume $VoiceVolume
    }
}

function Write-TimerSpeechQueueScriptFile {
    <#
    .SYNOPSIS
        Writes a short-lived fire-and-forget script for queued TTS (watch/list async start speech).
    #>
    param(
        [Parameter(Mandatory)][string[]]$Texts,
        [string]$VoiceName = $null,
        [int]$VoiceRate = 0,
        [int]$VoiceVolume = 100
    )

    $queue = @($Texts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($queue.Count -eq 0) { return $null }

    $scriptId = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $scriptPath = Join-Path $env:TEMP "PSTimer_speech_$scriptId.ps1"
    $escapedScriptPath = $scriptPath -replace "'", "''"

    $voiceNameLine = if ($VoiceName) {
        $escapedVoice = $VoiceName -replace "'", "''"
        "`$synth.SelectVoice('$escapedVoice') | Out-Null"
    } else { '' }

    $speakLines = [System.Collections.Generic.List[string]]::new()
    foreach ($text in $queue) {
        $escapedText = ([string]$text) -replace "'", "''"
        [void]$speakLines.Add("`$synth.Speak('$escapedText')")
    }
    if ($speakLines.Count -eq 0) { return $null }

    $content = (Get-TimerTestScriptGuard) + @"
try {
    Add-Type -AssemblyName System.Speech
    `$synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    $voiceNameLine
    `$synth.Rate = $VoiceRate
    `$synth.Volume = $VoiceVolume
    $($speakLines -join "`n    ")
    `$synth.Dispose()
} catch {
    try { [console]::beep(440, 300) } catch { }
}
Remove-Item -LiteralPath '$escapedScriptPath' -Force -ErrorAction SilentlyContinue
"@

    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($scriptPath, $content, $utf8Bom)
    return $scriptPath
}

function Invoke-TimerSpeechQueueAsync {
    <#
    .SYNOPSIS
        Speaks queued text in a hidden pwsh process so watch/list UI can render immediately.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Texts,
        [string]$VoiceName = $null,
        [int]$VoiceRate = 0,
        [int]$VoiceVolume = 100
    )

    $queue = @($Texts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($queue.Count -eq 0) { return }
    if (Test-PS1TimerTestMode) { return }

    $scriptPath = Write-TimerSpeechQueueScriptFile -Texts $queue -VoiceName $VoiceName -VoiceRate $VoiceRate -VoiceVolume $VoiceVolume
    if (-not $scriptPath) { return }

    try {
        Start-Process -FilePath $script:PS1TimerPwsh -ArgumentList @(
            '-NoProfile',
            '-WindowStyle', 'Hidden',
            '-File', $scriptPath
        ) -WindowStyle Hidden -ErrorAction Stop | Out-Null
    }
    catch {
        try { [console]::beep(440, 300) } catch { }
    }
}

function Get-TimerPhaseDataFromObject {
    param([object]$Phase)

    $countdown = 'none'
    if ($Phase.PSObject.Properties.Name -contains 'Countdown' -and $Phase.Countdown) {
        $countdown = [string]$Phase.Countdown
    }
    $announceStart = if ($Phase.PSObject.Properties.Name -contains 'AnnounceStart' -and $Phase.AnnounceStart) {
        [string]$Phase.AnnounceStart
    } elseif ($Phase.Label) {
        [string]$Phase.Label
    } else { '' }

    return @{
        Countdown     = $countdown
        AnnounceStart = $announceStart
        AnnounceEnd   = if ($Phase.PSObject.Properties.Name -contains 'AnnounceEnd') { $Phase.AnnounceEnd } else { $null }
        PhaseType     = if ($Phase.PSObject.Properties.Name -contains 'PhaseType') { $Phase.PhaseType } else { $null }
        ExerciseName  = if ($Phase.PSObject.Properties.Name -contains 'ExerciseName') { $Phase.ExerciseName } else { $null }
        SetNumber     = if ($Phase.PSObject.Properties.Name -contains 'SetNumber') { $Phase.SetNumber } else { $null }
        SetTotal      = if ($Phase.PSObject.Properties.Name -contains 'SetTotal') { $Phase.SetTotal } else { $null }
    }
}

function New-TimerCueTaskName {
    param([string]$TimerId)
    return "PSTimer_${TimerId}_cue_$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
}

function Write-TimerBeepCueFireScriptFile {
    param([Parameter(Mandatory)][string]$CueTaskName)

    $scriptPath = Join-Path $env:TEMP "$CueTaskName.ps1"
    $content = (Get-TimerTestScriptGuard) + @"
try { [console]::beep(880, 120) } catch { }
"@
    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($scriptPath, $content, $utf8Bom)
    return $scriptPath
}

function Get-TimerBeepAtSeconds {
    param(
        [PSCustomObject]$Timer,
        [object]$Phase = $null
    )

    if ($Phase -and $Phase.PSObject.Properties.Name -contains 'BeepAt' -and $Phase.BeepAt) {
        return @($Phase.BeepAt | ForEach-Object { [int]$_ })
    }
    if ($Timer.PSObject.Properties.Name -contains 'BeepAt' -and $Timer.BeepAt) {
        return @($Timer.BeepAt | ForEach-Object { [int]$_ })
    }
    return @()
}

function Test-TimerNeedsPhaseCues {
    param([PSCustomObject]$Timer)

    if ((Get-TimerBeepAtSeconds -Timer $Timer).Count -gt 0) {
        return $true
    }
    if ((Get-TimerNotifyChannelsFromTimer -Timer $Timer).Voice) {
        return $true
    }
    if ($Timer.IsSequence) {
        $phaseIndex = if ($Timer.PSObject.Properties.Name -contains 'CurrentPhase') { [int]$Timer.CurrentPhase } else { 0 }
        $totalPhases = if ($Timer.PSObject.Properties.Name -contains 'TotalPhases') { [int]$Timer.TotalPhases } else { 0 }
        if ($phaseIndex -lt ($totalPhases - 1)) {
            return $true
        }
    }
    return $false
}

function Save-TimerCueTaskNames {
    param(
        [Parameter(Mandatory)][string]$TimerId,
        [string[]]$CueTaskNames
    )

    $timers = @(Get-TimerData)
    $timer = Find-TimerById -Timers $timers -Id $TimerId
    if (-not $timer) { return }

    $timer | Add-Member -NotePropertyName 'CueTaskNames' -NotePropertyValue @($CueTaskNames) -Force
    Save-TimerData -Timers $timers
}

function Write-TimerCueFireScriptFile {
    param(
        [Parameter(Mandatory)][string]$CueTaskName,
        [Parameter(Mandatory)][string]$SpeakText,
        [string]$VoiceName = $null,
        [int]$VoiceRate = 0,
        [int]$VoiceVolume = 100
    )

    $escapedText = $SpeakText -replace "'", "''"
    $voiceBlock = Get-TimerFireScriptVoiceBlock -Voice $true -TextExpr "'$escapedText'" -VoiceName $VoiceName -VoiceRate $VoiceRate -VoiceVolume $VoiceVolume
    $scriptPath = Join-Path $env:TEMP "$CueTaskName.ps1"
    $content = (Get-TimerTestScriptGuard) + @"
`$notifyVoice = `$true
$voiceBlock
"@
    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($scriptPath, $content, $utf8Bom)
    return $scriptPath
}

function Register-TimerCueTask {
    param(
        [Parameter(Mandatory)][string]$CueTaskName,
        [Parameter(Mandatory)][datetime]$TriggerTime,
        [Parameter(Mandatory)][string]$ScriptPath
    )

    $vbsPath = Join-Path $env:TEMP "$CueTaskName.vbs"
    Write-TimerVbsLauncherFile -VbsPath $vbsPath -Ps1Path $ScriptPath

    $null = Register-TimerScheduledTask -TaskName $CueTaskName -TriggerTime $TriggerTime -VbsPath $vbsPath
    return $CueTaskName
}

function Unregister-TimerCueTasks {
    param([PSCustomObject]$Timer)

    $cueNames = [System.Collections.Generic.List[string]]::new()
    if ($Timer.PSObject.Properties.Name -contains 'CueTaskNames' -and $Timer.CueTaskNames) {
        foreach ($n in @($Timer.CueTaskNames)) {
            if (-not [string]::IsNullOrWhiteSpace($n)) { [void]$cueNames.Add($n) }
        }
    }

    $id = [string]$Timer.Id
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
            if ($name -like "PSTimer_${id}_cue_*") {
                [void]$cueNames.Add($name)
            }
        }
    }
    catch { }
    finally {
        if ($tasks) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($tasks) | Out-Null }
        if ($folder) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($folder) | Out-Null }
        if ($service) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($service) | Out-Null }
    }

    $unique = @($cueNames | Select-Object -Unique)
    if ($unique.Count -gt 0) {
        Remove-TimerScheduledTasks -Names $unique
    }

    foreach ($name in $unique) {
        $ps1 = Join-Path $env:TEMP "$name.ps1"
        $vbs = Join-Path $env:TEMP "$name.vbs"
        Remove-Item -LiteralPath $ps1 -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $vbs -Force -ErrorAction SilentlyContinue
    }

    $Timer | Add-Member -NotePropertyName 'CueTaskNames' -NotePropertyValue @() -Force
}

function Register-TimerPhaseCueTasks {
    param(
        [PSCustomObject]$Timer,
        [int]$PhaseSeconds,
        [object]$Phase = $null,
        [datetime]$PhaseStart = (Get-Date)
    )

    Unregister-TimerCueTasks -Timer $Timer

    $phaseIndex = if ($Timer.PSObject.Properties.Name -contains 'CurrentPhase') { [int]$Timer.CurrentPhase } else { 0 }
    $beepAt = @(Get-TimerBeepAtSeconds -Timer $Timer -Phase $Phase)
    $hasNextPhase = $false
    if ($Timer.IsSequence) {
        $totalPhases = if ($Timer.PSObject.Properties.Name -contains 'TotalPhases') { [int]$Timer.TotalPhases } else { @($Timer.Phases).Count }
        $hasNextPhase = ($phaseIndex -lt ($totalPhases - 1))
    }

    $channels = Get-TimerNotifyChannelsFromTimer -Timer $Timer
    $needVoice = $channels.Voice
    if (-not $needVoice -and $beepAt.Count -eq 0 -and -not $hasNextPhase) {
        return @()
    }

    $phaseData = if ($Phase) {
        Get-TimerPhaseDataFromObject -Phase $Phase
    }
    else {
        @{
            Countdown     = if ($Timer.PSObject.Properties.Name -contains 'CountdownMode' -and $Timer.CountdownMode) { [string]$Timer.CountdownMode } else { 'none' }
            AnnounceStart = if ($Timer.Message) { [string]$Timer.Message } else { '' }
        }
    }

    $countdown = if ($needVoice) { $phaseData.Countdown } else { 'none' }
    $startText = if ($needVoice) { $phaseData.AnnounceStart } else { $null }

    # Phase transitions speak the next label at phase end; skip start cues to avoid duplicates.
    # Workout phase 0 first exercise is spoken synchronously at workout start.
    $includePhaseStart = $false

    $cues = @(Get-TimerPhaseCueSchedule -PhaseSeconds $PhaseSeconds `
        -CountdownMode $countdown `
        -PhaseStartText $startText `
        -IncludePhaseStartAtZero:$includePhaseStart `
        -BeepAtSeconds $beepAt `
        -IncludeEndBeep321:$hasNextPhase)

    if ($cues.Count -eq 0) { return @() }

    $phaseEnd = if ($Timer.EndTime) { [DateTime]::Parse($Timer.EndTime) } else { $PhaseStart.AddSeconds($PhaseSeconds) }
    $voiceName = if ($Timer.PSObject.Properties.Name -contains 'VoiceName') { $Timer.VoiceName } else { $null }
    $voiceRate = if ($Timer.PSObject.Properties.Name -contains 'VoiceRate') { [int]$Timer.VoiceRate } else { 0 }
    $voiceVolume = if ($Timer.PSObject.Properties.Name -contains 'VoiceVolume') { [int]$Timer.VoiceVolume } else { 100 }

    $cueNames = [System.Collections.Generic.List[string]]::new()
    foreach ($cue in $cues) {
        $trig = $phaseEnd.AddSeconds(-[int]$cue.OffsetFromEnd)
        if ($trig -le (Get-Date)) { continue }
        $cueTask = New-TimerCueTaskName -TimerId $Timer.Id
        if ($cue.CueType -eq 'beep') {
            $scriptPath = Write-TimerBeepCueFireScriptFile -CueTaskName $cueTask
        }
        else {
            $scriptPath = Write-TimerCueFireScriptFile -CueTaskName $cueTask -SpeakText $cue.Text -VoiceName $voiceName -VoiceRate $voiceRate -VoiceVolume $voiceVolume
        }
        $null = Register-TimerCueTask -CueTaskName $cueTask -TriggerTime $trig -ScriptPath $scriptPath
        [void]$cueNames.Add($cueTask)
    }

    $Timer | Add-Member -NotePropertyName 'CueTaskNames' -NotePropertyValue @($cueNames) -Force
    Save-TimerCueTaskNames -TimerId $Timer.Id -CueTaskNames @($cueNames)

    Write-TimerCueRegistrarFile -TimerId $Timer.Id -VoiceName $voiceName -VoiceRate $voiceRate -VoiceVolume $voiceVolume | Out-Null

    return @($cueNames)
}

function Write-TimerCueRegistrarFile {
    param(
        [Parameter(Mandatory)][string]$TimerId,
        [string]$VoiceName = $null,
        [int]$VoiceRate = 0,
        [int]$VoiceVolume = 100
    )

    $path = Join-Path $env:TEMP "PSTimer_${TimerId}_register_cues.ps1"
    $voiceNameLine = if ($VoiceName) {
        $escaped = $VoiceName -replace "'", "''"
        "`$synth.SelectVoice('$escaped') | Out-Null"
    } else { '' }
    $escapedPwsh = $script:PS1TimerPwsh -replace "'", "''"

    $content = @"
param([Parameter(Mandatory)][int]`$PhaseIndex)

$(Get-TimerEmbeddedDataFileIoScript)

`$dataFile = Join-Path `$env:TEMP 'ps-timers.json'
`$timerId = '$TimerId'
if (-not (Test-Path -LiteralPath `$dataFile)) { exit }
`$parsed = Get-Content -LiteralPath `$dataFile -Raw | ConvertFrom-Json
`$timers = if (`$parsed -is [array]) { @(`$parsed) } else { @(`$parsed) }
`$timer = `$timers | Where-Object { [string]`$_.Id -eq `$timerId } | Select-Object -First 1
if (-not `$timer) { exit }

`$existing = @()
if (`$timer.CueTaskNames) { `$existing = @(`$timer.CueTaskNames) }
foreach (`$cn in `$existing) {
    Unregister-ScheduledTask -TaskName `$cn -Confirm:`$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path `$env:TEMP "`$cn.ps1") -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path `$env:TEMP "`$cn.vbs") -Force -ErrorAction SilentlyContinue
}

`$isSequence = [bool]`$timer.IsSequence
`$phase = `$null
`$seconds = [int]`$timer.Seconds
if (`$isSequence) {
    `$phases = @(`$timer.Phases)
    if (`$PhaseIndex -lt 0 -or `$PhaseIndex -ge `$phases.Count) { exit }
    `$phase = `$phases[`$PhaseIndex]
    `$seconds = [int]`$phase.Seconds
}

`$hasNextPhase = `$false
if (`$isSequence) {
    `$hasNextPhase = (`$PhaseIndex -lt (@(`$timer.Phases).Count - 1))
}

`$beepAt = @()
if (`$timer.BeepAt) { `$beepAt = @(`$timer.BeepAt | ForEach-Object { [int]`$_ }) }
if (`$phase -and `$phase.BeepAt) { `$beepAt = @(`$phase.BeepAt | ForEach-Object { [int]`$_ }) }

`$needVoice = [bool]`$timer.NotifyVoice
if (-not `$needVoice -and `$beepAt.Count -eq 0 -and -not `$hasNextPhase) {
    `$timer.CueTaskNames = @()
    Write-TimerDataFileAtomic -DataFile `$dataFile -Content (ConvertTo-Json -InputObject `$timers -Depth 12)
    exit
}

`$phaseEnd = if (`$timer.EndTime) { [DateTime]::Parse(`$timer.EndTime) } else { (Get-Date).AddSeconds(`$seconds) }
`$remaining = [int](`$phaseEnd - (Get-Date)).TotalSeconds
if (`$remaining -gt 0 -and `$remaining -lt `$seconds) { `$seconds = `$remaining }
if (`$seconds -le 0) { exit }

`$countdown = 'none'
if (`$needVoice) {
    `$countdown = if (`$timer.CountdownMode) { [string]`$timer.CountdownMode } else { 'none' }
    if (`$phase -and `$phase.Countdown) { `$countdown = [string]`$phase.Countdown }
}

`$cueList = @()
if (`$countdown -eq 'both') { `$modes = @('10','321') } elseif (`$countdown -ne 'none') { `$modes = @(`$countdown) } else { `$modes = @() }
foreach (`$mode in `$modes) {
    if (`$mode -eq '10' -and `$seconds -ge 10) { `$cueList += [PSCustomObject]@{ OffsetFromEnd = 10; Text = '10'; CueType = 'countdown' } }
    if (`$mode -eq '321') {
        `$maxTick = [Math]::Min(3, `$seconds)
        for (`$ci = `$maxTick; `$ci -ge 1; `$ci--) { `$cueList += [PSCustomObject]@{ OffsetFromEnd = `$ci; Text = [string]`$ci; CueType = 'countdown' } }
    }
}

`$beepOffsets = [System.Collections.Generic.HashSet[int]]::new()
foreach (`$offset in `$beepAt) {
    if (`$offset -gt 0 -and `$offset -le `$seconds) { [void]`$beepOffsets.Add([int]`$offset) }
}
if (`$hasNextPhase) {
    `$maxTick = [Math]::Min(3, `$seconds)
    for (`$ci = `$maxTick; `$ci -ge 1; `$ci--) { [void]`$beepOffsets.Add(`$ci) }
}
foreach (`$offset in (`$beepOffsets | Sort-Object -Descending)) {
    `$cueList += [PSCustomObject]@{ OffsetFromEnd = `$offset; Text = `$null; CueType = 'beep' }
}

`$newCueNames = @()
foreach (`$cue in (`$cueList | Sort-Object -Property OffsetFromEnd -Descending)) {
    `$trig = `$phaseEnd.AddSeconds(-[int]`$cue.OffsetFromEnd)
    if (`$trig -le (Get-Date)) { continue }
    `$cueTask = "PSTimer_`$timerId`_cue_`$([Guid]::NewGuid().ToString('N').Substring(0,8))"
    `$cuePs1 = Join-Path `$env:TEMP "`$cueTask.ps1"
    if (`$cue.CueType -eq 'beep') {
        `$cueBody = 'try { [console]::beep(880, 120) } catch { }'
    } else {
        `$escapedSpeak = (`$cue.Text -replace "'", "''")
        `$cueLines = @(
            '`$notifyVoice = `$true',
            'try {',
            '    Add-Type -AssemblyName System.Speech',
            '    `$synth = New-Object System.Speech.Synthesis.SpeechSynthesizer',
            'VOICE_NAME_LINE',
            '    `$synth.Rate = VOICE_RATE',
            '    `$synth.Volume = VOICE_VOLUME',
            '    `$synth.Speak(''SPEAK_TEXT'')',
            '    `$synth.Dispose()',
            '} catch { try { [console]::beep(440,300) } catch {} }'
        )
        `$cueBody = (`$cueLines -join [char]10) -replace 'VOICE_NAME_LINE', '$voiceNameLine' -replace 'VOICE_RATE', '$VoiceRate' -replace 'VOICE_VOLUME', '$VoiceVolume' -replace 'SPEAK_TEXT', `$escapedSpeak
    }
    `$utf8 = New-Object System.Text.UTF8Encoding `$true
    [System.IO.File]::WriteAllText(`$cuePs1, `$cueBody, `$utf8)
    `$cueVbs = Join-Path `$env:TEMP "`$cueTask.vbs"
    `$pwshPath = '$escapedPwsh'
    `$ps1Esc = `$cuePs1.Replace('"', '""')
    `$pwshEsc = `$pwshPath.Replace('"', '""')
    `$vbsArgs = ' -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File '
    `$vbsContent = (
        'Set WshShell = CreateObject("WScript.Shell")' + [char]13 + [char]10 +
        'WshShell.Run Chr(34) & "' + `$pwshEsc + '" & Chr(34) & "' + `$vbsArgs + '" & Chr(34) & "' + `$ps1Esc + '" & Chr(34), 0, False' + [char]13 + [char]10 +
        'Set WshShell = Nothing'
    )
    [System.IO.File]::WriteAllText(`$cueVbs, `$vbsContent, [System.Text.Encoding]::ASCII)
    `$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"`$cueVbs`""
    `$trigger = New-ScheduledTaskTrigger -Once -At `$trig
    `$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Hidden
    try {
        Register-ScheduledTask -TaskName `$cueTask -Action `$action -Trigger `$trigger -Settings `$settings -Force -ErrorAction Stop | Out-Null
        `$newCueNames += `$cueTask
    } catch { }
}

`$timer.CueTaskNames = `$newCueNames
Write-TimerDataFileAtomic -DataFile `$dataFile -Content (ConvertTo-Json -InputObject `$timers -Depth 12)
"@

    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($path, $content, $utf8Bom)
    return $path
}

function Invoke-TimerPhaseCueRegistration {
    param(
        [Parameter(Mandatory)][string]$TimerId,
        [Parameter(Mandatory)][int]$PhaseIndex,
        [string]$VoiceName = $null,
        [int]$VoiceRate = 0,
        [int]$VoiceVolume = 100
    )

    $registrar = Write-TimerCueRegistrarFile -TimerId $TimerId -VoiceName $VoiceName -VoiceRate $VoiceRate -VoiceVolume $VoiceVolume
    & $script:PS1TimerPwsh -NoProfile -WindowStyle Hidden -File $registrar -PhaseIndex $PhaseIndex | Out-Null
}

function Get-TimerFireScriptRegisterCuesBlock {
    param([string]$TimerId)

    $registrar = Join-Path $env:TEMP "PSTimer_${TimerId}_register_cues.ps1"
    $escaped = $registrar -replace "'", "''"
    return @"
            `$registrar = '$escaped'
            if (Test-Path -LiteralPath `$registrar) {
                & '$($script:PS1TimerPwsh -replace "'", "''")' -NoProfile -WindowStyle Hidden -File `$registrar -PhaseIndex `$nextPhaseIdx
            }
"@
}

function Get-TimerFireScriptVisualBlock {
    <#
    .SYNOPSIS
        PowerShell switch block for visual notifications in fire scripts.
    #>
    param(
        [ValidateSet('popup', 'toast', 'none')]
        [string]$Visual = 'popup',
        [ValidateSet('simple', 'sequence')]
        [string]$Mode = 'simple'
    )

    if ($Visual -eq 'none') { return '' }

    if ($Mode -eq 'sequence') {
        return @"
switch (`$notifyVisual) {
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
    'popup' {
        `$popup = New-Object -ComObject WScript.Shell
        `$popup.Popup((`$body -join [char]10), 0, `$title, 64) | Out-Null
    }
    'none' { }
}
"@
    }

    return @"
switch (`$notifyVisual) {
    'toast' {
        try {
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
            `$popup = New-Object -ComObject WScript.Shell
            `$popup.Popup((`$body -join [char]10), 0, `$message, 64) | Out-Null
        }
    }
    'popup' {
        `$popup = New-Object -ComObject WScript.Shell
        `$popup.Popup((`$body -join [char]10), 0, `$message, 64) | Out-Null
    }
    'none' { }
}
"@
}

function Get-TimerFireScriptWebhookBlock {
    <#
    .SYNOPSIS
        PowerShell if-block for webhook notifications in fire scripts.
    #>
    param([string]$WebhookUrl)
    if ([string]::IsNullOrWhiteSpace($WebhookUrl)) { return '' }
    $escapedUrl = $WebhookUrl -replace "'", "''"
    return @"
if (`$webhookUrl) {
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
    $timerDefaults = Get-PS1TimerModuleTimerDefaults
    if ($timerDefaults.AfterStart -and ($valid -contains $timerDefaults.AfterStart)) {
        return $timerDefaults.AfterStart
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

    if (Test-PS1TimerTestMode) { return }

    switch (Get-TimerAfterStartAction -Override $AfterStart) {
        'watch' { Timer-Watch -Id $TimerId }
        'list'  { Timer-List -Watch }
    }
}

function Show-TimerNotification {
    <#
    .SYNOPSIS
        Shows a timer notification using composable visual and sound channels.
    .PARAMETER Visual
        Visual channel: popup, toast, none
    .PARAMETER Sound
        Whether to play sound
    .PARAMETER Type
        Legacy notification type (maps to Visual/Sound when Visual not set)
    #>
    param(
        [ValidateSet('popup', 'toast', 'none')]
        [string]$Visual = $null,
        [bool]$Sound = $true,
        [ValidateSet('popup', 'toast', 'sound', 'silent', 'webhook')]
        [string]$Type = $null,
        [Parameter(Mandatory=$true)]
        [string]$Title,
        [string]$Message = '',
        [array]$Body = @(),
        [string]$SoundFile = $null
    )

    if ($Type -and -not $Visual) {
        $legacy = ConvertFrom-LegacyNotifyMode -Notify $Type
        $Visual = $legacy.Visual
        $Sound = $legacy.Sound
    }
    if (-not $Visual) { $Visual = 'popup' }

    if (Test-PS1TimerTestMode) { return }

    if ($Sound) {
        $soundType = if ($Visual -eq 'none') { 'sound' } else { $Visual }
        Play-TimerSound -Type $soundType -SoundFile $SoundFile
    }

    switch ($Visual) {
        'popup' { Show-TimerPopup -Title $Title -Body $Body }
        'toast' { Show-TimerToast -Title $Title -Message $Message -Body $Body }
        'none'  { }
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

    if (Test-PS1TimerTestMode) { return }

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

    if (Test-PS1TimerTestMode) { return }

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

    if (Test-PS1TimerTestMode) { return }
    
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
        Resolves legacy notification type from various sources (deprecated).
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
    Write-Host "  Three independent channels (config.ps1 TimerDefaults):" -ForegroundColor White
    Write-Host "    Visual  popup | toast | none" -ForegroundColor Green
    Write-Host "    Sound   `$true | `$false" -ForegroundColor Green
    Write-Host "    Webhook named key from Webhooks (fires when set)" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Per-timer flags:" -ForegroundColor Yellow
    Write-Host "    t 25m -Visual toast -Sound" -ForegroundColor Gray
    Write-Host "    t 25m -Visual none -Sound              # sound only" -ForegroundColor Gray
    Write-Host "    t 25m -Webhook discord-main            # adds webhook" -ForegroundColor Gray
    Write-Host "    t 25m -Notify toast                    # legacy shorthand" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Legacy -Notify shorthand:" -ForegroundColor Yellow
    Write-Host "    popup | toast | sound | silent | webhook" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Default Configuration (config.ps1):" -ForegroundColor Yellow
    Write-Host "    TimerDefaults = @{" -ForegroundColor Gray
    Write-Host "        Visual  = 'toast'" -ForegroundColor Gray
    Write-Host "        Sound   = `$true" -ForegroundColor Gray
    Write-Host "        Webhook = 'discord-main'" -ForegroundColor Gray
    Write-Host "        SoundFile = 'notify'             # name from Sounds" -ForegroundColor Gray
    Write-Host "    }" -ForegroundColor Gray
    Write-Host ""
    $sounds = Get-PS1TimerModuleSounds
    if ($sounds -and $sounds.Count -gt 0) {
        Write-Host "  Available sounds (Config.Sounds):" -ForegroundColor Yellow
        foreach ($name in ($sounds.Keys | Sort-Object)) {
            Write-Host "    $name" -ForegroundColor Green
        }
        Write-Host ""
    }
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
    $content = (Get-TimerTestScriptGuard) + $ScriptBody
    [System.IO.File]::WriteAllText($scriptPath, $content, $utf8Bom)
    return $scriptPath
}

function Write-TimerVbsLauncherFile {
    param(
        [Parameter(Mandatory)][string]$VbsPath,
        [Parameter(Mandatory)][string]$Ps1Path
    )

    $vbsScript = Get-TimerVbsWrapperScript -Ps1Path $Ps1Path
    $vbsScript | Set-Content -LiteralPath $VbsPath -Force -Encoding Ascii
    return $VbsPath
}

function Write-TimerVbsWrapperFile {
    param([Parameter(Mandatory)][string]$TimerId)
    $scriptPath = Join-Path $env:TEMP "PSTimer_$TimerId.ps1"
    $vbsPath = Join-Path $env:TEMP "PSTimer_$TimerId.vbs"
    return Write-TimerVbsLauncherFile -VbsPath $vbsPath -Ps1Path $scriptPath
}

function Register-TimerScheduledTask {
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][datetime]$TriggerTime,
        [Parameter(Mandatory)][string]$VbsPath,
        [string]$TimerId = $null
    )

    if (Test-PS1TimerTestMode) { return $true }

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
        $embeddedIo = @'
function Write-TimerDataFileAtomic {
    param(
        [Parameter(Mandatory)][string]$DataFile,
        [Parameter(Mandatory)][string]$Content
    )
    $mutexName = 'Global\PS1Timer_ps-timers_json'
    $utf8Bom = [System.Text.UTF8Encoding]::new($true)
    $attempt = 0
    while ($attempt -lt 8) {
        $attempt++
        $mutex = $null
        $acquired = $false
        try {
            $mutex = [System.Threading.Mutex]::new($false, $mutexName)
            $acquired = $mutex.WaitOne(8000)
            if (-not $acquired) {
                throw [System.IO.IOException]::new('Timed out waiting for timer data file lock.')
            }
            $tmpPath = "$DataFile.$([Guid]::NewGuid().ToString('N')).tmp"
            try {
                [System.IO.File]::WriteAllText($tmpPath, $Content, $utf8Bom)
                [System.IO.File]::Move($tmpPath, $DataFile, $true)
            }
            finally {
                if (Test-Path -LiteralPath $tmpPath) {
                    Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue
                }
            }
            return
        }
        catch [System.IO.IOException] {
            if ($attempt -ge 8) { throw }
            Start-Sleep -Milliseconds (50 * $attempt)
        }
        catch [System.UnauthorizedAccessException] {
            if ($attempt -ge 8) { throw }
            Start-Sleep -Milliseconds (50 * $attempt)
        }
        finally {
            if ($mutex) {
                if ($acquired) {
                    try { $mutex.ReleaseMutex() } catch { }
                }
                $mutex.Dispose()
            }
        }
    }
}
'@
        Invoke-Expression $embeddedIo
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
                    Write-TimerDataFileAtomic -DataFile $dataFile -Content (ConvertTo-Json -InputObject $list -Depth 12)
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
        [ValidateSet('popup', 'toast', 'none')]
        [string]$Visual = $null,
        $Sound = $null,
        [string]$WebhookUrl = $null,
        [string]$SoundFile = $null
    )

    $channels = Get-TimerNotifyChannelsFromTimer -Timer $Timer
    if (-not $Visual) { $Visual = $channels.Visual }
    if ($null -eq $Sound) { $Sound = $channels.Sound }
    if (-not $SoundFile) { $SoundFile = (Get-TimerNotificationConfig).SoundFile }

    $taskName = if ($Timer.PSObject.Properties.Name -contains 'TaskName' -and -not [string]::IsNullOrWhiteSpace($Timer.TaskName)) {
        $Timer.TaskName
    } else {
        New-TimerTaskName -TimerId $Timer.Id
    }
    $dataFile = Join-Path $env:TEMP "ps-timers.json"

    if (-not $WebhookUrl -and $Timer.WebhookName) {
        $WebhookUrl = Resolve-TimerWebhookUrl -Name $Timer.WebhookName
    }

    $triggerTime = if ($Timer.EndTime) {
        [DateTime]::Parse($Timer.EndTime)
    } else {
        (Get-Date).AddSeconds($Timer.Seconds)
    }

    $soundBlock = Get-TimerFireScriptSoundBlock -Sound $Sound -SoundFile $SoundFile -Mode 'simple'
    $visualBlock = Get-TimerFireScriptVisualBlock -Visual $Visual -Mode 'simple'
    $webhookBlock = Get-TimerFireScriptWebhookBlock -WebhookUrl $WebhookUrl
    $historyBlock = Get-TimerFireScriptHistoryBlock -TimerIdExpr '$timerId' -LabelExpr '$message' -SecondsExpr '$timerSeconds' -IsSequenceExpr '$false'
    $notifySoundLiteral = if ($Sound) { '$true' } else { '$false' }
    $webhookLiteral = if ($WebhookUrl) { "'$($WebhookUrl -replace "'", "''")'" } else { '$null' }

    # Build the notification script that runs when timer fires
    $script = @"
`$timerId = '$($Timer.Id)'
`$message = '$($Timer.Message -replace "'", "''")'
`$duration = '$($Timer.Duration)'
`$repeatTotal = $($Timer.RepeatTotal)
`$currentRun = $($Timer.CurrentRun)
`$timerSeconds = $($Timer.Seconds)
`$dataFile = '$dataFile'
$(Get-TimerEmbeddedDataFileIoScript)
`$logFile = "`$env:TEMP\PSTimer_`$timerId.log"
`$notifyVisual = '$Visual'
`$notifySound = $notifySoundLiteral
`$webhookUrl = $webhookLiteral
`$currentTaskName = '$taskName'

try {
    # Update timer data FIRST (before sound/popup, so tl/watch stay in sync)
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
                `$nextTaskName = "PSTimer_`${timerId}_`$([Guid]::NewGuid().ToString('N').Substring(0, 8))"

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
$(Get-TimerFireScriptPreserveNotifyFieldsBlock)
                `$timers[`$timerIndex] = `$updatedTimer

                # Save BEFORE scheduling next task
                Write-TimerDataFileAtomic -DataFile `$dataFile -Content (ConvertTo-Json -InputObject `$timers -Depth 12)

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
$(Get-TimerFireScriptPreserveNotifyFieldsBlock)
                `$timers[`$timerIndex] = `$updatedTimer

                Write-TimerDataFileAtomic -DataFile `$dataFile -Content (ConvertTo-Json -InputObject `$timers -Depth 12)

                Unregister-ScheduledTask -TaskName `$currentTaskName -Confirm:`$false -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath "`$env:TEMP\PSTimer_`$timerId.ps1" -Force -ErrorAction SilentlyContinue
            }
        }
    }
$soundBlock
} catch {
    "`$(Get-Date -Format 'o') ERROR: `$(`$_.Exception.Message)" | Add-Content -LiteralPath `$logFile -Force
}

# Show notification (after state update, so it can block without affecting tl display)
`$endStr = (Get-Date).ToString('HH:mm:ss')
`$body = @("Timer #`$timerId completed!", "", "Duration: `$duration", "Finished: `$endStr")
if (`$repeatTotal -gt 1) { `$body += "Run:      `$currentRun of `$repeatTotal" }

$visualBlock
$webhookBlock
$historyBlock
"@

    $null = Write-TimerFireScriptFile -TimerId $Timer.Id -ScriptBody $script
    $vbsPath = Write-TimerVbsWrapperFile -TimerId $Timer.Id

    Register-TimerScheduledTaskAsync -TimerId $Timer.Id -TaskName $taskName -TriggerTime $triggerTime -VbsPath $vbsPath
    $Timer | Add-Member -NotePropertyName 'TaskName' -NotePropertyValue $taskName -Force

    if (Test-TimerNeedsPhaseCues -Timer $Timer) {
        Register-TimerPhaseCueTasks -Timer $Timer -PhaseSeconds $Timer.Seconds
    }
}

function Clear-TimerScheduledTaskNameCache {
    $script:TimerTaskNameCache = $null
    $script:TimerTaskNameCacheTime = [DateTime]::MinValue
}

function Get-PSTimerScheduledTaskNames {
    <#
    .SYNOPSIS
        Returns cached set of existing PSTimer_* scheduled task names (one COM enumeration per TTL).
        Returns $null when the Task Scheduler lookup fails (callers must not treat as "no tasks").
    #>
    param([switch]$ForceRefresh)

    if ($global:TimerTestScheduledTaskNamesUseResultOverride) {
        return ,$global:TimerTestScheduledTaskNamesResultOverride
    }

    if ($null -ne $global:TimerTestGetPSTimerScheduledTaskNamesOverride) {
        return & $global:TimerTestGetPSTimerScheduledTaskNamesOverride
    }

    $now = Get-Date
    if (-not $ForceRefresh -and $null -ne $script:TimerTaskNameCache -and ($now - $script:TimerTaskNameCacheTime).TotalSeconds -lt $script:TimerTaskNameCacheTtlSeconds) {
        return ,$script:TimerTaskNameCache
    }

    for ($attempt = 1; $attempt -le 2; $attempt++) {
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
            Write-Warning "PS1Timer: Could not list scheduled tasks (attempt $attempt): $($_.Exception.Message)"
            if ($attempt -lt 2) { continue }
            return $null
        }
        finally {
            if ($tasks) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($tasks) | Out-Null }
            if ($folder) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($folder) | Out-Null }
            if ($service) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($service) | Out-Null }
        }

    $script:TimerTaskNameCache = $names
    $script:TimerTaskNameCacheTime = $now
    return ,$names
}

    return $null
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
    Unregister-TimerCueTasks -Timer $timer
    Stop-TimerTask -TimerId $Id -TaskName (Get-TimerTaskName -Timer $timer)
    $endTime = [DateTime]::Parse($timer.EndTime)
    $remaining = [int]($endTime - (Get-Date)).TotalSeconds
    if ($remaining -lt 0) { $remaining = 0 }
    $timer | Add-Member -NotePropertyName 'RemainingSeconds' -NotePropertyValue $remaining -Force
    $timer.State = 'Paused'
    Save-TimerData -Timers $Timers
    return $remaining
}

function Invoke-RegisterTimerResumeCues {
    param([PSCustomObject]$Timer)

    if (-not (Test-TimerNeedsPhaseCues -Timer $Timer)) { return }

    $seconds = [int](Get-TimerResumeSeconds -Timer $Timer)
    $phaseObj = $null
    if ($Timer.IsSequence -and $Timer.Phases) {
        $phaseIndex = if ($Timer.PSObject.Properties.Name -contains 'CurrentPhase') { [int]$Timer.CurrentPhase } else { 0 }
        if ($Timer.Phases.Count -gt $phaseIndex) {
            $phaseObj = $Timer.Phases[$phaseIndex]
        }
    }
    Register-TimerPhaseCueTasks -Timer $Timer -PhaseSeconds $seconds -Phase $phaseObj
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
        Start-TimerScheduledJob -Timer $t
        Invoke-RegisterTimerResumeCues -Timer $t
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
    Start-TimerScheduledJob -Timer $timer
    Invoke-RegisterTimerResumeCues -Timer $timer
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
    Unregister-TimerCueTasks -Timer $timer
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
        $preset = $script:TimerPresets[$Pattern]
        if (Test-TimerSimpleRepeatingPreset -Preset $preset) {
            return $false
        }
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

        # Parameter flag (-BeepAt, etc.)
        if ($char -eq '-' -and $i + 1 -lt $len -and $Pattern[$i + 1] -match '[a-zA-Z]') {
            $word = '-'
            $i++
            while ($i -lt $len -and $Pattern[$i] -match '[a-zA-Z0-9_-]') {
                $word += $Pattern[$i]
                $i++
            }
            $tokens += @{ Type = 'LABEL'; Value = $word }
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

    if ($phases.Count -gt $script:MaxSequencePhases) {
        throw "Pattern expands to $($phases.Count) phases; maximum is $($script:MaxSequencePhases). Use a repeating simple timer instead (e.g. t 45m message -Repeat 100)."
    }

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

            $beepAt = @()
            if ($Index.Value -lt $Tokens.Count -and $Tokens[$Index.Value].Type -eq 'LABEL' -and $Tokens[$Index.Value].Value -match '^-?BeepAt$') {
                $Index.Value++
                while ($Index.Value -lt $Tokens.Count) {
                    $beepToken = $Tokens[$Index.Value]
                    if ($beepToken.Type -eq 'COMMA') {
                        $nextIdx = $Index.Value + 1
                        if ($nextIdx -lt $Tokens.Count -and $Tokens[$nextIdx].Type -eq 'DURATION') {
                            $afterDur = $nextIdx + 1
                            if ($afterDur -lt $Tokens.Count -and $Tokens[$afterDur].Type -eq 'LABEL') {
                                break
                            }
                        }
                        $Index.Value++
                        continue
                    }
                    if ($beepToken.Type -eq 'DURATION') {
                        $beepSeconds = ConvertTo-Seconds -Time $beepToken.Value
                        if ($beepSeconds -gt 0) { $beepAt += [int]$beepSeconds }
                        $Index.Value++
                        continue
                    }
                    break
                }
                $beepAt = @($beepAt | Sort-Object -Descending -Unique)
            }

            $phaseItem = @{
                Type     = 'PHASE'
                Seconds  = $seconds
                Label    = $label
                Duration = $token.Value
            }
            if ($beepAt.Count -gt 0) {
                $phaseItem['BeepAt'] = $beepAt
            }
            $items += $phaseItem
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
            $phaseObj = [PSCustomObject]@{
                Seconds       = $item.Seconds
                Label         = $item.Label
                Duration      = $item.Duration
                LoopId        = $ParentLoopId
                LoopIteration = $ParentIteration
                LoopTotal     = $ParentTotal
            }
            if ($item.BeepAt) {
                $phaseObj | Add-Member -NotePropertyName 'BeepAt' -NotePropertyValue @($item.BeepAt) -Force
            }
            $phases += $phaseObj
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
        [string]$NotifyVisual = 'popup',
        $NotifySound = $true,
        $NotifyVoice = $false,
        [string]$NotifyType = $null,
        [string]$WebhookName = $null,
        [string]$VoiceName = $null,
        [int]$VoiceRate = 0,
        [int]$VoiceVolume = 100,
        [string]$CountdownMode = 'none',
        [switch]$IsWorkout,
        [string]$WorkoutRoutine = $null,
        [int[]]$BeepAt = @()
    )
    $firstPhase = $Phases[0]
    $endTime = $Now.AddSeconds($firstPhase.Seconds)
    $phasesData = @()
    foreach ($p in $Phases) {
        $entry = @{
            Seconds       = $p.Seconds
            Label         = $p.Label
            Duration      = $p.Duration
            LoopId        = $p.LoopId
            LoopIteration = $p.LoopIteration
            LoopTotal     = $p.LoopTotal
        }
        foreach ($key in @('PhaseType', 'ExerciseName', 'SetNumber', 'SetTotal', 'AnnounceStart', 'AnnounceEnd', 'Countdown', 'NotifyVoice', 'NotifySound', 'SoundFile', 'BeepAt')) {
            if ($p.PSObject.Properties.Name -contains $key -and $null -ne $p.$key) {
                $entry[$key] = $p.$key
            }
        }
        $phasesData += $entry
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
        NotifyVisual    = $NotifyVisual
        NotifySound     = $NotifySound
        NotifyVoice     = [bool]$NotifyVoice
        NotifyType      = $NotifyType
        WebhookName     = $WebhookName
        VoiceName       = $VoiceName
        VoiceRate       = $VoiceRate
        VoiceVolume     = $VoiceVolume
        CountdownMode   = $CountdownMode
        CueTaskNames    = @()
        IsWorkout       = [bool]$IsWorkout
        WorkoutRoutine  = $WorkoutRoutine
        TaskName        = New-TimerTaskName -TimerId $Id
    }
    if ($BeepAt -and @($BeepAt).Count -gt 0) {
        $timer | Add-Member -NotePropertyName 'BeepAt' -NotePropertyValue @($BeepAt)
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
        [Nullable[DateTime]]$ScheduledStart,
        [string]$NotifyLabel = $null,
        [string]$WebhookName = $null,
        [string]$SessionLabel = $null,
        [Nullable[DateTime]]$FinalEndTime = $null
    )
    Write-Host ""
    if ($ScheduledStart) {
        Write-Host "  Sequence scheduled " -ForegroundColor Green -NoNewline
    }
    else {
        Write-Host "  Sequence started " -ForegroundColor Green -NoNewline
    }
    Write-Host "[$Id]" -ForegroundColor Cyan
    if ($SessionLabel) {
        Write-Host "  Session:  " -ForegroundColor Gray -NoNewline
        Write-Host $SessionLabel -ForegroundColor Cyan
    }
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
    Write-Host "  Phase end:" -ForegroundColor Gray -NoNewline
    Write-Host $EndTime.ToString('HH:mm:ss') -ForegroundColor Yellow
    if ($FinalEndTime) {
        Write-Host "  Final end:" -ForegroundColor Gray -NoNewline
        Write-Host $FinalEndTime.ToString('HH:mm:ss') -ForegroundColor Yellow
    }
    if ($NotifyLabel) {
        Write-Host "  Notify:   " -ForegroundColor Gray -NoNewline
        Write-Host $NotifyLabel -ForegroundColor Green
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
    $channels = Get-TimerNotifyChannelsFromTimer -Timer $Timer
    $webhookUrl = if ($Timer.WebhookName) { Resolve-TimerWebhookUrl -Name $Timer.WebhookName } else { $null }
    $soundFile = (Get-TimerNotificationConfig).SoundFile

    $triggerTime = if ($Timer.EndTime) {
        [DateTime]::Parse($Timer.EndTime)
    } else {
        (Get-Date).AddSeconds($Timer.Seconds)
    }

    $soundBlock = Get-TimerFireScriptSoundBlock -Sound $channels.Sound -SoundFile $soundFile -Mode 'sequence'
    $visualBlock = Get-TimerFireScriptVisualBlock -Visual $channels.Visual -Mode 'sequence'
    $webhookBlock = Get-TimerFireScriptWebhookBlock -WebhookUrl $webhookUrl
    $historyBlock = Get-TimerFireScriptHistoryBlock -TimerIdExpr '$timerId' -LabelExpr '$phaseLabel' -SecondsExpr '$timer.Seconds' -IsSequenceExpr '$true'
    $notifySoundLiteral = if ($channels.Sound) { '$true' } else { '$false' }
    $notifyVoiceLiteral = if ($channels.Voice) { '$true' } else { '$false' }
    $webhookLiteral = if ($webhookUrl) { "'$($webhookUrl -replace "'", "''")'" } else { '$null' }
    $voiceName = if ($Timer.PSObject.Properties.Name -contains 'VoiceName') { $Timer.VoiceName } else { $null }
    $voiceRate = if ($Timer.PSObject.Properties.Name -contains 'VoiceRate') { [int]$Timer.VoiceRate } else { 0 }
    $voiceVolume = if ($Timer.PSObject.Properties.Name -contains 'VoiceVolume') { [int]$Timer.VoiceVolume } else { 100 }
    $voiceBlock = Get-TimerFireScriptVoiceBlock -Voice $channels.Voice -TextExpr '$announceText' -VoiceName $voiceName -VoiceRate $voiceRate -VoiceVolume $voiceVolume
    $registerCuesBlock = Get-TimerFireScriptRegisterCuesBlock -TimerId $Timer.Id
    $workoutCompleteText = (Resolve-TimerSpeechText -TemplateKey 'WorkoutComplete') -replace "'", "''"
    Write-TimerCueRegistrarFile -TimerId $Timer.Id -VoiceName $voiceName -VoiceRate $voiceRate -VoiceVolume $voiceVolume | Out-Null

    # Build the notification script using here-string
    $script = @"
`$timerId = '$($Timer.Id)'
`$dataFile = '$dataFile'
$(Get-TimerEmbeddedDataFileIoScript)
`$notifyVisual = '$($channels.Visual)'
`$notifySound = $notifySoundLiteral
`$notifyVoice = $notifyVoiceLiteral
`$webhookUrl = $webhookLiteral
`$logFile = "`$env:TEMP\PSTimer_`$timerId.log"
`$utf8Bom = New-Object System.Text.UTF8Encoding `$true

function Write-TimerDataFile {
    param([array]`$Items)
    Write-TimerDataFileAtomic -DataFile `$dataFile -Content (ConvertTo-Json -InputObject `$Items -Depth 12)
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

`$phases = @(`$timer.Phases)
`$phaseCount = `$phases.Count
`$nextPhaseIdx = `$currentPhase + 1
`$announceText = ''
if (`$notifyVoice) {
    if (`$nextPhaseIdx -lt `$phaseCount) {
        `$np = `$phases[`$nextPhaseIdx]
        if (`$np.AnnounceStart) { `$announceText = [string]`$np.AnnounceStart }
        elseif (`$np.Label) { `$announceText = [string]`$np.Label }
    } elseif (`$nextPhaseIdx -ge `$totalPhases) {
        `$announceText = '$workoutCompleteText'
    }
}

if (`$nextPhaseIdx -lt `$phaseCount) {
    if (`$nextPhaseIdx -ge `$totalPhases) {
        "`$(Get-Date -Format 'o') WARN phase index `$nextPhaseIdx exceeds TotalPhases=`$totalPhases (count=`$phaseCount)" | Add-Content -LiteralPath `$logFile -Force
    }
    `$nextPhase = `$phases[`$nextPhaseIdx]
    `$nextSeconds = [int]`$nextPhase.Seconds
    `$nextLabel = `$nextPhase.Label
    `$nextTaskName = "PSTimer_`${timerId}_`$([Guid]::NewGuid().ToString('N').Substring(0, 8))"

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
$registerCuesBlock
        if (`$currentTaskName) {
            Unregister-ScheduledTask -TaskName `$currentTaskName -Confirm:`$false -ErrorAction SilentlyContinue
        }
    } else {
        `$timer.State = 'Paused'
        `$timer | Add-Member -NotePropertyName 'RemainingSeconds' -NotePropertyValue `$nextSeconds -Force
        `$timer.TaskName = `$null
        Write-TimerDataFile -Items `$timers
    }
} elseif (`$nextPhaseIdx -ge `$totalPhases) {
    `$timer.State = 'Completed'
    `$timer.CurrentPhase = `$totalPhases
    `$timer.TaskName = `$null
    Write-TimerDataFile -Items `$timers

    if (`$currentTaskName) {
        Unregister-ScheduledTask -TaskName `$currentTaskName -Confirm:`$false -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath "`$env:TEMP\PSTimer_`$timerId.ps1" -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "`$env:TEMP\PSTimer_`$timerId.vbs" -Force -ErrorAction SilentlyContinue
} else {
    "`$(Get-Date -Format 'o') ERROR invalid phase index `$nextPhaseIdx (TotalPhases=`$totalPhases, count=`$phaseCount)" | Add-Content -LiteralPath `$logFile -Force
    `$timer.State = 'Lost'
    `$timer.TaskName = `$null
    Write-TimerDataFile -Items `$timers
}

$voiceBlock

$soundBlock

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

$visualBlock
$webhookBlock
$historyBlock
"@

    $null = Write-TimerFireScriptFile -TimerId $Timer.Id -ScriptBody $script
    $vbsPath = Write-TimerVbsWrapperFile -TimerId $Timer.Id

    Register-TimerScheduledTaskAsync -TimerId $Timer.Id -TaskName $taskName -TriggerTime $triggerTime -VbsPath $vbsPath
    $Timer | Add-Member -NotePropertyName 'TaskName' -NotePropertyValue $taskName -Force

    $phaseIndex = if ($Timer.PSObject.Properties.Name -contains 'CurrentPhase') { [int]$Timer.CurrentPhase } else { 0 }
    $currentPhaseObj = $null
    if ($Timer.Phases -and $Timer.Phases.Count -gt $phaseIndex) {
        $currentPhaseObj = $Timer.Phases[$phaseIndex]
    }
    Register-TimerPhaseCueTasks -Timer $Timer -PhaseSeconds $Timer.Seconds -Phase $currentPhaseObj
}

function Start-TimerScheduledJob {
    <#
    .SYNOPSIS
        Registers the correct scheduled task fire script for a timer record (simple, repeat, or sequence).
    #>
    param([PSCustomObject]$Timer)

    if ($Timer.IsSequence) {
        Start-SequenceTimerJob -Timer $Timer
    }
    else {
        $channels = Get-TimerNotifyChannelsFromTimer -Timer $Timer
        $webhookUrl = if ($Timer.WebhookName) { Resolve-TimerWebhookUrl -Name $Timer.WebhookName } else { $null }
        $soundFile = (Get-TimerNotificationConfig).SoundFile
        Start-TimerJob -Timer $Timer -Visual $channels.Visual -Sound $channels.Sound -WebhookUrl $webhookUrl -SoundFile $soundFile
    }
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
        @{ Name='Timer <time>'; Alias='T'; Params='[msg] [repeat] [-Visual] [-Sound] [-Voice] [-Countdown] [-BeepAt] [-Webhook] [-At]'; Desc='Start a timer (simple, sequence, or t workout)' }
        @{ Name='Timer-Workout'; Alias='TWKO'; Params='[routine] [-List] [-Voice] [-Countdown]'; Desc='Structured workout with voice coaching' }
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
                @{ Type='example'; Code='t tabata                     '; Comment='# Voice HIIT preset' }
                @{ Type='example'; Code='t workout upper-push         '; Comment='# Structured workout' }
                @{ Type='raw'; Text='' }
                @{ Type='text'; Label='  Presets: '; Value='pomodoro, tabata, gym-sets, hiit-30-30, emom-12' }
            )
        }
        @{
            Title = 'NOTIFICATION OPTIONS'
            Underline = '===================='
            Lines = @(
                @{ Type='text'; Label='  Per-timer: '; Value='t 25m -Visual toast -Sound -Voice -Countdown 321'; LabelColor='Yellow'; ValueColor='Gray' }
                @{ Type='text'; Label='  Mid-timer:  '; Value='t 5m stretch -BeepAt 3m,1m'; LabelColor='Yellow'; ValueColor='Gray' }
                @{ Type='raw'; Text='' }
                @{ Type='raw'; Text='  Channels: Visual popup|toast|none  Sound on|off  Voice on|off  Webhook if set'; Color='Green' }
                @{ Type='raw'; Text='  Legacy: -Notify popup|toast|sound|silent|webhook' }
                @{ Type='raw'; Text='' }
                @{ Type='raw'; Text='  Default: config.ps1 -> TimerDefaults.Visual, .Sound, .Webhook' }
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
        Legacy shorthand: popup, toast, sound, silent, webhook (replaces Visual/Sound combo).
    .PARAMETER Visual
        Visual channel: popup, toast, none. Overrides TimerDefaults.Visual.
    .PARAMETER Sound
        Play sound when timer completes. Overrides TimerDefaults.Sound.
    .PARAMETER Webhook
        Named webhook from Config.Webhooks (e.g. discord-main). Fires when set.
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
        t 25m -Visual toast -Sound
        t 25m -Notify toast
        t 25m -Webhook discord-main
        t 25m work -At "14:30"
    #>
    param(
        [Parameter(Position=0)][string]$Time,
        [Parameter(Position=1)][Alias('m')][string]$Message = "Time is up!",
        [Parameter(Position=2)][Alias('r')][int]$Repeat = 1,
        [ValidateSet('popup', 'toast', 'sound', 'silent', 'webhook')]
        [string]$Notify = $null,
        [ValidateSet('popup', 'toast', 'none')]
        [string]$Visual = $null,
        [switch]$Sound,
        [switch]$NoSound,
        [switch]$Voice,
        [switch]$NoVoice,
        [ValidateSet('none', '321', '10', 'both')]
        $Countdown = $null,
        [string]$BeepAt = $null,
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

    if ($Time -eq 'workout') {
        $routineName = if ($Message -ne 'Time is up!') { $Message } else { $null }
        $soundOverride = if ($Sound) { $true } elseif ($NoSound) { $false } else { $null }
        $voiceOverride = if ($Voice) { $true } elseif ($NoVoice) { $false } else { $null }
        $workoutParams = @{
            Routine       = $routineName
            Notify        = $Notify
            Visual        = $Visual
            SoundOverride = $soundOverride
            VoiceOverride = $voiceOverride
            Webhook       = $Webhook
            At            = $At
            AfterStart    = $AfterStart
        }
        if ($Countdown -in @('none', '321', '10', 'both')) {
            $workoutParams['Countdown'] = $Countdown
        }
        Timer-Workout @workoutParams
        return
    }

    if ($script:TimerPresets.Keys -contains $Time) {
        $simplePreset = $script:TimerPresets[$Time]
        if (Test-TimerSimpleRepeatingPreset -Preset $simplePreset) {
            $presetNotify = Get-TimerPresetNotifyOverrides -Preset $simplePreset
            $Time = [string]$simplePreset.Time
            if ($Message -eq 'Time is up!' -and $simplePreset.Message) {
                $Message = [string]$simplePreset.Message
            }
            if ($Repeat -le 1 -and $simplePreset.Repeat) {
                $Repeat = [int]$simplePreset.Repeat
            }
            if (-not $Notify -and $presetNotify.Notify) { $Notify = $presetNotify.Notify }
            if (-not $Visual -and $presetNotify.Visual) { $Visual = $presetNotify.Visual }
            if (-not $Sound -and -not $NoSound -and $null -ne $presetNotify.Sound) {
                if ($presetNotify.Sound) { $Sound = $true } else { $NoSound = $true }
            }
            if (-not $Voice -and -not $NoVoice -and $null -ne $presetNotify.Voice) {
                if ($presetNotify.Voice) { $Voice = $true } else { $NoVoice = $true }
            }
            if (-not $Webhook -and $presetNotify.Webhook) { $Webhook = $presetNotify.Webhook }
            if (-not $Countdown -and $presetNotify.Countdown) { $Countdown = $presetNotify.Countdown }
        }
    }

    # Check if this is a sequence pattern or preset
    if (Test-TimerSequence -Pattern $Time) {
        $soundOverride = if ($Sound) { $true } elseif ($NoSound) { $false } else { $null }
        $voiceOverride = if ($Voice) { $true } elseif ($NoVoice) { $false } else { $null }
        Start-SequenceTimer -Pattern $Time -Notify $Notify -Visual $Visual -SoundOverride $soundOverride -VoiceOverride $voiceOverride -CountdownOverride $Countdown -BeepAtOverride $BeepAt -Webhook $Webhook -At $At -AfterStart $AfterStart
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

    $soundOverride = if ($Sound) { $true } elseif ($NoSound) { $false } else { $null }
    $voiceOverride = if ($Voice) { $true } elseif ($NoVoice) { $false } else { $null }
    $notifySettings = Resolve-TimerNotificationSettings -NotifyOverride $Notify -VisualOverride $Visual -SoundOverride $soundOverride -VoiceOverride $voiceOverride -CountdownOverride $Countdown -WebhookOverride $Webhook

    $beepAtSeconds = if ($BeepAt) { @(Parse-BeepAtList -InputObject $BeepAt) } else { @() }
    if ($BeepAt -and $beepAtSeconds.Count -eq 0) {
        Write-Host "Invalid -BeepAt. Use comma-separated durations (e.g. 3m,1m)." -ForegroundColor Red
        return
    }

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
        NotifyVisual    = $notifySettings.Visual
        NotifySound     = $notifySettings.Sound
        NotifyVoice     = $notifySettings.Voice
        NotifyType      = $notifySettings.NotifyType
        WebhookName     = $notifySettings.WebhookName
        VoiceName       = $notifySettings.VoiceName
        VoiceRate       = $notifySettings.VoiceRate
        VoiceVolume     = $notifySettings.VoiceVolume
        CountdownMode   = $notifySettings.Countdown
        CueTaskNames    = @()
        TaskName        = New-TimerTaskName -TimerId $id
    }
    if ($beepAtSeconds.Count -gt 0) {
        $timer | Add-Member -NotePropertyName 'BeepAt' -NotePropertyValue @($beepAtSeconds)
    }

    $timers = @(Get-TimerData)
    $timers += $timer
    Save-TimerData -Timers $timers

    Start-TimerJob -Timer $timer -Visual $notifySettings.Visual -Sound $notifySettings.Sound -WebhookUrl $notifySettings.WebhookUrl -SoundFile $notifySettings.SoundFile

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
    $notifyLabel = Format-TimerNotifyLabel -Visual $notifySettings.Visual -Sound $notifySettings.Sound -WebhookName $notifySettings.WebhookName -Voice $notifySettings.Voice -CountdownMode $notifySettings.Countdown -BeepAt $(if ($beepAtSeconds.Count -gt 0) { @($beepAtSeconds | ForEach-Object { Format-Duration -Seconds $_ }) } else { $null })
    Write-Host $notifyLabel -ForegroundColor Green
    Write-Host ""

    Invoke-TimerAfterStart -TimerId $id -AfterStart $AfterStart
}

function Timer-Workout {
    <#
    .SYNOPSIS
        Starts a structured workout routine with voice coaching.
    #>
    param(
        [string]$Routine = $null,
        [switch]$List,
        [string]$Notify = $null,
        [string]$Visual = $null,
        $SoundOverride = $null,
        $VoiceOverride = $null,
        [ValidateSet('none', '321', '10', 'both')]
        $Countdown = $null,
        [string]$Webhook = $null,
        [string]$At = $null,
        [string]$AfterStart = $null
    )

    $workouts = Get-PS1TimerModuleWorkouts
    if ($List -or ($workouts.Count -eq 0 -and -not $Routine)) {
        if ($workouts.Count -eq 0) {
            Write-Host "`n  No workouts defined in Config.Workouts.`n" -ForegroundColor Yellow
            return
        }
        Write-Host "`n  WORKOUT ROUTINES" -ForegroundColor Cyan
        foreach ($key in ($workouts.Keys | Sort-Object)) {
            $w = $workouts[$key]
            $desc = if ($w.Description) { $w.Description } else { '' }
            Write-Host "    $key" -ForegroundColor Yellow -NoNewline
            if ($desc) { Write-Host " — $desc" -ForegroundColor DarkGray }
            else { Write-Host '' }
        }
        Write-Host ""
        return
    }

    if ([string]::IsNullOrWhiteSpace($Routine)) {
        $options = Get-WorkoutPickerOptions
        if ($options.Count -eq 0) {
            Write-Host "`n  No workouts defined in Config.Workouts.`n" -ForegroundColor Yellow
            return
        }
        $Routine = Show-MenuPicker -Title 'SELECT WORKOUT ROUTINE' -Options $options -AllowCancel
        if (-not $Routine) { return }
    }

    if (-not $workouts.ContainsKey($Routine)) {
        Write-Host "`n  Workout '$Routine' not found. Use 't workout -List' or Config.Workouts.`n" -ForegroundColor Red
        return
    }

    $workout = $workouts[$Routine]
    $presetNotify = $null
    $presetVisual = $null
    $presetSound = $null
    $presetVoice = $null
    $presetWebhook = $null
    $presetCountdown = $null
    if ($workout.Notify) { $presetNotify = $workout.Notify }
    if ($workout.Visual) { $presetVisual = $workout.Visual }
    if ($workout.ContainsKey('Sound')) { $presetSound = [bool]$workout.Sound }
    if ($workout.ContainsKey('Voice')) { $presetVoice = [bool]$workout.Voice }
    if ($workout.Webhook) { $presetWebhook = $workout.Webhook }
    if ($workout.Countdown) { $presetCountdown = [string]$workout.Countdown }

    try {
        $phases = @(ConvertFrom-WorkoutRoutine -RoutineName $Routine -CountdownMode $Countdown)
    }
    catch {
        Write-Host "`n  $($_.Exception.Message)`n" -ForegroundColor Red
        return
    }

    if ($phases.Count -eq 0) {
        Write-Host "`n  Workout '$Routine' produced no phases.`n" -ForegroundColor Red
        return
    }

    $patternLabel = "workout:$Routine"
    $startNotify = if ($Notify) { $Notify } elseif ($presetNotify) { $presetNotify } else { $null }
    $startVisual = if ($Visual) { $Visual } elseif ($presetVisual) { $presetVisual } else { $null }
    $startSound = if ($null -ne $SoundOverride) { $SoundOverride } elseif ($null -ne $presetSound) { $presetSound } else { $null }
    $startVoice = if ($null -ne $VoiceOverride) { $VoiceOverride } elseif ($null -ne $presetVoice) { $presetVoice } else { $null }
    $startWebhook = if ($Webhook) { $Webhook } elseif ($presetWebhook) { $presetWebhook } else { $null }
    $startCountdown = if ($Countdown -in @('none', '321', '10', 'both')) { $Countdown } elseif ($presetCountdown) { $presetCountdown } else { $null }

    Start-SequenceTimer -Pattern $patternLabel -PhasesOverride $phases `
        -Notify $startNotify `
        -Visual $startVisual `
        -SoundOverride $startSound `
        -VoiceOverride $startVoice `
        -CountdownOverride $startCountdown `
        -Webhook $startWebhook `
        -At $At `
        -AfterStart $AfterStart `
        -IsWorkout `
        -WorkoutRoutine $Routine
}

function Start-SequenceTimer {
    <#
    .SYNOPSIS
        Starts a sequence-based timer (Pomodoro-style).
    .PARAMETER Pattern
        Sequence pattern string or preset name.
    .PARAMETER Notify
        Legacy shorthand: popup, toast, sound, silent, webhook.
    .PARAMETER Visual
        Visual channel: popup, toast, none.
    .PARAMETER SoundOverride
        Optional sound on/off override.
    .PARAMETER Webhook
        Named webhook from Config.Webhooks.
    .PARAMETER At
        Schedule sequence start at HH:mm today (24h).
    .PARAMETER AfterStart
        After start: none, watch (tw), list (tl -w). Overrides TimerDefaults.AfterStart.
    #>
    param(
        [string]$Pattern,
        [string]$Notify = $null,
        [string]$Visual = $null,
        $SoundOverride = $null,
        $VoiceOverride = $null,
        [string]$CountdownOverride = $null,
        [string]$BeepAtOverride = $null,
        [string]$Webhook = $null,
        [string]$At = $null,
        [string]$AfterStart = $null,
        [switch]$IsWorkout,
        [string]$WorkoutRoutine = $null,
        [array]$PhasesOverride = $null
    )

    $originalPattern = $Pattern
    $presetNotify = $null
    $presetVisual = $null
    $presetSound = $null
    $presetVoice = $null
    $presetWebhook = $null
    $presetCountdown = $null
    if (-not $PhasesOverride -and ($script:TimerPresets.Keys -contains $Pattern)) {
        $preset = $script:TimerPresets[$Pattern]
        $Pattern = $preset.Pattern
        if ($preset.Notify) { $presetNotify = $preset.Notify }
        if ($preset.Visual) { $presetVisual = $preset.Visual }
        if ($preset.ContainsKey('Sound')) { $presetSound = [bool]$preset.Sound }
        if ($preset.ContainsKey('Voice')) { $presetVoice = [bool]$preset.Voice }
        if ($preset.Webhook) { $presetWebhook = $preset.Webhook }
        if ($preset.Countdown) { $presetCountdown = [string]$preset.Countdown }
    }

    try {
        if ($PhasesOverride) {
            $phases = @($PhasesOverride)
        }
        else {
            $phases = @(ConvertFrom-TimerSequence -Pattern $Pattern)
        }
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

    $notifySettings = Resolve-TimerNotificationSettings -NotifyOverride $Notify -VisualOverride $Visual -SoundOverride $SoundOverride -VoiceOverride $VoiceOverride -CountdownOverride $CountdownOverride -WebhookOverride $Webhook -PresetNotify $presetNotify -PresetVisual $presetVisual -PresetSound $presetSound -PresetVoice $presetVoice -PresetWebhook $presetWebhook -PresetCountdown $presetCountdown

    $beepAtSeconds = if ($BeepAtOverride) { @(Parse-BeepAtList -InputObject $BeepAtOverride) } else { @() }
    if ($BeepAtOverride -and $beepAtSeconds.Count -eq 0) {
        Write-Host "Invalid -BeepAt. Use comma-separated durations (e.g. 3m,1m)." -ForegroundColor Red
        return
    }

    $startTime = if ($scheduledStart) { $scheduledStart } else { $now }
    $timerState = if ($scheduledStart) { 'Scheduled' } else { 'Running' }

    $timer = New-SequenceTimerFromPhases -Id $id -OriginalPattern $originalPattern -Phases $phases -Summary $summary -Now $startTime -NotifyVisual $notifySettings.Visual -NotifySound $notifySettings.Sound -NotifyVoice $notifySettings.Voice -NotifyType $notifySettings.NotifyType -WebhookName $notifySettings.WebhookName -VoiceName $notifySettings.VoiceName -VoiceRate $notifySettings.VoiceRate -VoiceVolume $notifySettings.VoiceVolume -CountdownMode $notifySettings.Countdown -IsWorkout:$IsWorkout -WorkoutRoutine $WorkoutRoutine -BeepAt $beepAtSeconds
    $firstPhase = $phases[0]
    $afterStartAction = Get-TimerAfterStartAction -Override $AfterStart
    $deferTimerStartForIntro = $notifySettings.Voice -and -not $scheduledStart -and $IsWorkout
    $speechVoiceParams = @{
        VoiceName   = $notifySettings.VoiceName
        VoiceRate   = $notifySettings.VoiceRate
        VoiceVolume = $notifySettings.VoiceVolume
    }

    if ($deferTimerStartForIntro) {
        $introText = Get-SequenceTimerIntroSpeechText -IsWorkout:$IsWorkout -WorkoutRoutine $WorkoutRoutine -FirstPhase $firstPhase -StartTime $startTime -Summary $summary -Phases $phases
        if (-not [string]::IsNullOrWhiteSpace($introText)) {
            Write-Host "  Reading workout intro..." -ForegroundColor Cyan
            Invoke-TimerSpeechQueue -Texts @($introText) @speechVoiceParams
        }

        $phaseStart = Get-Date
        $timer.State = 'Running'
        $timer.StartTime = $phaseStart.ToString('o')
        $timer.EndTime = $phaseStart.AddSeconds($firstPhase.Seconds).ToString('o')
        $startTime = $phaseStart

        $timers = @(Get-TimerData)
        $timers += $timer
        Save-TimerData -Timers $timers
        Start-SequenceTimerJob -Timer $timer

        $phaseEndTime = [DateTime]::Parse($timer.EndTime)
        $finalEnd = $phaseStart.AddSeconds($summary.TotalSeconds)
        $sessionLabel = $null
        if ($WorkoutRoutine) {
            $workouts = Get-PS1TimerModuleWorkouts
            if ($workouts -and $workouts.ContainsKey($WorkoutRoutine)) {
                $w = $workouts[$WorkoutRoutine]
                $sessionLabel = if ($w.Description) { [string]$w.Description } else { $WorkoutRoutine }
            }
        }
        Write-SequenceTimerConfirmation -Id $id -OriginalPattern $originalPattern -Summary $summary -PhaseCount $phases.Count -FirstPhase $firstPhase -EndTime $phaseEndTime -ScheduledStart $scheduledStart -NotifyLabel $notifySettings.Label -SessionLabel $sessionLabel -FinalEndTime $finalEnd
    }
    else {
        $timer.State = $timerState
        $timer.EndTime = $startTime.AddSeconds($firstPhase.Seconds).ToString('o')

        $timers = @(Get-TimerData)
        $timers += $timer
        Save-TimerData -Timers $timers
        Start-SequenceTimerJob -Timer $timer

        $phaseEndTime = [DateTime]::Parse($timer.EndTime)
        $finalEnd = $startTime.AddSeconds($summary.TotalSeconds)
        $sessionLabel = $null
        if ($IsWorkout -and $WorkoutRoutine) {
            $workouts = Get-PS1TimerModuleWorkouts
            if ($workouts -and $workouts.ContainsKey($WorkoutRoutine)) {
                $w = $workouts[$WorkoutRoutine]
                $sessionLabel = if ($w.Description) { [string]$w.Description } else { $WorkoutRoutine }
            }
        }
        Write-SequenceTimerConfirmation -Id $id -OriginalPattern $originalPattern -Summary $summary -PhaseCount $phases.Count -FirstPhase $firstPhase -EndTime $phaseEndTime -ScheduledStart $scheduledStart -NotifyLabel $notifySettings.Label -SessionLabel $sessionLabel -FinalEndTime $finalEnd

        if ($notifySettings.Voice -and -not $scheduledStart) {
            $speechTexts = Get-SequenceTimerStartSpeechTexts -IsWorkout:$IsWorkout -WorkoutRoutine $WorkoutRoutine -FirstPhase $firstPhase -StartTime $startTime -Summary $summary -Phases $phases
            if ($speechTexts.Count -gt 0) {
                $speechParams = @{
                    Texts       = $speechTexts
                    VoiceName   = $notifySettings.VoiceName
                    VoiceRate   = $notifySettings.VoiceRate
                    VoiceVolume = $notifySettings.VoiceVolume
                }
                if ($afterStartAction -in @('watch', 'list')) {
                    Invoke-TimerSpeechQueueAsync @speechParams
                }
                else {
                    Invoke-TimerSpeechQueue @speechParams
                }
            }
        }
    }

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

function Test-TimerWatchAwaitingContinuation {
    <#
    .SYNOPSIS
        True when watch should poll for a repeat run or next sequence phase after EndTime.
    #>
    param([PSCustomObject]$Timer)

    if ($Timer.IsSequence) {
        $currentPhase = [int]$Timer.CurrentPhase
        $totalPhases = if ($null -ne $Timer.TotalPhases) { [int]$Timer.TotalPhases } else { 0 }
        return ($currentPhase + 1) -lt $totalPhases
    }

    $repeatRemaining = if ($null -ne $Timer.RepeatRemaining) { [int]$Timer.RepeatRemaining } else { 0 }
    return $repeatRemaining -gt 0
}

function Get-TimerWatchOptimisticNextPhaseDisplay {
    <#
    .SYNOPSIS
        Predicts the next sequence phase for watch UI while the scheduled task transitions.
    #>
    param(
        [PSCustomObject]$Timer,
        [DateTime]$PreviousEndTime,
        [DateTime]$Now = (Get-Date)
    )

    if (-not $Timer.IsSequence) { return $null }

    $currentPhase = [int]$Timer.CurrentPhase
    $totalPhases = if ($null -ne $Timer.TotalPhases) { [int]$Timer.TotalPhases } else { 0 }
    $nextIdx = $currentPhase + 1
    if ($nextIdx -ge $totalPhases) { return $null }

    $phases = @($Timer.Phases)
    if ($nextIdx -ge $phases.Count) { return $null }

    $nextPhase = $phases[$nextIdx]
    $nextSeconds = [int]$nextPhase.Seconds
    if ($nextSeconds -le 0) { return $null }

    $nextLabel = if ($nextPhase.Label) { [string]$nextPhase.Label } else { '' }
    $predictedStart = if ($PreviousEndTime -gt $Now) { $PreviousEndTime } else { $Now }
    $predictedEnd = $predictedStart.AddSeconds($nextSeconds)

    $displayTimer = [PSCustomObject]@{
        Id            = $Timer.Id
        IsSequence    = $true
        CurrentPhase  = $nextIdx
        TotalPhases   = $totalPhases
        PhaseLabel    = $nextLabel
        Seconds       = $nextSeconds
        TotalSeconds  = $Timer.TotalSeconds
        Message       = $nextLabel
        StartTime     = $predictedStart.ToString('o')
        EndTime       = $predictedEnd.ToString('o')
        State         = 'Running'
        Phases        = $Timer.Phases
        NotifyVisual  = $Timer.NotifyVisual
        NotifySound   = $Timer.NotifySound
        NotifyVoice   = $Timer.NotifyVoice
        CountdownMode = if ($nextPhase.PSObject.Properties.Name -contains 'Countdown' -and $nextPhase.Countdown) { [string]$nextPhase.Countdown } elseif ($Timer.PSObject.Properties.Name -contains 'CountdownMode') { $Timer.CountdownMode } else { 'none' }
    }

    return [PSCustomObject]@{
        DisplayTimer = $displayTimer
        EndTime      = $predictedEnd
        TotalSeconds = $nextSeconds
    }
}

function Write-TimerWatchCompletedScreen {
    param(
        [hashtable]$Colors,
        [PSCustomObject]$CurrentTimer,
        [PSCustomObject]$Timer,
        [int]$TotalSeconds,
        [DateTime]$EndTime
    )

    $msg = if ($CurrentTimer) {
        if ($CurrentTimer.IsSequence) { $CurrentTimer.PhaseLabel } else { $CurrentTimer.Message }
    } else {
        $Timer.Message
    }
    $secs = if ($CurrentTimer) {
        if ($CurrentTimer.IsSequence) { $CurrentTimer.Seconds } else { $CurrentTimer.Seconds }
    } else {
        $TotalSeconds
    }
    Clear-Host
    $notifyTimer = if ($CurrentTimer) { $CurrentTimer } else { $Timer }
    $sb = Get-TimerWatchCompletedContent -Colors $Colors -Message $msg -TotalSeconds $secs -EndTime $EndTime -Timer $notifyTimer
    [Console]::Write($sb.ToString())
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
    $watchId = [string]$Timer.Id
    $showHelp = $false

    try {
        $totalSeconds = $Timer.Seconds
        $endTime = [DateTime]::Parse($Timer.EndTime)
        $currentTimer = $Timer

        while ($true) {
            $sw.Restart()
            $now = Get-Date

            $allTimers = @()
            try {
                $allTimers = @(Sync-TimerData)
            }
            catch {
                $allTimers = @(Get-TimerData)
            }
            $activeTimers = Get-TimerWatchActiveTimers -Timers $allTimers
            $cacheResult = Get-TimerDataIfChanged
            if ($cacheResult.Changed) {
                $currentTimer = @($cacheResult.Data | Where-Object { [string]$_.Id -eq $watchId })[0]
                if ($currentTimer -and $currentTimer.EndTime) {
                    $endTime = [DateTime]::Parse($currentTimer.EndTime)
                }
            }

            if (-not $currentTimer) {
                Clear-Host
                Write-Host ""
                Write-Host "  Timer [$watchId] was removed." -ForegroundColor Yellow
                Write-Host ""
                break
            }

            if ($currentTimer.State -notin @('Running', 'Scheduled', 'Paused')) {
                Clear-Host
                Write-Host ""
                Write-Host "  Timer [$watchId] is no longer active (state: $($currentTimer.State))." -ForegroundColor Yellow
                Write-Host ""
                break
            }

            $displayTimer = $currentTimer
            $displayEndTime = $endTime
            $displayTotalSeconds = if ($currentTimer.IsSequence) { [int]$currentTimer.Seconds } else { $totalSeconds }

            if ($currentTimer.State -eq 'Paused') {
                $remaining = [TimeSpan]::FromSeconds([int]$currentTimer.RemainingSeconds)
                $percent = 0
                $remainingSeconds = [int]$currentTimer.RemainingSeconds
            }
            else {
                $remaining = $displayEndTime - $now
                $remainingSeconds = [math]::Max(0, $remaining.TotalSeconds)
                $percent = Get-TimerProgress -Timer $displayTimer

                if ($currentTimer.State -eq 'Running' -and $remainingSeconds -le 0) {
                    if (-not (Test-TimerWatchAwaitingContinuation -Timer $currentTimer)) {
                        Write-TimerWatchCompletedScreen -Colors $c -CurrentTimer $currentTimer -Timer $Timer -TotalSeconds $totalSeconds -EndTime $endTime
                        break
                    }

                    $refresh = Get-TimerDataIfChanged -Force
                    $refreshed = @($refresh.Data | Where-Object { [string]$_.Id -eq $watchId })[0]
                    if ($refreshed) {
                        if ($refreshed.State -eq 'Completed') {
                            Write-TimerWatchCompletedScreen -Colors $c -CurrentTimer $refreshed -Timer $Timer -TotalSeconds $totalSeconds -EndTime $endTime
                            break
                        }
                        if ($refreshed.State -eq 'Running' -and $refreshed.EndTime) {
                            $refreshedEnd = [DateTime]::Parse($refreshed.EndTime)
                            if ($refreshedEnd -gt $now) {
                                $currentTimer = $refreshed
                                $endTime = $refreshedEnd
                                $displayTimer = $refreshed
                                $displayEndTime = $refreshedEnd
                                $displayTotalSeconds = [int]$refreshed.Seconds
                                $remaining = $displayEndTime - $now
                                $remainingSeconds = [math]::Max(0, $remaining.TotalSeconds)
                                $percent = Get-TimerProgress -Timer $displayTimer
                            }
                        }
                    }

                    if ($remainingSeconds -le 0) {
                        $optimistic = Get-TimerWatchOptimisticNextPhaseDisplay -Timer $currentTimer -PreviousEndTime $endTime -Now $now
                        if ($optimistic) {
                            $displayTimer = $optimistic.DisplayTimer
                            $displayEndTime = $optimistic.EndTime
                            $displayTotalSeconds = $optimistic.TotalSeconds
                            $remaining = $displayEndTime - $now
                            $remainingSeconds = [math]::Max(0, $remaining.TotalSeconds)
                            $percent = Get-TimerProgress -Timer $displayTimer
                        }
                        else {
                            $foundNextRun = $false
                            $pollMs = @(200, 200, 300, 500, 500, 1000, 1000, 1000)
                            foreach ($delay in $pollMs) {
                                Start-Sleep -Milliseconds $delay
                                $pollRefresh = Get-TimerDataIfChanged -Force
                                $pollTimer = @($pollRefresh.Data | Where-Object { [string]$_.Id -eq $watchId })[0]
                                if ($pollTimer -and $pollTimer.State -eq 'Completed') {
                                    Write-TimerWatchCompletedScreen -Colors $c -CurrentTimer $pollTimer -Timer $Timer -TotalSeconds $totalSeconds -EndTime $endTime
                                    return
                                }
                                if ($pollTimer -and $pollTimer.State -eq 'Running' -and $pollTimer.EndTime) {
                                    $pollEnd = [DateTime]::Parse($pollTimer.EndTime)
                                    if ($pollEnd -gt (Get-Date)) {
                                        $currentTimer = $pollTimer
                                        $endTime = $pollEnd
                                        $foundNextRun = $true
                                        break
                                    }
                                }
                            }
                            if ($foundNextRun) { continue }
                            Write-TimerWatchCompletedScreen -Colors $c -CurrentTimer $currentTimer -Timer $Timer -TotalSeconds $totalSeconds -EndTime $endTime
                            break
                        }
                    }
                }
            }

            $endsAtStr = $displayEndTime.ToString('HH:mm:ss')
            $stateSuffix = if ($currentTimer.State -eq 'Paused') { ' (paused)' } else { '' }
            $sb = Get-TimerWatchRunningContent -Colors $c -CurrentTimer $displayTimer -Timer $Timer -Percent $percent -Remaining $remaining -EndsAtFormatted $endsAtStr
            $phaseSb = Get-TimerWatchPhaseTimelineContent -Colors $c -CurrentTimer $displayTimer
            if ($phaseSb) { [void]$sb.Append($phaseSb.ToString()) }
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine((Get-TimerWatchFooterText -Colors $c -ShowHelp:$showHelp) + $stateSuffix)
            Clear-Host
            [Console]::Write($sb.ToString())

            $input = Wait-TimerWatchInput -Stopwatch $sw
            switch ($input.Action) {
                'exit' { return }
                'toggleHelp' { $showHelp = -not $showHelp; continue }
                'togglePause' {
                    $timers = @(Get-TimerData)
                    if ($currentTimer.State -eq 'Paused') {
                        $result = Invoke-ResumeSingleTimer -Timers $timers -Id $watchId
                        if ($result.CanResume -and $result.NewEndTime) {
                            $endTime = $result.NewEndTime
                        }
                    }
                    else {
                        Invoke-PauseSingleTimer -Timers $timers -Id $watchId | Out-Null
                    }
                    continue
                }
                'prevTimer' {
                    $watchId = Switch-TimerWatchTarget -ActiveTimers $activeTimers -CurrentId $watchId -Direction 'up'
                    $Timer = @($allTimers | Where-Object { [string]$_.Id -eq $watchId })[0]
                    $currentTimer = $Timer
                    if ($currentTimer.EndTime) { $endTime = [DateTime]::Parse($currentTimer.EndTime) }
                    continue
                }
                'nextTimer' {
                    $watchId = Switch-TimerWatchTarget -ActiveTimers $activeTimers -CurrentId $watchId -Direction 'down'
                    $Timer = @($allTimers | Where-Object { [string]$_.Id -eq $watchId })[0]
                    $currentTimer = $Timer
                    if ($currentTimer.EndTime) { $endTime = [DateTime]::Parse($currentTimer.EndTime) }
                    continue
                }
                'nextPhase' {
                    if ($currentTimer.IsSequence) {
                        if (Invoke-TimerSequencePhaseJump -TimerId $watchId -Direction 'next') {
                            $refreshed = @((Get-TimerData) | Where-Object { [string]$_.Id -eq $watchId })[0]
                            if ($refreshed) {
                                $currentTimer = $refreshed
                                $endTime = [DateTime]::Parse($refreshed.EndTime)
                            }
                        }
                    }
                    continue
                }
                'prevPhase' {
                    if ($currentTimer.IsSequence) {
                        if (Invoke-TimerSequencePhaseJump -TimerId $watchId -Direction 'prevOrRestart') {
                            $refreshed = @((Get-TimerData) | Where-Object { [string]$_.Id -eq $watchId })[0]
                            if ($refreshed) {
                                $currentTimer = $refreshed
                                $endTime = [DateTime]::Parse($refreshed.EndTime)
                            }
                        }
                    }
                    continue
                }
                default { continue }
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
            Invoke-TimerAfterStart -TimerId $Id
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
Set-Alias -Name twko -Value Timer-Workout -Scope Global
# endregion Timer-Aliases.ps1

