# Groovelight for Windows

The Windows 11 port of Groovelight: C# on .NET 10 with WinUI 3 (Windows App SDK), the same features as the Mac app with
a Windows 11 (Fluent 2) interface. Work in progress: see the plan in the project notes.

## Layout

- `src/Groovelight.Core`: the library and its rules, no Windows APIs (builds and is tested on macOS too).
- `src/Groovelight.App`: the WinUI 3 app (unpackaged, self-contained).
- `tests/Groovelight.Tests`: xUnit v3 tests, on Microsoft.Testing.Platform.

## Build

Needs the .NET 10 SDK (see `global.json`). The app builds on Windows only; the core and the tests anywhere.

```sh
dotnet test --project tests/Groovelight.Tests
dotnet build src/Groovelight.App/Groovelight.App.csproj -p:Platform=x64 -r win-x64      # or ARM64 / win-arm64
```

`Groovelight.exe --debug-snapshot <file.png>` renders the window to a PNG once it has laid out, then quits (for checking
the UI without a screen; nothing renders while the session is locked).
