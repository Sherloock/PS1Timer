# Workout timers

Structured gym/HIIT routines with voice coaching, built on the sequence engine.

## Quick start

```powershell
t tabata                    # preset with voice + 3-2-1
t workout                   # picker from Config.Workouts
t workout upper-push        # named routine
twko -List                  # list configured routines
```

## Config.Workouts

Define routines in `config.ps1` (copy from `config.example.ps1`):

```powershell
Workouts = @{
    'upper-push' = @{
        Description      = 'Push day'
        Warmup           = '5m warmup'
        Cooldown         = '3m cooldown'
        Voice            = $true
        Visual           = 'none'
        Sound            = $false
        Countdown        = '321'
        BetweenExercises = '60s'
        Exercises        = @(
            @{ Name = 'Bench press'; Sets = 4; Work = '45s'; Rest = '90s' }
            @{ Name = 'Overhead press'; Sets = 3; Work = '45s'; Rest = '90s' }
        )
    }
    'tabata-hiit' = @{
        Description = '4-minute Tabata'
        Pattern     = '(20s work, 10s rest)x8'
        Voice       = $true
        Countdown   = '321'
    }
}
```

### Pattern-only routines

Use `Pattern` for interval workouts (same syntax as sequence presets). PS1Timer expands the pattern and applies `Voice` / `Countdown` from the routine block.

**Mobility / stretch flows:** Add a **10s prepare phase before every stretch/hold**, including the first. Example:

```powershell
Pattern = @(
    "10s 'Készülj: piriformis nyújtás, bal oldal'"
    "45s 'Piriformis nyújtás, bal oldal' -BeepAt 10s"
    "10s 'Váltás jobb oldalra'"
    "45s 'Piriformis nyújtás, jobb oldal' -BeepAt 10s"
) -join ', '
```

Use `tw` / `AfterStart watch` during voice workouts. The watch opens after the spoken intro; the first phase timer starts only once intro playback finishes.

### Exercise-based routines

| Key | Purpose |
|-----|---------|
| `Warmup` | Sequence pattern prepended |
| `Exercises` | Array of `{ Name, Sets, Work, Rest }` |
| `BetweenExercises` | Optional rest between exercise blocks |
| `Cooldown` | Sequence pattern appended |

Each set produces a **work** phase (spoken exercise name) and **rest** phase.

## Overrides

```powershell
t workout upper-push -Countdown 10 -AfterStart watch
t workout -Voice -NoSound -Visual none
```

Priority: CLI flags > routine config > `TimerDefaults`.

## Timer record fields

Workout timers set `IsWorkout = $true` and `WorkoutRoutine = '<name>'` in `%TEMP%\ps-timers.json`.

Phase objects may include `PhaseType`, `AnnounceStart`, `Countdown`, `ExerciseName`, `SetNumber`.

See [voice.md](voice.md) for TTS templates and countdown behavior.
