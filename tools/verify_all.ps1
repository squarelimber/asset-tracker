# One-command full verification: analyze + tests + all-platform builds.
# Usage:
#   .\tools\verify_all.ps1                 # everything
#   .\tools\verify_all.ps1 -SkipAndroid    # skip the slow Gradle build
#   .\tools\verify_all.ps1 -ChangedOnly    # only rebuild platforms whose
#                                          # files changed (git diff vs HEAD)
#   .\tools\verify_all.ps1 -Force          # always build every platform
#
# Optimizations:
# - pub get runs exactly once; analyze/test/build all use --no-pub and
#   --no-version-check (avoids 5x redundant dependency resolution)
# - platform builds run in parallel (web/windows/android are independent
#   toolchains), cutting wall-clock time to the slowest build
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
$flutter = $null
$flutterCommand = Get-Command flutter.bat -ErrorAction SilentlyContinue
if ($flutterCommand) {
    $flutter = $flutterCommand.Source
} else {
    $flutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
    if ($flutterCommand) {
        $flutter = $flutterCommand.Source
    }
}
if (-not $flutter -and (Test-Path 'C:\flutter\flutter\bin\flutter.bat')) {
    $flutter = 'C:\flutter\flutter\bin\flutter.bat'
}
if (-not $flutter) {
    throw 'Flutter SDK not found. Add flutter to PATH or set the expected C:\flutter\flutter\bin\flutter.bat path.'
}

function Invoke-Step {
    param([string]$Name, [scriptblock]$Body)
    Write-Host "`n=== $Name ===" -ForegroundColor Cyan
    & $Body
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAILED: $Name" -ForegroundColor Red
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

# Resolve dependencies exactly once.
Invoke-Step 'flutter pub get' {
    & $flutter --no-version-check pub get 2>&1 | Out-Null
}

Invoke-Step 'flutter analyze' {
    & $flutter --no-version-check analyze --no-pub 2>&1 | Out-Host
}

Invoke-Step 'flutter test' {
    & $flutter --no-version-check test --no-pub 2>&1 | Out-Host
}

# Platform builds in parallel jobs; logs go to %TEMP%\verify_all_logs.
$jobsDir = Join-Path $env:TEMP 'verify_all_logs'
New-Item -ItemType Directory -Force -Path $jobsDir | Out-Null
$jobs = @()

if (-not $SkipWeb -and (Should-Build 'web')) {
    $jobs += Start-Job -Name web -ScriptBlock {
        param($f, $r, $log)
        Set-Location $r
        & $f --no-version-check build web --wasm --release --base-href=/asset-tracker/ *> $log
        $LASTEXITCODE
    } -ArgumentList $flutter, $root, "$jobsDir\web.log"
}

if (-not $SkipWindows -and (Should-Build 'windows')) {
    $jobs += Start-Job -Name windows -ScriptBlock {
        param($f, $r, $log)
        Set-Location $r
        & $f --no-version-check build windows --release *> $log
        $LASTEXITCODE
    } -ArgumentList $flutter, $root, "$jobsDir\windows.log"
}

if (-not $SkipAndroid -and (Should-Build 'android')) {
    $jobs += Start-Job -Name android -ScriptBlock {
        param($f, $r, $log)
        Set-Location $r
        & $f --no-version-check build apk --debug *> $log
        $LASTEXITCODE
    } -ArgumentList $flutter, $root, "$jobsDir\android.log"
}

$failed = $false
foreach ($j in $jobs) {
    $result = Receive-Job -Job $j -Wait -AutoRemoveJob
    $code = if ($result.Count -gt 0) { $result[-1] } else { 0 }
    if ($code -ne 0) {
        Write-Host "FAILED: $($j.Name) build (exit $code)" -ForegroundColor Red
        Get-Content "$jobsDir\$($j.Name).log" -Tail 25 | Out-Host
        $failed = $true
    } else {
        Write-Host "OK: $($j.Name) build" -ForegroundColor Green
    }
}
if ($failed) { exit 1 }

Write-Host "`nAll checks passed." -ForegroundColor Green
exit 0
