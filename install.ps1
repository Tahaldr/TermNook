# TermNook installer: adds TermNook to your PowerShell profile.
#   git clone https://github.com/Tahaldr/TermNook "$HOME\.termnook"
#   & "$HOME\.termnook\install.ps1"            # the nook command in every tab
#   & "$HOME\.termnook\install.ps1" -Dashboard # and the dashboard when a tab opens
param([switch]$Dashboard)

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host 'TermNook needs PowerShell 7: https://aka.ms/powershell (winget install Microsoft.PowerShell)' -ForegroundColor Red
    return
}
$dir = $PSScriptRoot
$line = ". `"$dir\termnook.ps1`""
if (-not (Test-Path $PROFILE)) { New-Item -ItemType File -Force $PROFILE | Out-Null }
$text = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
if ($text -and $text.Contains('termnook.ps1')) {
    Write-Host "TermNook is already in your profile ($PROFILE)." -ForegroundColor DarkGray
} else {
    $add = "`n# TermNook: app launcher, dashboard and project picker`n$line`n"
    if ($Dashboard) {
        $add += "if (-not `$env:NOOK_STARTED -and `$env:TERM_PROGRAM -ne 'vscode') { `$env:NOOK_STARTED = 1; nook -Dashboard }`n"
    }
    # at the top, so the dashboard shows before slower prompt tools load
    Set-Content $PROFILE -Value ($add + $text) -Encoding utf8
    Write-Host "Added TermNook to $PROFILE" -ForegroundColor Green
}
. "$dir\termnook.ps1"
nook -reload | Out-Null
Write-Host @"

Done. Open a new tab, then try:
  nook          quick picker
  nook -d       dashboard
  nook -p       project picker
  nook config   your settings ($dir\config.psd1)
  nook --help   everything else

Icons need a Nerd Font in your terminal: https://www.nerdfonts.com
"@
