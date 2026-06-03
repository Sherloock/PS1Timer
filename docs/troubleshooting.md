# Troubleshooting

## Timer shows Lost

**Cause:** Scheduled task was removed or failed, and the end time passed.

**Fix:**

```powershell
tr <id>    # resume if remaining time was saved
td <id>    # or remove and start fresh
```

## Stale PSTimer_* tasks after upgrade

If you migrated from PS1Toolz or an older PS1Timer version, orphaned tasks may remain.

```powershell
# List PS1Timer tasks
Get-ScheduledTask | Where-Object TaskName -like 'PSTimer_*'

# Remove all via PS1Timer
td all

# Or unregister manually
Get-ScheduledTask | Where-Object TaskName -like 'PSTimer_*' | Unregister-ScheduledTask -Confirm:$false
```

## Notifications not appearing

1. Confirm mode: `t 1m -Notify popup` for a quick test.
2. Check Focus Assist / Do Not Disturb on Windows.
3. Toast mode requires a user session; headless SSH sessions may not show UI.
4. For `sound`, verify `SoundFile` path exists if configured.

## Permission errors registering tasks

Scheduled tasks register in the **current user** context. Run PowerShell as your normal user (not a restricted sandbox). Corporate policy blocking task creation will prevent PS1Timer from starting timers.

## `%TEMP%\ps-timers.json` corrupted

```powershell
td all
Remove-Item $env:TEMP\ps-timers.json -ErrorAction SilentlyContinue
```

Then start a new timer.

## Commands not found after install

```powershell
Import-Module C:\path\to\PS1Timer\PS1Timer.psd1 -Force
Get-Command t
```

Add `loader.ps1` to `$PROFILE` for persistence.

## Errors before `tpre` menu / confirm `t` is PS1Timer

**Red errors before the preset picker** often come from PS1Toolz failing to parse a script during `Load-Toolkit` (check the first `ParserError` line). Fix that file, then open a new terminal.

**Many errors only when opening `tpre`** were caused by `[ordered]@{}` presets not supporting `.ContainsKey` — fixed in current `Timer.ps1`; reload the module.

**Verify source** (after first `t` or `Load-PS1Timer`):

```powershell
Show-TimerCommandSource   # if defined in profile.local.ps1
# or:
Get-Command t, Timer, tpre | Format-Table Name, CommandType, Source, @{ n='Module'; e={ $_.ModuleName } }
```

`Module` should be **PS1Timer**. `Source` should point under your `PS1Timer` folder, not `PS1Toolz`.

**Lazy load:** dotfile `profile.local.ps1` can defer PS1Timer until the first `t` / `tpre`. Set `$env:PS1TIMER_EAGER = '1'` before profile runs to load at startup instead.

## Tests fail locally

```powershell
.\Run-Tests.ps1 -Detailed
```

Requires Pester 5.x — `Run-Tests.ps1` installs it if missing.

## Wrong preset count or missing preset

Built-ins come from `config/presets.ps1`. After editing, reload:

```powershell
Import-Module .\PS1Timer.psd1 -Force
```

Custom presets belong in `config.ps1` under `TimerPresets`.
