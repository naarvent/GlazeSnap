<#
.SYNOPSIS
    Installs this setup on a Windows machine.

.DESCRIPTION
    Copies every file into place, rewrites the absolute paths to the current
    user and builds the native helper. Anything it overwrites is backed up
    with a .bak extension first.

    Run it with -WhatIf to see what it would do without touching anything.

    Reinstalling never wipes your own keybindings: the regions marked PERSONAL
    in config.yaml are carried over from the copy already on disk.

.PARAMETER Link
    Create symbolic links into the repo instead of copying, so edits are
    version-controlled as you make them. Needs Windows developer mode, or an
    elevated shell.

.EXAMPLE
    .\install.ps1 -WhatIf
    .\install.ps1
    .\install.ps1 -Link
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Link
)

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
. (Join-Path $PSScriptRoot 'personal-blocks.ps1')

# Windows PowerShell 5.1's `Set-Content -Encoding utf8` writes a BOM, which
# GlazeWM's YAML parser chokes on ("deserializing from YAML containing more
# than one document"). Write plain UTF-8 without BOM instead.
function Set-Utf8NoBom {
    param([string]$Path, [string]$Value)
    [System.IO.File]::WriteAllText($Path, $Value, (New-Object System.Text.UTF8Encoding $false))
}

$GLAZE_DIR = "$env:USERPROFILE\.glzr\glazewm"

# repo directory -> where it goes
$MAP = @(
    @{ from = 'glazewm'; to = $GLAZE_DIR }
    @{ from = 'altsnap'; to = "$env:APPDATA\AltSnap" }
)

function Test-Requirements {
    $missing = @()
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        $missing += 'Node.js 22+           winget install OpenJS.NodeJS'
    }
    # config.yaml starts glaze-mouse.ahk and autotiling.vbs by file association,
    # so what matters is that .ahk opens with AutoHotkey, wherever it lives
    # (Program Files, or %LOCALAPPDATA%\Programs for a per-user install).
    if (-not (Test-Path 'Registry::HKEY_CLASSES_ROOT\.ahk')) {
        $missing += 'AutoHotkey v2         winget install AutoHotkey.AutoHotkey'
    }
    $vbsOpen = (Get-ItemProperty 'Registry::HKEY_CLASSES_ROOT\VBSFile\Shell\Open\Command' -ErrorAction SilentlyContinue).'(default)'
    if ($vbsOpen -notmatch 'wscript') {
        Write-Warning '.vbs files do not open with wscript here (some hardening tools reassign them), so the autotiling daemon will not start. Restore the association or change the autotiling line in config.yaml.'
    }
    if (-not (Test-Path "$env:ProgramFiles\glzr.io\GlazeWM\glazewm.exe")) {
        $missing += 'GlazeWM               winget install glzr-io.glazewm'
    }
    # Only needed to build the fullscreen-game helper. Everything else works
    # without it.
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        $missing += '.NET SDK 10 (optional) winget install Microsoft.DotNet.SDK.10'
    }

    if ($missing) {
        Write-Warning 'Not installed yet:'
        $missing | ForEach-Object { Write-Warning "  $_" }
        Write-Warning 'Files will be copied anyway, but nothing will run until you install them.'
    }
}

Test-Requirements

foreach ($pair in $MAP) {
    $source = Join-Path $repo $pair.from
    $target = $pair.to
    if (-not (Test-Path $source)) { Write-Warning "missing: $source, skipped"; continue }

    if (-not (Test-Path $target)) {
        if ($PSCmdlet.ShouldProcess($target, 'create directory')) {
            New-Item -ItemType Directory -Force -Path $target | Out-Null
        }
    }

    foreach ($file in Get-ChildItem $source -File) {
        if ($file.Name -eq 'wm-helpers.exe') { continue }  # Build-Helper owns this one
        $finalPath = Join-Path $target $file.Name

        if ((Test-Path $finalPath) -and -not (Get-Item $finalPath).LinkType) {
            if ($PSCmdlet.ShouldProcess($finalPath, 'back up as .bak')) {
                Copy-Item $finalPath "$finalPath.bak" -Force
            }
        }

        # Carry your own keybindings over to the incoming config instead of
        # flattening them.
        if ($file.Name -eq 'config.yaml' -and (Test-Path $finalPath) -and -not $Link) {
            $current = Get-Content $finalPath -Raw -Encoding UTF8
            $incoming = Get-Content $file.FullName -Raw -Encoding UTF8
            $kept = @()

            foreach ($blockName in $PERSONAL_TEMPLATES.Keys) {
                $mine = Get-PersonalBlock -Text $current -Name $blockName
                if ($null -eq $mine -or (Test-BlockEmpty -Content $mine)) { continue }
                $incoming = Set-PersonalBlock -Text $incoming -Name $blockName -Content $mine
                $kept += $blockName
            }

            if ($kept) {
                if ($PSCmdlet.ShouldProcess($finalPath, "keep your $($kept -join ', ') and copy the rest")) {
                    Set-Utf8NoBom -Path $finalPath -Value $incoming
                    Write-Host "  kept your $($kept -join ', ')" -ForegroundColor DarkGray
                }
                continue
            }
        }

        if ($Link) {
            if ($PSCmdlet.ShouldProcess($finalPath, "link to $($file.FullName)")) {
                Remove-Item $finalPath -Force -ErrorAction SilentlyContinue
                New-Item -ItemType SymbolicLink -Path $finalPath -Target $file.FullName | Out-Null
            }
            continue
        }

        if ($PSCmdlet.ShouldProcess($finalPath, 'copy')) {
            Copy-Item $file.FullName $finalPath -Force
        }
    }
}

# The shipped startup commands use %USERPROFILE%, which GlazeWM expands itself.
# This rewrite is for absolute paths you put in your own PERSONAL regions,
# carried over from another machine's user.
$configPath = Join-Path $GLAZE_DIR 'config.yaml'
if ((Test-Path $configPath) -and -not $Link) {
    if ($PSCmdlet.ShouldProcess($configPath, "rewrite paths to $env:USERPROFILE")) {
        # Backslash is not an escape character in a .NET replacement string,
        # only $ is. Doubling it here used to write C:\\Users\\you\\ into the
        # config and break every path in it.
        $text = Get-Content $configPath -Raw -Encoding UTF8
        $text = [regex]::Replace($text, 'C:\\Users\\[^\\]+\\', ($env:USERPROFILE + '\'))
        Set-Utf8NoBom -Path $configPath -Value $text
    }
} elseif ($Link) {
    Write-Warning 'config.yaml holds absolute paths and you used -Link: fix them by hand if the user name differs.'
}

# The C# helper is staged at wm-helpers.exe as a prebuilt binary when the MSI
# ships it, otherwise (the git-clone path) it's built from source here via
# dotnet publish. Either way it ends up at ~\.glzr\glazewm\wm-helpers.exe, and
# autotiling.mjs simply skips the taskbar fix if it is not there.
function Build-Helper {
    $prebuilt = Join-Path $repo 'glazewm\wm-helpers.exe'
    if (Test-Path $prebuilt) {
        $dest = Join-Path $GLAZE_DIR 'wm-helpers.exe'
        if ($PSCmdlet.ShouldProcess($dest, 'copy prebuilt wm-helpers.exe')) {
            Copy-Item $prebuilt $dest -Force
            Write-Host 'wm-helpers.exe copied (prebuilt)' -ForegroundColor Green
        }
        return
    }

    $source = Join-Path $repo 'glazewm\wm-helpers'
    if (-not (Test-Path $source)) { return }

    $buildDir = Join-Path $GLAZE_DIR 'wm-helpers'
    if ($PSCmdlet.ShouldProcess($buildDir, 'copy the wm-helpers source')) {
        New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
        Copy-Item (Join-Path $source '*') $buildDir -Recurse -Force
    }

    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        Write-Warning 'no dotnet: wm-helpers.exe not built, fullscreen-game taskbar fix disabled'
        return
    }

    if (-not $PSCmdlet.ShouldProcess('wm-helpers.exe', 'build')) { return }

    Push-Location $buildDir
    try {
        dotnet publish -c Release -r win-x64 --self-contained false -p:PublishSingleFile=true | Out-Null
        $exe = Join-Path $buildDir 'bin\Release\net10.0\win-x64\publish\wm-helpers.exe'
        if (Test-Path $exe) {
            Copy-Item $exe (Join-Path $GLAZE_DIR 'wm-helpers.exe') -Force
            Write-Host 'wm-helpers.exe built' -ForegroundColor Green
        } else {
            Write-Warning 'the build did not leave wm-helpers.exe where expected'
        }
    } finally {
        Pop-Location
        # Build output has no business sitting in a config directory.
        Remove-Item (Join-Path $buildDir 'bin'), (Join-Path $buildDir 'obj') `
            -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Build-Helper

Write-Host ""
Write-Host 'Done. Start GlazeWM, or press Alt+Shift+R if it is already running.' -ForegroundColor Green
Write-Host "Check $GLAZE_DIR\errors.log for complaints." -ForegroundColor Green
