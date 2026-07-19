---
name: ps1timer-workout-builder
description: >-
  Designs PS1Timer workout routines from user instructions: routine key, Description,
  timing, exercises, prepare/rest transitions, loops, and enriched form cues.
  Use when the user asks to create, add, or design a workout, exercise plan, HIIT/strength
  routine, or Config.Workouts entry for PS1Timer.
---

# PS1Timer Workout Builder

Turn brief user instructions into a **complete, runnable PS1Timer workout** plus **form guidance** the user did not have to spell out.

## When to use

- User wants a new workout routine (`Config.Workouts` entry)
- User lists exercises loosely (“push day with bench and OHP”)
- User asks for HIIT/Tabata/strength/circuit/mobility with timers
- User wants how-to instructions for each exercise

## Ask before building (when unclear)

Use `AskQuestion` or a short bullet list when any of these are missing and would change the routine:

| Missing | Ask |
|---------|-----|
| Goal / type | Strength, HIIT, mobility, rehab, mixed? |
| Duration cap | “How long should the full session be?” |
| Equipment | Bodyweight, dumbbells, barbell, bands? |
| Side / unilateral | Both sides explicitly, or one-sided only? |
| Prepare / transition | Need setup time between poses (e.g. “switch sides”, “get into child’s pose”)? |
| Rest between sets/exercises | Default rest unless user specified |
| Voice language | Hungarian vs English labels (match user’s language) |
| Intensity cues | Countdown `321` vs `10` vs `none` |

Do **not** guess prepare/rest durations when the user describes complex flow — confirm typical transition length (often `10s`–`30s`).

## Output (always deliver both)

### 1. PS1Timer config block

Ready to paste into `config.ps1` under `Workouts`:

```powershell
'routine-key' = @{
    Description      = 'Push day: chest and shoulders, ~35 min'
    Warmup           = '5m warmup'          # optional sequence pattern
    Cooldown         = '3m cooldown'        # optional
    Voice            = $true
    Visual           = 'none'               # no popup at phase end
    Sound            = $false               # no WAV at phase end
    Countdown        = '321'                # none | 321 | 10 | both
    BetweenExercises = '60s'                # optional rest between exercise blocks
    Exercises        = @(
        @{
            Name     = 'Bench press'
            Sets     = 4
            Work     = '45s'
            Rest     = '90s'
            FormCues = 'Flat back, feet planted, bar to mid-chest, full lockout'
        }
    )
}
```

**Pattern-only routines** — use human-readable multiline format (mandatory for 3+ phases):

```powershell
'gyors-nyujtas' = @{
    Description = 'Gyors csípő–hát nyújtás (~7 perc)'
    Pattern     = @(
        "45s 'Piriformis stretch, left side' -BeepAt 10s"
        "10s 'Switch to right side'"
        "45s 'Piriformis stretch, right side' -BeepAt 10s"
        "15s 'Move to child pose'"
        "2m30s 'Child pose, deep breathing'"
    ) -join ', '
    Voice       = $true
    Visual      = 'none'
    Sound       = $false
    Countdown   = 'none'
}
```

### Pattern syntax rules

| Element | Syntax | Example |
|---------|--------|---------|
| Phase | `duration 'label'` | `45s 'Squat hold'` |
| Loop | `(phase, phase)xN` | `(20s work, 10s rest)x8` |
| Nested loop | `((a, b)x4, c)x2` | Pomodoro-style nesting |
| Prepare / transition | Short labeled phase | `10s 'Switch sides'`, `15s 'Set up bench'` |
| Rest (in pattern) | Same as any phase | `90s 'Rest'` |
| Mid-phase beep | `-BeepAt` after label | `45s 'Hold' -BeepAt 10s, 30s` |
| Quoted label | Required if label has spaces | `'Figura négy, bal oldal'` |

**Loops:** Prefer explicit `(work, rest)xN` over repeating lines. For unilateral work, expand both sides or use a loop only when both sides share the same duration and label pattern.

**Prepare vs rest:**

- **Prepare / transition** — short phase before the next hold or exercise (`10s 'Váltás jobb oldalra'`)
- **Rest** — recovery between work sets (`90s 'Rest'` or `BetweenExercises` in exercise-based routines)
- **Work** — main hold or effort window

**Mobility / stretch flows:** Always add a **10s prepare phase before every stretch/hold**, including the first. Use a setup label (`10s 'Készülj: piriformis nyújtás, bal oldal'`) then the hold. Use separate 10s transition phases between position changes.

Always include transition phases when the user must change position; do not merge “switch sides” into the next hold without a timed gap.

**Pattern-only vs exercise-based**

| User intent | Use |
|-------------|-----|
| Tabata, EMOM, fixed intervals | `Pattern` + `Description` |
| Gym sets with named lifts | `Exercises` array (+ optional Warmup/Cooldown) |
| Mobility / stretch flows | `Pattern` with prepare phases + `-BeepAt` on long holds |
| Mixed | `Warmup` + `Exercises` + `Cooldown` |

**Routine key rules:** lowercase, hyphenated, 2–4 words (`upper-push`, `gyors-nyujtas`).

**`Description` is spoken** at workout start via `VoiceTemplates.WorkoutStart` (`{description}`, `{duration}`, `{endTime}`, `{phaseCount}`). Write it as a clear session name, not the routine key.

**Timing defaults** (override when user specifies):

| Type | Work | Rest / prepare | Countdown |
|------|------|----------------|-----------|
| Strength compound | 45–60s | 90–120s rest | `10` or `321` |
| Strength isolation | 30–45s | 60–90s rest | `321` |
| HIIT / Tabata | 20–40s | 10–30s rest | `321` |
| EMOM | `1m` per round | — | `10` |
| Mobility hold | 30–90s | **10s prepare** before every hold (incl. first) | `none` + `-BeepAt 10s` on long holds |
| Warmup / cooldown | 3–8m | — | `none` |

**Voice labels:** Keep phase labels short and speakable (under ~8 words). Session intro is spoken before the clock starts; the first phase label is shown on watch/confirmation. Later phases are announced at the previous phase end.

### 2. Form guide (markdown)

Separate section with per-exercise detail the timer does **not** speak:

```markdown
## Bench press

**Setup:** Shoulder blades pinched, feet flat, grip slightly wider than shoulders.

**Execution:** Lower bar to mid-chest, elbows ~45°, press to lockout without bouncing.

**Breathing:** Inhale on the way down, exhale on the press.

**Avoid:** Flared elbows, lifting hips off bench, half reps.
```

One subsection per exercise. Match user language (Hungarian if they wrote in Hungarian).

## Workflow

1. **Parse intent** — goal, duration cap, equipment, experience, injuries.
2. **Clarify gaps** — prepare/rest, sides, countdown preference if ambiguous.
3. **Choose structure** — pattern vs exercise list; warmup/cooldown.
4. **Name the routine** — key + `Description` (spoken session name + ~duration).
5. **Fill timing** — work, rest, prepare; sanity-check total duration.
6. **Format pattern** — multiline `@(...) -join ', '`; loops where repetitive.
7. **Enrich exercises** — `FormCues` + form guide (Setup, Execution, Breathing, Avoid).
8. **Validate** — checklist below.
9. **Present** — config block + form guide + `t workout <key>`.

## Enrichment rules (mandatory)

Do **not** copy only the user's words. Always add:

| Field | Agent fills |
|-------|-------------|
| `Description` | Session purpose, muscle groups, ~duration (used in TTS) |
| `Warmup` / `Cooldown` | Suggest if missing and session > 15 min |
| Prepare phases | **10s before every stretch/hold** in mobility; between position changes otherwise |
| `FormCues` | Short speakable cue per exercise |
| Form guide | Setup, Execution, Breathing, Avoid |
| `Countdown` | Match intensity; mobility often `none` + `-BeepAt` |

**Safety:** No extreme volume for beginners. Flag injury contraindications briefly.

## Validation checklist

- [ ] Routine key unique, lowercase, hyphenated
- [ ] `Description` is human-readable (spoken at start)
- [ ] Every exercise has `Name`, `Sets`, `Work`, `Rest` OR valid `Pattern`
- [ ] Pattern uses multiline `@(...) -join ', '` when 3+ phases
- [ ] Prepare/transition phases where user changes position
- [ ] **10s prepare before every stretch/hold** in mobility flows (including the first)
- [ ] `-BeepAt` on holds ≥ 30s when user wants a warning beep
- [ ] `Work`/`Rest` use PS1Timer syntax (`45s`, `90s`, `2m30s`)
- [ ] Form guide matches exercise list
- [ ] User told: `t workout <key>` after reload

## Where to write files

| Action | Target |
|--------|--------|
| Add routine | User's `PS1Timer/config.ps1` → `Workouts` |
| Optional doc | `PS1Timer/docs/workouts/<routine-key>.md` if user asks |
| Example reference | [examples.md](examples.md) |

After editing `config.ps1`: `. .\loader.ps1` or `Reload-PS1Timer`.

## Do not

- Edit `config.example.ps1` unless user asks
- Use one long unreadable Pattern string when multiline is clearer
- Put long text in phase labels (> ~8 words)
- Skip prepare phases for multi-position mobility flows
- Promise medical outcomes

## Examples

See [examples.md](examples.md) for full input → output pairs.
