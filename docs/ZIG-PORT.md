# MakePack Zig port - handoff

Branch `zig`. The C# build in `legacy/` is the specification (Engine.cs, Program.cs incl. `--selftest`, Cli.cs,
Assoc.cs, Settings.cs, Strings.cs, Shell.cs, forms), plus `legacy/shell/MakePackShell.cpp` + `shell/test`,
`tools/bugtest.ps1` (CLI black box), `docs/*.md`, `.scratch/*/issues/*.md` (ticket decisions, Ukrainian).
Zig 0.17.1 at `%LOCALAPPDATA%\Programs\zig\0.17.1\zig.exe`; read `../MakeKit/docs/ZIG-0.17-NOTES.md` first.

## Build steps

| Step | What |
|---|---|
| `zig build` | `zig-out/bin`: MakePack.exe (GUI subsystem, icon 1 + kit manifest via `app.rc`), 7z.dll, 7z.sfx, MakePackShell.dll |
| `zig build test` | every unit test: `src/test_all.zig` + shell.zig's own tests |
| `zig build test-base` | strings, settings, shared types, testutil |
| `zig build test-sevenzip` / `test-engine` / `test-platform` | one package's tests (`test-engine` runs the whole `--selftest`) |
| `zig build test-shell` | shell.zig unit tests + MakePackShell.dll + `shell/test/{harness,fake_makepack}.cpp` (zig c++, static libc++, wmain), runs the harness |
| `zig build shell` | MakePackShell.dll only (tools/build_shell.ps1 uses `test-shell shell`, no MakePack.exe build) |
| `zig build run` | runs MakePack.exe (no arguments) |

Tests get absolute paths of the bundled 7-Zip files from `@import("paths")`: `seven_zip_dll`, `seven_zip_sfx`,
`seven_zip_exe` (7z.exe = test oracle only, never installed).

ReleaseSafe sizes (2026-11-10): MakePack.exe 3,256,320 bytes, MakePackShell.dll 956,928 bytes (+ .pdb files).

## Packages

| Id | Owned files | Spec | Tests | Status |
|---|---|---|---|---|
| skeleton | build.zig, build.zig.zon, app.rc, src/main.zig, src/strings.zig, src/settings.zig, src/core/types.zig, src/testutil.zig, src/test_base.zig, src/test_all.zig, docs/ZIG-PORT.md | Strings.cs, Settings.cs, Program.Main | test-base: 16 pass | done |
| MP-A | src/core/sevenzip.zig, src/test_sevenzip.zig | SevenZipSharp usage in Engine.cs; 7-Zip's IArchive.h | test-sevenzip: 19 pass | done (open items below) |
| MP-B | src/core/engine.zig, src/selftest.zig, src/test_engine.zig | Engine.cs, Program.SelfTest | test-engine: 29 pass; `MakePack --selftest`: ALL OK | done (gui check deferred) |
| MP-C | src/platform/assoc.zig, single.zig, cli.zig, platform_win.zig, platform_dispatch.zig, src/test_platform.zig | Assoc.cs, Cli.cs, Program.Main/Send/Serve/Absolute/RegistryVerb/UseConsole | test-platform: 52 pass (e2e CLI included) | done |
| MP-D | shell/shell.zig, tools/build_shell.ps1, shell/package/*, shell/test/* | legacy/shell/MakePackShell.cpp | test-shell: 5 unit tests + harness ALL OK | done (not run in a real Explorer) |
| integration | cross-package fixes, selftest registry/single checks, build.zig shell steps | all | `zig build test` 71 + 5 pass; black-box CLI; single instance | done |
| GUI | later phase (src/gui/...) | forms, Shell.cs, Program.Dispatch | MakeKit imgui-auto | placeholder window |

`src/core/types.zig` and `src/testutil.zig` are shared: a public signature change = a line in "Contract changes".

## Verified at integration (2026-11-10)
- `zig build test`, `test-base`, `test-sevenzip`, `test-engine`, `test-platform`, `test-shell`: all pass.
- `zig-out/bin/MakePack.exe --selftest` (ReleaseSafe, MAKEPACK_SETTINGS in temp): every check OK, `gui: deferred`,
  `ALL OK`, exit 0. Includes the new `registry` (register/heal/addmenu/unregister under
  `HKCU\Software\MakePackTest-<random>`, deleted) and `single` (mutex owner/client + pipe round trip, private name).
- Black-box CLI from PowerShell (redirected stdout/stderr, temp dir, 7z.exe as oracle): `a -t7z` 0, existing
  without -y 2, `-p<value>` 7, bad switch 7, no-match mask 10, `t` 0 + TestOk text, `l` report, `x -y -o` 0 with
  byte-identical files (also vs 7z.exe's extraction), damaged 3, header-encrypted without / with a wrong password 11,
  zip-slip `x -y` 1 with nothing outside dest.
- Single instance (GUI placeholder, MAKEPACK_INSTANCE + MAKEKIT_DISPLAY=\\.\DISPLAY1): the second process forwards
  and exits 0 in ~20 ms, exactly one process remains, quit via MakeKit automation exits 0, no leak report.
- No `MakePackTest-*` key or `makepack-test-*` / `MakePack-selftest-*` folder left behind.

## Contracts

### Shared data (src/core/types.zig, re-exported by engine.zig)
- Enums persisted in settings.json or the registry keep the **C# member spelling** (`ArchiveKind.SevenZip`,
  `.TarGz`, `CompressionLevel.Ultra`, `CompressionMethod.Lzma2`, `OverwriteMode`, `UpdateMode`, `DeleteAfter`,
  `MotwPolicy`, `OutFormat`): `@tagName` is the JSON value and Assoc's `QuickFormat` registry value.
  Non-persisted enums are snake_case (`engine.ProbeResult`, `sevenzip.Format` excepted: mirrors InArchiveFormat).
- TRAP: `CompressionMethod`'s zero value is `Copy` (no compression); every default is `.Default`.
- `kinds` / `kind(k)` (Engine.Kinds), `archive_exts` (Assoc.All), `default_exts` (Assoc.Defaults),
  `CompressOptions`, `ExtractOptions` (integer types as in C#: i64 sizes, i32 threads), `parseSize`,
  `eqlIgnoreCase` (.NET OrdinalIgnoreCase via CompareStringOrdinal: profile names and paths).

### strings.zig
`S.newArchive.get()` etc. (C# names in camelCase; keywords `@"error"`, `@"test"`, `@"type"`, `@"packed"`),
`S.levels()`, `S.foldersN/filesN/bytes(buf, n)` (Ukrainian plural), `S.write/fill/fillZ(template, .{args})` for the
`*Fmt` templates (`{0}`..`{9}`), `S.plain` strips the WinForms `&`. `S.init()` picks uk/en from
GetUserDefaultUILanguage. All 304 string pairs verified against Strings.cs by script.

### settings.zig
Structs mirror the C# JSON: **field names are the JSON keys**. `load(gpa, io, path)` (never fails: defaults),
`save` / `saveOrFail` (atomic temp+rename), `defaultPath(gpa)` (MAKEPACK_SETTINGS or %APPDATA%\MakePack\settings.json).
Settings.Current: `settings.init(gpa, io)`, `current()`, `arena()`, `commit()`, `reset()`, `reload()`, `deinit()`.
Known difference: enum names are matched case-sensitively (System.Text.Json also took "zip").

### MP-A sevenzip.zig
`load(dll_path)`; `InArchive.open(gpa, path, password)` with `items` (index, path, is_dir, size, packed_size,
mtime, attrib, crc, encrypted, method) and `props`; `extract(indices, Sink)` / `check(indices, Sink)`;
`create(gpa, out, []NewItem{name, source, folder}, WriteOptions)`, `update(a, out, []Change, WriteOptions)`.
Errors: NotArchive, Damaged, PasswordNeeded, WrongPassword, Canceled, InvalidOption, DataError, UnsupportedMethod,
FileBusy, Failed + `last_hr`. Paths get the `\\?\` prefix (toPathW). Source files open with share READ|DELETE only:
a file open for writing elsewhere = FileBusy (an error, never a silent skip).

### MP-B engine.zig
Everything in Engine.cs, minus `PackedSizes` (callers read `sevenzip.Item.packed_size`). Signatures take `gpa`,
`io`, `?*Diag`; `extract` takes the MotW policy explicitly. Callbacks (`Progress`, `Conflict`, Sink) run on 7z.dll
worker threads with small stacks and block them: never open a modal from inside one (module doc).
`selftest.run(gpa, io) -> u8` (exit code), `selftest.runIn(...)` (failure count; test-engine).

### MP-C platform
- assoc.zig: `Hive{ prefix }` injectable root (tests: `.{ .prefix = "Software\\MakePackTest-x\\" }`, HKCR reads
  become HKCU reads under prefix ++ `Software\Classes\`), `MenuItems` packed struct(u32), menu/setMenu,
  quickKind/setQuickKind, applyMenu/applyProfiles, registerProgId, heal, owner, isOurs, register, unregister,
  setAddMenu, unregisterAll, notify, `empty_seven_zip`, `prog_id`.
- single.zig: `sessionName`, `Instance.acquire/release`, `send` (CRLF lines, 1.5 s), `serve(Handler)`, `serveOne`,
  `absolute`. Same mutex/pipe names as C#. ERROR_NO_DATA from ConnectNamedPipe counts as connected.
- cli.zig: `Env{ gpa, io, out?, err?, ask_password, hive, motw?, engine_dir? }`, `run(env, args) ?u8` (null = GUI;
  loads 7z.dll lazily before the first engine call), `registryVerb(env, args, profiles) u8`, `useConsole()`.
  `a -y` moves the old archive to `<archive>.makepack~[N]` and puts it back if compress fails (C# deleted it first).
- platform_dispatch.zig: Program.Dispatch's decision table without UI (route, parseExtractJob, quickProfile, Gather).

### MP-D shell
`shell/shell.zig`: IExplorerCommand + class factory, exports `DllGetClassObject` / `DllCanUnloadNow`; reads
`Software\MakePack` MenuItems/QuickExt/MenuProfiles. Imports `kit` only (cannot import `src/`). The harness
redirects HKCU (RegOverridePredefKey) to a throw-away `MakePackTest-<random>` key and a random temp dir.

### main.zig (dispatch order = Program.Main)
`--selftest` -> settings.init -> `--register/--unregister/--addmenu` (cli.registryVerb) -> `--assoc/--settings`
(GUI phase: exit 0) -> `cli.run` -> single instance (acquire; client: send absolute args, else standalone;
server: serve + assoc.heal on the real HKCU, skipped when MAKEPACK_INSTANCE is set = a test run) -> GUI placeholder.

## Rules
- Core (`src/core/**`, `src/platform/**`) never imports kit.im / kit.ui / kit.app; prompts are callbacks.
- Tests: files only in `testutil.TempDir`, registry only under `testutil.regTestKey`, settings via
  MAKEPACK_SETTINGS, Recycle Bin only for files in the temp dir (put back), GUI only with
  `MAKEKIT_DISPLAY=\\.\DISPLAY1`, kill only your own PIDs.
- Non-ASCII text only via Write/Edit; check with `LC_ALL=C.UTF-8 grep -rnE "Р[°ѕµ‡]|С[–‚”]" src shell` (in a
  non-UTF-8 locale grep matches bytes and flags the genuine word "Рівень" in strings.zig).

## Contract changes
- engine: `friendly()` returns a threadlocal buffer valid until the next `friendly()` on that thread.
- engine: a 7z.dll E_INVALIDARG during create/update is `OperationFailed` (exit 2), not `InvalidOption` (exit 7).
- engine: `canEncryptHeaders` requires a non-empty next header that fits inside the file.
- engine: `Archive.io`, `fileExists/dirExists/fullPath`, `runIn`, close-on-NotSupported are public.
- engine.compress (integration): files named `<out_path>.makepack~*` are never packed into `out_path` (cli's `a -y`
  backup sits next to the archive; C#: `a -y x.7z .` worked because the old archive was already deleted).
- selftest prints `gui: deferred` instead of `SKIP gui`; new checks `registry` and `single`.
- build.zig: `test` also runs shell.zig's tests; `test-shell` = shell unit tests + harness; new step `shell`.

## Open items
- **GUI phase**: MainForm and all forms, Program.Dispatch (x queue, a dialog, --quick/--profile with progress and
  ConfirmOverwrite, convert, open archive), PasswordForm (main passes a callback that cancels: `-p` = cancelled),
  `--assoc` / `--settings` (exit 0 now), the selftest `gui` check, tools/bugtest.ps1 (GUI + real HKCU: not run).
- Error text: `engine.friendly` falls back to the Zig error name (AccessDenied, FileBusy, NoSpaceLeft, ...) where C#
  showed the localized Windows message. Map via FormatMessageW or a table of S strings.
- Long paths: engine file helpers rely on the manifest's longPathAware (needs HKLM LongPathsEnabled=1, off on stock
  Windows); only sevenzip.zig adds `\\?\`. recycle() (SHFileOperationW) cannot take `\\?\` at all.
- Case folding: engine buildDict/append conflict maps and the report sort fold ASCII only, so Cyrillic names that
  differ only in case are not seen as conflicts (C#: OrdinalIgnoreCase).
- Extracted folders get no mtime/attributes (C# restored them). CON/AUX device names get no special handling.
- sevenzip: no last-resort open pass (signature-less handlers under a foreign extension, zip/rar SFX = PE);
  truncated zip/tar/gz open with S_OK (kpidErrorFlags warnings not read - parity with SevenZipSharp); extract()
  does not dedupe indices; multi-volume RAR / .z01 through IArchiveOpenVolumeCallback untested.
- Data-loss windows kept from C#: convert recycles the source before the final move (a failed move leaves only the
  Recycle Bin copy); convert target==source without delete_original replaces in place; an in-place edit drops the
  archive's own Zone.Identifier.
- CLI: interactive-console output (AttachConsole when there are no std handles) untested (redirected runs work);
  DOS mask corner cases (`*.`, `?` before a dot) not reproduced; exit 255 (Ctrl+C) untested; numeric QuickFormat
  not accepted; "Пропущено 2 записів" has no plural form (same as Strings.cs).
- single: no FILE_FLAG_FIRST_PIPE_INSTANCE / read timeout (a client that never closes blocks the serve thread;
  C# had the same).
- Shell: not run in a real Explorer (sparse package install forbidden in tests); no panic containment inside the
  host; `dir()` ignores a GetModuleHandleExW failure; 64 KB arena per launch (grows with huge selections).
- Docs: README.md lines 33/59 still describe the shell build as CMake + MSVC; legacy/shell/CMakeLists.txt not rebuilt.
- MakeKit: `third_party/imgui/VERSION` shadows libc++'s `<version>`; build.zig works around it with
  `-idirafter` until MakeKit renames the file.
