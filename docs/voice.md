# Voice announcements (TTS)

PS1Timer uses Windows built-in text-to-speech via `System.Speech.Synthesis.SpeechSynthesizer`.

## Enable voice

```powershell
# Default in config.ps1
TimerDefaults = @{
    Voice     = $true
    VoiceRate = 0        # -10 .. 10
    VoiceName = $null    # system default
    Countdown = '321'    # none | 321 | 10 | both
}

# Per timer
t tabata -Voice
t gym-sets -Voice -NoSound -Visual none
t "(40s work, 20s rest)x10" -Voice -Countdown both
```

## What gets spoken

| Event | Default template | Config key |
|-------|------------------|------------|
| Workout start | `Starting {routine}. {phaseCount} phases.` | `WorkoutStart` |
| Phase start | `{label}` | `PhaseStart` |
| Phase end (next phase) | `{next}` | `PhaseEnd` |
| Countdown tick | `{seconds}` | `CountdownTick` |
| Workout complete | `Workout complete. Well done.` | `WorkoutComplete` |

**Sequence/workout flow:** Voice workouts read the session intro first while the clock is stopped. Only after the intro finishes does phase 1 start counting. The first phase label is shown on watch/confirmation; later phases are announced at the previous phase end via the fire script. Non-workout voice sequences keep the existing immediate start behavior.

Templates live in `Config.VoiceTemplates` (`config.example.ps1`).

## Countdown modes

| Mode | Behavior |
|------|----------|
| `none` | No mid-phase countdown |
| `321` | Speak 3, 2, 1 in the last 3 seconds |
| `10` | Speak "10" at 10 seconds remaining (phases ≥ 10s) |
| `both` | 10-second warning + 3-2-1 |

Countdown uses auxiliary scheduled tasks (`PSTimer_{id}_cue_*`) so it works when the terminal is closed.

## List installed voices

```powershell
Get-TimerInstalledVoices
```

Set a voice in config:

```powershell
VoiceName = 'Microsoft Zira Desktop'
```

## Smoke test

```powershell
Invoke-TimerSpeech -Text 'Work'
Invoke-TimerSpeech -Text 'Rest' -VoiceName 'Microsoft Zira Desktop'
```

## Troubleshooting

- Voice runs in the same hidden scheduled-task context as popups (interactive desktop session).
- If TTS fails, PS1Timer falls back to a console beep.
- Prefer one active voice workout timer at a time to avoid overlapping speech.
- After config changes: `. .\loader.ps1` or `Reload-PS1Timer`.

See [troubleshooting.md](troubleshooting.md) for scheduled-task issues.
