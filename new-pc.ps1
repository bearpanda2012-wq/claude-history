# new-pc.ps1 - set up claude-setup on a new Windows computer with ONE command.
#   Run (Win+R, cmd or PowerShell):
#     powershell -ep bypass -c "irm https://raw.githubusercontent.com/bearpanda2012-wq/claude-history/main/new-pc.ps1 | iex"
# What it does (safe to run again on a computer that is already set up):
#   1. installs Git and Node.js LTS with winget if missing
#   2. git settings: long paths + browser login (Git Credential Manager)
#   3. clones the private claude-setup repo (or repairs a broken/partial clone)
#   4. runs "node sync.mjs setup"  -> you type the passphrase here (never in chat; skipped if already saved)
#   5. Google Drive upload, automatically, if the Rhino work folder exists on this computer
#   6. if ArtCAM 2018 is installed: clones/updates the private artcam-mcp repo, runs npm install,
#      and installs the in-app bridge (one Windows admin prompt)
# No y/n questions. The only things you may be asked for: Windows "Yes" prompts, GitHub / Google sign-in
# in the browser (first time only) and the passphrase (first time only).
# No secrets live in this file.
$ErrorActionPreference = 'Continue'   # 'Stop' would turn git's normal stderr chatter into errors in Windows PowerShell 5.1
$Repo   = 'https://github.com/bearpanda2012-wq/claude-setup.git'
$Dir    = Join-Path $env:USERPROFILE 'claude-setup'
$Rhino  = 'D:\Template Rhino'
$ArtCAM = Join-Path $env:ProgramFiles 'Autodesk\ArtCAM 2018\Exec\ArtCAMPro.exe'
$ArtRepo = 'https://github.com/bearpanda2012-wq/artcam-mcp.git'
$ArtDir  = Join-Path $env:USERPROFILE 'artcam-mcp'   # must match the path in the synced "artcam" MCP entry

function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "    OK  $m" -ForegroundColor Green }
function Die($m)  { Write-Host "`n[X] $m" -ForegroundColor Red; Read-Host 'Press Enter to close'; exit 1 }
function RefreshPath { $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User') }
function Has($c) { [bool](Get-Command $c -ErrorAction SilentlyContinue) }
function RunGit { & git @args; if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed (exit $LASTEXITCODE)" } }

function Need($cmd, $id, $name) {
  if (Has $cmd) { Ok "$name found"; return }
  if (-not (Has 'winget')) { Die "$name is missing and winget is not available. Install $name by hand, then run this again." }
  Write-Host "    installing $name (a Windows prompt may ask for permission)..."
  & winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements | Out-Host
  RefreshPath
  if (-not (Has $cmd)) {
    foreach ($p in @("$env:ProgramFiles\Git\cmd", "$env:ProgramFiles\nodejs")) { if (Test-Path $p) { $env:Path += ";$p" } }
  }
  if (-not (Has $cmd)) { Die "$name was installed but is not on PATH yet. Close this window and run the same command again." }
  Ok "$name installed"
}

Write-Host "claude-setup for a new computer: $env:COMPUTERNAME ($env:USERNAME)" -ForegroundColor Yellow

Step 'Checking Git and Node.js'
Need 'git'  'Git.Git'           'Git'
Need 'node' 'OpenJS.NodeJS.LTS' 'Node.js'

Step 'Git settings'
RunGit config --global core.longpaths true
$helper = (& git config --global credential.helper) 2>$null
if (-not $helper) { RunGit config --global credential.helper manager }
# commits fail without an identity; use the public GitHub no-reply address (no private email in this public file)
if (-not ((& git config --global user.email) 2>$null)) {
  RunGit config --global user.name 'Bear'
  RunGit config --global user.email 'bearpanda2012-wq@users.noreply.github.com'
}
Ok 'long paths on, browser login on, git identity set'

Step "Getting claude-setup into $Dir  (a browser window may ask you to log in to GitHub)"
if (Test-Path (Join-Path $Dir '.git')) {
  Push-Location $Dir
  try {
    RunGit fetch -q origin main
    RunGit checkout -q -f -B main FETCH_HEAD      # also repairs a half-finished first clone
    & git branch -q -u origin/main 2>$null | Out-Null
    if (-not (Test-Path "machines\$env:COMPUTERNAME.json")) {
      Remove-Item (Join-Path $env:USERPROFILE '.claude-setup\state.json') -ErrorAction SilentlyContinue   # forget a failed first run
    }
  } catch { Pop-Location; Die "Could not update the existing folder: $_" }
  Pop-Location
  Ok 'existing folder updated'
} else {
  if (Test-Path $Dir) {
    $bak = "$Dir.old-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Rename-Item $Dir $bak -ErrorAction Stop
    Write-Host "    an incomplete folder was moved aside to $bak"
  }
  try { RunGit clone -q $Repo $Dir } catch { Die "Clone failed. Log in to GitHub as bearpanda2012-wq in the browser window, then run this again. ($_)" }
  Ok 'cloned'
}

Step 'Running setup  (type your passphrase when asked - the same one as on your other computers)'
Push-Location $Dir
& node sync.mjs setup
$code = $LASTEXITCODE
Pop-Location
if ($code -ne 0) { Die "setup stopped with an error (exit $code). Take a screenshot of this window and send it to Claude." }

if (Test-Path $Rhino) {
  Step "Google Drive upload for '$Rhino'  (first time: sign in to Google in the browser and click Allow)"
  Push-Location $Dir; & node sync.mjs setup-drive; Pop-Location
}

if (Test-Path $ArtCAM) {
  Step "ArtCAM 2018 found - installing the artcam MCP server into $ArtDir"
  try {
    if (Test-Path (Join-Path $ArtDir '.git')) {
      Push-Location $ArtDir; RunGit pull -q --ff-only; Pop-Location
    } else {
      RunGit clone -q $ArtRepo $ArtDir
    }
    Push-Location $ArtDir
    & npm install --no-audit --no-fund --silent | Out-Host
    $npmCode = $LASTEXITCODE
    Pop-Location
    if ($npmCode -ne 0) { throw "npm install failed (exit $npmCode)" }
    Ok 'artcam-mcp ready (the "artcam" MCP entry arrives with the synced settings)'
    $frame = Join-Path $env:ProgramFiles 'Autodesk\ArtCAM 2018\Html\ArtCAMSideBar\AssistantProFrame.htm'
    if (-not (Select-String -Path $frame -Pattern 'McpBridge.js' -Quiet)) {
      Write-Host '    installing the ArtCAM in-app bridge (Windows asks for permission - click Yes)...'
      try {
        Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $ArtDir 'bridge\install-bridge.ps1'), '-NoPause'
      } catch { }   # "No" on the Windows prompt lands here
      if (Select-String -Path $frame -Pattern 'McpBridge.js' -Quiet) { Ok 'ArtCAM bridge installed (restart ArtCAM if it is open)' }
      else { Write-Host '    [!] bridge not installed - run bridge\install-bridge.ps1 as admin later.' -ForegroundColor Yellow }
    } else { Ok 'ArtCAM bridge already installed' }
  } catch {
    Write-Host "    [!] artcam-mcp was not installed: $_  - the rest of the setup is fine." -ForegroundColor Yellow
  }
}

Write-Host "`n================================================================" -ForegroundColor Green
Write-Host " DONE. This computer ($env:COMPUTERNAME) is now synced."            -ForegroundColor Green
Write-Host " Last step: Quit Claude Desktop (right-click the tray icon > Quit)" -ForegroundColor Green
Write-Host " and open it again, so it loads the MCP servers and skills."        -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host 'This window closes by itself in 30 seconds.'
Start-Sleep -Seconds 30
