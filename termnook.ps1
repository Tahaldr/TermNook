# TermNook: an app launcher, dashboard and project picker for PowerShell 7.
# https://github.com/Tahaldr/TermNook
# This file is the program. Your settings live in config.psd1 next to it
# (made from config.example.psd1 the first time); updates never touch them.
# Load it from your profile:   . "$HOME\.termnook\termnook.ps1"
# Then run:                    nook --help

$script:NookVersion   = '1.3.2'
$script:NookRepo      = 'Tahaldr/TermNook'   # where releases are published
$script:NookDir       = $PSScriptRoot
$script:NookStateFile = Join-Path $PSScriptRoot 'style.txt'
$script:NookStyles    = [ordered]@{ cards = 'Card row'; info = 'Info panel'; palette = 'Command palette'; list = 'Classic list' }
$script:NookReserved  = @('t', 'q', 'o', 'x')
$script:NookCache     = $null

$script:NookDefaults = @{
    Style  = 'cards'
    Logo   = 'logo.txt'
    GitHub = ''
    Theme  = [ordered]@{
        GradFrom = '#61afef'; GradTo = '#c678dd'; Accent = '#61afef'; Text = '#abb2bf'
        Muted = '#565c64'; SelBg = '#3e4451'; SelHint = '#818792'; Hot = '#e7c787'
    }
    Apps   = @(@{ Name = 'Shell'; Hint = 'prompt'; Key = 's' })
    Projects = @{ Roots = @(); OpenWith = @() }
}

# ===========================================================================
# Helpers
# ===========================================================================

function NookRgb([string]$hex) {
    @([Convert]::ToInt32($hex.Substring(1,2),16), [Convert]::ToInt32($hex.Substring(3,2),16), [Convert]::ToInt32($hex.Substring(5,2),16))
}

function NookEsc([string]$hex, [switch]$Bg) {
    $p = NookRgb $hex; $layer = if ($Bg) { 48 } else { 38 }
    "$([char]27)[$layer;2;$($p[0]);$($p[1]);$($p[2])m"
}

# Visible width in terminal cells (ignores color codes and links; a Nerd Font icon counts as 1)
function NookWidth([string]$s) {
    $plain = $s -replace '\e\[[0-9;?]*[A-Za-z]', '' -replace '\e\]8;;[^\e]*\e\\', ''
    [Globalization.StringInfo]::new($plain).LengthInTextElements
}

# Left/right padding that centers $len cells inside $w cells
function NookPad([int]$len, [int]$w) {
    $l = [int][Math]::Floor([Math]::Max(0, $w - $len) / 2)
    @((' ' * $l), (' ' * [Math]::Max(0, $w - $len - $l)))
}

# Pad a line on the right to exactly $w visible cells
function NookFit([string]$s, [int]$w) { $s + (' ' * [Math]::Max(0, $w - (NookWidth $s))) }

# Center a group of lines as one block (they keep their alignment to each other)
function NookBlock([string[]]$lines, [int]$W) {
    $bw = 0; foreach ($l in $lines) { $bw = [Math]::Max($bw, (NookWidth $l)) }
    $pad = ' ' * [Math]::Max(0, [int][Math]::Floor(($W - $bw) / 2))
    foreach ($l in $lines) { $pad + $l }
}

function NookMTime([string]$path) {
    if ($path -and (Test-Path -LiteralPath $path)) { (Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks } else { 0 }
}

function NookCursor([bool]$visible) { try { [Console]::CursorVisible = $visible } catch {} }

# ===========================================================================
# Config: read config.psd1, fill in defaults, check for mistakes.
# Cached, and re-read automatically when config.psd1 or the logo changes.
# ===========================================================================

function NookLoad([switch]$Force) {
    NookCheckUpdateStart
    $cfgPath = Join-Path $script:NookDir 'config.psd1'
    if (-not (Test-Path -LiteralPath $cfgPath)) {
        $example = Join-Path $script:NookDir 'config.example.psd1'
        if (Test-Path -LiteralPath $example) { Copy-Item -LiteralPath $example $cfgPath }
    }
    $c = $script:NookCache
    if (-not $Force -and $c -and $c.CfgTime -eq (NookMTime $cfgPath) -and $c.LogoTime -eq (NookMTime $c.LogoPath)) { return $c }

    $warn = [System.Collections.Generic.List[string]]::new()
    $raw = @{}
    if (Test-Path -LiteralPath $cfgPath) {
        try { $raw = Import-PowerShellDataFile -LiteralPath $cfgPath -ErrorAction Stop }
        catch { $warn.Add("config.psd1 could not be read: $($_.Exception.Message)") }
    }
    $D = $script:NookDefaults

    # colors
    $theme = @{}
    foreach ($k in $D.Theme.Keys) {
        $v = if ($raw.Theme) { $raw.Theme[$k] } else { $null }
        if ($v -and $v -notmatch '^#[0-9a-fA-F]{6}$') { $warn.Add("Theme.$k '$v' is not a #rrggbb color"); $v = $null }
        $theme[$k] = if ($v) { $v } else { $D.Theme[$k] }
    }
    $e = [char]27
    $K = @{
        Acc = NookEsc $theme.Accent; Txt = NookEsc $theme.Text; Mut = NookEsc $theme.Muted
        SelBg = NookEsc $theme.SelBg -Bg; Bdr = NookEsc $theme.SelBg; SelHint = NookEsc $theme.SelHint
        Kw = NookEsc $theme.GradTo; Hot = NookEsc $theme.Hot; Err = NookEsc '#e06c75'
        R = "$e[0m"; B = "$e[1m"; NB = "$e[22m"; U = "$e[4m"; NU = "$e[24m"
    }

    # style
    $style = if ($raw.Style) { [string]$raw.Style } else { $D.Style }
    if (-not $script:NookStyles.Contains($style)) { $warn.Add("Style '$style' is unknown, using cards"); $style = 'cards' }

    # apps
    $apps = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    $src = if ($raw.Apps) { @($raw.Apps) } else { $D.Apps }
    foreach ($a in $src) {
        if (-not ($a -is [hashtable]) -or -not $a.Name) { $warn.Add('an app without a Name was skipped'); continue }
        $key = if ($a.Key) { ([string]$a.Key).ToLower() } else { '' }
        if ($key.Length -gt 1) { $warn.Add("$($a.Name): Key must be one letter"); $key = '' }
        elseif ($key -and $script:NookReserved -contains $key) { $warn.Add("$($a.Name): key '$key' is used by TermNook itself"); $key = '' }
        elseif ($key -and $seen.ContainsKey($key)) { $warn.Add("$($a.Name): key '$key' is already used by $($seen[$key])"); $key = '' }
        if ($key) { $seen[$key] = $a.Name }
        $icon = ''
        if ($a.Icon) {
            try {
                $cp = if ($a.Icon -is [string]) { [Convert]::ToInt32(($a.Icon -replace '^0x', ''), 16) } else { [int]$a.Icon }
                $icon = [char]::ConvertFromUtf32($cp)
            } catch { $warn.Add("$($a.Name): Icon '$($a.Icon)' is not a valid code") }
        }
        $apps.Add([pscustomobject]@{
            Name = [string]$a.Name; Hint = [string]$a.Hint; Key = $key; Icon = $icon
            Run = if ($a.Run) { [string]$a.Run } else { '' }
        })
    }
    if (-not $apps.Count) { $warn.Add('no apps configured'); $apps.Add([pscustomobject]@{ Name = 'Shell'; Hint = 'prompt'; Key = 's'; Icon = ''; Run = '' }) }

    # projects
    $pr = if ($raw.Projects -is [hashtable]) { $raw.Projects } else { $D.Projects }
    $roots = [System.Collections.Generic.List[string]]::new()
    foreach ($r in @($pr.Roots)) {
        if (-not $r) { continue }
        $p = ([string]$r) -replace '^~', $HOME
        if ([IO.Directory]::Exists($p)) { $roots.Add($p) }   # folders that don't exist (yet) are skipped
    }
    $openWith = [System.Collections.Generic.List[object]]::new()
    foreach ($nm in @($pr.OpenWith)) {
        if (-not $nm) { continue }
        $hit = $apps | Where-Object Name -eq $nm | Select-Object -First 1
        if (-not $hit -and $nm -eq 'Shell') {   # built in: just go to the folder
            $hit = [pscustomobject]@{ Name = 'Shell'; Hint = 'prompt'; Key = 's'; Icon = [char]::ConvertFromUtf32(0xEBC7); Run = '' }
        }
        if ($hit) { $openWith.Add($hit) } else { $warn.Add("Projects.OpenWith: no app named '$nm'") }
    }
    if (-not $openWith.Count) { foreach ($a in $apps) { if ($a.Run -match '(^|\s)\.$') { $openWith.Add($a) } } }
    $search = if ($pr.Search) { ([string]$pr.Search) -replace '^~', $HOME } else { $HOME }
    if (-not [IO.Directory]::Exists($search)) { $warn.Add("Projects.Search '$($pr.Search)' not found"); $search = $HOME }
    $search = $search.TrimEnd('\')
    $skip = if ($null -ne $pr.Skip) { @($pr.Skip | ForEach-Object { [string]$_ }) } else { @('AppData', 'node_modules', 'scoop', 'vendor') }

    # logo with a two-tone gradient
    $logoName = if ($null -ne $raw.Logo) { [string]$raw.Logo } else { $D.Logo }
    $logoPath = if ($logoName) { Join-Path $script:NookDir $logoName } else { '' }
    $logo = [System.Collections.Generic.List[string]]::new(); $logoW = 0
    if ($logoPath -and (Test-Path -LiteralPath $logoPath)) {
        $lines = @([IO.File]::ReadAllLines($logoPath) | ForEach-Object { $_.TrimEnd() })
        while ($lines.Count -and -not $lines[-1]) { $lines = @($lines | Select-Object -SkipLast 1) }
        $from = NookRgb $theme.GradFrom; $to = NookRgb $theme.GradTo; $n = $lines.Count
        for ($i = 0; $i -lt $n; $i++) {
            $f = if ($n -le 1) { 0 } else { $i / ($n - 1) }
            $rgb = 0..2 | ForEach-Object { [int]($from[$_] + ($to[$_] - $from[$_]) * $f) }
            $logo.Add("$e[38;2;$($rgb[0]);$($rgb[1]);$($rgb[2])m$($lines[$i])$($K.R)")
            $logoW = [Math]::Max($logoW, (NookWidth $lines[$i]))
        }
    } elseif ($logoName) { $warn.Add("logo file '$logoName' not found") }

    $script:NookCache = [pscustomobject]@{
        CfgTime = NookMTime $cfgPath; LogoPath = $logoPath; LogoTime = NookMTime $logoPath
        K = $K; Style = $style; GitHub = [string]$raw.GitHub; Apps = $apps.ToArray()
        Recent = if ($null -ne $raw.Recent) { [bool]$raw.Recent } else { $true }
        Hints = if ($null -ne $raw.Hints) { [bool]$raw.Hints } else { $true }
        Prayer = if ($raw.Prayer -and $raw.Prayer.City) { [pscustomobject]@{ City = [string]$raw.Prayer.City; Country = [string]$raw.Prayer.Country; Method = $(if ($null -ne $raw.Prayer.Method) { [int]$raw.Prayer.Method } else { 3 }) } } else { $null }
        Logo = $logo.ToArray(); LogoW = $logoW; Warnings = $warn.ToArray()
        Projects = [pscustomobject]@{ Roots = $roots.ToArray(); OpenWith = $openWith.ToArray(); Search = $search; Skip = $skip }
    }
    $script:NookCache
}

function NookSavedStyle($C) {
    if (Test-Path -LiteralPath $script:NookStateFile) {
        $v = (Get-Content -LiteralPath $script:NookStateFile -TotalCount 1).Trim()
        if ($script:NookStyles.Contains($v)) { return $v }
    }
    $C.Style
}

# --- key hints: full hint lines, or only the hard-to-remember keys (toggled with h on the ? page) ---
# hints.txt holds 'on' / 'off' once toggled; it wins over Hints in config.psd1
$script:NookHintsFile = Join-Path $PSScriptRoot 'hints.txt'

function NookHintsOn($C) {
    try {
        if (Test-Path -LiteralPath $script:NookHintsFile) {
            $v = (Get-Content -LiteralPath $script:NookHintsFile -TotalCount 1).Trim()
            if ($v -eq 'on') { return $true } elseif ($v -eq 'off') { return $false }
        }
    } catch {}
    $C.Hints
}
function NookSetHints([bool]$on) {
    try { Set-Content -LiteralPath $script:NookHintsFile -Value $(if ($on) { 'on' } else { 'off' }) -Encoding utf8 } catch {}
}

# --- recent apps: recent.txt holds app names, last used first ---
$script:NookRecentFile = Join-Path $PSScriptRoot 'recent.txt'

function NookRemember([string]$name) {
    if (-not $name) { return }
    try {
        $old = if (Test-Path -LiteralPath $script:NookRecentFile) { @(Get-Content -LiteralPath $script:NookRecentFile) } else { @() }
        $new = @($name) + @($old | Where-Object { $_ -and $_ -ne $name }) | Select-Object -First 20
        Set-Content -LiteralPath $script:NookRecentFile -Value $new -Encoding utf8
    } catch {}
}

# The config with its apps ordered by last use (apps never used keep their config order,
# "back to the prompt" items stay last). Unchanged when Recent = $false.
function NookWithRecent($C) {
    if (-not $C.Recent -or -not (Test-Path -LiteralPath $script:NookRecentFile)) { return $C }
    $order = @(Get-Content -LiteralPath $script:NookRecentFile)
    $i = 0
    $ranked = foreach ($a in $C.Apps) {
        $r = [array]::IndexOf($order, $a.Name); if ($r -lt 0) { $r = 1000 }
        if (-not $a.Run) { $r = 2000 }
        [pscustomobject]@{ App = $a; Rank = $r; Pos = $i++ }
    }
    $copy = $C.PSObject.Copy()
    $copy.Apps = @($ranked | Sort-Object Rank, Pos | ForEach-Object App)
    $copy
}

# Run an app's command. Call it as a plain statement, never inside if (...) or $x = ...:
# capturing its output would cut apps like nvim off from the screen.
function NookRun($app) {
    NookRemember $app.Name
    NookCursor $true
    Clear-Host
    try { & ([scriptblock]::Create($app.Run)) }
    catch {
        Write-Host "nook: $($app.Name) failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'press any key to go back' -ForegroundColor DarkGray
        [void][Console]::ReadKey($true)
    }
}

# Current git branch, read from .git/HEAD (no git process, so it's instant)
function NookGitBranch {
    try {
        $d = (Get-Location).ProviderPath
        while ($d) {
            $h = Join-Path $d '.git\HEAD'
            if (Test-Path -LiteralPath $h) {
                $ref = Get-Content -LiteralPath $h -TotalCount 1
                if ($ref -match 'ref: refs/heads/(.+)') { return $Matches[1] }
                return $ref.Substring(0, [Math]::Min(7, $ref.Length))
            }
            $d = Split-Path $d -Parent
        }
    } catch {}
    $null
}

# Palette search: indexes of apps whose name or hint contains the filter, best name match first
function NookMatch($apps, [string]$filter) {
    $f = $filter.ToLower()
    $hits = for ($i = 0; $i -lt $apps.Count; $i++) {
        $a = $apps[$i]
        if (-not $f -or "$($a.Name) $($a.Hint)".ToLower().Contains($f)) {
            $pos = $a.Name.ToLower().IndexOf($f); if ($pos -lt 0) { $pos = 99 }
            [pscustomobject]@{ I = $i; Pos = $pos }
        }
    }
    @($hits | Sort-Object Pos, I | ForEach-Object I)
}

function NookMaxLen($apps, [string]$prop) {
    $m = 0; foreach ($a in $apps) { $m = [Math]::Max($m, $a.$prop.Length) }; $m
}

# ===========================================================================
# Projects: folders you visit often (zoxide) first, then projects found under Projects.Roots
# ===========================================================================

$script:NookProjectMarkers = @('.git', 'package.json', 'composer.json', 'go.mod', 'Cargo.toml', 'pyproject.toml', 'requirements.txt', 'pubspec.yaml')

# A folder counts as a project when it holds one of the markers; the search doesn't go inside projects
function NookScanProjects([string]$dir, [int]$depth, $out) {
    foreach ($m in $script:NookProjectMarkers) {
        $p = Join-Path $dir $m
        if ([IO.Directory]::Exists($p) -or [IO.File]::Exists($p)) { $out.Add($dir); return }
    }
    if ($depth -ge 4) { return }
    try { $subs = [IO.Directory]::GetDirectories($dir) } catch { return }
    foreach ($s in $subs) {
        if ([IO.Path]::GetFileName($s) -match '^(\.|node_modules$|vendor$|dist$|build$|bin$|obj$|target$)') { continue }
        NookScanProjects $s ($depth + 1) $out
    }
}

function NookProjectList($C) {
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $list = [System.Collections.Generic.List[string]]::new()
    if (Get-Command zoxide -ErrorAction SilentlyContinue) {
        foreach ($p in @(zoxide query --list 2>$null)) {
            # skip drive roots and the home folder itself, they are not projects
            if ($p.Length -gt 3 -and $p -ne $HOME -and [IO.Directory]::Exists($p) -and $seen.Add($p)) { $list.Add($p) }
        }
    }
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $C.Projects.Roots) { NookScanProjects $r 0 $found }
    foreach ($p in ($found | Sort-Object)) { if ($seen.Add($p)) { $list.Add($p) } }
    $list.ToArray()
}

# Suggestions for what's typed so far, best first.
#   no \ yet  -> projects whose name starts with (then contains) the text, then folders in Projects.Search
#   with a \  -> entries of that folder starting with the last part (folders first)
# Paths are relative to Projects.Search; ~\ and C:\ style paths work too.
function NookPathCandidates($C, [string]$text, $projects) {
    $base = $C.Projects.Search
    $list = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $add = { param($s) if ($seen.Add($s)) { $list.Add($s) } }
    $t = $text -replace '/', '\'
    $sep = $t.LastIndexOf('\')
    if ($sep -lt 0) {
        foreach ($p in $projects) { if ((Split-Path $p.TrimEnd('\') -Leaf).StartsWith($t, [StringComparison]::OrdinalIgnoreCase)) { & $add $p } }
        if ($t) { foreach ($p in $projects) { if ((Split-Path $p.TrimEnd('\') -Leaf).IndexOf($t, [StringComparison]::OrdinalIgnoreCase) -gt 0) { & $add $p } } }
    }
    $dirPart = if ($sep -ge 0) { $t.Substring(0, $sep + 1) } else { '' }
    $leaf = $t.Substring($sep + 1)
    $dirAbs = if ($dirPart -match '^~') { $HOME + $dirPart.Substring(1) }
              elseif ($dirPart -and [IO.Path]::IsPathRooted($dirPart)) { $dirPart }
              else { Join-Path $base $dirPart }
    if ([IO.Directory]::Exists($dirAbs)) {
        $dirs = @(); $files = @()
        try {
            $dirs = [IO.Directory]::GetDirectories($dirAbs) | ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object
            $files = [IO.Directory]::GetFiles($dirAbs) | ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object
        } catch {}
        # hidden, dot and skipped folders only show once you type the start of their name
        foreach ($n in $dirs) {
            if (-not $leaf -and ($n.StartsWith('.') -or $C.Projects.Skip -contains $n)) { continue }
            if ($n.StartsWith($leaf, [StringComparison]::OrdinalIgnoreCase)) { & $add "$dirPart$n\" }
        }
        foreach ($n in $files) {
            if (-not $leaf -and $n.StartsWith('.')) { continue }
            if ($n.StartsWith($leaf, [StringComparison]::OrdinalIgnoreCase)) { & $add "$dirPart$n" }
        }
    }
    $list.ToArray()
}

function NookResolvePath($C, [string]$p) {
    $p = $p -replace '/', '\'
    if ($p -match '^~') { return $HOME + $p.Substring(1) }
    if ([IO.Path]::IsPathRooted($p)) { return $p }
    Join-Path $C.Projects.Search $p
}

# --- picker helpers ----------------------------------------------------------

# Keyboard + mouse input for the picker. [Console]::ReadKey can't see the mouse, so this reads
# console input records directly (wheel and clicks with their position). Compiled once and cached.
$script:NookInputSrc = @'
using System;
using System.Runtime.InteropServices;
public static class NookInput {
    [StructLayout(LayoutKind.Explicit)] struct REC { [FieldOffset(0)] public ushort Type; [FieldOffset(4)] public KEY Key; [FieldOffset(4)] public MOUSE Mouse; }
    [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)] struct KEY {
        [FieldOffset(0)] public int Down; [FieldOffset(4)] public ushort Repeat; [FieldOffset(6)] public ushort Vk;
        [FieldOffset(8)] public ushort Scan; [FieldOffset(10)] public char Ch; [FieldOffset(12)] public uint State; }
    [StructLayout(LayoutKind.Sequential)] struct MOUSE { public short X; public short Y; public uint Buttons; public uint State; public uint Flags; }
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr h, out uint m);
    [DllImport("kernel32.dll")] static extern bool SetConsoleMode(IntPtr h, uint m);
    [DllImport("kernel32.dll")] static extern bool GetNumberOfConsoleInputEvents(IntPtr h, out uint n);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool ReadConsoleInputW(IntPtr h, [Out] REC[] r, uint len, out uint read);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    static IntPtr h; static uint old;
    public class Ev { public string Kind = "none"; public int Vk; public char Ch; public bool Ctrl, Alt, Shift; public int X, Y, Delta; }
    public static void Start() {
        h = GetStdHandle(-10); GetConsoleMode(h, out old);
        // + mouse input + extended flags, - quick edit (it would eat clicks), - VT input (keys as records)
        SetConsoleMode(h, (old | 0x10 | 0x80) & ~0x40u & ~0x200u);
    }
    public static void Stop() { SetConsoleMode(h, old); }
    public static bool Pending() { uint n; GetNumberOfConsoleInputEvents(h, out n); return n > 0; }
    public static Ev Read(int timeoutMs) {
        var ev = new Ev();
        if (WaitForSingleObject(h, (uint)timeoutMs) != 0 || !Pending()) return ev;
        var r = new REC[1]; uint got;
        if (!ReadConsoleInputW(h, r, 1, out got) || got == 0) return ev;
        if (r[0].Type == 1) {
            var k = r[0].Key;
            if (k.Down == 0 || k.Vk == 0x10 || k.Vk == 0x11 || k.Vk == 0x12) return ev;
            ev.Kind = "key"; ev.Vk = k.Vk; ev.Ch = k.Ch;
            ev.Alt = (k.State & 3) != 0; ev.Ctrl = (k.State & 12) != 0; ev.Shift = (k.State & 0x10) != 0;
        } else if (r[0].Type == 2) {
            var m = r[0].Mouse; ev.X = m.X; ev.Y = m.Y;
            if ((m.Flags & 4) != 0) { ev.Kind = "wheel"; ev.Delta = (short)(m.Buttons >> 16); }
            else if (m.Flags == 0 && (m.Buttons & 1) != 0) { ev.Kind = "click"; }
        }
        return ev;
    }
}
'@

function NookInputLoad {
    if ('NookInput' -as [type]) { return $true }
    try {
        $dir = Join-Path $env:LOCALAPPDATA 'nook'
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([Text.Encoding]::UTF8.GetBytes($script:NookInputSrc))).Substring(0, 10)
        $dll = Join-Path $dir "NookInput-$hash.dll"      # a new file whenever the source above changes
        if (-not (Test-Path -LiteralPath $dll)) {
            New-Item -ItemType Directory -Force $dir | Out-Null
            Add-Type -TypeDefinition $script:NookInputSrc -OutputAssembly $dll -OutputType Library -ErrorAction Stop
        }
        if (-not ('NookInput' -as [type])) { Add-Type -Path $dll -ErrorAction Stop }
        return $true
    } catch { return [bool]('NookInput' -as [type]) }
}

# Cut a line that may hold color codes to $w visible cells, padding with spaces
$script:NookEscRx = [regex]::new('\G\e(\[[0-9;?]*[A-Za-z]|\]8;;[^\e]*\e\\)')
function NookCut([string]$s, [int]$w) {
    $sb = [System.Text.StringBuilder]::new(); $vis = 0; $i = 0
    while ($i -lt $s.Length) {
        $c = $s[$i]
        if ($c -eq [char]27) {
            $m = $script:NookEscRx.Match($s, $i)
            if ($m.Success) { [void]$sb.Append($m.Value); $i += $m.Length; continue }
            $i++; continue
        }
        # drop other control characters: a stray \r (Windows line endings) or \b would move the cursor
        if ($c -lt [char]32 -or $c -eq [char]127) { $i++; continue }
        $len = 1; $cp = [int]$c
        if ([char]::IsHighSurrogate($c) -and $i + 1 -lt $s.Length) { $len = 2; $cp = [char]::ConvertToUtf32($c, $s[$i + 1]) }
        # wide characters (CJK, emoji) take two cells; Nerd Font icons take one
        $cells = if (($cp -ge 0x1100 -and $cp -le 0x115F) -or ($cp -ge 0x2E80 -and $cp -le 0xA4CF) -or ($cp -ge 0xAC00 -and $cp -le 0xD7A3) -or
                     ($cp -ge 0xF900 -and $cp -le 0xFAFF) -or ($cp -ge 0xFE30 -and $cp -le 0xFE4F) -or ($cp -ge 0xFF00 -and $cp -le 0xFF60) -or
                     ($cp -ge 0xFFE0 -and $cp -le 0xFFE6) -or ($cp -ge 0x1F300 -and $cp -le 0x1FAFF) -or ($cp -ge 0x20000 -and $cp -le 0x3FFFD)) { 2 }
                 elseif (($cp -ge 0x300 -and $cp -le 0x36F) -or ($cp -ge 0x200B -and $cp -le 0x200F) -or ($cp -ge 0xFE00 -and $cp -le 0xFE0F)) { 0 }
                 else { 1 }
        if ($vis + $cells -gt $w) { break }
        [void]$sb.Append($s, $i, $len); $i += $len; $vis += $cells
    }
    [void]$sb.Append("$([char]27)[0m")
    if ($vis -lt $w) { [void]$sb.Append(' ' * ($w - $vis)) }
    $sb.ToString()
}

# Preview lines for a folder (its contents) or a file (its text), cached per path
function NookPreview([string]$path, $cache) {
    if ($cache.ContainsKey($path)) { return $cache[$path] }
    $lines = @()
    try {
        if ([IO.Directory]::Exists($path)) {
            if (Get-Command eza -ErrorAction SilentlyContinue) {
                $lines = @(eza -1 --icons=always --color=always --group-directories-first -- $path 2>$null)
            } else {
                $lines = @([IO.Directory]::GetDirectories($path) | ForEach-Object { [IO.Path]::GetFileName($_) + '\' }) +
                         @([IO.Directory]::GetFiles($path) | ForEach-Object { [IO.Path]::GetFileName($_) })
            }
            if (-not $lines.Count) { $lines = @('(empty folder)') }
        } elseif ([IO.File]::Exists($path)) {
            $size = ([IO.FileInfo]$path).Length
            if ($size -gt 2MB) { $lines = @("($([Math]::Round($size / 1MB, 1)) MB, too large to preview)") }
            else {
                # only the first 4 KB tell if it's binary (piping the whole file through Select-Object took seconds)
                $head = [byte[]]::new(4096)
                $fs = [IO.File]::OpenRead($path)
                try { $got = $fs.Read($head, 0, $head.Length) } finally { $fs.Dispose() }
                if ([Array]::IndexOf($head, [byte]0, 0, $got) -ge 0) { $lines = @("(binary file, $([Math]::Round($size / 1KB, 1)) KB)") }
                elseif (Get-Command bat -ErrorAction SilentlyContinue) {
                    $lines = @(bat --color=always --style=numbers --theme=OneHalfDark --paging=never --tabs=4 --line-range=:1000 -- $path 2>$null)
                } else {
                    $lines = @([IO.File]::ReadLines($path) | Select-Object -First 1000 | ForEach-Object { $_ -replace "`t", '    ' })
                }
            }
        }
    } catch { $lines = @("(can't read: $($_.Exception.Message))") }
    $cache[$path] = $lines
    $lines
}

function NookItem([string]$rel, [string]$abs, [string]$label, [string]$sub, [bool]$isDir, [bool]$isRepo) {
    [pscustomobject]@{ Rel = $rel; Abs = $abs; Label = $label; Sub = $sub; IsDir = $isDir; IsRepo = $isRepo }
}

# Project rows, filtered by name (names that start with the text come first)
function NookProjectItems($all, [string]$text) {
    if (-not $text) { return $all }
    $a = @($all | Where-Object { $_.Label.StartsWith($text, [StringComparison]::OrdinalIgnoreCase) })
    $b = @($all | Where-Object { $_.Label.IndexOf($text, [StringComparison]::OrdinalIgnoreCase) -gt 0 -or ($_.Sub.IndexOf($text, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and $_.Label.IndexOf($text, [StringComparison]::OrdinalIgnoreCase) -lt 0) })
    @($a + $b)
}

# Folder rows, like a terminal's tab list: entries of the typed folder that start with the last part
function NookBrowseItems($C, [string]$text) {
    $t = $text -replace '/', '\'
    $sep = $t.LastIndexOf('\')
    $dirPart = if ($sep -ge 0) { $t.Substring(0, $sep + 1) } else { '' }
    $leaf = $t.Substring($sep + 1)
    $dirAbs = NookResolvePath $C $dirPart
    $out = [System.Collections.Generic.List[object]]::new()
    if (-not [IO.Directory]::Exists($dirAbs)) { return @() }
    try {
        # hidden / system / dot / skipped entries (AppData, .config, NTUSER.DAT, ...) only show once you type the start of their name
        $di = [IO.DirectoryInfo]::new($dirAbs); $hid = [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System
        foreach ($dd in ($di.GetDirectories() | Sort-Object Name)) {
            $n = $dd.Name; $d = $dd.FullName
            if (-not $leaf -and (($dd.Attributes -band $hid) -or $n.StartsWith('.') -or $C.Projects.Skip -contains $n)) { continue }
            if ($n.StartsWith($leaf, [StringComparison]::OrdinalIgnoreCase)) {
                $out.Add((NookItem "$dirPart$n\" $d "$n\" '' $true ([IO.Directory]::Exists("$d\.git"))))
            }
        }
        foreach ($ff in ($di.GetFiles() | Sort-Object Name)) {
            $n = $ff.Name; $p = $ff.FullName
            if (-not $leaf -and (($ff.Attributes -band $hid) -or $n.StartsWith('.'))) { continue }
            if ($n.StartsWith($leaf, [StringComparison]::OrdinalIgnoreCase)) { $out.Add((NookItem "$dirPart$n" $p $n '' $false $false)) }
        }
    } catch {}
    $out.ToArray()
}

# ===========================================================================
# Project picker: a list (recent projects, or a folder's contents), a scrollable preview on the right,
# and the input at the bottom with a grey suggestion. Returns @{ Path; File; App } or $null.
# ===========================================================================
function NookPickProject($C) {
    $ask = $null   # "create this path?" waiting for y / n
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $K = $C.K; $e = [char]27; $openers = @($C.Projects.OpenWith)
    if (-not $openers.Count) { Write-Host 'nook: Projects.OpenWith in config.psd1 has no apps' -ForegroundColor Red; return $null }
    $base = $C.Projects.Search
    $first = $openers[0]
    $others = @($openers | Select-Object -Skip 1 | Where-Object Key)

    $projAll = @(NookProjectList $C | ForEach-Object {
        $rel = if ($_.StartsWith("$base\", [StringComparison]::OrdinalIgnoreCase)) { $_.Substring($base.Length + 1) } else { $_ }
        $parent = (Split-Path $_ -Parent) -replace [regex]::Escape($HOME), '~'
        NookItem "$rel\" $_ (Split-Path $_ -Leaf) $parent $true ([IO.Directory]::Exists("$_\.git"))
    })
    $icons = @{ Repo = [char]0xF401; Dir = [char]0xF07B; File = [char]0xF15B }

    $text = ''; $sel = 0; $top = 0; $pscroll = 0; $cache = @{}; $lastPath = ''
    $itemsKey = $null; $items = @(); $isBrowse = $false
    $note = ''; $result = $null; $dirty = $true; $lastW = 0; $lastH = 0; $focus = 'list'
    # typed path ending in \ and nothing picked yet (arrows / tab / mouse pick): enter opens that folder itself
    $picked = $false
    $hintsOn = NookHintsOn $C; $showKeys = $false   # ? opens the shortcuts page
    $typedDir = { if ($text -and -not $picked -and $text -match '[\\/]$') { $p = NookResolvePath $C $text; if ([IO.Directory]::Exists($p)) { $p } } }
    if (-not (NookInputLoad)) { Write-Host 'nook: could not set up keyboard/mouse input for the picker' -ForegroundColor Red; return $null }
    # alternate screen, no autowrap (a too-long line is cut at the edge instead of pushing the screen)
    [Console]::Write("$e[?1049h$e[?7l"); NookCursor $false
    [NookInput]::Start()
    try {
        while ($true) {
            $W = [Console]::WindowWidth; $H = [Console]::WindowHeight
            if ($showKeys -and ($dirty -or $W -ne $lastW -or $H -ne $lastH)) {
                [Console]::Write((NookKeysPage $C $W $H $hintsOn)); $lastW = $W; $lastH = $H; $dirty = $false
            }
            elseif ($dirty -or $W -ne $lastW -or $H -ne $lastH) {
                # the list only changes when the text changes (scrolling doesn't recompute it)
                if ($itemsKey -ne $text) {
                    # empty input: recent projects. Anything typed is a path (relative to Projects.Search)
                    $isBrowse = [bool]$text
                    $items = if ($isBrowse) { @(NookBrowseItems $C $text) } else { @($projAll) }
                    $itemsKey = $text
                }
                if ($sel -ge $items.Count) { $sel = [Math]::Max(0, $items.Count - 1) }
                $typed = & $typedDir
                $cur = if ($typed) { $null } elseif ($items.Count) { $items[$sel] } else { $null }

                # grey suggestion: the rest of the highlighted entry
                $ghost = if ($cur -and $text -and $cur.Rel.StartsWith($text, [StringComparison]::OrdinalIgnoreCase)) { $cur.Rel.Substring($text.Length) } else { '' }

                $listW = [Math]::Min(56, [Math]::Max(28, [int]($W * 0.4)))
                $prevW = [Math]::Max(0, $W - $listW - 3)
                $bodyH = [Math]::Max(3, $H - 3)          # rows: title, body..., input, keys
                if ($sel -lt $top) { $top = $sel }
                if ($sel -ge $top + $bodyH) { $top = $sel - $bodyH + 1 }

                $prevPath = if ($typed) { $typed } elseif ($cur) { $cur.Abs } else { '' }
                if ($prevPath -ne $lastPath) { $pscroll = 0; $lastPath = $prevPath }
                $prev = if ($prevPath) { @(NookPreview $prevPath $cache) } else { @() }
                $pscroll = [Math]::Max(0, [Math]::Min($pscroll, $prev.Count - $bodyH))

                # every row is drawn at a fixed position, exactly as wide as the window
                $fr = [System.Text.StringBuilder]::new()
                $row = 1
                $lt = if ($isBrowse) { $d = ($text -replace '/', '\'); $d = $d.Substring(0, $d.LastIndexOf('\') + 1); if ($d) { $d } else { (Split-Path $base -Leaf) + '\' } } else { 'recent projects' }
                $pt = if ($typed) { 'folder' } elseif ($cur) { if ($cur.IsDir) { 'folder' } else { 'file' } } else { '' }
                if ($prev.Count -gt $bodyH) { $pt += "  $($pscroll + 1)-$([Math]::Min($prev.Count, $pscroll + $bodyH)) of $($prev.Count)" }
                # the focused side has the accent color; the divider lights up when the preview is focused
                $onPrev = $focus -eq 'preview'
                $ltC = if ($onPrev) { $K.Mut } else { $K.Acc }; $ptC = if ($onPrev) { $K.Acc } else { $K.Mut }
                $divC = if ($onPrev) { $K.Acc } else { $K.Bdr }
                [void]$fr.Append("$e[$row;1H").Append((NookCut " $ltC$lt" ($listW + 1))).Append("$divC$([char]0x252C)$($K.R) ").Append((NookCut "$ptC$pt" $prevW))
                for ($r = 0; $r -lt $bodyH; $r++) {
                    $row++
                    $i = $top + ($bodyH - 1 - $r)      # first item on the bottom row, right above the input
                    $left = ''
                    if ($i -lt $items.Count) {
                        $it = $items[$i]; $on = -not $typed -and $i -eq $sel
                        $ic = if ($it.IsRepo) { $icons.Repo } elseif ($it.IsDir) { $icons.Dir } else { $icons.File }
                        $icc = if ($it.IsDir) { $K.Acc } else { $K.Mut }
                        $mark = if ($on) { "$($K.Acc)$([char]0x276F) " } else { '  ' }
                        $lab = if ($on) { "$($K.B)$($K.Acc)$($it.Label)$($K.NB)" } else { "$($K.Txt)$($it.Label)" }
                        $left = " $mark$icc$ic $lab"
                        if ($it.Sub) { $left += "  $($K.Mut)$($it.Sub)" }
                    } elseif ($r -eq $bodyH - 1 -and -not $items.Count) {
                        $left = "   $($K.Mut)nothing matches"
                    }
                    $right = if ($pscroll + $r -lt $prev.Count) { $prev[$pscroll + $r] } else { '' }
                    [void]$fr.Append("$e[$row;1H").Append((NookCut $left ($listW + 1))).Append("$divC$([char]0x2502)$($K.R) ").Append((NookCut $right $prevW))
                }
                # input at the bottom
                $row++
                $room = [Math]::Max(10, $W - 6)
                $shown = if ($text.Length -gt $room) { [char]0x2026 + $text.Substring($text.Length - $room + 1) } else { $text }
                $placeholder = if (-not $text) { "$($K.Mut)  type a path, like Documents\" } else { '' }
                $count = if ($typed) { "$($items.Count)" } elseif ($items.Count) { "$($sel + 1)/$($items.Count)" } else { '0' }
                $inLine = " $($K.Kw)$([char]0x276F) $($K.Txt)$shown$($K.Acc)$([char]0x258F)$($K.Mut)$(if ($text) { $ghost })$placeholder"
                $inW = NookWidth $inLine
                $inLine += (' ' * [Math]::Max(1, $W - $inW - $count.Length - 2)) + "$($K.Mut)$count"
                [void]$fr.Append("$e[$row;1H").Append((NookCut $inLine $W))
                # keys
                $row++
                $alts = @($others | ForEach-Object { "alt+$($_.Key) $($_.Name)" })
                $keys = if (-not $hintsOn) {
                    @('? keys')   # hidden hints: only ? for the full list
                } elseif ($onPrev) {
                    @("$([char]0x2191)$([char]0x2193) scroll", 'pgup/pgdn page', 'home/end', "$([char]0x2190) back to list", "enter $($first.Name)", '? keys')
                } else {
                    @("$([char]0x2192) accept", 'tab list', "$([char]0x2191)$([char]0x2193) move", "ctrl+$([char]0x2192) preview", "enter $($first.Name)") +
                    $alts + @($(if ($isBrowse) { 'esc back' } else { 'esc cancel' }), '? keys')
                }
                $kl = "   $($K.Mut)$($keys -join '   ')"
                if ($note) { $kl = "   $($K.Err)$note$($K.Mut)   $($keys -join '   ')"; $note = '' }
                if ($ask) { $kl = "   $($K.Hot)Create the $($ask.Kind) $($ask.Path)?$($K.R)   $($K.Txt)y$($K.Mut) yes   $($K.Txt)n$($K.Mut) / $($K.Txt)esc$($K.Mut) no" }
                [void]$fr.Append("$e[$row;1H").Append((NookCut $kl $W))
                [Console]::Write($fr.ToString())
                $lastW = $W; $lastH = $H; $dirty = $false
            }

            $ev = [NookInput]::Read(30)
            if ($ev.Kind -eq 'none') { continue }
            # handle every event that is waiting, then draw once (fast wheel spins and held keys don't pile up)
            $done = $false
            while ($true) {
                $n = $items.Count; $half = [Math]::Max(1, [int]($bodyH / 2))
                $inBody = $ev.Y + 1 -ge 2 -and $ev.Y + 1 -le $bodyH + 1
                $overPreview = $ev.X + 1 -gt $listW + 2
                if ($showKeys) {
                    if ($ev.Kind -eq 'key') {
                        if ($ev.Ch -eq 'h') { $hintsOn = -not $hintsOn; NookSetHints $hintsOn } else { $showKeys = $false }
                        $dirty = $true
                    }
                }
                elseif ($ev.Kind -eq 'wheel') {
                    $dirty = $true
                    $steps = 3 * [Math]::Max(1, [int]([Math]::Abs($ev.Delta) / 120))
                    if ($overPreview) { $pscroll += $(if ($ev.Delta -lt 0) { $steps } else { -$steps }) }
                    elseif ($n) {
                        if (& $typedDir) { $sel = 0 } else { $sel = if ($ev.Delta -gt 0) { [Math]::Min($n - 1, $sel + 1) } else { [Math]::Max(0, $sel - 1) } }
                        $picked = $true
                    }
                }
                elseif ($ev.Kind -eq 'click' -and $inBody) {
                    $dirty = $true
                    if ($overPreview) { $focus = 'preview' }
                    elseif ($ev.X + 1 -le $listW + 1) {
                        $focus = 'list'
                        $i = $top + ($bodyH - 1 - ($ev.Y - 1))
                        if ($i -ge 0 -and $i -lt $n) { $sel = $i; $picked = $true }
                    }
                }
                elseif ($ev.Kind -eq 'key' -and $ev.Ch -eq '?' -and -not $ask) { $showKeys = $true; $dirty = $true }
                elseif ($ev.Kind -eq 'key') {
                    $dirty = $true
                    $vk = $ev.Vk; $ch = $ev.Ch; $alt = $ev.Alt; $ctrl = $ev.Ctrl; $shift = $ev.Shift
                    $opener = $null
                    if ($alt) { $letter = ([string][char]$vk).ToLower(); $opener = $others | Where-Object { $_.Key -eq $letter } | Select-Object -First 1 }

                    if ($ask) {
                        # "Create the folder ...?"  y makes it (with every missing folder on the way) and opens it
                        if ($ch -eq 'y' -or $ch -eq 'Y' -or $vk -eq 0x0D) {
                            try {
                                if ($ask.Kind -eq 'file') {
                                    New-Item -ItemType Directory -Force (Split-Path $ask.Path -Parent) | Out-Null
                                    New-Item -ItemType File -Force $ask.Path | Out-Null
                                    $result = @{ Path = (Split-Path $ask.Path -Parent); File = $ask.Path; App = $ask.App }
                                } else {
                                    New-Item -ItemType Directory -Force $ask.Path | Out-Null
                                    $result = @{ Path = $ask.Path; File = $null; App = $ask.App }
                                }
                                $done = $true
                            } catch { $note = "couldn't create it: $($_.Exception.Message)" }
                        }
                        $ask = $null
                    }
                    elseif ($vk -eq 0x27 -and $ctrl) { $focus = 'preview' }                     # ctrl+right: into the preview
                    elseif ($vk -eq 0x25 -and $ctrl) { $focus = 'list' }                    # ctrl+left: back to the list
                    elseif ($focus -eq 'preview' -and $vk -in 0x26, 0x28, 0x21, 0x22, 0x24, 0x23, 0x25, 0x1B) {
                        switch ($vk) {
                            0x26 { $pscroll-- }  0x28 { $pscroll++ }
                            0x21 { $pscroll -= $half }  0x22 { $pscroll += $half }
                            0x24 { $pscroll = 0 }  0x23 { $pscroll = 1000000 }
                            default { $focus = 'list' }                                    # left or esc
                        }
                    }
                    elseif ($vk -eq 0x1B) { if ($isBrowse) { $text = ''; $sel = 0; $top = 0; $picked = $false } else { $done = $true } }
                    elseif ($vk -eq 0x27) { if ($ghost) { $text += $ghost; $sel = 0; $top = 0; $picked = $false } }          # accept the grey suggestion
                    elseif ($vk -eq 0x09) {
                        if (& $typedDir) { if ($n) { $sel = 0; $picked = $true } }                             # inside a typed folder: tab picks the first entry
                        elseif ($sel -lt $n) { $text = $items[$sel].Rel; $sel = 0; $top = 0; $picked = $false }   # list what's inside
                    }
                    elseif ($vk -eq 0x26 -and $shift) { $pscroll-- }
                    elseif ($vk -eq 0x28 -and $shift) { $pscroll++ }
                    elseif ($vk -in 0x26, 0x28 -and $n -and (& $typedDir)) { $sel = 0; $picked = $true }   # first arrow just picks the first entry
                    elseif ($vk -eq 0x26) { if ($n) { $sel = ($sel + 1) % $n; $picked = $true } }        # the list grows upward
                    elseif ($vk -eq 0x28) { if ($n) { $sel = ($sel - 1 + $n) % $n; $picked = $true } }
                    elseif ($vk -eq 0x22) { $pscroll += $half }
                    elseif ($vk -eq 0x21) { $pscroll -= $half }
                    elseif ($vk -eq 0x08) {
                        if ($ctrl) { $text = $text -replace '[^\\/]*[\\/]?$', '' } elseif ($text) { $text = $text.Substring(0, $text.Length - 1) }
                        $sel = 0; $top = 0; $picked = $false
                    }
                    elseif ($vk -eq 0x0D -or $opener) {
                        # the highlighted entry, or what's typed when nothing is listed
                        $td = & $typedDir
                        $target = if ($td) { $td } elseif ($sel -lt $n) { $items[$sel].Abs } elseif ($text) { NookResolvePath $C $text } else { $null }
                        if ($target -and ([IO.Directory]::Exists($target) -or [IO.File]::Exists($target))) {
                            $app = if ($opener) { $opener } else { $first }
                            $file = $null; $path = $target.TrimEnd('\')
                            if ([IO.File]::Exists($path)) { $file = $path; $path = Split-Path $path -Parent }
                            $result = @{ Path = $path; File = $file; App = $app }
                            $done = $true
                        } elseif ($target) {
                            # it doesn't exist yet: offer to create it (a name with an extension is a file, the rest folders)
                            $leafName = Split-Path $target.TrimEnd('\') -Leaf
                            $kind = if ($text -match '[\\/]$' -or -not ($leafName -match '.\.[^.\\]+$')) { 'folder' } else { 'file' }
                            $ask = @{ Path = $target.TrimEnd('\'); Kind = $kind; App = $(if ($opener) { $opener } else { $first }) }
                        }
                    }
                    elseif (-not $alt -and -not $ctrl -and $ch -and -not [char]::IsControl($ch)) { $text += $ch; $sel = 0; $top = 0; $picked = $false; $focus = 'list' }
                }
                if ($done -or -not [NookInput]::Pending()) { break }
                $ev = [NookInput]::Read(0)
            }
            if ($done) { break }
        }
    } finally {
        [NookInput]::Stop()
        [Console]::Write("$e[?7h$e[?1049l")
        NookCursor $true
    }
    if ($result -and (Get-Command zoxide -ErrorAction SilentlyContinue)) { zoxide add -- $result.Path 2>$null }   # rank it higher next time
    $result
}
# The command that opens a picked project: "nvim ." becomes "nvim 'file'" when a file was picked
function NookProjectCommand($proj) {
    $run = $proj.App.Run
    if ($run -and $proj.File) { $run = $run -replace '\s\.$', " '$($proj.File -replace "'", "''")'" }
    $run
}

# ===========================================================================
# Prayer times (Prayer in config.psd1). A month of times comes from api.aladhan.com once
# and is kept in prayer.json, so the dashboard never waits on the network.
# ===========================================================================

$script:NookPrayerFile  = Join-Path $PSScriptRoot 'prayer.json'
$script:NookPrayerNames = @('Fajr', 'Dhuhr', 'Asr', 'Maghrib', 'Isha')
$script:NookPrayer      = $null    # @{ Key; Days = @{ 'yyyy-MM-dd' = @{ Fajr = 'HH:mm'; ... } } }
$script:NookPrayerTask  = $null    # download running in the background
$script:NookPrayerRetry = [datetime]::MinValue

function NookPrayerKey($P, [datetime]$d) { "$($P.City)|$($P.Country)|$($P.Method)|$($d.ToString('yyyy-MM'))" }

# Keeps the month's times loaded; starts or finishes the download without blocking.
# Returns $true when new times just arrived (so the dashboard redraws).
function NookPrayerUpdate($C) {
    $P = $C.Prayer; if (-not $P) { return $false }
    $key = NookPrayerKey $P (Get-Date)
    if ($script:NookPrayer -and $script:NookPrayer.Key -eq $key) { return $false }
    if (-not $script:NookPrayer -and [IO.File]::Exists($script:NookPrayerFile)) {
        try { $script:NookPrayer = [IO.File]::ReadAllText($script:NookPrayerFile) | ConvertFrom-Json -AsHashtable } catch {}
        if ($script:NookPrayer -and $script:NookPrayer.Key -eq $key) { return $true }
    }
    $t = $script:NookPrayerTask
    if ($t) {
        if (-not $t.IsCompleted) { return $false }
        $script:NookPrayerTask = $null
        try {
            if ($t.IsFaulted -or $t.IsCanceled) { throw 'download failed' }
            $days = @{}
            foreach ($d in ($t.Result | ConvertFrom-Json).data) {
                $g = $d.date.gregorian.date -split '-'      # dd-MM-yyyy
                $times = @{}; foreach ($n in $script:NookPrayerNames) { $times[$n] = ($d.timings.$n -split ' ')[0] }
                $days["$($g[2])-$($g[1])-$($g[0])"] = $times
            }
            $script:NookPrayer = @{ Key = $key; Days = $days }
            try { [IO.File]::WriteAllText($script:NookPrayerFile, ($script:NookPrayer | ConvertTo-Json -Depth 4)) } catch {}
            return $true
        } catch { $script:NookPrayerRetry = (Get-Date).AddMinutes(5); return $false }   # offline: try again later
    }
    if ((Get-Date) -lt $script:NookPrayerRetry) { return $false }
    $now = Get-Date
    $url = 'https://api.aladhan.com/v1/calendarByCity/{0}/{1}?city={2}&country={3}&method={4}' -f $now.Year, $now.Month,
        [uri]::EscapeDataString($P.City), [uri]::EscapeDataString($P.Country), $P.Method
    try {
        $http = [Net.Http.HttpClient]::new(); $http.Timeout = [timespan]::FromSeconds(20)
        $script:NookPrayerTask = $http.GetStringAsync($url)
    } catch { $script:NookPrayerRetry = (Get-Date).AddMinutes(5) }
    $false
}

# Where today stands: each prayer's time, which one is next, and how long until it.
function NookPrayerState($C) {
    if (-not $C.Prayer -or -not $script:NookPrayer) { return $null }
    $now = Get-Date; $day = $now.ToString('yyyy-MM-dd')
    $today = $script:NookPrayer.Days[$day]
    if (-not $today) { return $null }
    $at = @(foreach ($n in $script:NookPrayerNames) { [datetime]::ParseExact("$day $($today[$n])", 'yyyy-MM-dd HH:mm', $null) })
    $next = -1; for ($i = 0; $i -lt $at.Count; $i++) { if ($at[$i] -gt $now) { $next = $i; break } }
    # after Isha the next one is tomorrow's Fajr
    $nextAt = if ($next -ge 0) { $at[$next] } else {
        $tom = $now.AddDays(1).ToString('yyyy-MM-dd'); $tm = $script:NookPrayer.Days[$tom]
        [datetime]::ParseExact("$tom $(if ($tm) { $tm.Fajr } else { $today.Fajr })", 'yyyy-MM-dd HH:mm', $null)
    }
    $secs = [int][Math]::Ceiling(($nextAt - $now).TotalSeconds)
    $in = if ($secs -ge 3600) { '{0}h {1:00}m' -f [Math]::Floor($secs / 3600), [Math]::Floor(($secs % 3600) / 60) }
          elseif ($secs -ge 60) { '{0}m {1:00}s' -f [Math]::Floor($secs / 60), ($secs % 60) }
          else { "${secs}s" }
    [pscustomobject]@{ At = $at; Next = $next; NextName = $script:NookPrayerNames[[Math]::Max(0, $next)]; NextAt = $nextAt; In = $in }
}

# A quiet box with the day as its title and the countdown in its bottom edge:
#   ╭─ Thursday, Nov 6 · 14:21 ──────────────────────╮
#   │    Fajr    Dhuhr     Asr    Maghrib    Isha    │
#   │   05:24    12:19    15:13    17:39     18:54   │
#   ╰─────────────── Asr in 34m 12s ─────────────────╯
# Returns @{ Lines; Live = index of the countdown line; Next } or $null. Narrow windows get one line.
function NookPrayerBox($C, [int]$W, [string]$title) {
    $st = NookPrayerState $C; if (-not $st) { return $null }
    $K = $C.K; $h = [string][char]0x2500; $col = 9; $inner = $col * 5 + 2
    $count = "$($K.Mut)$($st.NextName) in $($st.In)"
    if ($W -lt $inner + 4) {
        return @{ Lines = @("$($K.Mut)$([char]0xF186)  $count$($K.R)"); Live = 0; Next = $st.Next }
    }
    $names = ''; $times = ''
    for ($i = 0; $i -lt 5; $i++) {
        $n = $script:NookPrayerNames[$i]; $t = $st.At[$i].ToString('HH:mm')
        $pn = NookPad $n.Length $col; $pt = NookPad $t.Length $col
        if ($i -eq $st.Next) { $nc = $K.Acc; $tc = $K.Acc }
        else { $nc = $K.Mut; $tc = $K.Mut }                                            # the others
        $names += "$($pn[0])$nc$n$($pn[1])"; $times += "$($pt[0])$tc$t$($pt[1])"
    }
    $side = "$($K.Bdr)$([char]0x2502)"
    $top = if ($title) {
        $tw = $title.Length + 2
        "$($K.Bdr)$([char]0x256D)$h $($K.Mut)$title$($K.Bdr) $($h * [Math]::Max(0, $inner - $tw - 1))$([char]0x256E)"
    } else { "$($K.Bdr)$([char]0x256D)$($h * $inner)$([char]0x256E)" }
    $cw = NookWidth $count; $pad = NookPad ($cw + 2) $inner
    $bottom = "$($K.Bdr)$([char]0x2570)$($h * $pad[0].Length) $count $($K.Bdr)$($h * $pad[1].Length)$([char]0x256F)$($K.R)"
    @{
        Lines = @("$top$($K.R)", "$side $names $side$($K.R)", "$side $times $side$($K.R)", $bottom)
        Live = 3; Next = $st.Next
    }
}

# nook salat: print the prayer box under the prompt (downloads the month first if needed)
function NookSalat {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $C = NookLoad
    if (-not $C.Prayer) { Write-Host "nook: prayer times are off. Set Prayer = @{ City = '...'; Country = '...' } in config.psd1" -ForegroundColor DarkGray; return }
    $t0 = Get-Date
    while (-not (NookPrayerState $C) -and ((Get-Date) - $t0).TotalSeconds -lt 20) {
        NookPrayerUpdate $C | Out-Null
        if ($script:NookPrayerRetry -gt (Get-Date)) { break }     # download failed
        Start-Sleep -Milliseconds 100
    }
    $W = try { [Console]::WindowWidth } catch { 120 }
    $box = NookPrayerBox $C $W ((Get-Date).ToString("dddd, MMM d  $([char]0xB7)  HH:mm"))
    if (-not $box) { Write-Host "nook: couldn't get prayer times for $($C.Prayer.City) (no internet?)" -ForegroundColor DarkGray; return }
    foreach ($l in $box.Lines) { [Console]::WriteLine($l) }
}

# ===========================================================================
# Dashboard layouts. Each returns @{ Lines = centered lines; PerRow = items per row }
# ===========================================================================

# --- cards: boxes side by side, wrapping into more rows when needed ---
function NookCard($K, $app, [bool]$on, [int]$cw) {
    $b  = if ($on) { $K.Acc } else { $K.Bdr }
    $kc = if ($on) { $K.SelHint } else { $K.Mut }
    $V = "$b$([char]0x2502)$($K.R)"; $hz = [string][char]0x2500 * $cw
    $name = if ($app.Name.Length -gt $cw) { $app.Name.Substring(0, $cw - 1) + [char]0x2026 } else { $app.Name }
    $mid = {
        param($text, $color)
        $p = NookPad (NookWidth $text) $cw
        "$V$($p[0])$color$text$($K.R)$($p[1])$V"
    }
    @(
        "$b$([char]0x256D)$hz$([char]0x256E)$($K.R)"
        (& $mid '' '')
        (& $mid $app.Icon $K.Acc)
        (& $mid '' '')
        (& $mid $name $K.Txt)
        (& $mid $app.Key $kc)
        (& $mid '' '')
        "$b$([char]0x2570)$hz$([char]0x256F)$($K.R)"
    )
}

function NookCards($C, [int]$sel, [int]$W) {
    $apps = $C.Apps; $n = $apps.Count; $gap = 2
    $cw = [Math]::Min(22, [Math]::Max(10, (NookMaxLen $apps 'Name') + 2))
    $perRow = [Math]::Max(1, [Math]::Floor(($W - 2 + $gap) / ($cw + 2 + $gap)))
    $out = [System.Collections.Generic.List[string]]::new()
    for ($s = 0; $s -lt $n; $s += $perRow) {
        if ($s) { $out.Add('') }
        $rows = 1..8 | ForEach-Object { [System.Text.StringBuilder]::new() }
        for ($i = $s; $i -lt [Math]::Min($n, $s + $perRow); $i++) {
            $card = NookCard $C.K $apps[$i] ($i -eq $sel) $cw
            for ($r = 0; $r -lt 8; $r++) {
                if ($i -gt $s) { [void]$rows[$r].Append(' ' * $gap) }
                [void]$rows[$r].Append($card[$r])
            }
        }
        foreach ($l in (NookBlock ($rows | ForEach-Object { $_.ToString() }) $W)) { $out.Add($l) }
    }
    @{ Lines = $out.ToArray(); PerRow = $perRow }
}

# --- info: logo beside live info, apps as a wrapping bar of chips ---
function NookChip($K, $app, [bool]$on) {
    $content = ''
    if ($app.Icon) { $content += "$($K.Acc)$($app.Icon) " }
    $content += "$($K.Txt)$($app.Name)"
    if ($app.Key) { $content += " $(if ($on) { $K.SelHint } else { $K.Mut })$($app.Key)" }
    $w = NookWidth $content
    if ($on) {
        $hz = [string][char]0x2500 * ($w + 2)
        @("$($K.Acc)$([char]0x256D)$hz$([char]0x256E)$($K.R)",
          "$($K.Acc)$([char]0x2502) $content $($K.Acc)$([char]0x2502)$($K.R)",
          "$($K.Acc)$([char]0x2570)$hz$([char]0x256F)$($K.R)")
    } else {
        $sp = ' ' * ($w + 4)
        @($sp, "  $content  $($K.R)", $sp)
    }
}

function NookInfo($C, [int]$sel, [int]$W) {
    $K = $C.K; $e = [char]27; $now = Get-Date
    $labels = [System.Collections.Generic.List[string]]::new(); $values = [System.Collections.Generic.List[string]]::new()
    $add = { param($l, $v) $labels.Add($l); $values.Add($v) }
    & $add 'time' $now.ToString('HH:mm')
    & $add 'date' $now.ToString('dddd, MMM d')
    $folder = (Get-Location).ProviderPath -replace [regex]::Escape($HOME), '~'
    if ($folder.Length -gt 32) { $folder = [char]0x2026 + $folder.Substring($folder.Length - 31) }
    & $add 'folder' $folder
    if ($C.GitHub) { & $add 'github' "$e]8;;https://github.com/$($C.GitHub)$e\$($C.GitHub)$e]8;;$e\" }
    $branch = NookGitBranch
    if ($branch) { & $add 'branch' "$([char]0xE0A0) $branch" }
    & $add 'shell' "pwsh $($PSVersionTable.PSVersion)"
    $info = for ($i = 0; $i -lt $labels.Count; $i++) { "$($K.Acc)$($labels[$i].PadRight(8))$($K.Txt)$($values[$i])$($K.R)" }
    $info = @($info); $infoW = 0; foreach ($l in $info) { $infoW = [Math]::Max($infoW, (NookWidth $l)) }

    $out = [System.Collections.Generic.List[string]]::new()
    $logo = $C.Logo; $gap = 5
    if ($logo.Count -and $W -ge $C.LogoW + $gap + $infoW + 2) {
        # side by side, info vertically centered next to the logo
        $h = [Math]::Max($logo.Count, $info.Count)
        $first = [int][Math]::Floor(($h - $info.Count) / 2); $lf = [int][Math]::Floor(($h - $logo.Count) / 2)
        $top = for ($r = 0; $r -lt $h; $r++) {
            $l = if ($r - $lf -ge 0 -and $r - $lf -lt $logo.Count) { $logo[$r - $lf] } else { '' }
            $j = $r - $first
            $right = if ($j -ge 0 -and $j -lt $info.Count) { $info[$j] } else { '' }
            (NookFit $l $C.LogoW) + (' ' * $gap) + $right
        }
    } else {
        $top = @($logo) + $(if ($logo.Count) { @('') } else { @() }) + $info
    }
    $topLines = @(NookBlock @($top) $W)
    foreach ($l in $topLines) { $out.Add($l) }
    $topW = 0; foreach ($l in $top) { $topW = [Math]::Max($topW, (NookWidth $l)) }

    # chips, wrapped into rows that fit the window
    $chips = @(for ($i = 0; $i -lt $C.Apps.Count; $i++) { , (NookChip $K $C.Apps[$i] ($i -eq $sel)) })
    $rowsOfChips = [System.Collections.Generic.List[object]]::new(); $cur = [System.Collections.Generic.List[object]]::new(); $cw = 0
    foreach ($ch in $chips) {
        $chipW = NookWidth $ch[1]
        if ($cur.Count -and $cw + 1 + $chipW -gt $W - 2) { $rowsOfChips.Add($cur); $cur = [System.Collections.Generic.List[object]]::new(); $cw = 0 }
        $cw += $(if ($cur.Count) { 1 } else { 0 }) + $chipW; $cur.Add($ch)
    }
    if ($cur.Count) { $rowsOfChips.Add($cur) }
    # each row of chips is centered on its own
    $barW = 0; $bar = [System.Collections.Generic.List[string]]::new()
    foreach ($row in $rowsOfChips) {
        $lines = for ($r = 0; $r -lt 3; $r++) { ($row | ForEach-Object { $_[$r] }) -join ' ' }
        foreach ($l in $lines) { $barW = [Math]::Max($barW, (NookWidth $l)) }
        $bar.AddRange([string[]]@(NookBlock @($lines) $W))
    }

    $dw = [Math]::Min($W - 2, [Math]::Max($topW, $barW))
    $out.Add('')
    foreach ($l in (NookBlock @("$($K.Bdr)$([string][char]0x2500 * $dw)$($K.R)") $W)) { $out.Add($l) }
    $out.AddRange($bar)
    @{ Lines = $out.ToArray(); PerRow = $C.Apps.Count; HasLogo = $true }
}

# --- palette: type to filter, the selected row gets a border ---
function NookPalette($C, [int]$sel, $found, [string]$filter, [int]$W) {
    $K = $C.K; $apps = $C.Apps; $n = $apps.Count
    $nameCol = [Math]::Max(14, (NookMaxLen $apps 'Name') + 3)
    $hintCol = [Math]::Max(12, (NookMaxLen $apps 'Hint') + 2)
    $iw = 2 + 1 + 2 + $nameCol + $hintCol
    $L = [System.Collections.Generic.List[string]]::new()
    $prompt = "$($K.Kw)$([char]0x276F) "
    $prompt += if ($filter) { "$($K.Txt)$filter$($K.Acc)$([char]0x258F)" } else { "$($K.Acc)$([char]0x258F)$($K.Mut)type to search" }
    $L.Add(" $prompt$($K.R)")
    $rule = "$($K.Bdr)$([string][char]0x2500 * ($iw + 2))$($K.R)"
    $L.Add($rule)
    $used = 0
    for ($p = 0; $p -lt $found.Count; $p++) {
        $a = $apps[$found[$p]]; $on = $p -eq $sel
        $nm = $a.Name; $at = if ($filter) { $nm.ToLower().IndexOf($filter.ToLower()) } else { -1 }
        $nameHl = if ($at -ge 0) { "$($K.Txt)$($nm.Substring(0,$at))$($K.Acc)$($nm.Substring($at,$filter.Length))$($K.Txt)$($nm.Substring($at+$filter.Length))" } else { "$($K.Txt)$nm" }
        $hc = if ($on) { $K.SelHint } else { $K.Mut }
        $icon = if ($a.Icon) { $a.Icon } else { ' ' }
        $content = NookFit "  $($K.Acc)$icon  $nameHl$(' ' * ($nameCol - $nm.Length))$hc$($a.Hint)" $iw
        if ($on) {
            $L.Add("$($K.Acc)$([char]0x256D)$([string][char]0x2500 * $iw)$([char]0x256E)$($K.R)")
            $L.Add("$($K.Acc)$([char]0x2502)$content$($K.Acc)$([char]0x2502)$($K.R)")
            $L.Add("$($K.Acc)$([char]0x2570)$([string][char]0x2500 * $iw)$([char]0x256F)$($K.R)")
            $used += 3
        } else { $L.Add(" $content $($K.R)"); $used++ }
    }
    if (-not $found.Count) { $L.Add("$($K.Mut)  no match, esc to clear$($K.R)"); $used = 1 }
    for ($i = $used; $i -lt $n + 2; $i++) { $L.Add('') }   # constant height while filtering
    $L.Add($rule)
    $count = "$($found.Count)/$n"
    $L.Add("$(' ' * ($iw + 2 - $count.Length))$($K.Mut)$count$($K.R)")
    @{ Lines = @(NookBlock $L.ToArray() $W); PerRow = 1 }
}

# --- list: the original vertical menu ---
function NookList($C, [int]$sel, [int]$W) {
    $K = $C.K
    $nameCol = [Math]::Max(16, (NookMaxLen $C.Apps 'Name') + 3)
    $hintCol = [Math]::Max(14, (NookMaxLen $C.Apps 'Hint') + 3)
    $L = for ($i = 0; $i -lt $C.Apps.Count; $i++) {
        $a = $C.Apps[$i]; $icon = if ($a.Icon) { $a.Icon } else { ' ' }
        $name = $a.Name.PadRight($nameCol); $hint = $a.Hint.PadRight($hintCol); $key = if ($a.Key) { $a.Key } else { ' ' }
        if ($i -eq $sel) { "$($K.SelBg)$($K.Acc)  $icon  $name$($K.SelHint)$hint$($K.Acc)$key  $($K.R)" }
        else { "$($K.Acc)  $icon  $($K.Txt)$name$($K.Mut)$hint$key  $($K.R)" }
        if ($i -lt $C.Apps.Count - 1) { '' }
    }
    @{ Lines = @(NookBlock @($L) $W); PerRow = 1 }
}

# Themes popup, drawn on top of the dashboard at absolute positions
function NookThemesPopup($C, [int]$popSel, [string]$current, [int]$W, [int]$H) {
    $K = $C.K; $e = [char]27; $names = @($script:NookStyles.Keys)
    $iw = 34; $title = ' themes '
    $V = "$($K.Hot)$([char]0x2502)"
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("$($K.Hot)$([char]0x256D)$([char]0x2500)$title$([string][char]0x2500 * ($iw - 1 - $title.Length))$([char]0x256E)$($K.R)")
    $lines.Add("$V$(' ' * $iw)$V$($K.R)")
    for ($i = 0; $i -lt $names.Count; $i++) {
        $label = $script:NookStyles[$names[$i]].PadRight(20)
        $cur = if ($names[$i] -eq $current) { 'current' } else { '' }
        $row = if ($i -eq $popSel) { "  $($K.Acc)$([char]0x276F) $label" } else { "    $($K.Txt)$label" }
        $lines.Add("$V$row$($K.Mut)$($cur.PadRight($iw - 24))$V$($K.R)")
    }
    $lines.Add("$V$(' ' * $iw)$V$($K.R)")
    $lines.Add("$V$($K.Mut)$("  $([char]0x2191)$([char]0x2193) move  enter apply  esc close".PadRight($iw))$V$($K.R)")
    $lines.Add("$($K.Hot)$([char]0x2570)$([string][char]0x2500 * $iw)$([char]0x256F)$($K.R)")
    $row0 = [Math]::Max(1, [int](($H - $lines.Count) / 2) + 1)
    $col0 = [Math]::Max(1, [int](($W - $iw - 2) / 2) + 1)
    $sb = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt $lines.Count; $i++) { [void]$sb.Append("$e[$($row0 + $i);$($col0)H").Append($lines[$i]) }
    $sb.ToString()
}

# ===========================================================================
# Dashboard (nook -dashboard)
# ===========================================================================
function NookDashboard([string]$Style) {
    $closeTab = $false
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $C = NookLoad
    if (-not $Style) { $Style = NookSavedStyle $C }
    $C = NookWithRecent $C
    $e = [char]27
    $sel = 0; $filter = ''; $popup = $false; $popSel = 0; $perRow = 1; $found = @()
    $lastW = 0; $lastH = 0; $lastMin = -1; $dirty = $true; $liveRow = 0; $lastSec = -1
    $hintsOn = NookHintsOn $C
    NookCursor $false
    try {
        while ($true) {
            $W = [Console]::WindowWidth; $H = [Console]::WindowHeight; $now = Get-Date
            # redraw on a key, a window resize, or when the minute changes (keeps the clock right)
            if ($dirty -or $W -ne $lastW -or $H -ne $lastH -or $now.Minute -ne $lastMin) {
                $K = $C.K; $apps = $C.Apps; $n = $apps.Count
                if ($Style -eq 'palette') { $found = @(NookMatch $apps $filter); $sel = [Math]::Min($sel, [Math]::Max(0, $found.Count - 1)) }
                $view = switch ($Style) {
                    'cards'   { NookCards $C $sel $W }
                    'info'    { NookInfo $C $sel $W }
                    'palette' { NookPalette $C $sel $found $filter $W }
                    default   { NookList $C $sel $W }
                }
                $perRow = $view.PerRow
                $help = switch ($Style) {
                    'list'    { "$([char]0x2191)$([char]0x2193) move   enter open   q shell   x close tab" }
                    'palette' { "type to filter   $([char]0x2191)$([char]0x2193) move   enter open   esc clear / shell   ctrl+x close tab" }
                    default   { if ($perRow -lt $n) { "arrows move   enter open   q shell   x close tab" } else { "$([char]0x2190)$([char]0x2192) move   enter open   q shell   x close tab" } }
                }
                $hot = if ($Style -eq 'palette') { 'ctrl+o projects   ctrl+t themes' } else { 'o projects   t themes' }
                $foot = [System.Collections.Generic.List[string]]::new()
                $foot.Add('')
                $date = $now.ToString("dddd, MMM d  $([char]0xB7)  HH:mm")
                # today's section: the date on top of the prayer box (the info layout shows its own date)
                $pbox = NookPrayerBox $C $W $(if ($Style -ne 'info') { $date } else { '' })
                $liveAt = -1
                if ($pbox) {
                    $liveAt = $foot.Count + $pbox.Live
                    $foot.AddRange([string[]]@(NookBlock $pbox.Lines $W)); $foot.Add('')
                } elseif ($Style -ne 'info') { $foot.AddRange([string[]]@(NookBlock @("$($K.Mut)$date$($K.R)") $W)) }
                # hidden hints: only ? for the full list
                $hl = if ($hintsOn) { "$($K.Mut)$help   $($K.Hot)$hot   $($K.Mut)? keys$($K.R)" } else { "$($K.Mut)? keys$($K.R)" }
                $foot.AddRange([string[]]@(NookBlock @($hl) $W))
                $nv = NookNewVersion
                if ($nv) { $foot.AddRange([string[]]@(NookBlock @("$($K.Hot)$([char]0x2191) TermNook $nv is out$($K.Mut): run  $($K.Txt)nook update$($K.Mut)  (your settings stay)$($K.R)") $W)) }
                if ($C.Warnings.Count) {
                    $msg = "config: $($C.Warnings[0])$(if ($C.Warnings.Count -gt 1) { "  (+$($C.Warnings.Count - 1) more, see nook --help)" })"
                    $foot.AddRange([string[]]@(NookBlock @("$($K.Err)$msg$($K.R)") $W))
                }
                # logo on top (the info layout draws its own); dropped when the window is too short
                $body = @($view.Lines)
                $head = @()
                if ($Style -ne 'info' -and $C.Logo.Count -and ($C.Logo.Count + 2 + $body.Count + $foot.Count) -le $H) {
                    $head = @(NookBlock $C.Logo $W) + @('', '')
                }
                $all = @($head) + $body + @($foot)
                if ($all.Count -gt $H) { $all = $all[0..($H - 1)] }
                $top = [Math]::Max(0, [int][Math]::Floor(($H - $all.Count) / 2))
                # screen row of the countdown, so it can tick every second without redrawing everything
                $liveRow = if ($liveAt -ge 0 -and $head.Count + $body.Count + $liveAt -lt $all.Count) { $top + $head.Count + $body.Count + $liveAt + 1 } else { 0 }
                $liveNext = if ($pbox) { $pbox.Next } else { $null }; $liveLine = ''; $lastSec = $now.Second
                $frame = "$e[H$e[J" + ("`n" * $top) + ($all -join "`n")
                if ($popup) { $frame += NookThemesPopup $C $popSel $Style $W $H }
                [Console]::Write($frame)
                $lastW = $W; $lastH = $H; $lastMin = $now.Minute; $dirty = $false
            }

            if (NookPrayerUpdate $C) { $dirty = $true; continue }
            if ($liveRow -and $now.Second -ne $lastSec -and -not $popup) {
                $lastSec = $now.Second
                $pb = NookPrayerBox $C $W ''
                if (-not $pb -or $pb.Next -ne $liveNext) { $dirty = $true; continue }   # next prayer changed: full redraw
                $l = @(NookBlock $pb.Lines $W)[$pb.Live]
                if ($l -ne $liveLine) { [Console]::Write("$e[$liveRow;1H$l$e[K"); $liveLine = $l }
            }
            if (-not [Console]::KeyAvailable) { Start-Sleep -Milliseconds 40; continue }
            $key = [Console]::ReadKey($true); $ch = [string]$key.KeyChar; $dirty = $true
            $shift = $key.Modifiers -band [ConsoleModifiers]::Shift
            $ctrlT = $key.Key -eq 'T' -and ($key.Modifiers -band [ConsoleModifiers]::Control)
            $names = @($script:NookStyles.Keys)
            $pick = $null

            if ($popup) {
                if ($key.Key -eq 'UpArrow') { $popSel = ($popSel - 1 + $names.Count) % $names.Count }
                elseif ($key.Key -in 'DownArrow','Tab') { $popSel = ($popSel + 1) % $names.Count }
                elseif ($key.Key -eq 'Enter') {
                    $Style = $names[$popSel]; $popup = $false; $sel = 0; $filter = ''
                    try { Set-Content -LiteralPath $script:NookStateFile -Value $Style -Encoding utf8 } catch {}
                }
                elseif ($key.Key -eq 'Escape' -or $ch -eq 't' -or $ctrlT) { $popup = $false }
                continue
            }
            if ($ch -eq '?') {
                # shortcuts page: h shows / hides the hint lines, any other key goes back
                while ($true) {
                    [Console]::Write((NookKeysPage $C ([Console]::WindowWidth) ([Console]::WindowHeight) $hintsOn))
                    if ([Console]::ReadKey($true).KeyChar -eq 'h') { $hintsOn = -not $hintsOn; NookSetHints $hintsOn } else { break }
                }
                continue
            }
            if ($ctrlT -or ($Style -ne 'palette' -and $ch -eq 't')) {
                $popup = $true; $popSel = [Math]::Max(0, [array]::IndexOf($names, $Style)); continue
            }
            $ctrlX = $key.Key -eq 'X' -and ($key.Modifiers -band [ConsoleModifiers]::Control)
            if ($ctrlX -or ($Style -ne 'palette' -and $ch -eq 'x')) { $closeTab = $true; break }
            $ctrlO = $key.Key -eq 'O' -and ($key.Modifiers -band [ConsoleModifiers]::Control)
            if ($ctrlO -or ($Style -ne 'palette' -and $ch -eq 'o')) {
                $proj = NookPickProject $C
                NookCursor $false
                if ($proj) { Set-Location -LiteralPath $proj.Path; $pick = [pscustomobject]@{ Name = $proj.App.Name; Run = NookProjectCommand $proj } }
                else { continue }
            }

            if ($pick) { }
            elseif ($Style -eq 'palette') {
                # letters type into the filter here, so they are not shortcuts
                $fc = [Math]::Max(1, $found.Count)
                if ($key.Key -eq 'UpArrow' -or ($key.Key -eq 'Tab' -and $shift)) { $sel = ($sel - 1 + $fc) % $fc }
                elseif ($key.Key -in 'DownArrow','Tab') { $sel = ($sel + 1) % $fc }
                elseif ($key.Key -eq 'Enter') { if ($found.Count) { $pick = $apps[$found[$sel]] } }
                elseif ($key.Key -eq 'Escape') { if ($filter) { $filter = ''; $sel = 0 } else { break } }
                elseif ($key.Key -eq 'Backspace') { if ($filter) { $filter = $filter.Substring(0, $filter.Length - 1); $sel = 0 } }
                elseif ($ch -match '^[\w .+-]$') { $filter += $ch; $sel = 0 }
            } else {
                $row = $Style -eq 'cards' -and $perRow -lt $n     # up/down jump a row of cards
                if ($key.Key -eq 'LeftArrow' -or ($key.Key -eq 'Tab' -and $shift)) { $sel = ($sel - 1 + $n) % $n }
                elseif ($key.Key -in 'RightArrow','Tab') { $sel = ($sel + 1) % $n }
                elseif ($key.Key -eq 'UpArrow') { $sel = if ($row) { if ($sel -ge $perRow) { $sel - $perRow } else { $sel } } else { ($sel - 1 + $n) % $n } }
                elseif ($key.Key -eq 'DownArrow') { $sel = if ($row) { [Math]::Min($n - 1, $sel + $perRow) } else { ($sel + 1) % $n } }
                elseif ($key.Key -eq 'Enter') { $pick = $apps[$sel] }
                elseif ($key.Key -eq 'Escape' -or $ch -eq 'q') { break }
                elseif ($ch) {
                    $j = [array]::IndexOf(@($apps | ForEach-Object Key), $ch.ToLower())
                    if ($ch.Trim() -and $j -ge 0) { $sel = $j; $pick = $apps[$j] }
                }
            }

            if ($pick) {
                if (-not $pick.Run) { break }        # the "back to the prompt" item
                NookRun $pick
                $filter = ''
                NookCursor $false
                $C = NookWithRecent (NookLoad)          # pick up config edits made meanwhile, newest app first
                $sel = 0
            }
        }
    } finally {
        NookCursor $true
        Clear-Host
    }
    if ($closeTab) { [Environment]::Exit(0) }   # ends this shell, so the terminal closes the tab
}

# ===========================================================================
# Quick picker (plain `nook`): one row under the prompt, erased when done
#   Nvim   VS Code   Git   Files       ←→ move  enter open  esc cancel
#           ━━━━  editor
# ===========================================================================
function NookQuick {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $C = NookWithRecent (NookLoad); $K = $C.K; $e = [char]27
    $items = @($C.Apps | Where-Object { $_.Run })       # "back to the prompt" items make no sense here
    if (-not $items.Count) { Write-Host 'nook: no apps with a Run command in config.psd1' -ForegroundColor Red; return }
    $n = $items.Count; $sel = 0; $gap = 3; $lead = 2
    $help = "$([char]0x2190)$([char]0x2192) move  enter open  esc cancel"; $hintsOn = NookHintsOn $C
    $more = [char]0x2026

    NookCursor $false
    $pick = $null; $drawn = $false
    try {
        while ($true) {
            $W = [Console]::WindowWidth
            # which items fit: keep the selected one visible, show … where items are hidden
            $widths = $items | ForEach-Object { $_.Name.Length }
            $span = { param($a, $b) $s = 0; for ($i = $a; $i -le $b; $i++) { $s += $widths[$i] + $(if ($i -gt $a) { $gap } else { 0 }) }; $s }
            $avail = $W - $lead - 4
            $first = 0
            while ($first -lt $sel -and (& $span $first $sel) + 4 -gt $avail) { $first++ }
            $last = $sel
            while ($last + 1 -lt $n -and (& $span $first ($last + 1)) + 4 -le $avail) { $last++ }

            $line = ' ' * $lead; $pos = $lead; $selStart = $lead
            if ($first -gt 0) { $line += "$($K.Mut)$more $($K.R)"; $pos += 2 }
            for ($i = $first; $i -le $last; $i++) {
                $nm = $items[$i].Name; $at = if ($items[$i].Key) { $nm.ToLower().IndexOf($items[$i].Key) } else { -1 }
                $pre = if ($at -ge 0) { $nm.Substring(0, $at) } else { $nm }
                $ltr = if ($at -ge 0) { $nm.Substring($at, 1) } else { '' }
                $post = if ($at -ge 0) { $nm.Substring($at + 1) } else { '' }
                if ($i -eq $sel) {
                    $selStart = $pos
                    $line += "$($K.B)$($K.Acc)$pre$($K.U)$ltr$($K.NU)$post$($K.NB)$($K.R)"
                } else {
                    $line += "$($K.Mut)$pre$($K.Txt)$ltr$($K.Mut)$post$($K.R)"
                }
                $pos += $nm.Length
                if ($i -lt $last) { $line += ' ' * $gap; $pos += $gap }
            }
            if ($last -lt $n - 1) { $line += " $($K.Mut)$more$($K.R)"; $pos += 2 }
            if ($hintsOn -and $pos + 4 + $help.Length -lt $W) { $line += "    $($K.Mut)$help$($K.R)" }   # hidden hints: the underlined letters are enough

            $it = $items[$sel]
            $under = (' ' * $selStart) + "$($K.Acc)$([string][char]0x2501 * $it.Name.Length)$($K.R)"
            if ($it.Hint -and $selStart + $it.Name.Length + 2 + $it.Hint.Length -lt $W) { $under += "  $($K.SelHint)$($it.Hint)$($K.R)" }

            $out = if ($drawn) { "`r$e[1F$e[J" } else { '' }
            [Console]::Write($out + $line + "`n" + $under)
            $drawn = $true

            $key = [Console]::ReadKey($true); $ch = [string]$key.KeyChar
            $shift = $key.Modifiers -band [ConsoleModifiers]::Shift
            if ($key.Key -in 'LeftArrow','UpArrow' -or ($key.Key -eq 'Tab' -and $shift)) { $sel = ($sel - 1 + $n) % $n }
            elseif ($key.Key -in 'RightArrow','DownArrow','Tab') { $sel = ($sel + 1) % $n }
            elseif ($key.Key -eq 'Enter') { $pick = $it; break }
            elseif ($key.Key -eq 'Escape' -or $ch -eq 'q') { break }
            elseif ($ch.Trim()) {
                $hit = $items | Where-Object { $_.Key -eq $ch.ToLower() } | Select-Object -First 1
                if ($hit) { $pick = $hit; break }
            }
        }
    } finally {
        if ($drawn) { [Console]::Write("`r$e[1F$e[J") }   # leave the shell clean
        NookCursor $true
    }
    if ($pick) {
        NookRemember $pick.Name
        try { & ([scriptblock]::Create($pick.Run)) }
        catch { Write-Host "nook: $($pick.Name) failed: $($_.Exception.Message)" -ForegroundColor Red }
    }
}

# ===========================================================================
# Help
# ===========================================================================

# Every key, by screen: shared by nook --help and the ? shortcuts page
function NookKeyLines($C) {
    $K = $C.K; $t = $K.Txt; $m = $K.Mut; $y = $K.Hot; $h = $K.Kw; $r = $K.R
    $keys = (@($C.Apps | Where-Object Key | ForEach-Object Key)) -join ' '
    $qkeys = (@($C.Apps | Where-Object { $_.Key -and $_.Run } | ForEach-Object Key)) -join ' '
    $alts = @($C.Projects.OpenWith | Select-Object -Skip 1 | Where-Object Key | ForEach-Object { "$($t)alt+$($_.Key)$r $($_.Name)" }) -join '   '
    $first = if (@($C.Projects.OpenWith).Count) { @($C.Projects.OpenWith)[0].Name } else { 'the first app' }
    @(
        "  $($h)QUICK PICKER KEYS$r  $m(nook)$r"
        "    $($t)$([char]0x2190)$([char]0x2192)$r / $($t)tab$r move   $($t)enter$r open   $($t)$qkeys$r open directly   $($t)esc$r / $($t)q$r cancel"
        ''
        "  $($h)DASHBOARD KEYS$r  $m(nook -d)$r"
        "    $($t)arrows$r / $($t)tab$r move   $($t)enter$r open   $($t)$keys$r open directly   $($t)q$r / $($t)esc$r back to the prompt"
        "    $($y)o$r projects   $($y)t$r themes   $($y)x$r close the terminal tab   ($($y)ctrl+o$r / $($y)ctrl+t$r / $($y)ctrl+x$r in the palette style)"
        "    $($t)?$r this shortcuts page"
        ''
        "  $($h)PROJECT PICKER KEYS$r  $m(nook -p, or o in the dashboard)$r"
        "    type a name or path   $($t)$([char]0x2192)$r accept the grey suggestion   $($t)tab$r list inside   $($t)$([char]0x2191)$([char]0x2193)$r move   $($t)ctrl+backspace$r remove the last part"
        "    $($t)enter$r open in $first   $(if ($alts) { "$alts   " })$($t)esc$r back / cancel"
        "    a typed folder path ending in \ opens that folder; pick an entry inside first to open it instead"
        "    $($t)ctrl+$([char]0x2192)$r / click into the preview: $($t)$([char]0x2191)$([char]0x2193)$r scroll   $($t)pgup/pgdn$r page   $($t)home/end$r   $($t)$([char]0x2190)$r back to the list"
        "    $($t)shift+$([char]0x2191)$([char]0x2193)$r / $($t)pgup/pgdn$r scroll the preview from the list   mouse wheel scrolls what it is over"
        "    $($t)?$r this shortcuts page"
        ''
    )
}

# The ? shortcuts page (dashboard and project picker): every key, and h to show / hide the hint lines
function NookKeysPage($C, [int]$W, [int]$H, [bool]$hintsOn) {
    $K = $C.K; $e = [char]27
    $state = if ($hintsOn) { 'shown' } else { 'hidden (only ? keys)' }
    $lines = @('', "  $($K.Acc)Shortcuts$($K.R)", '') + @(NookKeyLines $C) +
        @("  $($K.Mut)hint lines: $($K.Txt)$state$($K.R)",
          '', "  $($K.Hot)h$($K.Mut) $(if ($hintsOn) { 'hide' } else { 'show' }) hint lines   any other key: back$($K.R)")
    $sb = [System.Text.StringBuilder]::new("$e[H$e[J")
    for ($i = 0; $i -lt [Math]::Min($lines.Count, $H); $i++) { [void]$sb.Append("$e[$($i + 1);1H").Append((NookCut $lines[$i] $W)) }
    $sb.ToString()
}
function NookHelp {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $C = NookLoad; $K = $C.K
    $a = $K.Acc; $t = $K.Txt; $m = $K.Mut; $y = $K.Hot; $h = $K.Kw; $r = $K.R
    $o = [System.Collections.Generic.List[string]]::new()
    $o.AddRange([string[]]@(
        ''
        "  $($a)TermNook$r $m$($script:NookVersion) - app launcher, dashboard and project picker. Command:$r $($a)nook$r"
        ''
        "  $($h)USAGE$r"
        "    $($t)nook$r                    $m quick picker: one line under your prompt$r"
        "    $($t)nook -dashboard$r, $($t)-d$r      $m full dashboard in your saved style$r"
        "    $($t)nook -d -style info$r     $m dashboard once in another style: $(@($script:NookStyles.Keys) -join ', ')$r"
        "    $($t)nook -projects$r, $($t)-p$r       $m pick a project, open it in $(@($C.Projects.OpenWith | ForEach-Object Name) -join ' / ')$r"
        "    $($t)nook salat$r              $m today's prayer times and the next one, right under the prompt$r"
        "    $($t)nook -reload$r            $m re-read config.psd1 and the logo now$r"
        "    $($t)nook update$r             $m get the newest TermNook (your settings stay as they are)$r"
        "    $($t)nook update --check$r     $m only check whether there's a newer version$r"
        "    $($t)nook config$r             $m open config.psd1 in your editor$r"
        "    $($t)nook --version$r          $m show the version$r"
        "    $($t)nook -h$r, $($t)--help$r          $m show this help$r"
        ''
    ))
    $o.AddRange([string[]]@(NookKeyLines $C))
    $o.AddRange([string[]]@(
        "  $($h)FILES$r  $m($($script:NookDir))$r"
        "    $($t)config.psd1$r  $m apps, keys, icons, colors, logo, GitHub user$r"
        "    $($t)logo.txt$r     $m the logo$r"
        "    $($t)style.txt$r    $m the style you last picked with t$r"
        "    $($t)hints.txt$r    $m hint lines shown or hidden (h on the ? page; wins over Hints in config.psd1)$r"
        "    $($t)recent.txt$r   $m apps you opened, last used first (Recent = `$false in config.psd1 turns it off)$r"
        "    $($t)prayer.json$r  $m this month's prayer times (downloaded again each month, delete to refresh)$r"
        "    $($t)termnook.ps1$r $m the program itself$r"
        "    $($t)config.example.psd1$r $m every setting with an explanation (copied to config.psd1 the first time)$r"
        ''
    ))
    if ($C.Warnings.Count) {
        $o.Add("  $($K.Err)CONFIG PROBLEMS$r")
        foreach ($w in $C.Warnings) { $o.Add("    $($K.Err)-$r $t$w$r") }
        $o.Add('')
    }
    [Console]::Write(($o -join "`n") + "`n")
}

# ===========================================================================
# nook update / nook config
# ===========================================================================

# ---- updates: releases on GitHub ----
# TermNook looks for a newer release at most once a day, in the background, and the dashboard says
# when one is out. `nook update` installs it: git clones pull it, other copies download it.
# Only the program's files are replaced: config.psd1, my-*.txt and saved files are never touched.

$script:NookUpdateFile = Join-Path $PSScriptRoot 'update.json'
$script:NookUpdateTask = $null

function NookNewer([string]$a, [string]$b) {
    $pa = @(($a.TrimStart('v') -split '[-+]')[0] -split '\.' | ForEach-Object { [int]$_ }) + 0, 0, 0
    $pb = @(($b.TrimStart('v') -split '[-+]')[0] -split '\.' | ForEach-Object { [int]$_ }) + 0, 0, 0
    for ($i = 0; $i -lt 3; $i++) { if ($pa[$i] -ne $pb[$i]) { return $pa[$i] -gt $pb[$i] } }
    $false
}

function NookLatestRelease {
    $h = @{ 'User-Agent' = "termnook/$($script:NookVersion)"; Accept = 'application/vnd.github+json' }
    Invoke-RestMethod -Uri "https://api.github.com/repos/$($script:NookRepo)/releases/latest" -Headers $h -TimeoutSec 15
}

# start the daily check without waiting for it
function NookCheckUpdateStart {
    if ($script:NookUpdateTask) { return }
    try {
        if (Test-Path -LiteralPath $script:NookUpdateFile) {
            $u = Get-Content -LiteralPath $script:NookUpdateFile -Raw | ConvertFrom-Json
            if (([datetime]::UtcNow - [datetime]$u.at).TotalHours -lt 24) { return }
        }
        $client = [System.Net.Http.HttpClient]::new()
        $client.Timeout = [TimeSpan]::FromSeconds(10)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd("termnook/$($script:NookVersion)")
        $script:NookUpdateTask = $client.GetStringAsync("https://api.github.com/repos/$($script:NookRepo)/releases/latest")
    } catch {}
}

# the newer version, if there is one ('' if not, or not known yet)
function NookNewVersion {
    $t = $script:NookUpdateTask
    if ($t -and $t.IsCompleted) {
        $script:NookUpdateTask = $null
        try {
            if ($t.Status -eq 'RanToCompletion') {
                $tag = ($t.Result | ConvertFrom-Json).tag_name
                @{ at = [datetime]::UtcNow.ToString('o'); latest = $tag } | ConvertTo-Json | Set-Content -LiteralPath $script:NookUpdateFile -Encoding utf8
            }
        } catch {}
    }
    try {
        if (Test-Path -LiteralPath $script:NookUpdateFile) {
            $u = Get-Content -LiteralPath $script:NookUpdateFile -Raw | ConvertFrom-Json
            if ($u.latest -and (NookNewer $u.latest $script:NookVersion)) { return $u.latest.TrimStart('v') }
        }
    } catch {}
    ''
}

# the files that are the program (everything else in the folder is yours)
$script:NookProgramFiles = @('termnook.ps1', 'config.example.psd1', 'logo.txt', 'install.ps1', 'README.md', 'LICENSE', '.gitignore')

function NookUpdate([switch]$Check) {
    $dir = $script:NookDir
    Write-Host 'nook: looking for a newer TermNook…' -ForegroundColor DarkGray
    try { $rel = NookLatestRelease } catch { Write-Host "nook: couldn't reach GitHub: $($_.Exception.Message)" -ForegroundColor Red; return }
    @{ at = [datetime]::UtcNow.ToString('o'); latest = $rel.tag_name } | ConvertTo-Json | Set-Content -LiteralPath $script:NookUpdateFile -Encoding utf8
    $new = $rel.tag_name.TrimStart('v')
    if (-not (NookNewer $rel.tag_name $script:NookVersion)) { Write-Host "nook: you have the newest version ($($script:NookVersion))." -ForegroundColor DarkGray; return }
    Write-Host "nook: TermNook $new is out (you have $($script:NookVersion)). What's new: $($rel.html_url)" -ForegroundColor Green
    if ($Check) { Write-Host 'nook: run  nook update  to get it.' -ForegroundColor DarkGray; return }

    if (Test-Path -LiteralPath (Join-Path $dir '.git')) {
        # a git clone: pull (only the program's files are tracked, so your files can't be touched)
        $out = git -C $dir pull --ff-only 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Host "nook: update failed: $out" -ForegroundColor Red; return }
    } else {
        # downloaded copy: get the release zip and replace only the program's files
        $asset = @($rel.assets | Where-Object name -eq 'termnook.zip')[0]
        $url = if ($asset) { $asset.browser_download_url } else { $rel.zipball_url }
        $tmp = Join-Path ([IO.Path]::GetTempPath()) "termnook-$new"
        try {
            Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Force $tmp | Out-Null
            Invoke-WebRequest -Uri $url -OutFile "$tmp\t.zip" -Headers @{ 'User-Agent' = 'termnook' } -TimeoutSec 120
            Expand-Archive "$tmp\t.zip" -DestinationPath "$tmp\x" -Force
            $src = (Get-ChildItem "$tmp\x" -Recurse -Filter termnook.ps1 | Select-Object -First 1).DirectoryName
            if (-not $src) { throw 'the download has no termnook.ps1' }
            foreach ($f in $script:NookProgramFiles) {
                if (Test-Path -LiteralPath (Join-Path $src $f)) { Copy-Item -LiteralPath (Join-Path $src $f) -Destination (Join-Path $dir $f) -Force }
            }
        } catch { Write-Host "nook: update failed: $($_.Exception.Message)" -ForegroundColor Red; return }
        finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }
    . (Join-Path $dir 'termnook.ps1')   # load the new version right away
    Write-Host "nook: updated to $($script:NookVersion). Your settings weren't touched." -ForegroundColor Green
}

function NookEditConfig {
    $cfg = Join-Path $script:NookDir 'config.psd1'
    if (-not (Test-Path -LiteralPath $cfg)) { NookLoad | Out-Null }
    $ed = if ($env:EDITOR) { $env:EDITOR } elseif (Get-Command nvim -ErrorAction SilentlyContinue) { 'nvim' } elseif (Get-Command code -ErrorAction SilentlyContinue) { 'code' } else { 'notepad' }
    & $ed $cfg
}

# ===========================================================================
# nook: the command you type
# ===========================================================================
function nook([switch]$Dashboard, [string]$Style, [switch]$Reload, [switch]$Help, [switch]$Projects, [switch]$Salat) {
    # PowerShell hands a bare word like --help to the first parameter; take it back
    $rest = @($args)
    if ($Style -like '-*' -or $Style -like '/*') { $rest = @($Style) + $rest; $Style = '' }
    if ($Style -in 'salat', 'prayer') { $Salat = $true; $Style = '' }   # nook salat
    if ($Style -in 'update', 'upgrade') { NookUpdate -Check:($rest -contains '--check' -or $rest -contains 'check'); return }
    if ($Style -in 'config', 'settings') { NookEditConfig; return }
    if ($Style -eq 'version') { "TermNook $($script:NookVersion)"; return }
    foreach ($a in $rest) {
        switch -Regex ($a) {
            '^--?help$|^/\?$' { $Help = $true }
            '^--?version$|^-v$' { "TermNook $($script:NookVersion)"; return }
            '^--?check$|^check$' { }
            '^--dashboard$'   { $Dashboard = $true }
            '^--reload$'      { $Reload = $true }
            '^--projects$'    { $Projects = $true }
            '^--(salat|prayer)$' { $Salat = $true }
            default { Write-Host "nook: unknown option '$a'. Try nook --help" -ForegroundColor Red; return }
        }
    }
    if ($Style -and -not $script:NookStyles.Contains($Style)) {
        Write-Host "nook: unknown style '$Style'. Use one of: $(@($script:NookStyles.Keys) -join ', ')" -ForegroundColor Red; return
    }
    if ($Help) { NookHelp; return }
    if ($Reload) {
        $C = NookLoad -Force
        if (-not ($Dashboard -or $Style)) {
            Write-Host 'nook: reloaded' -ForegroundColor DarkGray
            foreach ($w in $C.Warnings) { Write-Host "  config: $w" -ForegroundColor Yellow }
            return
        }
    }
    if ($Salat) { NookSalat; return }
    if ($Projects) {
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $proj = NookPickProject (NookLoad)
        if (-not $proj) { return }
        Set-Location -LiteralPath $proj.Path
        $run = NookProjectCommand $proj
        if ($run) {
            try { & ([scriptblock]::Create($run)) }
            catch { Write-Host "nook: $($proj.App.Name) failed: $($_.Exception.Message)" -ForegroundColor Red }
        }
        return
    }
    if ($Dashboard -or $Style) { NookDashboard -Style $Style; return }
    NookQuick
}
