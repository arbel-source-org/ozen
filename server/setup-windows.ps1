param([string]$Dir = 'C:\ozen')
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

New-Item -Force -ItemType Directory $Dir | Out-Null
icacls $Dir /inheritance:r /grant:r "${env:USERNAME}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "could not limit $Dir to $env:USERNAME" }
$python = Join-Path $Dir 'python\python.exe'
if (-not (Test-Path $python)) {
    $installer = Join-Path $Dir 'python-installer.exe'
    Invoke-WebRequest -UseBasicParsing 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe' -OutFile $installer
    Start-Process -Wait $installer -ArgumentList '/quiet', 'InstallAllUsers=0', 'PrependPath=0', 'Include_launcher=0', 'Include_test=0', 'Include_doc=0', 'Include_tcltk=0', 'Shortcuts=0', "TargetDir=$Dir\python"
    Remove-Item $installer
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
$run = @(
    '@echo off'
    "cd /d `"$Dir`""
    "set PATH=$site\cublas\bin;$site\cudnn\bin;%PATH%"
    "set HF_HOME=$Dir\hf"
    "set /p OZEN_TOKEN=<`"$codeFile`""
    "`"$venvPython`" `"$Dir\ozen_server.py`" >> `"$Dir\server.log`" 2>&1"
) -join "`r`n"
[IO.File]::WriteAllText((Join-Path $Dir 'run.cmd'), $run + "`r`n")

$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\cmd.exe" -Argument "/c `"$Dir\run.cmd`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType S4U -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName 'Ozen server' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Stop-ScheduledTask -TaskName 'Ozen server' -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "name='python.exe'" |
    Where-Object { $_.CommandLine -like "*$Dir\ozen_server.py*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep 3
for ($i = 0; $i -lt 5 -and (Get-ScheduledTask -TaskName 'Ozen server').State -ne 'Running'; $i++) {
    Start-ScheduledTask -TaskName 'Ozen server'
    Start-Sleep 2
}
if ((Get-ScheduledTask -TaskName 'Ozen server').State -ne 'Running') { throw 'the Ozen server task did not start' }

Write-Output ''
Write-Output "Set up in $Dir. The server starts with Windows and restarts itself if it stops."
Write-Output "Pairing code: $(Get-Content $codeFile)"
Write-Output ('Log: ' + (Join-Path $Dir 'server.log'))
& $venvPython (Join-Path $Dir 'pairing.py') --code-file $codeFile --out (Join-Path $Dir 'pairing.html')
