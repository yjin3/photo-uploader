Option Explicit

Dim files, shell, root, pythonw, launcher, command
Set files = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
root = files.GetParentFolderName(WScript.ScriptFullName)
pythonw = files.BuildPath(root, ".venv\Scripts\pythonw.exe")
launcher = files.BuildPath(root, "Photo Uploader.pyw")

If Not files.FileExists(pythonw) Then
    MsgBox "Python environment not found. Run these commands in the project folder:" & vbCrLf & vbCrLf & _
        "python -m venv .venv" & vbCrLf & _
        ".venv\Scripts\python -m pip install -r pc_server\requirements.txt", vbExclamation, "Photo Uploader"
    WScript.Quit 1
End If
If Not files.FileExists(launcher) Then
    MsgBox "Photo Uploader.pyw was not found. Keep this launcher in the project folder.", vbExclamation, "Photo Uploader"
    WScript.Quit 1
End If

shell.CurrentDirectory = root
command = Chr(34) & pythonw & Chr(34) & " " & Chr(34) & launcher & Chr(34)
On Error Resume Next
shell.Run command, 0, False
If Err.Number <> 0 Then
    MsgBox "Unable to start Photo Uploader: " & Err.Description, vbExclamation, "Photo Uploader"
    WScript.Quit 1
End If
