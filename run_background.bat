@echo off
cd /d "c:\schooltranscription"
rem stop the previous API server (whatever is listening on 8000)
for /f "tokens=5" %%a in ('netstat -aon ^| findstr :8000 ^| findstr LISTENING 2^>nul') do taskkill /f /pid %%a >nul 2>&1
rem stop any tunnel left from an earlier start: ngrok free allows one session at a time, so leftovers
rem pile up on every restart and knock each other off the domain until the public link stops answering
rem (ERR_NGROK_6030). PowerShell, not wmic: wmic is gone from Windows 11, so the old line found nothing and
rem 29 tunnels (~70 MB each) had piled up by 12 Nov 2026.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'node.exe' -and $_.CommandLine -like '*start_ngrok*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }" >nul 2>&1
timeout /t 2 /nobreak >nul
start /b "" node start_ngrok.js
python -m uvicorn main:app --host 0.0.0.0 --port 8000
