# Changelog

All notable changes to PS1Timer are documented here.

## [Unreleased]

### Added

- `TimerDefaults.AfterStart`: `none` | `watch` | `list` — optional `tw` or `tl -w` after starting a timer
- Per-command `-AfterStart` on `Timer` / `t`

### Changed

- `config.example.ps1` loads automatically when `config.ps1` is absent (zero-config install)
- All presets live in `Config.Presets` inside config (removed `src/BuiltInPresets.ps1`)
- `TimerPresets` config key deprecated in favor of `Presets`

### Fixed

- VBS launcher uses `Chr(34)` quoting so `pwsh` under `Program Files` no longer breaks scheduled tasks
- Preset/sequence timers advance to phase 2+ (pwsh fire script, `@(Phases)` coercion, register-then-save, live `TaskName`)
- Scheduled-task registration no longer blocks the CLI (~3s delay); registers in a background job

### Performance

- `Sync-TimerData` skips `Get-ScheduledTask` while a running timer still has >2s remaining
- `Stop-TimerTask` skips wildcard task scan when a concrete `TaskName` is known

## [1.0.0] - 2026-05-31

### Added

- Standalone PowerShell 7.4+ module extracted from PS1Toolz
- Simple timers, repeat runs, and multi-phase sequence syntax
- 19 built-in presets (Pomodoro, 52-17, Tabata, cooking, gym, and more)
- Windows Scheduled Task backend (timers survive terminal close)
- Notifications: popup, toast, sound, silent
- Live list/watch UI with ANSI progress display
- Pester test suite and GitHub Actions CI
- Full documentation under `docs/`
