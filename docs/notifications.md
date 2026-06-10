# Notifications

When a timer phase completes, PS1Timer can notify you through three **independent** channels:

| Channel | Config key | Values | Behavior |
|---------|------------|--------|----------|
| Visual | `Visual` | `popup` \| `toast` \| `none` | Modal dialog, tray balloon, or no UI |
| Sound | `Sound` | `$true` \| `$false` | Console beep or `SoundFile` when on |
| Webhook | `Webhook` | named key or `$null` | POST JSON when defined (additive) |

Example combinations:

- `Visual='toast', Sound=$true, Webhook='discord-main'` → toast + beep + Discord POST
- `Visual='none', Sound=$true` → sound only (Tabata-style)
- `Visual='none', Sound=$false` → silent (timer still advances)

## Default configuration

```powershell
$global:Config = @{
    TimerDefaults = @{
        Visual    = 'none'
        Sound     = $true
        Webhook   = 'discord-main'   # optional; fires when set
        SoundFile = $null            # e.g. 'C:\sounds\alarm.wav'
        AfterStart = 'none'
    }
    Webhooks = @{
        'discord-main' = 'https://discord.com/api/webhooks/...'
        'ntfy-phone'   = 'https://ntfy.sh/my-topic'
    }
}
```

Reload: `Import-Module .\PS1Timer.psd1 -Force` or `Reload-PS1Timer` (lazy-load profile).

## Per-timer override

```powershell
t 25m -Visual toast -Sound
t 10m -Visual none -Sound -Message "Break over"
t 5m -Visual none -NoSound
t 25m -Webhook discord-main
```

Legacy shorthand still works:

```powershell
t 25m -Notify toast
t 10m -Notify sound
t 5m -Notify silent
t 25m -Notify webhook -Webhook discord-main
```

Priority: `-Notify` > `-Visual` / `-Sound` / `-Webhook` > preset > `TimerDefaults`.

Presets may set `Visual`, `Sound`, and `Webhook` per preset (e.g. `tabata` with `Visual='none', Sound=$true`).

## Webhook

- Define URLs in `Config.Webhooks` by name
- Set `TimerDefaults.Webhook` or use `-Webhook <name>` on the command
- Payload: `{ "content": "message | details" }` (Discord-compatible)
- Fires **in addition** to visual/sound when using the new config model

## Sound

- Without `SoundFile`: uses `[console]::beep`
- With `SoundFile`: plays the `.wav` via `System.Media.SoundPlayer`

## Legacy `Notify` mapping

| Legacy `Notify` | Visual | Sound |
|-----------------|--------|-------|
| `popup` | `popup` | `$true` |
| `toast` | `toast` | `$true` |
| `sound` | `none` | `$true` |
| `silent` | `none` | `$false` |
| `webhook` | `none` | `$false` (webhook required) |

## Help in the shell

Run `Show-TimerNotificationHelp` for a quick reference.

## Scheduled task context

Notifications fire from a hidden PowerShell script launched by the scheduled task. Popups and toasts appear on the **interactive desktop session** where the task was registered.

If notifications never appear, check [troubleshooting.md](troubleshooting.md).
