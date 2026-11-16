[CmdletBinding()]
param([ValidateSet('baby', 'fab4', 'all', 'rg35xxh')][string]$Hardware = 'all')
$ErrorActionPreference = 'Stop'
if ($Hardware -eq 'rg35xxh') {
    $ManifestPath = Join-Path $PSScriptRoot 'out/native-targets-rg35xxh.json'
    $BinDir = Join-Path $PSScriptRoot 'out/rg35xxh'
    $Out = Join-Path $PSScriptRoot 'out/applet-rg35xxh/SpotifyConnect'
    $Targets = @('rg35xxh')
} else {
    $ManifestPath = Join-Path $PSScriptRoot 'out/native-targets.json'
    $BinDir = Join-Path $PSScriptRoot 'out'
    $Out = Join-Path $PSScriptRoot 'out/applet/SpotifyConnect'
    $Targets = if ($Hardware -eq 'all') { @('baby', 'fab4') } else { @($Hardware) }
}
if (-not (Test-Path -LiteralPath $ManifestPath)) { throw 'Run build-native.ps1 before staging the applet' }
$Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
foreach ($Target in $Targets) {
    if ($Target -notin $Manifest.hardware) { throw "Native runtime does not support $Target" }
}
$Root = Split-Path $PSScriptRoot -Parent
if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Recurse -Force }
New-Item -ItemType Directory -Force $Out | Out-Null
Copy-Item "$Root/applet/*.lua","$Root/applet/strings.txt" $Out -Force
Copy-Item "$Root/applet/spotify-metadata-event" "$Out/spotify-metadata-event" -Force
Copy-Item "$Root/applet/spotify-logo.jpg" "$Out/spotify-logo.jpg" -Force
foreach ($Binary in @('ogg-http-bridge', 'spotify-supervisor', 'spotify-metadata', 'librespot')) {
    $Source = Join-Path $BinDir $Binary
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "Native binary is missing: $Source" }
    Copy-Item $Source $Out -Force
}
Write-Host "Applet staged in $Out"
