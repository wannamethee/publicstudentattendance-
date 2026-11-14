Set WshShell = CreateObject("WScript.Shell")
WshShell.CurrentDirectory = "c:\schooltranscription"
WshShell.Run "cmd /c c:\schooltranscription\run_background.bat", 0, False
