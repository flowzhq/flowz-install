# Flowz CLI installer for Windows (ADR-032).
#
#   $env:FLOWZ_TOKEN = "<your token>"
#   irm https://raw.githubusercontent.com/flowzhq/flowz-install/main/install.ps1 | iex
#
# Downloads the flowz build for this machine from the private registry, verifies
# its sha256 against the published release metadata, and installs it to
# %USERPROFILE%\.flowz\bin. After this, `flowz upgrade` handles every update.
#
# Environment:
#   FLOWZ_TOKEN        (required) the access token you were issued
#   FLOWZ_VERSION      install this exact version instead of the latest
#   FLOWZ_INSTALL_DIR  install here instead of ~\.flowz\bin
#   FLOWZ_CLI_PACKAGE  override the registry package (testing)
#
# Unlike install.sh this can use a real JSON parser (ConvertFrom-Json is built
# in), so it reads the manifest properly rather than by pattern.

$ErrorActionPreference = 'Stop'

function Die($msg) { Write-Error $msg; exit 1 }

$package = if ($env:FLOWZ_CLI_PACKAGE) { $env:FLOWZ_CLI_PACKAGE } else { 'ghcr.io/flowzhq/flowz-cli' }
$registry = $package.Split('/')[0]
$repository = $package.Substring($registry.Length + 1)
$installDir = if ($env:FLOWZ_INSTALL_DIR) { $env:FLOWZ_INSTALL_DIR } else { Join-Path $HOME '.flowz\bin' }
$scheme = if ($registry -match '^(localhost|127\.0\.0\.1)(:|$)') { 'http' } else { 'https' }

if (-not $env:FLOWZ_TOKEN) {
  Die @"
FLOWZ_TOKEN is not set.
flowz is distributed privately to design partners. Set the access token you were
issued and re-run:
  `$env:FLOWZ_TOKEN = "<your token>"
"@
}

# --- platform -----------------------------------------------------------------
$arch = switch ($env:PROCESSOR_ARCHITECTURE) {
  'AMD64' { 'amd64' }
  'ARM64' { 'arm64' }
  default { Die "unsupported architecture '$($env:PROCESSOR_ARCHITECTURE)' (flowz ships amd64 and arm64)" }
}
$platform = "windows-$arch"

if ($arch -eq 'arm64') {
  Write-Warning @"
Windows on ARM: this build ships WITHOUT the embedded analyzer, because Bun has
no windows-arm64 compile target (ADR-029). 'flowz scan', 'init' and 'view'
work; 'flowz system build' will not. Use an amd64 machine or WSL for the full pipeline.
"@
}

# --- registry helpers ---------------------------------------------------------
$basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x:$($env:FLOWZ_TOKEN)"))
try {
  $tokenResp = Invoke-RestMethod -Headers @{ Authorization = "Basic $basic" } `
    -Uri "${scheme}://$registry/token?service=$registry&scope=repository:${repository}:pull"
} catch {
  Die "could not authenticate to $registry.`nCheck the token hasn't been revoked and that it has read:packages on $package."
}
$bearer = if ($tokenResp.token) { $tokenResp.token } else { $tokenResp.access_token }
if (-not $bearer) { Die "authentication to $registry returned no token" }
$authHeader = @{ Authorization = "Bearer $bearer" }

function Get-LayerDigest($tag) {
  $headers = $authHeader.Clone()
  $headers['Accept'] = 'application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
  try {
    $manifest = Invoke-RestMethod -Headers $headers -Uri "${scheme}://$registry/v2/$repository/manifests/$tag"
  } catch {
    return $null
  }
  # Every artifact the release workflow publishes is single-layer by design.
  if ($manifest.layers.Count -ne 1) { Die "$package`:$tag has $($manifest.layers.Count) layers, want exactly 1" }
  return $manifest.layers[0].digest
}

# --- resolve the release ------------------------------------------------------
$metaTag = if ($env:FLOWZ_VERSION) {
  $v = $env:FLOWZ_VERSION; if (-not $v.StartsWith('v')) { $v = "v$v" }; "$v-meta"
} else { 'latest' }

$metaDigest = Get-LayerDigest $metaTag
if (-not $metaDigest) { Die "$package`:$metaTag not found - check the version, or ask for access" }

$release = Invoke-RestMethod -Headers $authHeader -Uri "${scheme}://$registry/v2/$repository/blobs/$metaDigest"
$version = $release.version
if (-not $version) { Die 'release metadata has no version' }

$entry = $release.platforms.$platform
if (-not $entry -or -not $entry.sha256) { Die "release $version has no build for $platform" }

Write-Host "Installing flowz $version ($platform)..."

# --- download, verify, install ------------------------------------------------
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("flowz-install-" + [Guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  $binDigest = Get-LayerDigest "$version-$platform"
  if (-not $binDigest) { Die "$package`:$version-$platform not found" }

  $gzPath = Join-Path $tmp 'flowz.gz'
  Invoke-WebRequest -Headers $authHeader -OutFile $gzPath `
    -Uri "${scheme}://$registry/v2/$repository/blobs/$binDigest"

  $exePath = Join-Path $tmp 'flowz.exe'
  $in = [IO.File]::OpenRead($gzPath)
  $gz = New-Object IO.Compression.GzipStream($in, [IO.Compression.CompressionMode]::Decompress)
  $out = [IO.File]::Create($exePath)
  try { $gz.CopyTo($out) } finally { $out.Dispose(); $gz.Dispose(); $in.Dispose() }

  $got = (Get-FileHash -Algorithm SHA256 -Path $exePath).Hash.ToLower()
  if ($got -ne $entry.sha256.ToLower()) {
    Die "checksum mismatch for $version $platform`n  got:      $got`n  expected: $($entry.sha256)`nThe download was corrupted or tampered with. Nothing was installed."
  }

  # Move into place last, so a failure above never leaves a partial binary on PATH.
  New-Item -ItemType Directory -Force -Path $installDir | Out-Null
  Move-Item -Force $exePath (Join-Path $installDir 'flowz.exe')

  # Store the token so `flowz upgrade` works without re-supplying it. The CLI
  # always reads ~\.flowz\credentials.json regardless of where the binary lives.
  $flowzHome = Join-Path $HOME '.flowz'
  New-Item -ItemType Directory -Force -Path $flowzHome | Out-Null
  [IO.File]::WriteAllText(
    (Join-Path $flowzHome 'credentials.json'),
    (@{ registry = $package; token = $env:FLOWZ_TOKEN } | ConvertTo-Json))
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Installed flowz $version to $installDir\flowz.exe"

if (($env:PATH -split ';') -notcontains $installDir) {
  Write-Host ""
  Write-Host "$installDir is not on your PATH. Add it for this user:"
  Write-Host "  [Environment]::SetEnvironmentVariable('PATH', `"`$env:PATH;$installDir`", 'User')"
  Write-Host "  `$env:PATH += ';$installDir'"
  Write-Host ""
}
Write-Host "Then run: flowz version"
Write-Host "Future updates: flowz upgrade"
