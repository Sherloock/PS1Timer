# Installation

## Requirements

- PowerShell **7.4 or later** — check with `$PSVersionTable.PSVersion`
- **Windows 10 or 11** — timers use the Windows Task Scheduler

PS1Timer does not run on Linux or macOS. The scheduled-task backend is Windows-specific.

## Clone and import

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

## Profile auto-load

Add one line to your PowerShell profile (`$PROFILE`):

```powershell
. C:\F\Fejlesztes\projects\my\PS1Timer\loader.ps1
```

The loader checks for PowerShell 7.4+ and imports the module globally so aliases (`t`, `tl`, …) are available in every session.

## Optional configuration

```powershell
Copy-Item config.example.ps1 config.ps1
```

Edit `config.ps1` to set default notifications and custom presets. `config.ps1` is gitignored — do not commit secrets or personal paths.

## Upgrading

```powershell
Set-Location PS1Timer
git pull
Import-Module .\PS1Timer.psd1 -Force
```

If you use `loader.ps1` in your profile, the next shell session picks up changes automatically.

## PowerShell Gallery (future)

Gallery publish is optional. For now, install from GitHub as above.
