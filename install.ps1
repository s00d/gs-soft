# Gateway Soft installer for Windows: installs or updates to the latest GitHub release.
#
#   irm https://s00d.github.io/gs-soft/install.ps1 | iex
#
# Environment: $env:GS_VERSION = "v0.8.0" (a specific release), $env:GS_REPO = "owner/name".
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"  # Invoke-WebRequest is many times slower with the bar
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$repo = if ($env:GS_REPO) { $env:GS_REPO } else { "s00d/gs-soft" }
$api = if ($env:GS_VERSION) {
  "https://api.github.com/repos/$repo/releases/tags/$($env:GS_VERSION)"
} else {
  "https://api.github.com/repos/$repo/releases/latest"
}

function Say($text) { Write-Host "==> $text" -ForegroundColor Cyan }

Say "Reading release info from github.com/$repo"
try {
  $release = Invoke-RestMethod -Uri $api -Headers @{ Accept = "application/vnd.github+json"; "User-Agent" = "gateway-soft-installer" }
} catch {
  throw "No published release found ($(if ($env:GS_VERSION) { $env:GS_VERSION } else { 'latest' }))"
}

# PROCESSOR_ARCHITEW6432 is set when a 32-bit PowerShell runs on 64-bit Windows.
$cpu = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
$suffix = switch ($cpu) {
  "AMD64" { "_x64-setup.exe" }
  "ARM64" { "_arm64-setup.exe" }
  "x86" { "_x86-setup.exe" }
  default { throw "Unsupported CPU: $cpu" }
}

$asset = $release.assets | Where-Object { $_.name.EndsWith($suffix) } | Select-Object -First 1
if (-not $asset) { throw "Release $($release.tag_name) has no installer for $cpu" }

$file = Join-Path ([IO.Path]::GetTempPath()) $asset.name
Say "Downloading $($asset.name)"
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $file -UseBasicParsing

if ($asset.digest -and $asset.digest.StartsWith("sha256:")) {
  $want = $asset.digest.Substring(7)
  $got = (Get-FileHash -Algorithm SHA256 -Path $file).Hash
  if ($got -ne $want) { Remove-Item $file -Force; throw "SHA-256 mismatch for $($asset.name)" }
  Say "SHA-256 verified"
}

# NSIS installer, silent; updating closes the running app first.
Get-Process -Name "gateway-soft-rs" -ErrorAction SilentlyContinue | Stop-Process -Force
Say "Installing $($release.tag_name)"
$proc = Start-Process -FilePath $file -ArgumentList "/S" -Wait -PassThru
Remove-Item $file -Force -ErrorAction SilentlyContinue
if ($proc.ExitCode -ne 0) { throw "Installer exited with code $($proc.ExitCode)" }

Say "Installed Gateway Soft $($release.tag_name)"
Write-Host "    Start it from the Start menu. Headless: gateway-soft-rs.exe --serve --print-secret"
