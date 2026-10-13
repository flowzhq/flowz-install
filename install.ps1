# Flowz CLI installer for Windows (ADR-032). The install command is in
# docs/partner-install.md. Keep it out of this file: antivirus AMSI scans
# (Bitdefender) block a script that carries a URL piped to iex, comment or not.
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
# Local mode (offline bundles): with flowz_<version>_windows_<arch>.exe (or
# flowz.exe) and a SHA256SUMS file beside this script, it verifies the binary
# against SHA256SUMS and installs it, with no network, no token and no update
# check. It needs this file run as a file, with SHA256SUMS beside it, never
# `irm | iex` (which has no script directory):
#   powershell -ExecutionPolicy Bypass -File .\install.ps1
#   -Local             require local mode (fail if no binary or SHA256SUMS is beside the script)
#   FLOWZ_LOCAL=0      never use local mode
#   FLOWZ_BINARY=<p>   install this binary; SHA256SUMS is read from its directory
#
# flowz-install-script (marker: local mode trusts only a script path that carries this line)
#
# Unlike install.sh this can use a real JSON parser (ConvertFrom-Json is built
# in), so it reads the manifest properly rather than by pattern.

$ErrorActionPreference = 'Stop'

function Die($msg) { Write-Error $msg; exit 1 }

$package = if ($env:FLOWZ_CLI_PACKAGE) { $env:FLOWZ_CLI_PACKAGE } else { 'ghcr.io/flowzhq/flowz-cli' }
$registry = $package.Split('/')[0]
$repository = $package.Substring($registry.Length + 1)
$installDir = if ($env:FLOWZ_INSTALL_DIR) { $env:FLOWZ_INSTALL_DIR } else { Join-Path $HOME '.flowz\bin' }
$installDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($installDir)
$scheme = if ($registry -match '^(localhost|127\.0\.0\.1)(:|$)') { 'http' } else { 'https' }

# Move-Item onto a directory named flowz.exe moves the binary inside it and succeeds.
$target = Join-Path $installDir 'flowz.exe'
if (Test-Path -LiteralPath $target -PathType Container) {
  Die "$target is a directory, not the flowz binary. Move or delete it and rerun. Nothing was installed."
}

function Get-Arch {
  switch ($env:PROCESSOR_ARCHITECTURE) {
    'AMD64' { 'amd64' }
    'ARM64' { 'arm64' }
    default { Die "unsupported architecture '$($env:PROCESSOR_ARCHITECTURE)' (flowz ships amd64 and arm64)" }
  }
}

function Write-ArmWarning {
  Write-Warning @"
Windows on ARM: this build ships WITHOUT the embedded analyzer, because Bun has
no windows-arm64 compile target (ADR-029). 'flowz scan', 'init' and 'view'
work; 'flowz system build' will not. Use an amd64 machine or WSL for the full pipeline.
"@
}

# A PATH entry matches with or without a trailing separator.
function Test-OnPath($pathList) {
  $want = $installDir.TrimEnd('\', '/')
  @(("$pathList" -split ';') | ForEach-Object { $_.Trim().TrimEnd('\', '/') }) -contains $want
}

function Write-PathHint {
  if (-not (Test-OnPath $env:PATH)) {
    $q = $installDir -replace "'", "''"
    Write-Host ""
    if (Test-OnPath ([Environment]::GetEnvironmentVariable('PATH', 'User'))) {
      Write-Host "$installDir is on your user PATH but not in this session. Open a new terminal, or:"
    } else {
      Write-Host "$installDir is not on your PATH. Add it for this user:"
      Write-Host "  [Environment]::SetEnvironmentVariable('PATH', ([Environment]::GetEnvironmentVariable('PATH', 'User') + ';$q').TrimStart(';'), 'User')"
    }
    Write-Host "  `$env:PATH += ';$q'"
    Write-Host ""
  }
  Write-Host "Then run: flowz version"
}

# Replace flowz.exe with $src. Windows refuses while flowz.exe runs (flowz view,
# flowz studio) or a scanner holds it: retry briefly, then fail with the binary
# unchanged. The caller removes $src.
function Install-Binary($src) {
  $dst = Join-Path $installDir 'flowz.exe'
  for ($try = 1; ; $try++) {
    try { Move-Item -Force -LiteralPath $src -Destination $dst -ErrorAction Stop; return }
    catch {
      if ($try -ge 5) {
        $why = $_.Exception.Message
        $left = if (Test-Path -LiteralPath $dst) { 'The installed flowz is unchanged.' } else { 'Nothing is installed now.' }
        # Only a flowz.exe that cannot be opened for writing is in use; any
        # other failure (access denied to the folder, full disk) says so plainly.
        $busy = $false
        if (Test-Path -LiteralPath $dst) {
          try { [IO.File]::Open($dst, 'Open', 'Write', 'None').Dispose() } catch [IO.IOException] { $busy = $true } catch { }
        }
        if ($busy) { Die "could not replace $dst ($why)`nflowz.exe is in use - stop ``flowz view`` / ``flowz studio`` and rerun. $left" }
        Die "could not replace $dst ($why). $left"
      }
      Start-Sleep -Seconds 1
    }
  }
}

# --- local mode ---------------------------------------------------------------
# Install the binary that came with this script. Nothing below touches the
# network, so this runs before the token check of the online path.
$localWanted = ($args -contains '-Local')
$localBin = $env:FLOWZ_BINARY
if ($env:FLOWZ_LOCAL -and $env:FLOWZ_LOCAL -notin @('0', '1')) { Die "FLOWZ_LOCAL must be 1 or 0, not '$($env:FLOWZ_LOCAL)'" }
if ($env:FLOWZ_LOCAL -eq '1') { $localWanted = $true }
# $PSScriptRoot is empty under `irm | iex` at a prompt, and is the CALLER's folder
# when another .ps1 pipes this script to iex: only a path that is this installer
# (it carries the marker line) counts.
$selfDir = $null
if ($PSCommandPath -and $PSScriptRoot -and (Test-Path -LiteralPath $PSCommandPath -PathType Leaf) -and
    (Select-String -LiteralPath $PSCommandPath -Pattern '^# flowz-install-script ' -Quiet)) { $selfDir = $PSScriptRoot }
if (-not $localBin -and $env:FLOWZ_LOCAL -ne '0' -and $selfDir -and
    ($localWanted -or (Test-Path -LiteralPath (Join-Path $selfDir 'SHA256SUMS') -PathType Leaf))) {
  $a = Get-Arch
  $found = @(Get-ChildItem -LiteralPath $selfDir -File -Filter "flowz_*_windows_$a.exe" -ErrorAction SilentlyContinue)
  if ($found.Count -gt 1) {
    Die "several flowz_*_windows_$a.exe binaries are beside this script: $(($found | ForEach-Object Name) -join ', ')`nKeep one, or name it: `$env:FLOWZ_BINARY = '<path>'"
  } elseif ($found.Count -eq 1) { $localBin = $found[0].FullName }
  elseif (Test-Path -LiteralPath (Join-Path $selfDir 'flowz.exe') -PathType Leaf) { $localBin = Join-Path $selfDir 'flowz.exe' }
  elseif ($localWanted) { Die "-Local but no flowz_*_windows_$a.exe or flowz.exe is beside $selfDir" }
} elseif (-not $localBin -and $localWanted) {
  Die "-Local needs the installer run as a file beside the binary (powershell -File .\install.ps1), or `$env:FLOWZ_BINARY = '<path>'"
}

if ($localBin) {
  if (-not (Test-Path -LiteralPath $localBin -PathType Leaf)) { Die "$localBin is not a file" }
  $binItem = Get-Item -LiteralPath $localBin
  $binName = $binItem.Name
  $sums = Join-Path $binItem.DirectoryName 'SHA256SUMS'
  if (-not (Test-Path -LiteralPath $sums -PathType Leaf)) { Die "no SHA256SUMS beside $binName (looked in $($binItem.DirectoryName)). Nothing was installed." }
  $want = $null
  foreach ($line in Get-Content -LiteralPath $sums) {
    if ($line -match '^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$' -and $Matches[2] -eq $binName) { $want = $Matches[1].ToLower(); break }
  }
  if (-not $want) { Die "SHA256SUMS has no entry for $binName. Nothing was installed." }
  $localVersion = $null
  if ($binName -match '^flowz_(.+)_[a-z0-9]+_[a-z0-9]+\.exe$') { $localVersion = $Matches[1] }
  if ($localVersion -and $env:FLOWZ_VERSION) {
    $wantV = $env:FLOWZ_VERSION; if (-not $wantV.StartsWith('v')) { $wantV = "v$wantV" }
    if ($wantV -ne $localVersion) { Die "FLOWZ_VERSION=$($env:FLOWZ_VERSION) but $binName is $localVersion. Nothing was installed." }
  }
  $label = if ($localVersion) { " $localVersion" } else { '' }
  if ((Get-Arch) -eq 'arm64') { Write-ArmWarning }
  Write-Host "Installing flowz$label from $binName (local, no network)..."
  New-Item -ItemType Directory -Force -Path $installDir | Out-Null
  # Verify the copy, not the source: nothing can swap the file between check and install.
  $staged = Join-Path $installDir ".flowz.install.$PID.exe"
  try {
    Copy-Item -LiteralPath $localBin -Destination $staged -Force
    $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $staged).Hash.ToLower()
    if ($got -ne $want) {
      Die "checksum mismatch for $binName`n  got:      $got`n  expected: $want`nThe file was corrupted or changed after SHA256SUMS was made. Nothing was installed."
    }
    Install-Binary $staged
  } finally {
    Remove-Item -Force -LiteralPath $staged -ErrorAction SilentlyContinue
  }
  Write-Host ""
  Write-Host "Installed flowz$label to $installDir\flowz.exe"
  Write-PathHint
  Write-Host "Updates: install a newer offline bundle."
  exit 0
}

if (-not $env:FLOWZ_TOKEN) {
  Die @"
FLOWZ_TOKEN is not set.
flowz is distributed privately to design partners. Set the access token you were
issued and re-run:
  `$env:FLOWZ_TOKEN = "<your token>"
"@
}

# --- platform -----------------------------------------------------------------
$arch = Get-Arch
$platform = "windows-$arch"

if ($arch -eq 'arm64') { Write-ArmWarning }

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
  # Windows PowerShell's progress bar slows this download about tenfold.
  $progress = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
  try {
    Invoke-WebRequest -Headers $authHeader -OutFile $gzPath `
      -Uri "${scheme}://$registry/v2/$repository/blobs/$binDigest"
  } finally { $ProgressPreference = $progress }

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
  Install-Binary $exePath

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

Write-PathHint
Write-Host "Future updates: flowz upgrade"
