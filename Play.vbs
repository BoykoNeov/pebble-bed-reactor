Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

projectDir = fso.GetParentFolderName(WScript.ScriptFullName)

godotExe = ""
On Error Resume Next
pathResult = shell.Exec("where godot").StdOut.ReadLine()
On Error Goto 0
If Len(pathResult) > 0 And fso.FileExists(pathResult) Then
    godotExe = pathResult
End If

If godotExe = "" Then
    candidate = shell.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\Microsoft\WinGet\Links\godot.exe"
    If fso.FileExists(candidate) Then
        godotExe = candidate
    End If
End If

If godotExe = "" Then
    MsgBox "Could not find Godot. Install Godot 4.x, or edit Play.vbs to point at your godot.exe.", vbExclamation, "Pebble Bed"
    WScript.Quit 1
End If

shell.Run """" & godotExe & """ --path """ & projectDir & """", 1, False
