# Runs the on-device integration tests against the REAL Telegram network on a
# physical Android device (e.g. MIUI/Xiaomi), reproducing the OS-kills-socket
# condition and verifying the reconnect fix end to end.
#
# The Telegram session is injected at runtime via --dart-define so credentials
# never live in the repo. It is read from a file in the user's home directory
# (NOT the repo) — capture it once while the app is logged in.
#
# Usage:
#   tool/run_device_tests.ps1                 # run the tests
#   tool/run_device_tests.ps1 -CaptureSession # pull a fresh session from device
#
# Prereqs:
#   - Device connected via USB with debugging enabled.
#   - Screen unlocked & awake (MIUI cuts app network in Doze; the test enables
#     wakelock but the screen must be on when it starts).
#   - First run after an uninstall shows a MIUI "install via USB" dialog —
#     accept it on the phone.

param(
    [switch]$CaptureSession,
    [string]$Device = $env:TV_DEVICE,
    [string]$Package = "com.masucode.tele_vault",
    [string]$SessionFile = "$env:USERPROFILE\.tele_vault_device_session.json"
)

$ErrorActionPreference = "Stop"
$adb = if ($env:ANDROID_HOME) { Join-Path $env:ANDROID_HOME "platform-tools\adb.exe" } else { Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools\adb.exe" }
$flutter = (Get-Command flutter -ErrorAction Stop).Source
$projectDir = Split-Path $PSScriptRoot -Parent

if ($CaptureSession) {
    Write-Host "Capturing session from device (app must be logged in)..."
    $json = & $adb shell "run-as $Package cat app_flutter/tele_vault_session.json"
    if ([string]::IsNullOrWhiteSpace($json) -or $json -match "unknown package") {
        throw "Could not read session. Is the app installed and logged in?"
    }
    $json | Out-File -FilePath $SessionFile -Encoding ascii -NoNewline
    Write-Host "Saved session to $SessionFile ($($json.Length) chars)."
    exit 0
}

if (-not (Test-Path $SessionFile)) {
    throw "No session file at $SessionFile. Log in on the app, then run: tool/run_device_tests.ps1 -CaptureSession"
}

# Ensure the app is installed so flutter's install is an upgrade (no MIUI dialog).
$installed = & $adb shell pm list packages 2>$null | Select-String $Package
if (-not $installed) {
    $apk = Join-Path $projectDir "build\app\outputs\flutter-apk\app-debug.apk"
    if (Test-Path $apk) {
        Write-Host "App not installed — installing existing APK (accept the dialog on the phone)..."
        & $adb install -r $apk
    } else {
        Write-Host "App not installed and no prebuilt APK; flutter will install (accept the MIUI dialog)."
    }
}

$json = Get-Content $SessionFile -Raw
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))

Write-Host "Running on-device integration tests (keep the screen unlocked)..."
Set-Location $projectDir
& $flutter test integration_test/reconnect_test.dart -d $Device --dart-define=TV_SESSION_B64=$b64
