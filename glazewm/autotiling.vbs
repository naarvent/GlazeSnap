' Starts autotiling.mjs with no console window (that is what the 0 does).
' GlazeWM invokes this with `shell-exec wscript ...` from startup_commands.
' It expands %USERPROFILE% rather than hardcoding a path, so unlike config.yaml
' this file needs no rewriting when it moves to another machine.
Set sh = CreateObject("WScript.Shell")
path = sh.ExpandEnvironmentStrings("%USERPROFILE%\.glzr\glazewm\autotiling.mjs")
sh.Run "node """ & path & """", 0, False
