Option Explicit

Dim shell, fso, scriptDir, scriptPath, quote, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fso.BuildPath(scriptDir, "ClockWidget.ps1")
quote = Chr(34)
command = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File " & quote & scriptPath & quote

If WScript.Arguments.Named.Exists("check") Then
    WScript.Echo command
    WScript.Quit 0
End If

shell.Run command, 0, False
