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

No configuration copy is required — `config.example.ps1` loads automatically.

## Profile auto-load

Add one line to your PowerShell profile (`$PROFILE`):

```powershell
. C:\path\to\PS1Timer\loader.ps1
```

The loader checks for PowerShell 7.4+ and imports the module globally so aliases (`t`, `tl`, …) are available in every session.

## Optional configuration

Copy the example only when you want personal settings that stay out of git:

```powershell
Copy-Item config.example.ps1 config.ps1
```

Edit `config.ps1` for default notifications and custom presets. When `config.ps1` exists, it **replaces** `config.example.ps1` (not merged). `config.ps1` is gitignored.

Reload after changes:

```powershell
Import-Module .\PS1Timer.psd1 -Force
```

## Upgrading

```powershell
Set-Location PS1Timer
git pull
Import-Module .\PS1Timer.psd1 -Force
```

If you use `loader.ps1` in your profile, the next shell session picks up changes automatically. Personal settings in `config.ps1` are preserved across `git pull`.

## PowerShell Gallery (future)

Gallery publish is optional. For now, install from GitHub as above.
