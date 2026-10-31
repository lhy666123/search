@echo off
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0ShortcutRestorer.ps1"
if errorlevel 1 (
    echo.
    echo The tool failed to start or returned an error.
    echo Press any key to exit...
    pause >nul
)
endlocal
