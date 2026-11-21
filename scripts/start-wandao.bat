@echo off
REM ============================================================
REM  WandaoHermes launcher (portable / share-build friendly)
REM  ASCII-only on purpose: console is GBK on CN Windows and
REM  non-ASCII inside .bat turns into mojibake.
REM ============================================================
setlocal
set "ROOT=%~dp0"

if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"

if not exist "%ROOT%\logs" mkdir "%ROOT%\logs"

set "LAUNCHLOG=%ROOT%\logs\launcher.log"

echo [%DATE% %TIME%] launcher start ROOT=%ROOT% >> "%LAUNCHLOG%"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
set "KERNEL=%ROOT%\kernel\run"
set "TOOLS=%ROOT%\tools"
set "LOGS=%ROOT%\logs"
set "DATA=%ROOT%\data"
set "CONFIG=%ROOT%\config"

set "PY=%TOOLS%\python\pythonw.exe"
set "NODE=%TOOLS%\node\node.exe"

set "WANDAO_ROOT=%ROOT%"
set "WANDAO_HOME=%DATA%\_wandao"
set "WANDAO_GW=http://127.0.0.1:42200"
set "WANDAO_GW_NO_AUTH=1"
set "WANDAO_SINGLE_SESSION=1"
set "HERMES_HOME=%DATA%\home"
set "HERMES_DESKTOP_ISOLATED_BACKEND=0"
set "HERMES_PROBE_TIMEOUT_MS=60000"
set "WANDAO_MAX_WALL_SEC=600"
set "WANDAO_MEMORY_DB=%DATA%\memory.db"
set "WANDAO_TRACE_DIR=%DATA%\traces"
set "WANDAO_RUNS_DIR=%DATA%\runs"
set "WANDAO_VM_DIR=%DATA%\vm"
set "WANDAO_SANDBOX=jailed"
set "WANDAO_HUB_AUTO_ANSWER=1"

REM dirs must exist, otherwise every redirect below fails silently
if not exist "%LOGS%" mkdir "%LOGS%"
if not exist "%DATA%" mkdir "%DATA%"
if not exist "%DATA%\_wandao" mkdir "%DATA%\_wandao"
if not exist "%DATA%\home" mkdir "%DATA%\home"
if not exist "%DATA%\traces" mkdir "%DATA%\traces"
if not exist "%DATA%\runs" mkdir "%DATA%\runs"
if not exist "%DATA%\vm" mkdir "%DATA%\vm"

if not exist "%PY%" (
  echo [ERROR] Python runtime not found: %PY%
  echo         The kernel package looks incomplete. Re-extract the kernel archive into %ROOT%
  pause
  exit /b 1
)
if not exist "%KERNEL%\chat_server.py" (
  echo [ERROR] Kernel not found: %KERNEL%\chat_server.py
  echo         Re-extract the kernel archive into %ROOT%
  pause
  exit /b 1
)

if exist "%CONFIG%\secrets.env" (
  for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%CONFIG%\secrets.env") do (
    if not "%%~B"=="" set "%%A=%%B"
  )
)

echo [1/3] kernel  127.0.0.1:42200
netstat -ano | findstr /r /c:"127.0.0.1:42200 .*LISTENING" >nul 2>&1
if errorlevel 1 start "" /b "%PY%" -X utf8 -u "%KERNEL%\chat_server.py" --task-approve-writes >> "%LOGS%\kernel-boot.log" 2>&1

echo [2/3] hub     127.0.0.1:42210
netstat -ano | findstr /r /c:"127.0.0.1:42210 .*LISTENING" >nul 2>&1
if errorlevel 1 start "" /b "%PY%" -X utf8 -u "%KERNEL%\hub_server.py" >> "%LOGS%\hub.log" 2>&1

echo [3/3] weixin bridge + proactive
netstat -ano | findstr /r /c:"127.0.0.1:42202 .*LISTENING" >nul 2>&1
if errorlevel 1 start "" /b "%PY%" -X utf8 -u "%KERNEL%\weixin_bridge.py" >> "%LOGS%\weixin-bridge.log" 2>&1
powershell -NoProfile -Command "if (Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*proactive.py*' }) { exit 0 } else { exit 1 }" >nul 2>&1
if errorlevel 1 start "" /b "%PY%" -X utf8 -u "%KERNEL%\proactive.py" >> "%LOGS%\proactive.log" 2>&1

REM optional: local postgres (only when the package carries it)
set "PGBIN=%ROOT%\tools\pgsql\Library\bin"
if exist "%PGBIN%\pg_ctl.exe" (
  "%PGBIN%\pg_ctl.exe" -D "%ROOT%\data\pg" status >nul 2>&1
  if errorlevel 1 "%PGBIN%\pg_ctl.exe" -D "%ROOT%\data\pg" -o "-p 5433" -l "%LOGS%\pg.log" -w start >nul 2>&1
)

echo.
echo.

echo Kernel is starting on 127.0.0.1:42200 .

echo If the desktop app shows no reply, check: %LOGS%\kernel-boot.log

echo.

if exist "%ROOT%\shell\app\electron.exe" (
  echo Opening desktop shell ...
  start "" "%ROOT%\shell\app\electron.exe" "%ROOT%\shell\app" --remote-debugging-port=9333
) else (
  echo Desktop shell not bundled here - open the installed WandaoHermes app.
)



echo.

echo Done. Press any key to close this window.

pause >nul

