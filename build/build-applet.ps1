[CmdletBinding()]
param([ValidateSet('baby', 'fab4', 'all')][string]$Hardware = 'all')
$ErrorActionPreference = 'Stop'
$ManifestPath = Join-Path $PSScriptRoot 'out/native-targets.json'
if (-not (Test-Path -LiteralPath $ManifestPath)) { throw 'Run build-native.ps1 before staging the applet' }
$Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$Targets = if ($Hardware -eq 'all') { @('baby', 'fab4') } else { @($Hardware) }
foreach ($Target in $Targets) {
    if ($Target -notin $Manifest.hardware) { throw "Native runtime does not support $Target" }
}
$Root = Split-Path $PSScriptRoot -Parent
$Out = Join-Path $PSScriptRoot 'out/applet/SpotifyConnect'
if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Recurse -Force }
New-Item -ItemType Directory -Force $Out | Out-Null
Copy-Item "$Root/applet/*.lua","$Root/applet/strings.txt" $Out -Force
Copy-Item "$Root/applet/spotify-metadata-event" "$Out/spotify-metadata-event" -Force
Copy-Item "$Root/applet/spotify-logo.jpg" "$Out/spotify-logo.jpg" -Force
if (Test-Path "$PSScriptRoot/out/ogg-http-bridge") { Copy-Item "$PSScriptRoot/out/ogg-http-bridge" "$Out/ogg-http-bridge" -Force }
if (Test-Path "$PSScriptRoot/out/spotify-supervisor") { Copy-Item "$PSScriptRoot/out/spotify-supervisor" "$Out/spotify-supervisor" -Force }
if (Test-Path "$PSScriptRoot/out/spotify-metadata") { Copy-Item "$PSScriptRoot/out/spotify-metadata" "$Out/spotify-metadata" -Force }
if (Test-Path "$PSScriptRoot/out/librespot") { Copy-Item "$PSScriptRoot/out/librespot" "$Out/librespot" -Force }
Write-Host "Applet staged in $Out"
