# CmdPal Screenshot Automation

Automate repeatable screenshots for Microsoft PowerToys Command Palette extension states.

The script can:

- Open Command Palette with a configurable hotkey.
- Type a configured query.
- Send follow-up key presses like `Enter`, `Down`, or `Esc`.
- Temporarily set a per-screenshot Windows desktop gradient background.
- Capture the Command Palette window with configurable real desktop padding.
- Restore the original desktop wallpaper when finished.
- Optionally minimize existing windows before capture and restore them when done.

## Requirements

- Windows 10/11
- PowerShell 7+
- Microsoft PowerToys Command Palette enabled

## Quick start

```powershell
pwsh ./Invoke-CmdPalScreenshots.ps1 -Config ./examples/cmdpal-screenshots.example.json
```

Validate without sending keys, changing wallpaper, or taking screenshots:

```powershell
pwsh ./Invoke-CmdPalScreenshots.ps1 -Config ./examples/cmdpal-screenshots.example.json -DryRun
```

## Configuration

Create a JSON file like this:

```json
{
  "outputDir": "screenshots",
  "openHotkey": "Win+Alt+Space",
  "initialDelayMs": 900,
  "settleDelayMs": 500,
  "cases": [
    {
      "name": "tableplus-connections",
      "query": "TablePlus",
      "keys": ["Enter"],
      "gradientStart": "#FFAF40",
      "gradientEnd": "#FF5F6D",
      "gradientAngle": 135
    }
  ]
}
```

Each case supports:

- `name` — output file name without extension.
- `query` — text to paste into Command Palette.
- `keys` — optional key chords or key objects to send after the query.
- `paddingPx` — optional per-case screenshot padding override.
- `gradientStart`, `gradientEnd`, `gradientAngle` — optional per-case desktop gradient override.

Object key steps are also supported:

```json
"keys": [
  "Enter",
  { "delayMs": 1000 },
  { "text": "kitchen" },
  "Down"
]
```

## Common options

Use a different CmdPal hotkey:

```powershell
pwsh ./Invoke-CmdPalScreenshots.ps1 -OpenHotkey Alt+Space
```

Change padding:

```powershell
pwsh ./Invoke-CmdPalScreenshots.ps1 -PaddingPx 100
```

Skip changing your real desktop wallpaper:

```powershell
pwsh ./Invoke-CmdPalScreenshots.ps1 -NoSetDesktopBackground
```

Minimize all existing windows before taking screenshots and restore them when the script finishes or fails:

```powershell
pwsh ./Invoke-CmdPalScreenshots.ps1 -MinimizeWindows
```

Capture the full desktop instead of the foreground window region:

```powershell
pwsh ./Invoke-CmdPalScreenshots.ps1 -CaptureDesktop
```

## Notes

The script sends real keyboard input and temporarily changes your wallpaper by default. It restores the original wallpaper in a `finally` block, but use `-DryRun` first when editing configs.
