[CmdletBinding()]
param(
    [ValidateSet('baby', 'fab4', 'all', 'rg35xxh')]
    [string]$Hardware = 'all'
)
$ErrorActionPreference = 'Stop'
$Out = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force $Out | Out-Null
if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) { throw 'WSL Ubuntu-24.04 is required for reproducible native builds' }
$LinuxScript = (wsl -d Ubuntu-24.04 -- wslpath -a ($PSScriptRoot.Replace('\', '/') + '/build-native.sh')).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve build script in WSL' }
wsl -d Ubuntu-24.04 -- bash $LinuxScript $Hardware
if ($LASTEXITCODE -ne 0) { throw "Native build failed with exit code $LASTEXITCODE" }
if ($Hardware -eq 'rg35xxh') {
    Write-Host "Native Spotify binaries built for rg35xxh in $Out/rg35xxh (AArch64 runtime)"
} else {
    Write-Host "Native Spotify binaries built for $Hardware in $Out (shared baby/fab4 runtime)"
}
