# Diagnostic ADB and terminal UI checks

Run from the project root with .NET 10:

```sh
dotnet run --project Windows_x64/tests-ui/DiagnosticUiTests.csproj
```

The harness compiles current Windows UI sources for the local host, independently of the Windows application project. It never restores or edits `src/packages.lock.json`; its hash is checked before and after. No modem calls, user preferences, or live credentials are used.

Checks cover RU/EN force-ADB availability with existing SSH, terminal and pending-operation guards, preparation resume, the diagnostic help dialog, final terminal rows after output and resize, horizontal scrolling, and preservation of manual scrollback. Screenshots are written to `zte-diagnostic-terminal-ui` in the operating system temporary directory.
