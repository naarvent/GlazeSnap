<#
.SYNOPSIS
    Assembles the MSI's payload directory: the git tree's install.ps1 and
    scripts, plus the exe variants of the daemon and helper instead of their
    source forms. Run this, then `wix build`, to produce the MSI.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$payload = Join-Path $PSScriptRoot 'payload'

if (Test-Path $payload) { Remove-Item $payload -Recurse -Force }
New-Item -ItemType Directory -Force -Path $payload, "$payload\glazewm", "$payload\altsnap" | Out-Null

Copy-Item "$repo\install.ps1", "$repo\personal-blocks.ps1", "$repo\sync.ps1" $payload

$daemonExe = "$repo\glazewm\dist\autotiling.exe"
if (-not (Test-Path $daemonExe)) { throw "run glazewm\build-daemon-exe.ps1 first: $daemonExe not found" }
Copy-Item $daemonExe "$payload\glazewm\autotiling.exe"

$helperExe = "$repo\glazewm\wm-helpers\bin\Release\net10.0\win-x64\publish\wm-helpers.exe"
if (-not (Test-Path $helperExe)) { throw "run 'dotnet publish' for wm-helpers first: $helperExe not found" }
Copy-Item $helperExe "$payload\glazewm\wm-helpers.exe"

Copy-Item "$repo\glazewm\glaze-mouse.ahk", "$repo\glazewm\config.yaml" "$payload\glazewm"
Copy-Item "$repo\altsnap\AltSnap.ini" "$payload\altsnap"

# Same filename as the git tree's launcher (config.yaml's startup_commands
# hardcodes "autotiling.vbs"), but this variant execs the compiled exe
# instead of `node autotiling.mjs`.
@'
' Starts autotiling.exe with no console window (that is what the 0 does).
' GlazeWM opens this file from startup_commands (`shell-exec %USERPROFILE%\...`),
' and the .vbs association hands it to wscript. It expands %USERPROFILE% rather
' than hardcoding a path, so it needs no rewriting on another machine.
Set sh = CreateObject("WScript.Shell")
path = sh.ExpandEnvironmentStrings("%USERPROFILE%\.glzr\glazewm\autotiling.exe")
sh.Run """" & path & """", 0, False
'@ | Set-Content "$payload\glazewm\autotiling.vbs" -Encoding ASCII

Write-Host "Payload staged at $payload" -ForegroundColor Green
