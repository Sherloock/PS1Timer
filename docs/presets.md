# Presets

All presets are defined in [`config.example.ps1`](../config.example.ps1) under **`Presets`**, or in your gitignored `config.ps1` when you copy the example.

## Usage

```powershell
t pomodoro          # by name
tpre                # interactive picker
Timer-Presets       # same as tpre
```

## Shipped presets (19)

| Name | Pattern | Use case |
|------|---------|----------|
| `pomodoro` | `(25m work, 5m rest)x4, 20m 'long break'` | Classic Pomodoro |
| `pomodoro-short` | `(25m work, 5m rest)x2` | Quick Pomodoro |
| `pomodoro-long` | `(50m focus, 10m break)x3, 30m 'long break'` | Extended focus |
| `52-17` | `(52m focus, 17m break)x3` | 52/17 productivity |
| `90-20` | `(90m deep, 20m rest)x2` | Deep work cycles |
| `micro-pomodoro` | `(15m work, 3m rest)x4` | Short focus blocks |
| `eye-20-20-20` | `(20m screen, 20s 'eye break')x4` | Screen strain relief |
| `standup` | `15m 'standup prep'` | Meeting buffer |
| `deep-focus-3h` | `(50m focus, 10m break)x3` | ~3 hour deep work |
| `power-nap` | `20m 'power nap'` | Rest |
| `meditation` | `10m meditation` | Mindfulness |
| `tabata` | `(20s work, 10s rest)x8` | HIIT Tabata |
| `cooking-pasta` | `10m boil, 2m rest` | Pasta timer |
| `cooking-rice` | `18m simmer` | Rice simmer |
| `lecture` | `45m lecture, 15m break` | Study session |
| `gym-sets` | `(3m set, 90s rest)x5` | Weight training |
| `two-minute` | `2m 'quick task'` | GTD micro-start |
| `flowtime` | `(45m focus, 15m break)x4` | Flexible deep work |
| `ultradian` | `(90m focus, 20m break)x2` | Natural rhythm |

## Customize presets

Copy `config.example.ps1` to `config.ps1` and edit the `Presets` table:

```powershell
Presets = @{
    'my-focus' = @{
        Pattern     = '(40m focus, 10m break)x3'
        Description = 'Custom 40/10 rhythm'
    }
    # ... keep or remove shipped entries
}
```

Reload: `. .\loader.ps1` or `Import-Module .\PS1Timer.psd1 -Force -DisableNameChecking`

## Deprecated: TimerPresets

Older configs used `TimerPresets` instead of `Presets`. That key still works with a warning; rename to `Presets`.
