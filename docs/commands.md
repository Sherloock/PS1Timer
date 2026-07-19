# Commands

## Timer (`t`)

Start a simple countdown, sequence, or preset.

```powershell
Timer -Time 25m -Message "Focus" [-Repeat 3] [-Visual popup|toast|none] [-Sound] [-Webhook name] [-AfterStart none|watch|list]
t 25m
t pomodoro
t "(25m work, 5m rest)x2"
t 25m -AfterStart watch
t 5m stretch -BeepAt 3m,1m
```

| Parameter | Description |
|-----------|-------------|
| `-Time` | Duration (`25m`, `90s`, `1h30m`) or sequence/preset pattern |
| `-Message` | Notification text (default: `Time is up!`) |
| `-Repeat` | Number of runs (default: 1) |
| `-Visual` | Visual channel: `popup`, `toast`, `none` |
| `-Sound` / `-NoSound` | Enable or disable sound |
| `-Voice` / `-NoVoice` | Enable or disable Windows TTS announcements |
| `-Countdown` | Mid-phase voice countdown: `none`, `321`, `10`, `both` |
| `-BeepAt` | Mid-phase beeps when time remains (e.g. `3m,1m` on a 5m stretch timer) |
| `-Webhook` | Named webhook from `Config.Webhooks` |
| `-Notify` | Legacy shorthand: `popup`, `toast`, `sound`, `silent`, `webhook` |
| `-AfterStart` | After start: `none` (default), `watch` (`tw <id>`), `list` (`tl -w`). Default from `TimerDefaults.AfterStart` in config |

Bare `t` or `Timer` with no arguments shows the help menu.

## Timer-Workout (`twko` / `t workout`)

Structured gym/HIIT routines from `Config.Workouts` with voice coaching.

Every phase that has a next phase plays three short beeps at **3s, 2s, and 1s** remaining (always on; not configurable).

```powershell
t workout
t workout upper-push
twko -List
twko tabata-hiit -Countdown 321 -AfterStart watch
```

See [workouts.md](workouts.md) and [voice.md](voice.md).

## Timer-List (`tl`)

```powershell
tl           # running + paused timers
tl -a        # include completed and lost
tl -w        # live-updating list (press any key to exit)
```

## Timer-Watch (`tw`)

```powershell
tw           # picker if multiple timers
tw 1         # watch timer id 1
```

Shows progress bar, remaining time, **Notify** channels, **Final end** for sequences, and a phase timeline. **Esc** exits (other keys do not).

| Key | Action |
|-----|--------|
| Esc | Exit watch |
| Space | Pause / resume watched timer |
| Up / Down | Previous / next active timer |
| Right | Next sequence phase |
| Left | Restart current phase; if ≤3s elapsed, jump to previous phase start |
| ? | Toggle key help |

Press **Esc** only to exit.

## Timer-Presets (`tpre`)

Interactive menu of all presets plus a custom-pattern entry. Selected preset starts immediately via `Timer`.

## Timer-Pause (`tp`)

```powershell
tp 1         # pause timer 1
tp all       # pause all running
tp           # picker when id omitted
```

## Timer-Resume (`tr`)

```powershell
tr 1
tr all
tr           # picker
```

Resumes `Paused` or `Lost` timers with remaining time restored.

## Timer-Remove (`td`)

```powershell
td 1         # remove timer 1
td done      # remove completed and lost
td all       # remove everything
td           # picker
```

Unregisters scheduled tasks and deletes temp scripts for removed timers.

## Aliases summary

| Alias | Command |
|-------|---------|
| `t` | `Timer` |
| `tl` | `Timer-List` |
| `tw` | `Timer-Watch` |
| `tp` | `Timer-Pause` |
| `tr` | `Timer-Resume` |
| `td` | `Timer-Remove` |
| `tpre` | `Timer-Presets` |

Legacy names (`TimerList`, `TimerWatch`, …) remain as thin wrappers for backward compatibility.
