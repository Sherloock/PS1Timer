# PS1Timer

PowerShell 7 timer and Pomodoro for **Windows**. Countdowns run as **Windows Scheduled Tasks**, so they keep firing after you close the terminal.

## Requirements

- **PowerShell 7.4+** (`pwsh`)
- **Windows 10/11** (uses Scheduled Task API; not supported on Linux/macOS)

## Install

```powershell
git clone https://github.com/Sherloock/PS1Timer.git
Set-Location PS1Timer
Import-Module .\PS1Timer.psd1 -Force
```

Optional — load on every shell session:

```powershell
# Add to your $PROFILE:
. C:\path\to\PS1Timer\loader.ps1
```

## Quick start

```powershell
t 25m                    # 25-minute timer
t 1h30m "Deep work"      # custom message
t -Repeat 3 10m "Sets"   # repeat 3 times
t pomodoro               # run a preset sequence
tpre                     # interactive preset picker
tl                       # list active timers
tl -w                    # live-updating list
tw 1                     # watch timer #1
tp 1                     # pause timer #1
tr 1                     # resume
td all                   # remove all timers
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

Full reference: [docs/commands.md](docs/commands.md)

## Presets

19 built-in rhythms — Pomodoro variants, 52-17, Tabata, cooking, gym, and more.

```powershell
t pomodoro-short
t tabata
tpre
```

See [docs/presets.md](docs/presets.md) for the full table and how to add custom presets.

## Sequence syntax

```powershell
t "(25m work, 5m rest)x4, 20m 'long break'"
t "((25m work, 5m rest)x4, 20m break)x2"
```

Grammar and examples: [docs/sequence-syntax.md](docs/sequence-syntax.md)

## Configuration

```powershell
Copy-Item config.example.ps1 config.ps1
```

Set default notification mode (`popup`, `toast`, `sound`, `silent`) and override presets. Details: [docs/notifications.md](docs/notifications.md)

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

## License

MIT — see [LICENSE](LICENSE).
