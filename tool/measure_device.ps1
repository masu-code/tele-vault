# Runs one perf measurement on the physical device in PROFILE mode and prints
# NUMBERS ONLY (no screenshots, no names/paths, no raw dumps).
#
#   tool/measure_device.ps1 -Test crypto_bench
#   tool/measure_device.ps1 -Test synthetic_gallery [-Impeller on|off] [-KeepSynth]
#   tool/measure_device.ps1 -Test real_timing -AllowReal      # owner permission each time
#
# What it does for synthetic_gallery / real_timing:
#   1. starts `adb logcat` (tag flutter only) to a scratch file,
#   2. starts `flutter drive --profile` with test_driver/perf_driver.dart,
#   3. when the test logs "TVDIAG: SCRIPT_START" -> `dumpsys gfxinfo <pkg> reset`,
#   4. when it logs "TVDIAG: SCRIPT_END" -> `dumpsys gfxinfo` + `dumpsys meminfo`
#      and prints only: frames, janky %, 50/90/95/99th percentile, slow-UI/
#      vsync counters, TOTAL PSS, Native Heap, Graphics. (The test holds the app
#      alive ~10 s after SCRIPT_END for this.)
#   The test's own report is written by the driver to build/perf/<test>.json.
#   A numbers-only summary of the device side goes to build/perf/<test>_device.txt.
#
# Prereqs: device connected, debugging on, screen unlocked and awake.
# Never run real_timing without the owner's permission (it reads the real library).

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("crypto_bench", "synthetic_gallery", "real_timing")]
    [string]$Test,
    [ValidateSet("default", "on", "off")]
    [string]$Impeller = "default",
    [string]$Device = $env:TV_DEVICE,
    [string]$Package = "com.masucode.tele_vault",
    [int]$ImageCacheItems = 600,
    [int]$ImageCacheMb = 120,
    [int]$SynthN = 6000,
    [switch]$KeepSynth,
    [switch]$AllowReal,
    [string]$SessionFile = "",
    [int]$TimeoutMin = 25
)

$ErrorActionPreference = "Stop"
$adb = if ($env:ANDROID_HOME) { Join-Path $env:ANDROID_HOME "platform-tools\adb.exe" } else { Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools\adb.exe" }
$flutter = (Get-Command flutter -ErrorAction Stop).Source
$projectDir = Split-Path $PSScriptRoot -Parent
Set-Location $projectDir

if ($Test -eq "real_timing" -and -not $AllowReal) {
    throw "real_timing reads the REAL library. Get the owner's permission, then pass -AllowReal."
}

$perfDir = Join-Path $projectDir "build\perf"
New-Item -ItemType Directory -Force -Path $perfDir | Out-Null
$scratch = Join-Path $env:TEMP "tv_measure_$Test"
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
$driveOut = Join-Path $scratch "drive.out"
$driveErr = Join-Path $scratch "drive.err"
$logcatOut = Join-Path $scratch "logcat.out"
Remove-Item $driveOut, $driveErr, $logcatOut -ErrorAction SilentlyContinue

function Read-Shared([string]$path) {
    if (-not (Test-Path $path)) { return "" }
    $fs = [IO.File]::Open($path, "Open", "Read", "ReadWrite")
    try { $sr = New-Object IO.StreamReader($fs); return $sr.ReadToEnd() } finally { $fs.Dispose() }
}

$state = (& $adb -s $Device get-state 2>$null)
if ($state -ne "device") { throw "Device $Device not connected (adb get-state = '$state')." }

$driveArgs = @(
    "drive",
    "--driver=test_driver/perf_driver.dart",
    "--target=integration_test/${Test}_test.dart",
    "--profile", "-d", $Device,
    "--dart-define=TV_IMG_CACHE_ITEMS=$ImageCacheItems",
    "--dart-define=TV_IMG_CACHE_MB=$ImageCacheMb",
    "--dart-define=TV_SYNTH_N=$SynthN"
)
if ($KeepSynth) { $driveArgs += "--dart-define=TV_KEEP_SYNTH=true" }
if ($Impeller -eq "on") { $driveArgs += "--enable-impeller" }
if ($Impeller -eq "off") { $driveArgs += "--no-enable-impeller" }
if ($SessionFile -ne "" -and $Test -eq "real_timing") {
    $json = Get-Content $SessionFile -Raw
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    $driveArgs += "--dart-define=TV_SESSION_B64=$b64"
}

Write-Host "== $Test  impeller=$Impeller  device=$Device  imageCache=$ImageCacheItems/${ImageCacheMb}MB =="

& $adb -s $Device logcat -c | Out-Null
$lc = Start-Process -FilePath $adb -ArgumentList @("-s", $Device, "logcat", "-v", "brief", "flutter:I", "*:S") `
    -RedirectStandardOutput $logcatOut -PassThru -NoNewWindow
$drive = Start-Process -FilePath $flutter -ArgumentList $driveArgs `
    -RedirectStandardOutput $driveOut -RedirectStandardError $driveErr -PassThru -NoNewWindow

$deviceLines = New-Object System.Collections.Generic.List[string]
$didReset = $false
$didSample = $false
$deadline = (Get-Date).AddMinutes($TimeoutMin)

function Add-Out([string]$line) { Write-Host $line; $script:deviceLines.Add($line) }

try {
    while (-not $drive.HasExited) {
        if ((Get-Date) -gt $deadline) { Stop-Process -Id $drive.Id -Force; throw "Timed out after $TimeoutMin min." }
        if ($Test -ne "crypto_bench") {
            $text = Read-Shared $logcatOut
            if (-not $didReset -and $text -match "TVDIAG: SCRIPT_START") {
                & $adb -s $Device shell dumpsys gfxinfo $Package reset | Out-Null
                $didReset = $true
                Write-Host "[gfxinfo reset at SCRIPT_START]"
            }
            if ($didReset -and -not $didSample -and $text -match "TVDIAG: SCRIPT_END") {
                $didSample = $true
                Add-Out "--- gfxinfo (script window) ---"
                $gfx = & $adb -s $Device shell dumpsys gfxinfo $Package
                $gfx | Where-Object {
                    $_ -match '^\s*(Total frames rendered|Janky frames|\d+th percentile|Number (Missed Vsync|High input latency|Slow UI thread|Slow bitmap uploads|Slow issue draw commands|Frame deadline missed))'
                } | ForEach-Object { Add-Out ($_.Trim()) }
                Add-Out "--- meminfo ---"
                $mem = & $adb -s $Device shell dumpsys meminfo $Package
                $mem | Where-Object {
                    $_ -match '^\s*(TOTAL PSS|TOTAL RSS|TOTAL\s|Native Heap|Dalvik Heap|Graphics:|Java Heap:|Native Heap:|Code:|Stack:|Private Other:|System:)'
                } | ForEach-Object { Add-Out (($_.Trim()) -replace '\s{2,}', '  ') }
            }
        }
        Start-Sleep -Milliseconds 200
    }
} finally {
    if (-not $lc.HasExited) { Stop-Process -Id $lc.Id -Force -ErrorAction SilentlyContinue }
}

# Numbers-only extracts from the logs (strict allow-list of our own TVDIAG lines).
$lcText = Read-Shared $logcatOut
Write-Host "--- test output ---"
$lcText -split "`r?`n" | Where-Object {
    $_ -match 'TVDIAG: (BENCH|PARITY|SCRIPT_|RESULT|HOLD|synthetic files|real feed|wrote)'
} | ForEach-Object { ($_ -replace '^.*?TVDIAG:', 'TVDIAG:').Trim() } | ForEach-Object { Add-Out $_ }

$imp = $lcText -split "`r?`n" | Where-Object { $_ -match 'Impeller rendering backend' } | Select-Object -First 1
if ($imp) { Add-Out ("renderer: " + ($imp -replace '^.*?(Using the Impeller rendering backend.*)$', '$1').Trim()) }
elseif ($Test -ne "crypto_bench") { Add-Out "renderer: no Impeller line seen (Skia, or the flag was ignored by the manifest)" }

$outText = Read-Shared $driveOut
if ($outText -match "All tests passed") { Add-Out "RESULT: PASS" } else { Add-Out "RESULT: FAIL (see build\perf and the drive log in $scratch)" }

$deviceLines | Set-Content -Encoding utf8 (Join-Path $perfDir "${Test}_device.txt")
Write-Host "Report: build\perf\$Test.json (test) and build\perf\${Test}_device.txt (device side)."
if ($drive.ExitCode -ne 0) { exit $drive.ExitCode }
