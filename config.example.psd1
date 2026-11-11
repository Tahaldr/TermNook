# TermNook settings. TermNook copies this file to config.psd1 the first time it runs;
# edit config.psd1 (nook config opens it), then open a new tab or run: nook -reload
# Updates never change config.psd1.
@{
    # Default dashboard layout: cards, info, palette or list.
    # Changing it with  t  inside the dashboard saves your pick in style.txt, which wins over this.
    Style  = 'cards'

    # Logo shown on the dashboard: a text file next to this one ('' for none).
    # Make your own (e.g. my-logo.txt) so updates never replace it.
    Logo   = 'logo.txt'

    # Your GitHub user, shown as a Ctrl+click link in the info panel. '' hides the row.
    GitHub = ''

    # Colors (#rrggbb). These are NvChad's onedark values.
    Theme = @{
        GradFrom = '#61afef'   # logo gradient start
        GradTo   = '#c678dd'   # logo gradient end, palette prompt
        Accent   = '#61afef'   # icons, selection, borders
        Text     = '#abb2bf'   # normal text
        Muted    = '#565c64'   # hints and help
        SelBg    = '#3e4451'   # list selection background, dim borders
        SelHint  = '#818792'   # hint text on the selected item
        Hot      = '#e7c787'   # the "t themes" shortcut
    }

    # Put the apps you used last first (remembered in recent.txt). $false keeps the order below.
    Recent = $false

    # Today's prayer times under the clock, the next one highlighted with a countdown.
    # Times come from api.aladhan.com once a month (saved in prayer.json). City = '' turns it off.
    #   Method  calculation method, see https://aladhan.com/calculation-methods (e.g. 2 = ISNA, 3 = Muslim World League)
    # Example: Prayer = @{ City = 'London'; Country = 'United Kingdom'; Method = 3 }
    Prayer = @{ City = ''; Country = ''; Method = 3 }

    # Your apps, in order. Add or remove as many as you like; every layout adapts.
    #   Name  label shown everywhere (required)
    #   Hint  short description
    #   Key   one letter that opens it directly ('t', 'q', 'o' and 'x' are taken by TermNook)
    #   Icon  Nerd Font code from https://www.nerdfonts.com/cheat-sheet, e.g. 0xF0570 for f0570. Optional
    #   Run   the command to run, exactly as you'd type it. Leave Run out to make a "back to the prompt" item
    Apps = @(
        @{ Name = 'Nvim';     Hint = 'editor';   Key = 'n'; Icon = 0xF36F;  Run = 'nvim .' }
        @{ Name = 'VS Code';  Hint = 'code';     Key = 'v'; Icon = 0xF0A1E; Run = 'code .' }
        @{ Name = 'Git';      Hint = 'lazygit';  Key = 'g'; Icon = 0xF02A2; Run = 'lazygit' }
        @{ Name = 'Files';    Hint = 'explorer'; Key = 'f'; Icon = 0xF024B; Run = 'explorer .' }
        @{ Name = 'Monitor';  Hint = 'btop';     Key = 'm'; Icon = 0xF0128; Run = 'btop' }
        @{ Name = 'Shell';    Hint = 'prompt';   Key = 's'; Icon = 0xEBC7 }
    )

    # Project picker (nook -p, or  o  in the dashboard).
    #   Roots     folders searched for projects (a folder with .git, package.json, go.mod, ...)
    #             Folders you visit often (zoxide) are listed first.
    #   OpenWith  apps (names from Apps above) offered for a project. The first one opens on Enter,
    #             the others with alt + their key (e.g. alt+v). An app without Run just goes to the folder.
    #   Search    paths you type start from this folder (~\ and C:\ paths work too)
    #   Skip      folder names not suggested until you type the start of their name
    Projects = @{
        Roots    = @('~\code', '~\projects', '~\source\repos', '~\Documents\GitHub')
        OpenWith = @('Nvim', 'VS Code', 'Shell')
        Search   = '~'
        Skip     = @('AppData', 'node_modules', 'scoop', 'vendor')
    }
}
