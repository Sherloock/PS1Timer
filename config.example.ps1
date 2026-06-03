# PS1Timer default configuration
#
# This file is loaded automatically when you import the module.
# You do not need to copy it to get started.
#
# To keep personal settings across git pull (and out of the repo):
#   Copy-Item config.example.ps1 config.ps1
#   Edit config.ps1 (gitignored)
#
# When config.ps1 exists, it replaces this file entirely (not merged).

$global:Config = @{
    # TimerDefaults — applied to every new timer unless overridden with -Notify
    TimerDefaults = @{
        # Notification mode: popup | toast | sound | silent
        # Per-timer override: t 25m -Notify toast
        Notify = 'popup'

        # Optional .wav path for sound mode (null = console beep)
        # Example: SoundFile = 'C:\sounds\alarm.wav'
        SoundFile = $null
    }

    # TimerPresets — optional overrides and custom presets
    # Merged on top of 19 built-ins in src/BuiltInPresets.ps1 (see docs/presets.md).
    # Same key replaces a built-in; new keys add presets.
    #
    # TimerPresets = @{
    #     'my-focus' = @{
    #         Pattern     = '(40m focus, 10m break)x3'
    #         Description = 'Custom 40/10 rhythm'
    #     }
    # }
}
