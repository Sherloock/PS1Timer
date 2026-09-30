# Workout builder examples

## Example 1 — Minimal user input

**User:** „Csinálj egy push edzést bench press és mellből nyomással, 4 szett”

**Agent output (config excerpt):**

```powershell
'push-basic' = @{
    Description      = 'Push day: chest and shoulders, ~35 min, 4 sets each'
    Warmup           = '5m warmup'
    Cooldown         = '3m stretch'
    Voice            = $true
    Visual           = 'none'
    Sound            = $false
    Countdown        = '321'
    BetweenExercises = '90s'
    Exercises        = @(
        @{
            Name     = 'Bench press'
            Sets     = 4
            Work     = '45s'
            Rest     = '90s'
            FormCues = 'Flat back, feet down, bar to chest, full lockout'
        }
        @{
            Name     = 'Incline dumbbell press'
            Sets     = 4
            Work     = '45s'
            Rest     = '90s'
            FormCues = 'Bench 30 degrees, control down, press without clanking'
        }
    )
}
```

**Form guide (abbreviated):**

- **Bench press** — Setup: scapular retraction, feet flat. Execution: bar to mid-chest, elbows ~45°. Breathing: inhale down, exhale up. Avoid: bouncing, flared elbows.
- **Incline dumbbell press** — Setup: 30° bench, dumbbells at shoulder height. Execution: press up and slightly together. Avoid: excessive arch, dropping weights.

**Run:** `t workout push-basic`

---

## Example 2 — HIIT pattern only

**User:** „30 másodperc work 30 rest, 10 kör, tabata jelleg”

```powershell
'hiit-30-30-10' = @{
    Description = '10-round 30/30 HIIT, voice countdown'
    Pattern     = '(30s work, 30s rest)x10'
    Voice       = $true
    Visual      = 'none'
    Sound       = $false
    Countdown   = '321'
}
```

No per-exercise form guide unless user named movements. Add brief session note: maintain steady pace, scale intensity to fitness.

---

## Example 3 — Single exercise enrichment

**User:** „Romanian deadlift, 3x12”

Agent expands to timed sets (user said reps → map to ~45–60s work window or ask if they prefer rep counting elsewhere):

```powershell
'rdl-focus' = @{
    Description = 'RDL technique focus: 3 sets, hamstring and glute emphasis'
    Warmup      = '3m hip mobility'
    Voice       = $true
    Countdown   = '10'
    Exercises   = @(
        @{
            Name     = 'Romanian deadlift'
            Sets     = 3
            Work     = '50s'
            Rest     = '90s'
            FormCues = 'Soft knees, hinge hips back, bar close to legs, feel hamstrings'
        }
    )
}
```

**Form guide — Romanian deadlift**

- **Setup:** Hip-width stance, neutral spine, bar over mid-foot.
- **Execution:** Push hips back, bar slides along thighs, stop when hamstrings stretch, drive hips forward.
- **Breathing:** Brace at top, exhale on the way up.
- **Avoid:** Rounding lower back, squatting the weight, going below mobility.
