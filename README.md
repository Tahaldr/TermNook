# TermNook

**A home for your PowerShell terminal**: a quick app launcher under your prompt, a full-screen
dashboard with a clock (and optional prayer times), and a project picker with previews — all in
your colors, driven by one settings file. Command: `nook`.

```
          ▀█▀ █▀▀ █▀█ █▀▄▀█   █▄ █ █▀█ █▀█ █▄▀
           █  ██▄ █▀▄ █ ▀ █   █ ▀█ █▄█ █▄█ █ █

                 Sunday 9 November · 23:40

   ╭──────────╮ ╭──────────╮ ╭──────────╮ ╭──────────╮ ╭──────────╮
   │    Nvim  │ │  VS Code │ │    Git   │ │   Files  │ │   Shell  │
   │  editor  │ │   code   │ │  lazygit │ │ explorer │ │  prompt  │
   │    n     │ │    v     │ │    g     │ │    f     │ │    s     │
   ╰──────────╯ ╰──────────╯ ╰──────────╯ ╰──────────╯ ╰──────────╯
      ←→ move · enter open · a letter opens its app · o projects · t layouts · q back
```

## Contents

- [What it does](#what-it-does)
- [Install](#install)
- [Update](#update)
- [Use it](#use-it)
- [Configure](#configure)
  - [Adding apps](#adding-apps)
  - [Projects and "open with"](#projects-and-open-with)
  - [Layouts, colors and logo](#layouts-colors-and-logo)
  - [Prayer times](#prayer-times)
- [Keys](#keys)
- [Files](#files)
- [Uninstall](#uninstall)
- [FAQ](#faq)

## What it does

- **`nook`**: a **quick picker** — one line under your prompt with your apps; press a letter (or
  arrows + enter) and it runs. It disappears when you're done.
- **`nook -d`**: a **full-screen dashboard** in one of four layouts (card row, info panel, command
  palette, classic list), with a logo, the date and time, your apps and their keys.
- **`nook -p`**: a **project picker** — your recent projects (folders you visit often first, with
  [zoxide](https://github.com/ajeetdsouza/zoxide)), a scrollable preview of the folder or file, and
  an input that suggests paths as you type (hidden folders and files too, once you type the start of
  their name). Open the project in your editor, or with alt + a key in another app.
- **`nook salat`**: today's prayer times and the next one with a countdown (optional).
- Everything is set in **one file** (`config.psd1`): apps, keys, icons, colors, logo, projects.
  Mistakes in it are shown in red instead of breaking anything.

## Install

You need **PowerShell 7** (`winget install Microsoft.PowerShell`) and a **[Nerd Font](https://www.nerdfonts.com)**
selected in your terminal (for the icons). Windows Terminal is recommended. Optional:
[zoxide](https://github.com/ajeetdsouza/zoxide) (projects you visit often first),
[eza](https://github.com/eza-community/eza) (folder previews with icons),
[bat](https://github.com/sharkdp/bat) (file previews with colors).

**With git (recommended, lets `nook update` work):**

```powershell
git clone https://github.com/Tahaldr/TermNook "$HOME\.termnook"
& "$HOME\.termnook\install.ps1"              # adds TermNook to your profile
& "$HOME\.termnook\install.ps1" -Dashboard   # or: also open the dashboard in every new tab
```

**Without git:** download the ZIP from the green **Code** button, unzip it to `~\.termnook`, and run
`install.ps1` the same way.

**By hand:** add this to your profile (`notepad $PROFILE`):

```powershell
. "$HOME\.termnook\termnook.ps1"
# optional: the dashboard in every new tab (put it before slow prompt tools like oh-my-posh)
if (-not $env:NOOK_STARTED -and $env:TERM_PROGRAM -ne 'vscode') { $env:NOOK_STARTED = 1; nook -Dashboard }
```

Open a new tab and run `nook --help`. The first time, TermNook copies `config.example.psd1` to
`config.psd1` — that's your settings file.

## Update

```powershell
nook update            # install the newest release
nook update --check    # only tell me if there's a newer one
```

TermNook checks for a new release at most once a day (in the background) and the dashboard shows
**↑ TermNook x.y.z is out** when there is one. `nook update` installs it right away: git clones pull
it, other copies download the release and replace only the program's files.

**Your settings are never touched**: `config.psd1`, your own logos (`my-*.txt`) and everything TermNook
saves (`recent.txt`, `style.txt`, `prayer.json`, `update.json`) aren't part of the program, so an update
can't overwrite them. New settings added in later versions get their default until you add them to your
`config.psd1` (`config.example.psd1` always lists every setting).

## Use it

| Command | Does |
| --- | --- |
| `nook` | quick picker under the prompt |
| `nook -d` | dashboard in your saved layout |
| `nook -d -style info` | dashboard once in another layout: `cards`, `info`, `palette`, `list` |
| `nook -p` | project picker |
| `nook salat` | prayer times (when set up) |
| `nook config` | open your settings in your editor (`$env:EDITOR`, else Nvim, VS Code or Notepad) |
| `nook -reload` | read the settings again now (it also notices changes by itself) |
| `nook update` | install the newest release (`--check` only checks) |
| `nook --version`, `nook --help` | version, all of this |

## Configure

Everything lives in `config.psd1` (open it with `nook config`). It's a PowerShell data file:
`@{ Key = value }`. Save it and the next `nook` picks up the change. If something's wrong, the
dashboard shows a short red line and `nook --help` lists the problems.

| Setting | What it does |
| --- | --- |
| `Style` | default dashboard layout: `cards`, `info`, `palette` or `list` (`t` in the dashboard picks one and remembers it) |
| `Logo` | text file shown as the logo, or `''` for none |
| `GitHub` | your GitHub user, shown as a ctrl+click link in the info layout (`''` hides it) |
| `Theme` | colors as `#rrggbb` |
| `Hints` | `$true` shows the key hint lines; `$false` shows only `? keys` (`h` on the `?` page toggles it and remembers it) |
| `Recent` | `$true` puts the apps you used last first, `$false` keeps your order |
| `Prayer` | `@{ City = '...'; Country = '...'; Method = 3 }`, or `City = ''` for off |
| `Apps` | your apps (below) |
| `Projects` | where projects are found and what opens them (below) |

### Adding apps

Each app is one line in `Apps`:

```powershell
Apps = @(
    @{ Name = 'Nvim';   Hint = 'editor';  Key = 'n'; Icon = 0xF36F;  Run = 'nvim .' }
    @{ Name = 'Notes';  Hint = 'obsidian'; Key = 'b'; Icon = 0xF0B6E; Run = 'obsidian' }
    @{ Name = 'Music';  Hint = 'spotify'; Key = 'm'; Icon = 0xF04C7; Run = 'start spotify:' }
    @{ Name = 'Shell';  Hint = 'prompt';  Key = 's'; Icon = 0xEBC7 }      # no Run: back to the prompt
)
```

- **Name** (required): the label. **Hint**: the small description under it.
- **Key**: one letter that opens it directly. `t`, `q`, `o` and `x` are taken by TermNook.
- **Icon**: a code from the [Nerd Fonts cheat sheet](https://www.nerdfonts.com/cheat-sheet): `f36f`
  there is `0xF36F` here.
- **Run**: the command, exactly as you'd type it in PowerShell (`code .`, `lazygit`, `start https://...`,
  a script path…). Leave it out for a "back to the prompt" item.

Add as many as you like; every layout adapts and wraps.

### Projects and "open with"

```powershell
Projects = @{
    Roots    = @('~\code', '~\work')       # searched for projects: folders with .git, package.json, go.mod, …
    OpenWith = @('Nvim', 'VS Code', 'Shell') # names from Apps: the first opens on enter, others with alt + their key
    Search   = '~'                          # where typed paths start (~\ and C:\ paths work too)
    Skip     = @('AppData', 'node_modules') # not suggested until you type the start of their name
}
```

In the project picker, type a name or a path. A path that doesn't exist yet is offered to be created (`y`): a name with an extension (`notes.md`) becomes a file, anything else a folder, with every missing folder on the way. Then: `→` accepts the grey suggestion, `tab` lists what's
inside, `enter` opens the project in the first `OpenWith` app and `alt` + a key opens it in another.
An `OpenWith` app without `Run` just goes to the folder.

### Layouts, colors and logo

- Press **`t`** in the dashboard to switch layouts; your pick is saved (`style.txt`) and wins over `Style`.
- `Theme` takes `GradFrom` / `GradTo` (the logo's gradient), `Accent`, `Text`, `Muted`, `SelBg`, `SelHint` and `Hot`.
- For your own logo, make a text file (block letters work well, e.g. from a "figlet" / "ANSI Shadow"
  generator), call it e.g. `my-logo.txt` and set `Logo = 'my-logo.txt'`. Files called `my-*.txt` are
  never touched by updates.

### Prayer times

```powershell
Prayer = @{ City = 'London'; Country = 'United Kingdom'; Method = 3 }
```

The times come from [aladhan.com](https://aladhan.com) once a month (saved in `prayer.json`). `Method`
is the calculation method ([list](https://aladhan.com/calculation-methods)). They show under the clock
with the next prayer and a countdown, and `nook salat` prints them under the prompt.

## Keys

| Where | Keys |
| --- | --- |
| Quick picker | `←` `→` / `tab` move · `enter` open · an app's letter opens it · `esc` / `q` cancel |
| Dashboard | arrows / `tab` move · `enter` open · an app's letter opens it · `o` projects · `t` layouts · `x` close the terminal tab (`ctrl+o` / `ctrl+t` / `ctrl+x` in the palette layout, where letters filter) · `q` / `esc` back to the prompt · `?` shortcuts page |
| Project picker | type a name or path · `→` accept the suggestion · `tab` list inside (again to go deeper) · `↑` `↓` move · `ctrl+→` or a click: into the preview (`↑↓ PgUp PgDn Home End` scroll it, `←` / `esc` back) · mouse wheel scrolls what it's over · click selects · `ctrl+backspace` remove the last part of the path · `enter` open (a typed path ending in `\` opens that folder until you pick an entry) · `alt` + key open with · `esc` cancel · `?` shortcuts page |

On the `?` page, `h` hides or shows the hint lines at the bottom of each screen. Hidden, only `? keys` stays.

## Files

All in the TermNook folder (`~\.termnook`):

| File | | Updated by `nook update`? |
| --- | --- | --- |
| `termnook.ps1` | the program | yes |
| `config.example.psd1` | every setting, explained | yes |
| `logo.txt` | the default logo | yes |
| `install.ps1`, `README.md`, `LICENSE` | | yes |
| `config.psd1` | **your settings** | never |
| `my-*.txt` | your own logo(s) | never |
| `style.txt`, `hints.txt`, `recent.txt`, `prayer.json`, `update.json` | saved while you use it | never |

## Uninstall

Remove the TermNook lines from your profile (`notepad $PROFILE`) and delete the `~\.termnook` folder.

## FAQ

**The icons are boxes.** Select a Nerd Font in your terminal settings.

**The dashboard opens in every pane of my multiplexer / in VS Code.** The profile line skips VS Code;
add a check for your tool's environment variable the same way (`-and -not $env:YOUR_VAR`).

**Does it work on macOS or Linux?** It's made for Windows Terminal; PowerShell 7 on other systems may
work but isn't tested.

**Something looks wrong in my config.** Run `nook --help`: problems are listed at the bottom in red.

## License

MIT — see [LICENSE](LICENSE).
