' run.vbs — launcher detached per Main.ps1
Option Explicit
Dim shell, fso, scriptDir, psPath, cmd
Set shell = CreateObject("WScript.Shell")
Set fso   = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
psPath    = scriptDir & "\src\Main.ps1"
If Not fso.FileExists(psPath) Then
    MsgBox "File non trovato:" & vbCrLf & psPath, vbCritical, "Launcher"
    WScript.Quit 1
End If
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & psPath & """"
shell.Run cmd, 0, False
