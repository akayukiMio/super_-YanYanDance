' Launch the gallery web console with the host window completely hidden.
' WindowStyle 0 = hidden: no cmd window stays on screen.
' To stop the service: open http://127.0.0.1:8787/ and click the power button.
Set ws = CreateObject("WScript.Shell")
ws.CurrentDirectory = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
ws.Run "node web\server.mjs --open", 0, False
