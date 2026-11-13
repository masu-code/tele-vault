# Takes the README / landing-page screenshots from a DEMO library on an Android
# EMULATOR (never a physical phone, never real data).
#
#   tool/demo/screenshots.ps1                    # uses emulator-5554
#   tool/demo/screenshots.ps1 -Device emulator-5556
#
# Use a FRESH emulator: the test itself refuses to run when the app already holds
# a Telegram session or any non-demo thumbnails, i.e. a real install. The
# `tv_demo` AVD was made for this (Pixel 6 profile, API 34 Google APIs x86_64);
# boot it with `emulator -avd tv_demo -no-snapshot` so its data starts clean.
#
# What it does:
#   1. refuses any device that is not an emulator, and waits (up to 15 min) for any other
#      running flutter tool (two concurrent flutter commands in one project
#      corrupt the build);
#   2. puts the emulator in dark mode with a clean status bar (SystemUI demo
#      mode: 12:00, full battery, no notifications);
#   3. pushes tool/demo/photos (+ manifest.json) into the app's own private
#      files dir (`app_flutter/demo_photos`, via /data/local/tmp and run-as);
#   4. runs integration_test/screenshots_test.dart, which renders the real
#      screens over generated demo data and prints `TVSHOT:<name>` for each one;
#   5. grabs an `adb screencap` of the emulator the moment each marker appears
#      and writes build/screenshots_raw/<name>.png (1080x2400 on the tv_demo AVD);
#   6. removes the pushed photos and leaves demo mode.
#
# Then optimise: python tool/demo/optimize_screenshots.py
#
# Prereqs: a fresh emulator is booted and the sample photos are in
# tool/demo/photos (see CREDITS.md there). The dart define
# TV_DEMO_SCREENSHOTS=true is passed for you; the test refuses to run without it.

param(
    [string]$Device = "emulator-5554",
    [string]$Package = "com.masucode.tele_vault",
    [string]$PhotosDir = "",
    [string]$OutDir = "build\screenshots_raw"
)

# adb writes progress to stderr; failures are checked explicitly below.
$ErrorActionPreference = "Continue"
if ($Device -notlike "emulator-*") {
    throw "Refusing to run on '$Device': demo screenshots are only taken on an emulator."
}

$projectDir = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$adb = if ($env:ANDROID_HOME) { Join-Path $env:ANDROID_HOME "platform-tools\adb.exe" } else { Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools\adb.exe" }
$flutter = (Get-Command flutter -ErrorAction Stop).Source
$photos = if ($PhotosDir) { $PhotosDir } else { Join-Path $projectDir "tool\demo\photos" }
$out = Join-Path $projectDir $OutDir
$stage = "/data/local/tmp/tv_demo_photos"
$remote = "app_flutter/demo_photos"   # relative to the app's data dir (run-as)

function Adb { & $adb -s $Device @args }

# 1. guards ---------------------------------------------------------------
function Get-FlutterBusy {
    Get-CimInstance Win32_Process | Where-Object {
        $_.Name -eq "dart.exe" -and $_.CommandLine -match "flutter_tools.snapshot" -and $_.CommandLine -match "\b(build|test|run|drive|install|analyze)\b"
    }
}
$waited = 0
while ((Get-FlutterBusy) -and $waited -lt 900) { Start-Sleep -Seconds 5; $waited += 5 }
$busy = Get-FlutterBusy
if ($busy) { throw "Another flutter tool command is still running (pid $($busy[0].ProcessId)); try again later." }

$state = (& $adb devices | Select-String "^$Device\s+device")
if (-not $state) { throw "$Device is not connected/booted." }
if ((Adb shell getprop ro.kernel.qemu).Trim() -ne "1" -and (Adb shell getprop ro.boot.qemu).Trim() -ne "1") {
    throw "$Device does not report itself as an emulator."
}
if (-not (Test-Path (Join-Path $photos "manifest.json"))) { throw "tool/demo/photos/manifest.json is missing." }

# 2. clean system UI ------------------------------------------------------
Adb shell cmd uimode night yes | Out-Null
Adb shell cmd overlay enable com.android.internal.systemui.navbar.gestural 2>$null | Out-Null
Adb shell settings put global sysui_demo_allowed 1 | Out-Null
$demo = "am broadcast -a com.android.systemui.demo"
Adb shell "$demo -e command enter" | Out-Null
Adb shell "$demo -e command clock -e hhmm 1200" | Out-Null
Adb shell "$demo -e command battery -e level 100 -e plugged false" | Out-Null
Adb shell "$demo -e command network -e wifi show -e level 4 -e fully true" | Out-Null
Adb shell "$demo -e command network -e mobile show -e datatype none -e level 4 -e fully true" | Out-Null
Adb shell "$demo -e command notifications -e visible false" | Out-Null
Adb shell input keyevent KEYCODE_WAKEUP | Out-Null
Adb shell wm dismiss-keyguard | Out-Null

# 3. the app (first run) and the sample photos -----------------------------
if (-not (Adb shell pm list packages $Package | Select-String $Package)) {
    $apk = Join-Path $projectDir "build\app\outputs\flutter-apk\app-debug.apk"
    if (-not (Test-Path $apk)) {
        Write-Host "Building the debug APK..."
        Push-Location $projectDir
        try {
            & $flutter build apk --debug
            if ($LASTEXITCODE -ne 0) { throw "flutter build apk failed" }
        } finally { Pop-Location }
    }
    Write-Host "Installing $apk on $Device (grants runtime permissions)..."
    Adb install -r -g $apk | Out-Null
}
Adb shell pm grant $Package android.permission.READ_MEDIA_IMAGES 2>$null | Out-Null
Adb shell pm grant $Package android.permission.READ_MEDIA_VIDEO 2>$null | Out-Null
Adb shell pm grant $Package android.permission.POST_NOTIFICATIONS 2>$null | Out-Null
Adb shell "rm -rf $stage; mkdir -p $stage" | Out-Null
Adb push "$photos\." $stage | Out-Null
Adb shell "rm -f $stage/CREDITS.md; chmod -R a+rX $stage" | Out-Null
# adb-pushed files are not readable by the app on scoped storage: copy them into
# the app's private dir (debug builds allow run-as).
Adb shell "run-as $Package sh -c 'rm -rf $remote; mkdir -p $remote; cp $stage/* $remote/'" | Out-Null

# 4+5. run the test, capture at each marker (read from the flutter tool's stdout) --------------------------------
New-Item -ItemType Directory -Force $out | Out-Null
Get-ChildItem $out -Filter *.png | Remove-Item -Force
$testLog = Join-Path $out "flutter_test.log"
$test = Start-Process -FilePath $flutter -WorkingDirectory $projectDir -PassThru -NoNewWindow `
    -RedirectStandardOutput $testLog -RedirectStandardError (Join-Path $out "flutter_test.err.log") `
    -ArgumentList @("test", "integration_test/screenshots_test.dart", "-d", $Device, "--dart-define=TV_DEMO_SCREENSHOTS=true")
$null = $test.Handle   # keeps ExitCode readable after the process ends

# The flutter tool echoes the app's `TVSHOT:<name>` lines into its stdout log.
$shots = @()
$seen = @{}
while (-not $test.HasExited) {
    Start-Sleep -Milliseconds 250
    $fs = [System.IO.File]::Open($testLog, 'Open', 'Read', 'ReadWrite')
    $text = (New-Object System.IO.StreamReader $fs).ReadToEnd()
    $fs.Close()
    foreach ($m in [regex]::Matches($text, "TVSHOT:(\w+)")) {
        $name = $m.Groups[1].Value
        if ($seen.ContainsKey($name)) { continue }
        $seen[$name] = $true
        $png = Join-Path $out "$name.png"
        # exec-out keeps the PNG binary-safe
        cmd.exe /c "`"$adb`" -s $Device exec-out screencap -p > `"$png`""
        $shots += $name
        Write-Host "captured $name ($((Get-Item $png).Length) bytes)"
    }
}

# 6. cleanup ---------------------------------------------------------------
Adb shell "run-as $Package rm -rf $remote; rm -rf $stage" | Out-Null
Adb shell "$demo -e command exit" | Out-Null

Write-Host "flutter test exit code: $($test.ExitCode); screenshots: $($shots -join ', ')"
Write-Host "raw PNGs in $out ; test log in $testLog"
if ($test.ExitCode -ne 0) { exit $test.ExitCode }
