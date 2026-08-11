# One-command full verification: analyze + tests + all-platform builds.
# Usage:
#   .\tools\verify_all.ps1                 # everything
#   .\tools\verify_all.ps1 -SkipAndroid    # skip the slow Gradle build
#   .\tools\verify_all.ps1 -ChangedOnly    # only rebuild platforms whose
#                                          # files changed (git diff vs HEAD)
#   .\tools\verify_all.ps1 -Force          # always build every platform
#
# Exit code 0 = all green; any failure stops the script.

param(
    [switch]$SkipWeb,
    [switch]$SkipWindows,
    [switch]$SkipAndroid,
    [switch]$ChangedOnly,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$flutter = 'C:\flutter\flutter\bin\flutter.bat'
$failed = $false

function Invoke-Step {
    param([string]$Name, [scriptblock]$Body)
    Write-Host "`n=== $Name ===" -ForegroundColor Cyan
    & $Body
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAILED: $Name" -ForegroundColor Red
        $script:failed = $true
        exit 1
    }
}

# Which platforms were touched by uncommitted changes (vs HEAD)?
function Get-ChangedPlatforms {
    # -c core.autocrlf=false keeps git quiet (no LF/CRLF warnings on stderr).
    $changed = & git -C $root -c core.autocrlf=false diff --name-only HEAD 2>$null
    $changed += & git -C $root -c core.autocrlf=false diff --cached --name-only 2>$null
    $all = @($changed) -join "`n"
    $libChanged = $all -match '(^|\n)(lib|pubspec\.(yaml|lock))(/|\.|$)'
    $platforms = @()
    if ($libChanged -or $all -match '(^|\n)web/') { $platforms += 'web' }
    if ($libChanged -or $all -match '(^|\n)windows/') { $platforms += 'windows' }
    if ($libChanged -or $all -match '(^|\n)android/') { $platforms += 'android' }
    if ($platforms.Count -eq 0) { $platforms = @('web', 'windows', 'android') }
    return $platforms
}

$changedPlatforms = @()
if ($ChangedOnly -and -not $Force) {
    $changedPlatforms = Get-ChangedPlatforms
    Write-Host "Changed-only mode: building $($changedPlatforms -join ', ')" -ForegroundColor Yellow
}

function Should-Build([string]$platform) {
    if ($Force) { return $true }
    if ($ChangedOnly -and -not $Force) { return $changedPlatforms -contains $platform }
    return $true
}

Invoke-Step 'flutter analyze' { & $flutter analyze 2>&1 | Out-Host }

Invoke-Step 'flutter test' { & $flutter test 2>&1 | Out-Host }

if (-not $SkipWeb -and (Should-Build 'web')) {
    Invoke-Step 'build web (wasm release)' {
        Push-Location $root
        try { & $flutter build web --wasm --release --base-href=/asset-tracker/ 2>&1 | Out-Host }
        finally { Pop-Location }
    }
} else {
    Write-Host 'SKIP web build' -ForegroundColor Yellow
}

if (-not $SkipWindows -and (Should-Build 'windows')) {
    Invoke-Step 'build windows (release)' {
        Push-Location $root
        try { & $flutter build windows --release 2>&1 | Out-Host }
        finally { Pop-Location }
    }
} else {
    Write-Host 'SKIP windows build' -ForegroundColor Yellow
}

if (-not $SkipAndroid -and (Should-Build 'android')) {
    Invoke-Step 'build android (debug apk)' {
        Push-Location $root
        try { & $flutter build apk --debug 2>&1 | Out-Host }
        finally { Pop-Location }
    }
} else {
    Write-Host 'SKIP android build' -ForegroundColor Yellow
}

Write-Host "`nAll checks passed." -ForegroundColor Green
exit 0
