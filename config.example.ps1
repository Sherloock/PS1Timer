# User-specific PS1Timer configuration
# Copy to config.ps1 and customize

$global:Config = @{
    # Default notification for new timers: popup | toast | sound | silent
    # Per-timer override: t 25m -Notify toast
    TimerDefaults = @{
        Notify    = 'popup'
        SoundFile = $null   # Optional path to custom .wav for sound mode
    }

    # Override or add presets (merged on top of config/presets.ps1 built-ins)
    # TimerPresets = @{
    #     'my-focus' = @{
    #         Pattern     = '(40m focus, 10m break)x3'
    #         Description = 'Custom focus rhythm'
    #     }
    # }
}
