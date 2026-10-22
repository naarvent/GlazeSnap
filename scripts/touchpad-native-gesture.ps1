<#
.SYNOPSIS
    Turns Windows' own touchpad swipe off, or gives it back.

.DESCRIPTION
    The touchpad swipe in glaze-mouse.ahk and Windows' own swipe for the same
    number of fingers both see the same gesture, so with both on you get both
    actions at once. This sets the Windows one to "Nothing".

    It is the same setting as Settings > Bluetooth & devices > Touchpad, which
    is the other way to change it. -Restore deletes the value this script set,
    which puts Windows back to its default for that swipe (three fingers:
    switch apps; four: switch desktops). If you had chosen something else in
    Settings before, choose it there again.

    Per user, no elevation needed. It can take a sign-out to apply on some
    drivers.

.PARAMETER Fingers
    3 (default) or 4.

.PARAMETER Restore
    Give the swipe back to Windows.

.EXAMPLE
    .\touchpad-native-gesture.ps1
    .\touchpad-native-gesture.ps1 -Restore
    .\touchpad-native-gesture.ps1 -Fingers 4 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet(3, 4)][int]$Fingers = 3,
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'
$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PrecisionTouchPad'
$name = if ($Fingers -eq 3) { 'ThreeFingerSlideEnabled' } else { 'FourFingerSlideEnabled' }

$current = (Get-ItemProperty $key -ErrorAction SilentlyContinue).$name
$shown = if ($null -eq $current) { 'not set (Windows default)' } else { $current }
Write-Host "$name is $shown"

if ($Restore) {
    if ($null -eq $current) { Write-Host 'Nothing to restore.'; return }
    if ($PSCmdlet.ShouldProcess("$key\$name", 'delete, back to the Windows default')) {
        Remove-ItemProperty -Path $key -Name $name
        Write-Host 'Restored. Windows handles that swipe again.'
    }
    return
}

if ($current -eq 0) { Write-Host 'Already off.'; return }
if ($PSCmdlet.ShouldProcess("$key\$name", 'set to 0 (Nothing)')) {
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    New-ItemProperty -Path $key -Name $name -Value 0 -PropertyType DWord -Force | Out-Null
    Write-Host "Off. Undo with: .\touchpad-native-gesture.ps1 -Fingers $Fingers -Restore"
}
