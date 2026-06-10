# PS1Timer default configuration
#
# This file is loaded automatically when you import the module.
# You do not need to copy it to get started.
#
# To keep personal settings across git pull (and out of the repo):
#   Copy-Item config.example.ps1 config.ps1
#   Edit config.ps1 (gitignored)
#
# When config.ps1 exists, it replaces this file entirely (not merged).
#
# Reload after editing config.ps1 (config is read only at module import):
#
#   From the PS1Timer folder:
#     Import-Module .\PS1Timer.psd1 -Force
#
#   If your profile dot-sources loader.ps1:
#     . .\loader.ps1
#
#   If your profile uses dotfile PS1Timer-LazyLoad.ps1:
#     Reload-PS1Timer
#
# New PowerShell sessions pick up config.ps1 automatically when the module loads.

$global:Config = @{
    # TimerDefaults — applied to every new timer unless overridden per command
    TimerDefaults = @{
        # Notifications — three independent channels (combine freely):
        #
        #   Visual  popup | toast | none
        #     popup — modal dialog (blocks until OK)
        #     toast — system-tray balloon (~10s, non-blocking)
        #     none  — no UI
        #
        #   Sound   $true | $false — console beep or SoundFile when $true
        #
        #   Webhook named key from Webhooks below — POST when set (additive)
        #
        # Override per timer:  t 25m -Visual toast -Sound -Webhook discord-main
        # Override per preset:  Visual = 'none'; Sound = $true  (see tabata)
        # Legacy shorthand:     t 25m -Notify sound  (maps to Visual/Sound)
        #
        # Priority: -Notify > -Visual/-Sound/-Webhook > preset > TimerDefaults
        Visual  = 'none'
        Sound   = $true
        Webhook = $null

        # SoundFile — optional .wav when Sound = $true (null = built-in beep)
        SoundFile = $null

        # UI theme — name from Palettes below (default | minimal | vibrant | monochrome | your own)
        Theme = 'default'

        # After start: none | watch | list
        #   none  — show confirmation only (default)
        #   watch — open tw for the new timer
        #   list  — open tl -w (live list of all timers)
        AfterStart = 'none'

        # Skip "PS1Timer loaded" message on import (faster profile load)
        QuietLoad = $false
    }

    # Palettes — UI color themes (TimerDefaults.Theme picks one by name)
    #
    # Each role uses a named color: cyan, green, yellow, red, magenta, white, gray, darkgray
    # plus bright variants (brightcyan, brightgreen, brightyellow, brightred, brightmagenta, brightwhite).
    # Copy a block, rename the key, set Theme to that name. Description is for you only.
    Palettes = @{
        default = @{
            Description  = 'Balanced colors for everyday use'
            Primary      = 'cyan'       # titles, headers, timer IDs, progress bar
            PrimaryMuted = 'cyan'       # underlines beneath titles
            Text         = 'white'      # values, message text
            Muted        = 'darkgray'   # dim labels, borders, hints
            Success      = 'green'      # running, done, progress OK
            Warning      = 'yellow'     # remaining time, paused, countdown
            Danger       = 'red'        # errors, critical/low time
            Accent       = 'magenta'    # repeats, sequence phases
            Selected     = 'cyan'       # inverted row in picker menus
        }
        minimal = @{
            Description  = 'Low-contrast gray palette for busy or dim screens'
            Primary      = 'darkgray'
            PrimaryMuted = 'darkgray'
            Text         = 'white'
            Muted        = 'darkgray'
            Success      = 'white'
            Warning      = 'darkgray'
            Danger       = 'darkgray'
            Accent       = 'darkgray'
            Selected     = 'darkgray'
        }
        vibrant = @{
            Description  = 'Bright colors for high-contrast displays'
            Primary      = 'brightcyan'
            PrimaryMuted = 'cyan'
            Text         = 'brightwhite'
            Muted        = 'darkgray'
            Success      = 'brightgreen'
            Warning      = 'brightyellow'
            Danger       = 'brightred'
            Accent       = 'brightmagenta'
            Selected     = 'cyan'
        }
        monochrome = @{
            Description  = 'White and gray only — no hue'
            Primary      = 'white'
            PrimaryMuted = 'darkgray'
            Text         = 'brightwhite'
            Muted        = 'darkgray'
            Success      = 'white'
            Warning      = 'darkgray'
            Danger       = 'white'
            Accent       = 'darkgray'
            Selected     = 'darkgray'
        }
    }

    # Webhooks — named URLs; reference via TimerDefaults.Webhook or  t 25m -Webhook discord-main
    # Discord and ntfy.sh work out of the box; payload is { "content": "..." }.
    Webhooks = @{
        # 'discord-main' = 'https://discord.com/api/webhooks/...'
        # 'ntfy-phone'   = 'https://ntfy.sh/my-topic'
    }

    # Presets — sequence patterns by name (t pomodoro, tpre)
    Presets = @{
        'pomodoro' = @{
            Pattern     = "(25m work, 5m rest)x4, 20m 'long break'"
            Description = 'Classic Pomodoro: 4 cycles of 25m work + 5m rest, then 20m break'
        }
        'pomodoro-short' = @{
            Pattern     = '(25m work, 5m rest)x2'
            Description = 'Quick Pomodoro: 2 cycles of 25m work + 5m rest'
        }
        'pomodoro-long' = @{
            Pattern     = "(50m focus, 10m break)x3, 30m 'long break'"
            Description = 'Extended focus: 3 cycles of 50m work + 10m rest, then 30m break'
        }
        '52-17' = @{
            Pattern     = '(52m focus, 17m break)x3'
            Description = 'Science-backed: 52m focus + 17m break ratio'
        }
        '90-20' = @{
            Pattern     = '(90m deep, 20m rest)x2'
            Description = 'Ultradian rhythm: 90m deep work + 20m rest'
        }
        'micro-pomodoro' = @{
            Pattern     = '(15m work, 3m rest)x4'
            Description = 'Short focus blocks for low-energy days'
        }
        'eye-20-20-20' = @{
            Pattern     = "(20m screen, 20s 'eye break')x4"
            Description = '20-20-20 rule: look away every 20 minutes'
        }
        'standup' = @{
            Pattern     = "15m 'standup prep'"
            Description = 'Meeting buffer before standup or call'
        }
        'deep-focus-3h' = @{
            Pattern     = '(50m focus, 10m break)x3'
            Description = 'Three deep-focus blocks (~3 hours total)'
        }
        'power-nap' = @{
            Pattern     = "20m 'power nap'"
            Description = 'Short restorative nap timer'
        }
        'meditation' = @{
            Pattern     = '10m meditation'
            Description = 'Mindfulness or breathing session'
        }
        'tabata' = @{
            Pattern     = '(20s work, 10s rest)x8'
            Visual      = 'none'
            Sound       = $true
            Description = 'Tabata HIIT interval (4 minutes)'
        }
        'cooking-pasta' = @{
            Pattern     = '10m boil, 2m rest'
            Description = 'Pasta boil then brief rest before drain'
        }
        'cooking-rice' = @{
            Pattern     = '18m simmer'
            Description = 'White rice simmer timer'
        }
        'lecture' = @{
            Pattern     = '45m lecture, 15m break'
            Description = 'Study session with break'
        }
        'gym-sets' = @{
            Pattern     = '(3m set, 90s rest)x5'
            Description = 'Weight training sets with rest'
        }
        'two-minute' = @{
            Pattern     = "2m 'quick task'"
            Description = 'GTD two-minute rule starter'
        }
        'flowtime' = @{
            Pattern     = '(45m focus, 15m break)x4'
            Description = 'Flexible deep work rhythm'
        }
        'ultradian' = @{
            Pattern     = '(90m focus, 20m break)x2'
            Description = 'Natural ultradian work cycles'
        }
    }
}
