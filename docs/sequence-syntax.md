# Sequence syntax

PS1Timer sequences chain multiple countdown phases — ideal for Pomodoro, intervals, and workouts.

## Basic form

```
(duration label, duration label)xN
```

| Part | Meaning |
|------|---------|
| `duration` | `25m`, `90s`, `1h30m`, or bare seconds |
| `label` | Phase name shown in list/watch (optional) |
| `xN` | Repeat the group N times |

## Examples

```powershell
# Two phases, one cycle
t "25m work, 5m rest"

# Four work/rest cycles
t "(25m work, 5m rest)x4"

# Cycles plus trailing phase
t "(25m work, 5m rest)x4, 20m 'long break'"

# Nested loops
t "((25m work, 5m rest)x4, 20m break)x2"

# Preset name (same as pattern expansion)
t pomodoro
```

## Quoted labels

Use single quotes when the label contains spaces:

```powershell
t "(30m 'long break')x1"
```

## Preset names

If the string matches a preset key in `src/BuiltInPresets.ps1` (or your `config.ps1` overrides), it expands to that preset's pattern before parsing.

## Parser rules

1. **Simple timer** — `25m` or `25m message` (no comma, not a preset) → single countdown.
2. **Sequence** — contains `,`, `(`, `)`, or `x` multiplier → parsed as phases.
3. **Preset** — exact key match → pattern substituted first.

## Phase metadata

Each expanded phase includes:

| Field | Description |
|-------|-------------|
| `Seconds` | Phase duration |
| `Label` | Display name |
| `LoopId` / `LoopIteration` / `LoopTotal` | Loop tracking for nested groups |

## Tips

- Wrap complex patterns in quotes so PowerShell does not split on commas.
- Use `tpre` to browse presets without memorizing names.
- Test a pattern with `tl` after start — sequences show phase label and progress in `tw`.
