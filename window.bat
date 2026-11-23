@echo off
rem Opens the window. For the command line use zitto.exe: a .bat would cut
rem arguments at the first "&" when called from PowerShell.
if not exist "%~dp0.venv\Scripts\pythonw.exe" (
    echo Run setup.bat first.
    pause
    exit /b 1
)
cd /d "%~dp0"
start "" ".venv\Scripts\pythonw.exe" -m zitto
