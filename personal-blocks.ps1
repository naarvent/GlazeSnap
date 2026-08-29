<#
.SYNOPSIS
    Keeps personal settings out of the published config.

.DESCRIPTION
    GlazeWM has no include mechanism: config.yaml is one file. So the split is
    marked inside the file itself, with a pair of comment markers per region:

        # >>>>>> PERSONAL: <name> >>>>>>
        ...anything you like...
        # <<<<<< PERSONAL <<<<<<

    sync.ps1   (system -> repo)   swaps each region for its template.
    install.ps1 (repo -> system)  keeps whatever you already had in it.

    Dot-sourced by both scripts; not meant to be run on its own.
#>

$BLOCK_END = '# <<<<<< PERSONAL <<<<<<'

function Get-BlockStart {
    param([Parameter(Mandatory)][string]$Name)
    return "# >>>>>> PERSONAL: $Name >>>>>>"
}

# What someone cloning the repo sees in place of each region. The leading
# whitespace matters: it is YAML.
$PERSONAL_TEMPLATES = [ordered]@{
    startup     = @'
    # Anything else you want started with the window manager: a status bar, a
    # wallpaper engine, a tray app.
    #
    # - 'shell-exec C:\PROGRA~1\YASB\yasbc.exe start'
'@

    shutdown    = @'
  shutdown_commands: []
'@

    keybindings = @'
  # Your own bindings go here: launch a browser, an editor, a script. The
  # examples below are commented out; drop the # and fix the path.
  #
  # Neither sync.ps1 nor install.ps1 will overwrite this region once it has
  # anything real in it. Full guide, including the list of commands and the
  # key combinations Windows reserves for itself, in docs/CUSTOMIZING.md.

  # - commands: ['shell-exec C:\PROGRA~1\MOZILL~1\firefox.exe']
  #   bindings: ['alt+b']

  # - commands: ['shell-exec code']
  #   bindings: ['alt+c']
'@
}

<#
.SYNOPSIS
    Returns the contents of one named region, or $null when it is missing.
#>
function Get-PersonalBlock {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Name
    )

    $marker = Get-BlockStart -Name $Name
    $from = $Text.IndexOf($marker)
    if ($from -lt 0) { return $null }
    $from += $marker.Length

    $to = $Text.IndexOf($script:BLOCK_END, $from)
    if ($to -lt 0) { return $null }

    return $Text.Substring($from, $to - $from).Trim("`r", "`n")
}

<#
.SYNOPSIS
    Returns the text with one named region replaced by $Content.

.DESCRIPTION
    A file without the markers comes back untouched: guessing where the region
    would have gone is worse than doing nothing.
#>
function Set-PersonalBlock {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    $marker = Get-BlockStart -Name $Name
    $from = $Text.IndexOf($marker)
    if ($from -lt 0) { return $Text }
    $to = $Text.IndexOf($script:BLOCK_END, $from)
    if ($to -lt 0) { return $Text }

    # Walk back over the closing marker's indentation, or it ends up flush
    # against the margin.
    while ($to -gt 0 -and ($Text[$to - 1] -eq ' ' -or $Text[$to - 1] -eq "`t")) {
        $to--
    }

    $head = $Text.Substring(0, $from + $marker.Length)
    $tail = $Text.Substring($to)
    return "$head`n$Content`n$tail"
}

<#
.SYNOPSIS
    True when a region holds nothing but comments, i.e. it is still the
    untouched template.
#>
function Test-BlockEmpty {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)

    foreach ($line in $Content -split "`r?`n") {
        $trimmed = $line.Trim()
        if ($trimmed -and -not $trimmed.StartsWith('#')) { return $false }
    }
    return $true
}
