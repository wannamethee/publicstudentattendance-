' Scheduled every 5 minutes by setup_standby_windows.bat: copy the Linux server's data here, silently.
' While this machine is serving instead of Linux (takeover), it keeps the server up and Linux parked.
Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = "c:\schooltranscription"
sh.Run "cmd /c python standby_sync.py sync", 0, True
