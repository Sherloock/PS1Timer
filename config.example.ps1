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

$global:Config = @{
    # TimerDefaults — applied to every new timer unless overridden per command
    TimerDefaults = @{
        # Notification: popup | toast | sound | silent
        Notify = 'popup'

        # Optional .wav for sound mode (null = console beep)
        SoundFile = $null

        # After start: none | watch | list
        #   none  — show confirmation only (default)
        #   watch — open tw for the new timer
        #   list  — open tl -w (live list of all timers)
        AfterStart = 'none'

        # Skip "PS1Timer loaded" message on import (faster profile load)
        QuietLoad = $false
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
