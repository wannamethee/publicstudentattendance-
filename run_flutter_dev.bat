@echo off
chcp 65001 > nul
echo ===================================================
echo   Flutter Frontend Development Server (Hot Reload)
echo ===================================================
echo.
cd /d "%~dp0frontend"
flutter run -d chrome
pause
