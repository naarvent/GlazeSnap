' Starts autotiling.mjs with no console window (that is what the 0 does).
' GlazeWM opens this file from startup_commands (`shell-exec %USERPROFILE%\...`),
' and the .vbs association hands it to wscript. It expands %USERPROFILE% rather
' than hardcoding a path, so it needs no rewriting on another machine.
Set sh = CreateObject("WScript.Shell")
path = sh.ExpandEnvironmentStrings("%USERPROFILE%\.glzr\glazewm\autotiling.mjs")
sh.Run "node """ & path & """", 0, False
