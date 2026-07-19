# Architecture

## Overview

```mermaid
flowchart LR
    User["t / tl / tw"] --> Module["PS1Timer.psm1"]
    Module --> JSON["%TEMP%/ps-timers.json"]
    Module --> ST["Scheduled Task PSTimer_id_guid"]
    ST --> VBS["PSTimer_id.vbs"]
    VBS --> PS1["PSTimer_id.ps1"]
    PS1 --> JSON
    PS1 --> Notify["Popup / Toast / Sound / Voice"]
    Module --> CueST["Cue tasks PSTimer_id_cue_*"]
    CueST --> VoiceOnly["TTS countdown"]
```

## Why scheduled tasks?

Terminal-only sleep loops stop when you close the shell. PS1Timer registers a **one-shot** Windows Scheduled Task per active phase. A hidden `wscript.exe` launcher runs `pwsh -WindowStyle Hidden` to execute the fire script without flashing a window.

## File locations

| Path | Purpose |
|------|---------|
| `%TEMP%\ps-timers.json` | Timer state (all records) |
| `%TEMP%\PSTimer_<id>.ps1` | Script run when phase completes |
| `%TEMP%\PSTimer_<id>.vbs` | Hidden launcher wrapper |
| `%TEMP%\PSTimer_<id>.log` | Sequence/repeat error log |
| `%TEMP%\PSTimer_<id>_register_cues.ps1` | Cue task registrar (voice countdown) |
| `%TEMP%\PSTimer_<id>_cue_*.ps1` | One-shot TTS cue scripts |

## Task naming

Current format: `PSTimer_<id>_<8-char-guid>` — unique per phase/run so overlapping timers do not clash.

Cue tasks: `PSTimer_<id>_cue_<8-char-guid>` — mid-phase voice countdown only.

Legacy tasks may use `PSTimer_<id>` only; sync logic handles both via the `TaskName` field on each timer record.

## Timer record (JSON)

### Standard fields

| Field | Description |
|-------|-------------|
| `Id` | Sequential string id (`"1"`, `"2"`, …) |
| `Duration` | Human-readable duration |
| `Seconds` | Current phase length in seconds |
| `Message` | Notification message |
| `StartTime` / `EndTime` | ISO timestamps |
| `State` | `Running`, `Paused`, `Completed`, `Lost` |
| `RepeatTotal` / `RepeatRemaining` / `CurrentRun` | Repeat tracking |
| `RemainingSeconds` | Saved when paused |
| `TaskName` | Scheduled task name for this phase |
| `IsSequence` | `$true` for multi-phase timers |
| `NotifyVoice` | TTS announcements on/off |
| `CountdownMode` | `none` \| `321` \| `10` \| `both` |
| `CueTaskNames` | Active cue scheduled task names |
| `IsWorkout` | `$true` for `t workout` timers |
| `WorkoutRoutine` | Routine key from `Config.Workouts` |

### Sequence fields (when `IsSequence`)

| Field | Description |
|-------|-------------|
| `SequencePattern` | Original pattern string |
| `Phases` | Array of phase objects |
| `CurrentPhase` | 0-based index |
| `TotalPhases` | Phase count |
| `PhaseLabel` | Current label |
| `TotalSeconds` | Entire sequence duration |

Phase objects may include `PhaseType`, `AnnounceStart`, `Countdown`, `ExerciseName`, `SetNumber` for workout coaching.

See [voice.md](voice.md) and [workouts.md](workouts.md).

## Module load order

1. `config.ps1` if present, else `config.example.ps1` → `$global:Config` (includes `Presets`, `TimerDefaults`)
2. `src/TimerHelpers.ps1` → time parsing, menus, help
3. `src/Timer.ps1` → loads `Config.Presets` into `$script:TimerPresets`, defines commands

## Sync behavior

`Sync-TimerData` runs before list/watch operations. Running timers whose scheduled task is missing **and** whose end time has passed are marked `Lost`.

## States

| State | Meaning |
|-------|---------|
| `Running` | Active scheduled task |
| `Paused` | Task removed; remaining seconds saved |
| `Completed` | Finished all phases/repeats |
| `Lost` | Task missing after expiry; resumable via `tr` |
