@echo off
rem Creates the virtual environment and installs everything. Safe to run again to update.
cd /d "%~dp0"
if not exist .venv\Scripts\python.exe (
    C:\Python312\python.exe -m venv .venv || exit /b 1
)
.venv\Scripts\python.exe -m pip install --upgrade pip || exit /b 1
.venv\Scripts\python.exe -m pip install torch==2.11.0 torchvision==0.26.0 torchaudio==2.11.0 --index-url https://download.pytorch.org/whl/cu128 || exit /b 1
.venv\Scripts\python.exe -m pip install --upgrade -r requirements.txt || exit /b 1
.venv\Scripts\python.exe -m pip install --no-deps -e . || exit /b 1
copy /y .venv\Scripts\zitto.exe zitto.exe >nul || exit /b 1
echo.
echo Ready. Double-click window.bat, or use zitto.exe from a terminal.
