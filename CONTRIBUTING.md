# Contributing to PS1Timer

Thanks for helping improve PS1Timer.

## Development setup

1. Clone the repo and open PowerShell 7.4+ on Windows.
2. Load the module: `Import-Module .\PS1Timer.psd1 -Force`
3. Run tests: `.\Run-Tests.ps1`

## Built-in presets

Edit [`src/BuiltInPresets.ps1`](src/BuiltInPresets.ps1) to add or change shipped presets. Run `.\Run-Tests.ps1` — the suite expects 19 built-in keys.

User-facing defaults live in [`config.example.ps1`](config.example.ps1). Personal overrides belong in `config.ps1` (gitignored).

## Pull requests

- Keep changes focused; match existing PowerShell style.
- Add or update tests for behavior changes.
- Update `docs/` and `CHANGELOG.md` when user-facing behavior changes.
- Use lowercase commit prefixes: `feat:`, `fix:`, `docs:`, `test:`, `chore:`.

## Reporting issues

Use the bug report template and include PowerShell version and Windows version.
