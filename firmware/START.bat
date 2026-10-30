@echo off
REM Double-click to open the Incubator installer
cd /d "%~dp0"
python --version >nul 2>&1 || (echo Python is not installed. Get it from python.org and tick "Add python.exe to PATH". & pause & exit /b 1)
python -c "import esptool, mpremote, serial" >nul 2>&1 || (echo Installing esptool + mpremote + pyserial, about 5 MB... & python -m pip install esptool mpremote pyserial)
start "" pythonw installer.py || python installer.py
