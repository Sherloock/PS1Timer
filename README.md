# PS1Timer

PowerShell 7 timers and Pomodoro for **Windows**. Countdowns run as **Windows Scheduled Tasks**, so they keep firing after you close the terminal.

## Requirements

- **PowerShell 7.4+** (`pwsh`)
- **Windows 10/11** (Scheduled Task API; not supported on Linux/macOS)

## Install

```powershell
git clone https://github.com/Sherloock/PS1Timer.git
Set-Location PS1Timer
Import-Module .\PS1Timer.psd1 -Force
```

Verify:

```powershell
Get-Command t, tl, tw
t   # shows help
```

Optional — load on every shell session:

```powershell
# Add to your $PROFILE:
. C:\path\to\PS1Timer\loader.ps1
```

## Quick start

```powershell
# Simple countdown
t 25m
t 30m "Stretch break"
t 1h30m "Deep work" 2          # repeat twice

# Presets (19 built-in — no config setup needed)
t pomodoro
t tabata
tpre                           # interactive picker

# Custom sequence
t "(25m work, 5m rest)x4, 20m 'long break'"

# Manage running timers
tl                             # list active timers
tw 1                           # progress view for timer #1
tp 1; tr 1                     # pause / resume
td done                        # remove completed timers

# Notifications (Visual + Sound + optional Webhook)
t 25m -Visual toast -Sound
t 10m -Visual none -Sound
t 5m -Visual none -NoSound
t 25m -Webhook discord-main
t 25m -Notify toast   # legacy shorthand

# Stats & scheduled start
ts                             # today/week completion stats
t 25m work -At "14:30"         # starts at 14:30 today
```

## Commands

| Command | Alias | Description |
|---------|-------|-------------|
| `Timer` | `t` | Start simple or sequence timer; bare `t` shows help |
| `Timer-Presets` | `tpre` | Interactive preset picker |
| `Timer-List` | `tl` | List timers (`-a` all, `-w` live watch) |
| `Timer-Watch` | `tw` | Single-timer progress view |
| `Timer-Pause` | `tp` | Pause by id or `all` |
| `Timer-Resume` | `tr` | Resume paused/lost timers |
| `Timer-Remove` | `td` | Remove by id, `done`, or `all` |
| `Timer-Stats` | `ts` | Completion history (today/week/labels) |

Full reference: [docs/commands.md](docs/commands.md)

## Presets

19 built-in rhythms — Pomodoro variants, 52-17, Tabata, cooking, gym, and more.

```powershell
t pomodoro-short
t 52-17
tpre
```

Full table: [docs/presets.md](docs/presets.md)

## Sequence syntax

```powershell
t "25m work, 5m rest"
t "(25m work, 5m rest)x4, 20m 'long break'"
t "((25m work, 5m rest)x4, 20m break)x2"
```

Grammar and examples: [docs/sequence-syntax.md](docs/sequence-syntax.md)

## Configuration

Works out of the box — no copy step required.

| File | Role |
|------|------|
| [`config.example.ps1`](config.example.ps1) | Defaults + **19 presets** — loaded automatically when `config.ps1` is absent |
| `config.ps1` | Optional personal settings (gitignored) — **replaces** the example when present |

`TimerDefaults` keys: `Visual` (`popup` | `toast` | `none`), `Sound` (`$true` | `$false`), `Webhook`, `SoundFile`, `Theme`, `AfterStart` (`none` | `watch` | `list`). Legacy `Notify` still maps to Visual/Sound. `Theme` selects a palette from `Palettes`. Named URLs live in `Webhooks` (e.g. `discord-main`).

To customize:

```powershell
Copy-Item config.example.ps1 config.ps1
# Edit config.ps1 — Presets, TimerDefaults.Visual/Sound/Webhook, AfterStart, etc.
```

Then reload the module:

```powershell
Import-Module .\PS1Timer.psd1 -Force
```

Details: [docs/notifications.md](docs/notifications.md) · [docs/presets.md](docs/presets.md)

## Project layout

```
PS1Timer/
├── PS1Timer.psd1          # Module manifest
├── PS1Timer.psm1          # Loader (config + sources)
├── loader.ps1             # Profile entry point
├── config.example.ps1     # Config + Presets (auto-loaded)
├── src/
│   ├── Timer.ps1          # Timer commands
│   └── TimerHelpers.ps1   # Parsing, UI helpers
├── docs/                  # Full documentation
└── tests/                 # Pester tests
```

## Documentation

| Topic | File |
|-------|------|
| Installation | [docs/installation.md](docs/installation.md) |
| Commands | [docs/commands.md](docs/commands.md) |
| Sequence syntax | [docs/sequence-syntax.md](docs/sequence-syntax.md) |
| Presets | [docs/presets.md](docs/presets.md) |
| Notifications | [docs/notifications.md](docs/notifications.md) |
| Architecture | [docs/architecture.md](docs/architecture.md) |
| Troubleshooting | [docs/troubleshooting.md](docs/troubleshooting.md) |

## Development

```powershell
.\Run-Tests.ps1
.\Run-Tests.ps1 -Detailed
```

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).
