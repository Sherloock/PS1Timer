@{
    RootModule           = 'PS1Timer.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = 'a3f8c2e1-4b9d-4a7f-9e6c-1d2b3c4d5e6f'
    Author               = 'Deak, Balint'
    CompanyName          = 'Personal'
    Copyright            = '(c) Deak, Balint. MIT License.'
    Description          = 'PowerShell 7 timer and Pomodoro for Windows using scheduled tasks, sequences, and presets.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')

    FunctionsToExport = @(
        'ConvertFrom-TimerSequence', 'ConvertTo-Seconds', 'Expand-TimerSequence', 'Format-Duration',
        'Format-RemainingTime', 'Assert-TimerConfig', 'Get-AnsiColors', 'Get-SequenceSummary', 'Get-TimerData',
        'Get-TimerDataIfChanged', 'Get-TimerForWatch', 'Get-TimerHistory', 'Get-TimerListRowColorsForState',
        'Get-TimerListRowDisplayData', 'Get-TimerListWatchRowLine', 'Get-TimerNotificationConfig',
        'Get-TimerNotificationType', 'Get-TimerPickerOptions', 'Get-TimerProgress', 'Get-TimerStatsSummary',
        'Parse-TimerAtTime', 'Resolve-TimerNotificationSettings', 'Resolve-TimerWebhookUrl',
        'Get-TimerResumeSeconds', 'Get-TimerStateColor', 'Get-TimerTaskName', 'Get-TimerWatchCompletedContent',
        'Get-TimerWatchPhaseTimelineContent', 'Get-TimerWatchRunningContent', 'Get-TruncatedMessage',
        'Invoke-PauseSingleTimer', 'Invoke-PauseTimersBulk', 'Invoke-RemoveSingleTimer',
        'Invoke-RemoveTimersBulk', 'Invoke-ResumeSingleTimer', 'Invoke-ResumeTimersBulk',
        'New-SequenceTimerFromPhases', 'New-TimerId', 'New-TimerTaskName', 'ParseSequence',
        'Play-TimerSound', 'Save-TimerData', 'Show-MenuPicker', 'Show-TimerHelp', 'Show-TimerListOnce',
        'Show-TimerListWatch', 'Show-TimerNotification', 'Show-TimerNotificationHelp', 'Show-TimerPopup',
        'Show-TimerToast', 'Show-TimerWatchDisplay', 'Start-SequenceTimer', 'Start-SequenceTimerJob',
        'Start-TimerJob', 'Stop-TimerTask', 'Sync-TimerData', 'Test-TimerIsActiveDisplay',
        'Test-TimerSequence', 'Timer', 'Timer-List', 'Timer-Pause', 'Timer-Presets', 'Timer-Remove',
        'Timer-Resume', 'Timer-Stats', 'Timer-Watch', 'TimerList', 'TimerPause', 'TimerPresets', 'TimerRemove',
        'TimerResume', 'TimerStats', 'TimerWatch', 'Wait-OneSecondOrKeyPress', 'Write-HelpMenu',
        'Write-SequenceTimerConfirmation'
    )

    CmdletsToExport    = @()
    VariablesToExport  = @()
    AliasesToExport    = @('t', 'td', 'tl', 'tp', 'tpre', 'tr', 'ts', 'tw')
}
