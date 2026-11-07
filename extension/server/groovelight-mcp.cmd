@echo off
rem Claude Desktop runs this on Windows: the MCP server of the installed Groovelight (`groovelight mcp`, next to the
rem app), so the server always matches the app. %1: the folder of another copy to use (the "Groovelight app" setting).
rem It always runs in its own cmd /c, so a plain exit hands the code to Claude Desktop (exit /b in a block would not).
setlocal
set "tool="
if not "%~1"=="" (
    if not exist "%~1\groovelight.com" (
        echo The Groovelight folder set in the extension's settings ^(%~1^) has no groovelight.com. 1>&2
        exit 1
    )
    set "tool=%~1\groovelight.com"
)
rem The installer puts Groovelight in the user's own folder, which only they can change.
if not defined tool if exist "%LOCALAPPDATA%\Groovelight\current\groovelight.com" set "tool=%LOCALAPPDATA%\Groovelight\current\groovelight.com"
if not defined tool (
    echo Groovelight for Windows is not installed ^(it includes the command line tool this extension runs^). 1>&2
    echo Download it from https://github.com/irwingbraga/groovelight/releases/latest 1>&2
    exit 1
)
"%tool%" mcp
