param(
    [string]$Dir = 'C:\ozen',
    [string]$TaskName = 'Ozen server',
    # Skips every question (and the away-from-home setup), for a re-run
    # that only updates the server, and for testing.
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Windows.Forms

# Dialogs from a process Windows elevated can open behind other windows,
# and the setup then looks frozen; a topmost owner keeps them in front.
$dialogOwner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }

function Tell([string]$text, [string]$icon = 'Information') {
    if ($Quiet) { Write-Output $text; return }
    [System.Windows.Forms.MessageBox]::Show($dialogOwner, $text, 'Ozen', 'OK', $icon) | Out-Null
}

function Ask([string]$text) {
    if ($Quiet) { return $false }
    [System.Windows.Forms.MessageBox]::Show($dialogOwner, $text, 'Ozen', 'YesNo', 'Question') -eq 'Yes'
}

# The graphics card decides everything else: without an NVIDIA card the
# server can't run at all, and with a small one the second, more accurate
# model for finished lines doesn't fit next to the fast one (the two hold
# about 7 GB together on an RTX 2080 Ti). Checked before anything is
# downloaded, so a computer that can't do it is told so in a minute, not
# after 5 GB.
# Some drivers don't put nvidia-smi where Windows looks for programs.
$gpu = $null
$smiCandidates = @('nvidia-smi', "$env:SystemRoot\System32\nvidia-smi.exe", "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe")
foreach ($smi in $smiCandidates) {
    if ($gpu) { break }
    try {
        $line = & $smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1
        if ($line) {
            $name, $mib = $line -split ',\s*'
            $gpu = @{ Name = $name.Trim(); GB = [math]::Round([double]$mib / 1024, 1) }
        }
    } catch { }
}
if (-not $gpu) {
    Tell ("This computer has no NVIDIA graphics card that Windows can use, so it can't write captions for Ozen.`n`n" +
        "Ozen needs an NVIDIA card with at least 6 GB of memory (for example an RTX 2060 or 3060) and its normal NVIDIA driver.`n`n" +
        "Nothing was installed. The phone keeps writing captions by itself.") 'Warning'
    exit 1
}
if ($gpu.GB -lt 5.5) {
    Tell ("This computer's graphics card ($($gpu.Name), $($gpu.GB) GB) is too small for Ozen: it needs at least 6 GB.`n`n" +
        "Nothing was installed. The phone keeps writing captions by itself.") 'Warning'
    exit 1
}
$accurate = $gpu.GB -ge 7.5
if (-not $Quiet) {
    $what = if ($accurate) { 'the fast model for live words and the accurate one for finished lines' } else { 'the fast model (the accurate one needs 8 GB)' }
    if (-not (Ask ("Found $($gpu.Name) with $($gpu.GB) GB. Ozen will use $what.`n`n" +
            "Setting up downloads about $(if ($accurate) { '5' } else { '2' }) GB and takes 10-30 minutes. " +
            "The computer then writes captions whenever it is on, even before anyone logs in.`n`nContinue?"))) { exit 0 }
}

New-Item -Force -ItemType Directory $Dir | Out-Null
icacls $Dir /inheritance:r /grant:r "${env:USERNAME}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "could not limit $Dir to $env:USERNAME" }
$python = Join-Path $Dir 'python\python.exe'
if (-not (Test-Path $python)) {
    $installer = Join-Path $Dir 'python-installer.exe'
    Invoke-WebRequest -UseBasicParsing 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe' -OutFile $installer
    $setup = Start-Process -Wait -PassThru $installer -ArgumentList '/quiet', 'InstallAllUsers=0', 'PrependPath=0', 'Include_launcher=0', 'Include_test=0', 'Include_doc=0', 'Include_tcltk=0', 'Shortcuts=0', "TargetDir=$Dir\python"
    Remove-Item $installer
    if ($setup.ExitCode -ne 0 -or -not (Test-Path $python)) { throw "installing Python failed (code $($setup.ExitCode))" }
}

$venvPython = Join-Path $Dir 'venv\Scripts\python.exe'
if (-not (Test-Path $venvPython)) { & $python -m venv (Join-Path $Dir 'venv') }
& $venvPython -m pip install --quiet --upgrade pip
& $venvPython -m pip install --quiet -r (Join-Path $here 'requirements.txt') nvidia-cublas-cu12 'nvidia-cudnn-cu12==9.*'
if ($LASTEXITCODE -ne 0) { throw 'pip install failed' }
Copy-Item (Join-Path $here 'ozen_server.py'), (Join-Path $here 'try_server.py'), (Join-Path $here 'pairing.py') $Dir -Force

$codeFile = Join-Path $Dir 'pairing-code'
if (-not (Test-Path $codeFile)) {
    $code = & $venvPython -c "import secrets; print(secrets.token_urlsafe(12), end='')"
    [IO.File]::WriteAllText($codeFile, $code)
}

$site = Join-Path $Dir 'venv\Lib\site-packages\nvidia'
$options = if ($accurate) { ' --final-model ivrit-ai/whisper-large-v3-ct2' } else { '' }
$run = @(
    '@echo off'
    "cd /d `"$Dir`""
    "set PATH=$site\cublas\bin;$site\cudnn\bin;%PATH%"
    "set HF_HOME=$Dir\hf"
    "set /p OZEN_TOKEN=<`"$codeFile`""
    ':start'
    "for %%F in (`"$Dir\server.log`") do if %%~zF GTR 5000000 move /y `"$Dir\server.log`" `"$Dir\server.log.1`" >nul"
    "`"$venvPython`" `"$Dir\ozen_server.py`"$options >> `"$Dir\server.log`" 2>&1"
    'ping -n 6 127.0.0.1 >nul'
    'goto start'
) -join "`r`n"
[IO.File]::WriteAllText((Join-Path $Dir 'run.cmd'), $run + "`r`n")

# On the home Wi-Fi the phone connects straight to this computer, which
# Windows' firewall blocks unless it's let in (home networks only).
if (-not (Get-NetFirewallRule -DisplayName 'Ozen server' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName 'Ozen server' -Direction Inbound -Protocol TCP -LocalPort 8765 -Profile Private -Action Allow | Out-Null
}

$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\cmd.exe" -Argument "/c `"$Dir\run.cmd`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType S4U -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "name='python.exe'" |
    Where-Object { $_.CommandLine -like "*$Dir\ozen_server.py*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep 3
for ($i = 0; $i -lt 5 -and (Get-ScheduledTask -TaskName $TaskName).State -ne 'Running'; $i++) {
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep 2
}
if ((Get-ScheduledTask -TaskName $TaskName).State -ne 'Running') { throw 'the Ozen server task did not start' }

# Away from home the phone needs an address it can reach from anywhere.
# Tailscale Funnel gives the computer one with a real certificate; only
# the pairing code lets anyone use it. It needs a free Tailscale account,
# signed in once in the browser, so it's offered, not assumed.
$tailscale = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
$pairArgs = @('--lan')
$awayReady = $false
# Signing in and turning Funnel on each wait on a page in the browser,
# and Tailscale may only print that page's address: it is opened here.
# Neither waits for ever, so a closed browser tab can't hang the setup.
function RunTailscale([string[]]$arguments) {
    $out = Join-Path $env:TEMP "ozen-tailscale-$($arguments[0]).txt"
    $proc = Start-Process $tailscale -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    $opened = $false
    for ($i = 0; $i -lt 300 -and -not $proc.HasExited; $i++) {
        Start-Sleep 1
        if (-not $opened) {
            $text = (Get-Content $out, "$out.err" -Raw -ErrorAction SilentlyContinue) -join ' '
            if ($text -match 'https://login\.tailscale\.com/\S+') {
                Start-Process $Matches[0]
                $opened = $true
            }
        }
    }
    if (-not $proc.HasExited) { $proc.Kill() }
}

function FunnelIsOn {
    $status = (& $tailscale funnel status 2>$null) -join "`n"
    $status -match '\(Funnel on\)' -and $status -match '127\.0\.0\.1:8765'
}
if (Test-Path $tailscale) { $awayReady = FunnelIsOn }
if (-not $awayReady -and (Ask ("Should the phone also get captions from this computer away from home (at the doctor, on a visit)?`n`n" +
        "This installs Tailscale, a free service that gives the computer a safe address on the internet. " +
        "A browser window will open once to sign in or make a free account (Google, Microsoft or Apple sign-in works).`n`n" +
        "Choose No to use it only on this home's Wi-Fi. You can run this setup again later to add it."))) {
    # Captions at home already work by now: nothing here may stop the
    # setup before the pairing code is shown.
    try {
        if (-not (Test-Path $tailscale) -and (Get-Command winget -ErrorAction SilentlyContinue)) {
            winget install --id Tailscale.Tailscale -e --silent --accept-package-agreements --accept-source-agreements | Out-Null
        }
        if (Test-Path $tailscale) {
            Tell "Next, a browser window opens to sign in to Tailscale. Come back here when it says you are connected."
            RunTailscale @('up')
            Tell ("If the browser now asks to turn on 'Funnel' for this computer, allow it: that is what lets the phone reach it from outside.")
            RunTailscale @('funnel', '--bg', '8765')
            $awayReady = FunnelIsOn
        }
    } catch {
        $awayReady = $false
    }
    if (-not $awayReady) {
        Tell "Setting up the away-from-home address didn't finish. Captions work on this home's Wi-Fi; run this setup again to try once more." 'Warning'
    }
}
if ($awayReady) { $pairArgs = @() }

$pairingPage = Join-Path $Dir 'pairing.html'
& $venvPython (Join-Path $Dir 'pairing.py') --code-file $codeFile --out $pairingPage --no-open @pairArgs
if ($LASTEXITCODE -ne 0) { throw 'could not make the pairing page' }

$shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'Ozen - pair a phone.lnk'
$link = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut)
$link.TargetPath = $pairingPage
$link.Save()

Write-Output ''
Write-Output "Set up in $Dir. The server starts with Windows and restarts itself if it stops."
Write-Output "Pairing code: $(Get-Content $codeFile)"
Write-Output ('Log: ' + (Join-Path $Dir 'server.log'))
if (-not $Quiet) {
    Tell ("Done. The first start downloads the speech model, so give it about 10 minutes before the first captions.`n`n" +
        "Now a page with a square code opens. On the iPhone, open the Camera, point it at the code, tap the Ozen link and confirm.`n`n" +
        "To show the code again later: Start menu, 'Ozen - pair a phone'.")
    Start-Process $pairingPage
}
