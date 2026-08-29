<#
.SYNOPSIS
    Compiles autotiling.mjs into a standalone glazewm/dist/autotiling.exe
    using Node's Single Executable Applications (SEA) support, so the MSI
    package doesn't require the end user to install Node.js.

.NOTES
    autotiling.mjs is fed to SEA unmodified and unbundled: it is an ES module
    (uses import.meta.url and top-level await) with no dependencies beyond
    node: built-ins, so there is nothing for a bundler to do. The only thing
    that made this fail in earlier attempts is that SEA defaults to treating
    the injected main script as CommonJS ("mainFormat": "commonjs"), which
    breaks on import.meta and top-level await. Setting "mainFormat": "module"
    below tells Node to run it as an ES module instead - confirmed against
    this Node build by round-tripping both a minimal repro and the real
    autotiling.mjs through --experimental-sea-config, postject, and a live
    /ping request. See docs: https://nodejs.org/api/single-executable-applications.html
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null

$seaConfig = Join-Path $dist 'sea-config.json'
$blob = Join-Path $dist 'sea-prep.blob'
$exe = Join-Path $dist 'autotiling.exe'

@{
    main                           = (Join-Path $root 'autotiling.mjs')
    mainFormat                     = 'module'
    output                         = $blob
    disableExperimentalSEAWarning  = $true
} | ConvertTo-Json | Set-Content $seaConfig -Encoding utf8

node --experimental-sea-config $seaConfig
if ($LASTEXITCODE -ne 0) { throw "node --experimental-sea-config exited $LASTEXITCODE" }

Copy-Item (Get-Command node).Source $exe -Force

# node.exe from an official Windows build is Authenticode-signed. Modifying
# its bytes below invalidates that signature, which Windows treats worse than
# no signature at all - so strip it first if signtool is available.
#
# The Windows Kits bin tree has per-SDK-version arm\, arm64\, x64\, x86\
# subdirectories, so an unfiltered/alphabetical match could pick an
# arm/arm64 signtool.exe that won't run on an x64 runner - filter to x64
# and prefer the newest SDK version. This is best-effort: signtool failing
# here should never fail the whole release build over a step that's
# harmless to skip, but under $ErrorActionPreference = 'Stop',
# PowerShell 7.4+'s $PSNativeCommandUseErrorActionPreference would turn a
# nonzero signtool exit into a terminating error, so wrap it and swallow it.
$signtool = Get-Command signtool -ErrorAction SilentlyContinue
if (-not $signtool) {
    $signtool = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\x64\\' } |
        Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if ($signtool) {
    try { & $signtool remove /s $exe 2>$null } catch {}
    if ($LASTEXITCODE -ne 0) { Write-Warning "signtool remove exited $LASTEXITCODE; exe may carry an invalidated signature" }
} else {
    Write-Warning 'signtool not found: skipping signature removal (harmless if node.exe was not signed)'
}

npx --yes postject $exe NODE_SEA_BLOB $blob `
    --sentinel-fuse NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2 `
    --overwrite
if ($LASTEXITCODE -ne 0) { throw "npx postject exited $LASTEXITCODE" }

if (-not (Test-Path $exe)) { throw 'autotiling.exe was not produced' }
Write-Host "Built $exe" -ForegroundColor Green
