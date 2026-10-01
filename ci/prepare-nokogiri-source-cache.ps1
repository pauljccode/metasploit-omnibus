$ErrorActionPreference = 'Stop'

# Same source archive and SHA-256 as Nokogiri 1.19.4 dependencies.yml.
# Maintainer-hosted mirror introduced by sparklemotion/nokogiri#3671.
$uri = 'https://nokogiri.org/mirror/gnu/libiconv/libiconv-1.18.tar.gz'
$expected = '3b08f5f4f9b4eb82f151a7040bfd6fe6c6fb922efe4b1659c66ea933276965e8'
$cacheDir = Join-Path $env:RUNNER_TEMP 'msf-nokogiri-source-cache'
New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
if (Test-Path (Join-Path $cacheDir 'source-cache-use.yml')) { throw 'Unexpected stale source cache receipt' }
$archive = Join-Path $cacheDir 'libiconv-1.18.tar.gz'
$partial = "$archive.part"
if (Test-Path $partial) { throw "Unexpected partial download: $partial" }
if (-not (Test-Path $archive)) {
    try {
        & curl.exe --fail --location --proto '=https' --proto-redir '=https' `
            --connect-timeout 15 --max-time 120 --retry 2 --retry-max-time 180 `
            --output $partial $uri
        if ($LASTEXITCODE -ne 0) { throw "Source download failed: curl exit $LASTEXITCODE" }
        if ((Get-FileHash -Algorithm SHA256 $partial).Hash.ToLowerInvariant() -ne $expected) {
            throw 'Downloaded libiconv archive failed SHA-256 verification'
        }
        Move-Item $partial $archive
    } finally {
        if (Test-Path $partial) { Remove-Item $partial }
    }
}
if ((Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant() -ne $expected) {
    throw 'Cached libiconv archive failed SHA-256 verification'
}
$hook = (Join-Path $PSScriptRoot 'nokogiri-archive-cache.rb').Replace('\', '/')
if ($hook -match '\s') { throw 'Ruby preload path must not contain whitespace' }
"MSF_NOKOGIRI_SOURCE_CACHE=$cacheDir" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
"preload=$hook" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
Write-Output "NOKOGIRI_PREFETCH_VERIFIED libiconv-1.18.tar.gz sha256=$expected"
