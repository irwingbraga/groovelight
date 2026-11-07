# Downloads FFmpeg 9.0 (LGPL, shared libraries and ffmpeg.exe) for Windows x64 and ARM64 into native\ffmpeg\<runtime>, where the build
# picks the DLLs up. Builds from BtbN/FFmpeg-Builds; run once per checkout (and in CI).
param([string[]]$Runtimes = @('win-x64', 'win-arm64'))
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Join-Path $PSScriptRoot '..\native\ffmpeg'
$names = @{ 'win-x64' = 'win64'; 'win-arm64' = 'winarm64' }
foreach ($runtime in $Runtimes) {
    $target = Join-Path $root $runtime
    if ((Test-Path (Join-Path $target 'avcodec-*.dll')) -and (Test-Path (Join-Path $target 'ffmpeg.exe'))) { Write-Host "FFmpeg for $runtime is already there."; continue }
    $zip = Join-Path ([IO.Path]::GetTempPath()) "ffmpeg-$runtime.zip"
    $url = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-n9.0-latest-$($names[$runtime])-lgpl-shared-9.0.zip"
    Write-Host "Downloading $url"
    Invoke-WebRequest $url -OutFile $zip
    $staging = Join-Path ([IO.Path]::GetTempPath()) "ffmpeg-$runtime"
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
    Expand-Archive $zip $staging
    New-Item -ItemType Directory -Force $target | Out-Null
    Get-ChildItem $staging -Recurse -Filter *.dll | Where-Object { $_.Directory.Name -eq 'bin' } | Copy-Item -Destination $target
    # The command-line tool too: devices get songs converted (FLAC, Opus, AAC, MP3) through it.
    Get-ChildItem $staging -Recurse -Filter ffmpeg.exe | Where-Object { $_.Directory.Name -eq 'bin' } | Copy-Item -Destination $target
    Get-ChildItem $staging -Recurse -Filter LICENSE.txt | Select-Object -First 1 | Copy-Item -Destination (Join-Path $target 'LICENSE.txt')
    Remove-Item $zip, $staging -Recurse -Force
    Write-Host "FFmpeg for $runtime is in $target."
}
