Option Explicit

Dim shell
Dim psPath
Dim scriptPath
Dim extraArgs
Dim command
Dim exitCode

If WScript.Arguments.Count < 1 Then
  WScript.Quit 1
End If

Set shell = CreateObject("WScript.Shell")
psPath = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
scriptPath = WScript.Arguments(0)

extraArgs = ""
If WScript.Arguments.Count >= 2 Then
  extraArgs = WScript.Arguments(1)
End If

command = Quote(psPath) & " -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Quote(scriptPath)
If Len(extraArgs) > 0 Then
  command = command & " " & extraArgs
End If

exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode

Function Quote(value)
  Quote = Chr(34) & Replace(CStr(value), Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function

