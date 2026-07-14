@echo off
REM ---- Launch the MIDI -> Virtual Piano Player (no lingering console) ----
cd /d "%~dp0"

REM console python for setup; windowless python (pythonw) for the GUI itself
set "PY=python"
set "PYW=pythonw"
where py  >nul 2>&1 && set "PY=py -3"
where pyw >nul 2>&1 && set "PYW=pyw -3"

REM ensure mido is installed for this interpreter (only prints on first run)
%PY% -c "import mido" >nul 2>&1
if errorlevel 1 (
    echo Installing required package "mido" ^(first run only^)...
    %PY% -m pip install mido
    if errorlevel 1 (
        echo.
        echo Could not install mido automatically. Run manually:
        echo     %PY% -m pip install mido
        pause
        exit /b 1
    )
)

REM start the GUI detached with no console window, then close this one
start "" %PYW% "%~dp0midi_piano_player.py"
exit
