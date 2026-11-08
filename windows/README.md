# Groovelight for Windows

Groovelight for Windows 11 (x64 and ARM64): C# on .NET 10 with WinUI 3 (Windows App SDK), the same features as the Mac app
with a Windows 11 (Fluent 2) interface. Released from 0.9.0 on: see the [main README](../README.md) for what it does and how
to install it.

## Layout

- `src/Groovelight.Core`: the library and its rules, no Windows APIs (builds and is tested on macOS too).
- `src/Groovelight.App`: the WinUI 3 app (unpackaged, self-contained).
- `tests/Groovelight.Tests`: xUnit v3 tests, on Microsoft.Testing.Platform.

## Release

`.github/workflows/release.yml` (job `windows`) builds, for x64 and ARM64:

- **The installers:** `dotnet publish` of the app (self-contained, with the `groovelight` command beside it), packed by
  Velopack into `Groovelight-win-Setup.exe` and `Groovelight-win-arm64-Setup.exe`, with the packages and
  `releases.<channel>.json` the installed app updates from.
- **The portable exes:** the same app published as one file (`PublishSingleFile`, `IncludeAllContentForSelfExtract`,
  compressed), `Groovelight-<version>-win-x64-Portable.exe` and the ARM64 one. Everything (the .NET and Windows App SDK
  runtimes, FFmpeg, the assets and `Groovelight.pri`) is inside and unpacked to a temporary folder when it starts. It
  does not update itself (Velopack only updates an installed app) and has no `groovelight` command.

To make the portable exe locally:

```sh
dotnet publish src/Groovelight.App -c Release -r win-x64 -p:Platform=x64 -p:PublishSingleFile=true \
  -p:IncludeAllContentForSelfExtract=true -p:EnableCompressionInSingleFile=true -p:DebugType=none -o portable
```

## Build

Needs the .NET 10 SDK (see `global.json`). The app builds on Windows only; the core and the tests anywhere.

```sh
dotnet test --project tests/Groovelight.Tests
dotnet build src/Groovelight.App/Groovelight.App.csproj -p:Platform=x64 -r win-x64      # or ARM64 / win-arm64
```

`Groovelight.exe --debug-snapshot <file.png>` renders the window to a PNG once it has laid out, then quits (for checking
the UI without a screen; nothing renders while the session is locked).
