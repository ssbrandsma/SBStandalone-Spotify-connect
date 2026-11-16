[CmdletBinding()]
param(
    [string]$BaseUrl,
    [string]$OutputDirectory,
    [ValidateSet('baby', 'fab4', 'all', 'rg35xxh')]
    [string]$Hardware = 'all'
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$VersionFile = Join-Path $Root 'VERSION'

if (-not (Test-Path -LiteralPath $VersionFile -PathType Leaf)) {
    throw "Missing version file: $VersionFile"
}
$Version = (Get-Content -LiteralPath $VersionFile -Raw).Trim()
if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$') {
    throw "VERSION must contain a semantic version; found '$Version'"
}

if (-not $BaseUrl) {
    $BaseUrl = 'http://49.12.198.91/sbspotifyconnect'
}
try { $RepositoryUri = [Uri]$BaseUrl } catch { throw "BaseUrl is not a valid URL: $BaseUrl" }
if (-not $RepositoryUri.IsAbsoluteUri -or $RepositoryUri.Scheme -notin @('http', 'https')) {
    throw "BaseUrl must use HTTP or HTTPS: $BaseUrl"
}
$BaseUrl = $BaseUrl.TrimEnd('/')

if (-not $OutputDirectory) { $OutputDirectory = Join-Path $Root 'dist' }
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)

& "$PSScriptRoot/build-applet.ps1" -Hardware $Hardware
$Stage = if ($Hardware -eq 'rg35xxh') {
    Join-Path $PSScriptRoot 'out/applet-rg35xxh/SpotifyConnect'
} else {
    Join-Path $PSScriptRoot 'out/applet/SpotifyConnect'
}
$RequiredEntries = @(
    'librespot',
    'ogg-http-bridge',
    'qrencode.lua',
    'spotify-logo.jpg',
    'spotify-metadata',
    'spotify-metadata-event',
    'spotify-supervisor',
    'SpotifyConnectApplet.lua',
    'SpotifyConnectMeta.lua',
    'SpotifyConnectState.lua',
    'SpotifyNativeNowPlaying.lua',
    'SpotifyStandaloneNowPlaying.lua',
    'SpotifyUrlTransport.lua',
    'SpotifyPlayback.lua',
    'SpotifyOwnership.lua',
    'SpotifyPlatform.lua',
    'SpotifyService.lua',
    'strings.txt'
)
foreach ($Entry in $RequiredEntries) {
    if (-not (Test-Path -LiteralPath (Join-Path $Stage $Entry) -PathType Leaf)) {
        throw "Required package file is missing: $Entry"
    }
}

New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$ZipName = if ($Hardware -eq 'rg35xxh') { "SpotifyConnect-$Version-rg35xxh.zip" } else { "SpotifyConnect-$Version.zip" }
$ZipPath = Join-Path $OutputDirectory $ZipName
Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
Push-Location $Stage
try {
    Compress-Archive -Path $RequiredEntries -DestinationPath $ZipPath -CompressionLevel Optimal
}
finally {
    Pop-Location
}

$Archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
try {
    $ZipEntries = @($Archive.Entries | Where-Object { -not $_.FullName.EndsWith('/') } | ForEach-Object { $_.FullName.Replace('\', '/') })
}
finally {
    $Archive.Dispose()
}
$Unexpected = @($ZipEntries | Where-Object { $_ -notin $RequiredEntries })
$Missing = @($RequiredEntries | Where-Object { $_ -notin $ZipEntries })
if ($Unexpected.Count -gt 0) { throw "ZIP contains unexpected files: $($Unexpected -join ', ')" }
if ($Missing.Count -gt 0) { throw "ZIP is missing files: $($Missing -join ', ')" }
if ($ZipEntries | Where-Object { $_ -match '^(SpotifyConnect/|applet/)' }) {
    throw 'ZIP has an enclosing directory; Applet Installer requires runtime files at the archive root'
}

$Escape = { param([string]$Value) [System.Security.SecurityElement]::Escape($Value) }
$EntryFor = {
    param([string]$Target, [string]$Desc, [string]$FileName)
    $Path = Join-Path $OutputDirectory $FileName
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $Sha = (Get-FileHash -LiteralPath $Path -Algorithm SHA1).Hash.ToLowerInvariant()
    $Url = "$BaseUrl/$FileName"
    $Changes = 'Latch audio-completed events for reliable automatic track advancement; preserve complete endings and immediate manual skips; fix mobile selection and native Now Playing updates; remove UI shell polling.'
    [pscustomobject]@{ Target = $Target; FileName = $FileName; Url = $Url; Sha = $Sha; Xml = @"
    <applet name="SpotifyConnect" version="$(& $Escape $Version)" target="$Target" minTarget="7.7" maxTarget="*">
      <title lang="EN">Spotify Connect</title>
      <desc lang="EN">$Desc</desc>
      <changes lang="EN">$Changes</changes>
      <creator>Sjoerd Brandsma</creator>
      <url>$(& $Escape $Url)</url>
      <sha>$Sha</sha>
    </applet>
"@ }
}
$SharedZip = "SpotifyConnect-$Version.zip"
$GoZip = "SpotifyConnect-$Version-rg35xxh.zip"
$Entries = @(
    (& $EntryFor 'baby' 'Standalone Spotify Connect playback for Logitech Squeezebox Radio. LMS is only needed to install the applet.' $SharedZip),
    (& $EntryFor 'fab4' 'Standalone Spotify Connect playback for Logitech Squeezebox Touch. LMS is only needed to install the applet.' $SharedZip),
    (& $EntryFor 'rg35xxh' 'Standalone Spotify Connect playback for the Anbernic RG35XX H running SqueezeboxGo. No LMS server is needed after installation.' $GoZip)
) | Where-Object { $_ -ne $null }
if ($Entries.Count -eq 0) { throw 'No installable ZIP artifacts found; packaging produced nothing' }
$Xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<extensions>
  <details>
    <title lang="EN">Squeezebox Radio and Touch Spotify Connect Repository</title>
  </details>
  <applets>
$($Entries.Xml -join "`n")
  </applets>
</extensions>
"@
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$XmlPath = Join-Path $OutputDirectory 'extensions.xml'
[System.IO.File]::WriteAllText($XmlPath, $Xml, $Utf8NoBom)
$XmlSha1 = (Get-FileHash -LiteralPath $XmlPath -Algorithm SHA1).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText((Join-Path $OutputDirectory 'extensions.xml.sha1'), $XmlSha1, $Utf8NoBom)
# SHA-256 sidecars are for human/CI verification; the Installer reads SHA-1 only.
$ZipSha256 = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText("$ZipPath.sha256", "$ZipSha256  $(Split-Path $ZipPath -Leaf)`n", $Utf8NoBom)
$XmlSha256 = (Get-FileHash -LiteralPath $XmlPath -Algorithm SHA256).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText("$XmlPath.sha256", "$XmlSha256  extensions.xml`n", $Utf8NoBom)

[xml]$Parsed = Get-Content -LiteralPath $XmlPath -Raw
$Applets = @($Parsed.extensions.applets.applet)
if ($Applets.Count -ne $Entries.Count) {
    throw 'Generated extensions.xml did not round-trip with the expected entry count'
}
foreach ($Entry in $Entries) {
    $Applet = @($Applets | Where-Object { $_.target -eq $Entry.Target })
    if ($Applet.Count -ne 1 -or $Applet[0].name -ne 'SpotifyConnect' -or $Applet[0].version -ne $Version -or $Applet[0].url -ne $Entry.Url -or $Applet[0].sha -ne $Entry.Sha) {
        throw "Generated extensions.xml did not round-trip with the expected $($Entry.Target) package metadata"
    }
}

Write-Host 'Built Spotify Connect Applet Installer package'
Write-Host "Version:        $Version"
Write-Host "ZIP:            $ZipPath"
Write-Host "ZIP size:       $((Get-Item -LiteralPath $ZipPath).Length) bytes"
Write-Host "Repository XML: $XmlPath"
Write-Host "XML SHA-1:      $XmlSha1"
foreach ($Entry in $Entries) {
    Write-Host "Target $($Entry.Target): $($Entry.FileName) sha1=$($Entry.Sha)"
}
Write-Host 'Archive entries:'
$ZipEntries | ForEach-Object { Write-Host "  $_" }
