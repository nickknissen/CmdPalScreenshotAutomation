<#
.SYNOPSIS
Automates PowerToys Command Palette screenshot capture for configured UI states.

.EXAMPLE
pwsh ./scripts/Invoke-CmdPalScreenshots.ps1

.EXAMPLE
pwsh ./scripts/Invoke-CmdPalScreenshots.ps1 -Config ./scripts/cmdpal-screenshots.json -OpenHotkey Alt+Space -OutputDir ./docs/screenshots
#>
[CmdletBinding()]
param(
    [string]$Config = (Join-Path $PSScriptRoot 'cmdpal-screenshots.json'),
    [string]$OutputDir,
    [string]$OpenHotkey,
    [int]$InitialDelayMs,
    [int]$SettleDelayMs,
    [int]$PaddingPx = 50,
    [string]$GradientStart = '#0F172A',
    [string]$GradientEnd = '#7C3AED',
    [float]$GradientAngle = 135,
    [switch]$CaptureDesktop,
    [switch]$NoSetDesktopBackground,
    [switch]$MinimizeWindows,
    [switch]$NoClearBetweenCases,
    [switch]$DryRun
)

$script:CmdPalScreenshotDryRun = $DryRun.IsPresent

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$nativeCode = @'
using System;
using System.Runtime.InteropServices;

public static class CmdPalScreenshotNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    [DllImport("user32.dll")]
    public static extern uint MapVirtualKey(uint uCode, uint uMapType);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, string pvParam, uint fWinIni);
}
'@
Add-Type -TypeDefinition $nativeCode

$VirtualKeys = @{
    Ctrl = 0x11; Control = 0x11; Alt = 0x12; Shift = 0x10; Win = 0x5B; Windows = 0x5B
    Space = 0x20; Enter = 0x0D; Esc = 0x1B; Escape = 0x1B; Tab = 0x09; Backspace = 0x08; Delete = 0x2E
    Up = 0x26; Down = 0x28; Left = 0x25; Right = 0x27; Home = 0x24; End = 0x23
    A = 0x41; C = 0x43; V = 0x56; X = 0x58
}

function Get-VirtualKey([string]$Key) {
    if ($VirtualKeys.ContainsKey($Key)) { return [byte]$VirtualKeys[$Key] }
    if ($Key.Length -eq 1) { return [byte][char]$Key.ToUpperInvariant() }
    throw "Unsupported key '$Key'. Add it to `$VirtualKeys in $PSCommandPath."
}

function Send-KeyDown([byte]$Vk) {
    [CmdPalScreenshotNative]::keybd_event($Vk, [byte][CmdPalScreenshotNative]::MapVirtualKey($Vk, 0), 0, [UIntPtr]::Zero)
}

function Send-KeyUp([byte]$Vk) {
    [CmdPalScreenshotNative]::keybd_event($Vk, [byte][CmdPalScreenshotNative]::MapVirtualKey($Vk, 0), 2, [UIntPtr]::Zero)
}

function Send-KeyChord([string]$Chord) {
    if ($script:CmdPalScreenshotDryRun) { Write-Verbose "DRY RUN key chord: $Chord"; return }

    $parts = @($Chord -split '\+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($parts.Count -eq 0) { return }

    $keys = @($parts | ForEach-Object { Get-VirtualKey $_ })
    foreach ($key in $keys) { Send-KeyDown $key; Start-Sleep -Milliseconds 35 }
    [array]::Reverse($keys)
    foreach ($key in $keys) { Send-KeyUp $key; Start-Sleep -Milliseconds 35 }
}

function Send-Text([string]$Text) {
    if ($script:CmdPalScreenshotDryRun) { Write-Verbose "DRY RUN text: $Text"; return }

    $oldClipboard = $null
    $hadClipboard = $false
    try {
        try {
            $oldClipboard = [System.Windows.Forms.Clipboard]::GetText()
            $hadClipboard = $true
        } catch { }
        [System.Windows.Forms.Clipboard]::SetText($Text)
        Send-KeyChord 'Ctrl+V'
    } finally {
        if ($hadClipboard) {
            Start-Sleep -Milliseconds 100
            try { [System.Windows.Forms.Clipboard]::SetText($oldClipboard) } catch { }
        }
    }
}

function Get-DrawingColor([string]$Value) {
    try {
        return [System.Drawing.ColorTranslator]::FromHtml($Value)
    } catch {
        throw "Invalid color '$Value'. Use a named color or hex value like #0F172A."
    }
}

function New-GradientWallpaper([string]$Path, [string]$StartColor, [string]$EndColor, [float]$Angle) {
    if ($script:CmdPalScreenshotDryRun) { Write-Verbose "DRY RUN wallpaper: $Path"; return }

    $screenBounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bitmap = New-Object System.Drawing.Bitmap($screenBounds.Width, $screenBounds.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $brush = $null
    try {
        $start = Get-DrawingColor $StartColor
        $end = Get-DrawingColor $EndColor
        $bounds = New-Object System.Drawing.RectangleF(0, 0, $screenBounds.Width, $screenBounds.Height)
        $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($bounds, $start, $end, $Angle)
        $graphics.FillRectangle($brush, 0, 0, $screenBounds.Width, $screenBounds.Height)
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Bmp)
    } finally {
        if ($brush) { $brush.Dispose() }
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Set-DesktopWallpaper([string]$Path) {
    if ($script:CmdPalScreenshotDryRun) { Write-Verbose "DRY RUN set desktop wallpaper: $Path"; return }

    $SPI_SETDESKWALLPAPER = 0x0014
    $SPIF_UPDATEINIFILE = 0x0001
    $SPIF_SENDCHANGE = 0x0002
    $ok = [CmdPalScreenshotNative]::SystemParametersInfo($SPI_SETDESKWALLPAPER, 0, $Path, ($SPIF_UPDATEINIFILE -bor $SPIF_SENDCHANGE))
    if (-not $ok) { throw "Failed to set desktop wallpaper to '$Path'." }
}

function Invoke-MinimizeAllWindows {
    if ($script:CmdPalScreenshotDryRun) { Write-Verbose 'DRY RUN minimize all windows'; return }

    $shell = New-Object -ComObject Shell.Application
    $shell.MinimizeAll()
}

function Invoke-RestoreMinimizedWindows {
    if ($script:CmdPalScreenshotDryRun) { Write-Verbose 'DRY RUN restore minimized windows'; return }

    $shell = New-Object -ComObject Shell.Application
    $shell.UndoMinimizeALL()
}

function Capture-WindowOrDesktop(
    [string]$Path,
    [switch]$Desktop,
    [int]$Padding = 0,
    [string]$StartColor = '#0F172A',
    [string]$EndColor = '#7C3AED',
    [float]$Angle = 135
) {
    if ($script:CmdPalScreenshotDryRun) { Write-Verbose "DRY RUN capture: $Path"; return }

    $screenBounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds

    if ($Desktop) {
        $x = $screenBounds.X; $y = $screenBounds.Y; $width = $screenBounds.Width; $height = $screenBounds.Height

        $bitmap = New-Object System.Drawing.Bitmap($width, $height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.CopyFromScreen($x, $y, 0, 0, $bitmap.Size)
            $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        } finally {
            $graphics.Dispose()
            $bitmap.Dispose()
        }
        return
    }

    $handle = [CmdPalScreenshotNative]::GetForegroundWindow()
    if ($handle -eq [IntPtr]::Zero) { throw 'No foreground window found.' }
    $rect = New-Object CmdPalScreenshotNative+RECT
    if (-not [CmdPalScreenshotNative]::GetWindowRect($handle, [ref]$rect)) { throw 'Could not read foreground window bounds.' }

    $left = [Math]::Max($screenBounds.Left, $rect.Left - $Padding)
    $top = [Math]::Max($screenBounds.Top, $rect.Top - $Padding)
    $right = [Math]::Min($screenBounds.Right, $rect.Right + $Padding)
    $bottom = [Math]::Min($screenBounds.Bottom, $rect.Bottom + $Padding)

    $x = $left; $y = $top; $width = $right - $left; $height = $bottom - $top
    if ($width -le 0 -or $height -le 0) { throw "Invalid foreground window bounds: $width x $height." }

    $bitmap = New-Object System.Drawing.Bitmap($width, $height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($x, $y, 0, 0, $bitmap.Size)
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Get-OptionalProperty([object]$Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Invoke-ConfiguredKey([object]$KeySpec) {
    if ($KeySpec -is [string]) {
        Send-KeyChord $KeySpec
        return
    }

    $text = Get-OptionalProperty $KeySpec 'text'
    $key = Get-OptionalProperty $KeySpec 'key'
    $delayMs = Get-OptionalProperty $KeySpec 'delayMs'

    if ($text) {
        Send-Text ([string]$text)
    }
    if ($key) {
        Send-KeyChord ([string]$key)
    }
    if ($delayMs) {
        Start-Sleep -Milliseconds ([int]$delayMs)
    }
}

$configPath = Resolve-Path $Config
$configJson = Get-Content $configPath -Raw | ConvertFrom-Json

if (-not $OutputDir) { $OutputDir = Get-OptionalProperty $configJson 'outputDir' }
if (-not $OutputDir) { $OutputDir = Join-Path (Split-Path $configPath -Parent) 'screenshots' }
if (-not [System.IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir = Join-Path (Get-Location) $OutputDir
}

$configuredOpenHotkey = Get-OptionalProperty $configJson 'openHotkey'
$configuredInitialDelayMs = Get-OptionalProperty $configJson 'initialDelayMs'
$configuredSettleDelayMs = Get-OptionalProperty $configJson 'settleDelayMs'

if (-not $OpenHotkey) { $OpenHotkey = if ($configuredOpenHotkey) { $configuredOpenHotkey } else { 'Win+Alt+Space' } }
if (-not $PSBoundParameters.ContainsKey('InitialDelayMs')) { $InitialDelayMs = if ($configuredInitialDelayMs) { [int]$configuredInitialDelayMs } else { 900 } }
if (-not $PSBoundParameters.ContainsKey('SettleDelayMs')) { $SettleDelayMs = if ($configuredSettleDelayMs) { [int]$configuredSettleDelayMs } else { 500 } }

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$cases = @(Get-OptionalProperty $configJson 'cases')
Write-Host "Capturing $($cases.Count) Command Palette states to $OutputDir"
Write-Host "Open hotkey: $OpenHotkey"
Write-Host "Screenshot padding: $PaddingPx px"
if (-not $CaptureDesktop) { Write-Host "Gradient background: $GradientStart -> $GradientEnd ($GradientAngle°)" }
if (-not $NoSetDesktopBackground) { Write-Host 'Desktop wallpaper will be changed per case and restored at the end.' }
if ($MinimizeWindows) { Write-Host 'Open windows will be minimized before capture and restored at the end.' }
if ($DryRun) { Write-Host 'Dry run: no keys will be sent and no screenshots will be captured.' }

$windowsMinimized = $false
$originalWallpaper = $null
$restoreWallpaper = $false
$tempWallpaperDir = Join-Path ([System.IO.Path]::GetTempPath()) ('cmdpal-screenshots-' + [Guid]::NewGuid().ToString('N'))
if (-not $NoSetDesktopBackground) {
    $originalWallpaper = [string]((Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallPaper -ErrorAction SilentlyContinue).WallPaper)
    $restoreWallpaper = $true
    New-Item -ItemType Directory -Force -Path $tempWallpaperDir | Out-Null
}

try {
if ($MinimizeWindows) {
    Invoke-MinimizeAllWindows
    $windowsMinimized = $true
    Start-Sleep -Milliseconds 500
}

foreach ($case in $cases) {
    $name = [string](Get-OptionalProperty $case 'name')
    if (-not $name) { throw 'Each case requires a name.' }

    $casePadding = Get-OptionalProperty $case 'paddingPx'
    $caseGradientStart = Get-OptionalProperty $case 'gradientStart'
    $caseGradientEnd = Get-OptionalProperty $case 'gradientEnd'
    $caseGradientAngle = Get-OptionalProperty $case 'gradientAngle'

    if ($null -eq $casePadding) { $casePadding = $PaddingPx }
    if (-not $caseGradientStart) { $caseGradientStart = $GradientStart }
    if (-not $caseGradientEnd) { $caseGradientEnd = $GradientEnd }
    if ($null -eq $caseGradientAngle) { $caseGradientAngle = $GradientAngle }

    Write-Host "- $name"

    if (-not $NoSetDesktopBackground) {
        $wallpaperPath = Join-Path $tempWallpaperDir ($name + '.bmp')
        New-GradientWallpaper -Path $wallpaperPath -StartColor ([string]$caseGradientStart) -EndColor ([string]$caseGradientEnd) -Angle ([float]$caseGradientAngle)
        Set-DesktopWallpaper -Path $wallpaperPath
        Start-Sleep -Milliseconds 300
    }

    Send-KeyChord $OpenHotkey
    Start-Sleep -Milliseconds $InitialDelayMs

    if (-not $NoClearBetweenCases) {
        Send-KeyChord 'Ctrl+A'
        Start-Sleep -Milliseconds 100
        Send-KeyChord 'Backspace'
        Start-Sleep -Milliseconds 100
    }

    $query = Get-OptionalProperty $case 'query'
    if ($query) {
        Send-Text ([string]$query)
        Start-Sleep -Milliseconds $SettleDelayMs
    }

    $keys = Get-OptionalProperty $case 'keys'
    if ($keys) {
        foreach ($key in @($keys)) {
            Invoke-ConfiguredKey $key
            Start-Sleep -Milliseconds $SettleDelayMs
        }
    }

    $file = Join-Path $OutputDir ($name + '.png')
    Start-Sleep -Milliseconds $SettleDelayMs
    Capture-WindowOrDesktop -Path $file -Desktop:$CaptureDesktop -Padding ([int]$casePadding) -StartColor ([string]$caseGradientStart) -EndColor ([string]$caseGradientEnd) -Angle ([float]$caseGradientAngle)
    Write-Host "  wrote $file"

    Send-KeyChord 'Esc'
    Start-Sleep -Milliseconds 200
    Send-KeyChord 'Esc'
    Start-Sleep -Milliseconds 200
}
} finally {
    if (-not $NoSetDesktopBackground) {
        if ($restoreWallpaper) {
            Set-DesktopWallpaper -Path $originalWallpaper
        }
        if (Test-Path $tempWallpaperDir) {
            Remove-Item -Recurse -Force $tempWallpaperDir -ErrorAction SilentlyContinue
        }
    }

    if ($windowsMinimized) {
        Invoke-RestoreMinimizedWindows
    }
}

Write-Host 'Done.'
