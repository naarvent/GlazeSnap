<#
.SYNOPSIS
    Pulls the live configuration back into the repository.

.DESCRIPTION
    The inverse of install.ps1. Only needed if you installed by copying; with
    install.ps1 -Link the files are already symlinks into the repo.

    config.yaml is not copied verbatim. Every region marked PERSONAL is swapped
    for its template and your Windows user name is replaced with USERNAME, so
    nothing of yours ends up published. See docs/CUSTOMIZING.md.

.EXAMPLE
    .\sync.ps1 -WhatIf
    .\sync.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
. (Join-Path $PSScriptRoot 'personal-blocks.ps1')

$MAP = @(
    @{ to = 'glazewm'; from = "$env:USERPROFILE\.glzr\glazewm"
       files = @('config.yaml', 'autotiling.mjs', 'autotiling.vbs', 'glaze-mouse.ahk') }

    # Source only. The binary is rebuilt by install.ps1.
    @{ to = 'glazewm\wm-helpers'; from = "$env:USERPROFILE\.glzr\glazewm\wm-helpers"
       files = @('Program.cs', 'wm-helpers.csproj') }

    @{ to = 'altsnap'; from = "$env:APPDATA\AltSnap"; files = @('AltSnap.ini') }
)

foreach ($pair in $MAP) {
    $repoDir = Join-Path $repo $pair.to
    if (-not (Test-Path $repoDir)) {
        if ($PSCmdlet.ShouldProcess($repoDir, 'create directory in the repo')) {
            New-Item -ItemType Directory -Force -Path $repoDir | Out-Null
        }
    }

    foreach ($name in $pair.files) {
        $source = Join-Path $pair.from $name
        $target = Join-Path $repoDir $name
        if (-not (Test-Path $source)) { Write-Warning "missing: $source"; continue }
        if (-not $PSCmdlet.ShouldProcess($target, "pull from $source")) { continue }

        if ($name -ne 'config.yaml') {
            Copy-Item $source $target -Force
            continue
        }

        $text = Get-Content $source -Raw

        foreach ($blockName in $PERSONAL_TEMPLATES.Keys) {
            $mine = Get-PersonalBlock -Text $text -Name $blockName
            if ($null -eq $mine) {
                Write-Warning "config.yaml has no PERSONAL: $blockName marker, check what you are about to publish"
                continue
            }
            if (-not (Test-BlockEmpty -Content $mine)) {
                Write-Host "  $blockName -> template" -ForegroundColor DarkGray
            }
            $text = Set-PersonalBlock -Text $text -Name $blockName -Content $PERSONAL_TEMPLATES[$blockName]
        }

        # install.ps1 rewrites C:\Users\<anyone>\ to the user of whatever
        # machine it runs on, so the published copy carries a placeholder.
        $text = [regex]::Replace($text, 'C:\\Users\\[^\\]+\\', 'C:\Users\USERNAME\')
        Set-Content $target -Value $text -Encoding utf8 -NoNewline
    }
}

Write-Host ""
Write-Host "Pulled into the repo. Check 'git diff' before committing." -ForegroundColor Green
Write-Host "config.yaml went in without your personal regions, user name as USERNAME." -ForegroundColor DarkGray
