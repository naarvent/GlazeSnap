$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$prebuiltPath = Join-Path $repo 'glazewm\wm-helpers.exe'


# $PSCmdlet.ShouldProcess()'s "What if:" messages are written straight to the
# console host, bypassing every PowerShell stream (verified: 6>&1, 3>&1,
# 5>&1 and *>&1 all capture nothing, on both Windows PowerShell 5.1 and
# pwsh 7). Invoking install.ps1 as a real child process and capturing its
# actual stdout is what makes these messages observable here.
function Invoke-InstallWhatIf {
    & pwsh -NoProfile -File (Join-Path $repo 'install.ps1') -WhatIf | Out-String
}

Write-Host '--- without a prebuilt exe ---'
if (Test-Path $prebuiltPath) { Remove-Item $prebuiltPath -Force }
$withoutPrebuilt = Invoke-InstallWhatIf
if ($withoutPrebuilt -notmatch 'build.*wm-helpers\.exe') {
    throw "expected a 'build' WhatIf message when no prebuilt exe exists"
}
Write-Host 'OK: falls back to building from source'

Write-Host '--- with a prebuilt exe ---'
'dummy' | Set-Content $prebuiltPath
try {
    $withPrebuilt = Invoke-InstallWhatIf
    if ($withPrebuilt -notmatch 'copy prebuilt wm-helpers\.exe') {
        throw "expected a 'copy prebuilt wm-helpers.exe' WhatIf message when one exists"
    }
    Write-Host 'OK: prefers the prebuilt exe'
} finally {
    Remove-Item $prebuiltPath -Force -ErrorAction SilentlyContinue
}
