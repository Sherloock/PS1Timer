# Notifications

When a timer phase completes, PS1Timer notifies you using the configured mode.

## Modes

| Mode | Behavior |
|------|----------|
| `popup` | WScript.Shell popup dialog (default) |
| `toast` | Windows toast via `NotifyIcon` balloon |
| `sound` | Console beep or custom `.wav` |
| `silent` | No notification (timer still advances) |

## Default configuration

Defaults come from `config.example.ps1`, which loads automatically when `config.ps1` is absent.

To customize, copy to `config.ps1` and edit:

```powershell
$global:Config = @{
    TimerDefaults = @{
        Notify     = 'popup'    # popup | toast | sound | silent
        SoundFile  = $null      # e.g. 'C:\sounds\alarm.wav'
        AfterStart = 'none'     # none | watch | list
    }
}
```

Reload: `Import-Module .\PS1Timer.psd1 -Force`

## Per-timer override

```powershell
t 25m -Notify toast
t 10m -Notify sound -Message "Break over"
t 5m -Notify silent
```

## Sound mode

- Without `SoundFile`: uses `[console]::beep`
- With `SoundFile`: plays the `.wav` via `System.Media.SoundPlayer`

## Help in the shell

Run `Show-TimerNotificationHelp` for a quick reference of modes and config keys.

## Scheduled task context

Notifications fire from a hidden PowerShell script launched by the scheduled task. Popups and toasts appear on the **interactive desktop session** where the task was registered (typically your logged-in user).

If notifications never appear, check [troubleshooting.md](troubleshooting.md) — task may be running under a different session or blocked by focus assist.
