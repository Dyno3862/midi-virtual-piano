' ---- Zero-console launcher for the MIDI -> Virtual Piano Player ----
' Double-click this instead of run.bat for a completely windowless start.
Set sh = CreateObject("WScript.Shell")
dir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
sh.CurrentDirectory = dir
' run run.bat hidden (window style 0); it installs mido if needed, then
' launches the GUI via pythonw and exits -- nothing visible but the app.
sh.Run "cmd /c """ & dir & "run.bat""", 0, False
