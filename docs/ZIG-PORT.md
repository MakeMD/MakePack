# MakePack Zig port - handoff

`master` (2.0.0). The C# 1.x build is the behaviour spec, in git history only: `git show ce29887:legacy/<path>`
(Engine.cs, Program.cs incl. `--selftest`, Cli.cs, Assoc.cs, Settings.cs, Strings.cs, Shell.cs, forms,
`legacy/shell/MakePackShell.cpp`); plus `tools/bugtest.ps1` (CLI + GUI black box), `docs/*.md`.
Zig 0.17.1 (on PATH, `%LOCALAPPDATA%\Programs\zig\0.17.1`); read `../MakeKit/docs/ZIG-0.17-NOTES.md` first.

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
| GUI | see "GUI" below (src/ui/...) | forms, Shell.cs, Program.Dispatch | MakeKit imgui-auto | contract + stubs (MP-G1, MP-G2 next) |

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
Six UI languages (kit.i18n: en, uk, pl, de, es, fr). Texts live in `src/i18n/<code>.zig`: en.zig = the `Strings`
type (C# names in camelCase; keywords `@"error"`, `@"test"`, `@"type"`, `@"packed"`) + English + notes for
translators; the others = `pub const t: en.Strings` (a missing/extra key does not compile; the test checks
placeholders and plural forms). pl/de/es/fr are still English copies marked "TODO translate".
`S.tr().newArchive` = the current language; comptime tables keep an `S.Key` (`.tbAdd`) and draw `S.get(key)`.
`S.levels()`, `S.foldersN/filesN/bytes(buf, n)` (kit.i18n plural forms, number grouped by the user's locale),
`S.fillZ` (= kit.i18n.fmt) / `S.fill` / `S.write` for the `*Fmt` templates (`{0}`..`{9}`), `S.plain` strips `&`.
Language: MAKEKIT_LANG > settings.json "Language" ("Auto" | code; Settings dialog, applied at once) > Windows UI
language > en. The choice is mirrored to HKCU\Software\MakePack "Language" for MakePackShell.dll (its own six-language
title table). The 304 original uk/en pairs were verified byte-for-byte against the old strings.zig by script.

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
(`gui(.assoc/.settings)`: the dialog alone, no pipe, ctx.standalone) -> `cli.run` (ask_password =
`Dialogs.cliAskPassword`) -> single instance (acquire; client: send absolute args, else standalone; server: serve +
assoc.heal on the real HKCU, skipped when MAKEPACK_INSTANCE is set = a test run) -> own args into the Inbox -> GUI.

## GUI (contract set 2026-11-10; MP-G1 and MP-G2 work in parallel)

| Id | Owned files | Spec |
|---|---|---|
| GUI contract (main.zig) | src/main.zig (Inbox, Ui, frame loop, OpenMain, close, drop routing), src/ui/ctx.zig | Program.Main/Post/OpenMain/MaybeExit |
| MP-G1 main window | src/ui/main_window.zig + src/ui/mw_*.zig | MainForm.cs, Shell.cs, docs/ICONS-NEEDED.md, internal research notes (not published) |
| MP-G2 dialogs + dispatch | src/ui/dialogs.zig + src/ui/dlg_*.zig | Program.Dispatch/Enqueue/Pump/Extract/Add/Gather/RunProfile/Fail, every *Form.cs but MainForm, internal research notes (not published) |

A change to ctx.zig or to a public signature in dialogs.zig / main_window.zig = a line in "Contract changes".
The full contract is the module doc + doc comments of those three files; the essentials:

- **One OS window** (kit.app). `ctx.has_main_window` true: the main window fills it, dialogs are ImGui windows/popups
  on top. False: the dialogs own the OS window (size, title, visibility): the progress-only mode of Explorer's
  "Extract here/to" (the queue's ONE "n of N" progress), the compress dialog of `a`, convert, `--assoc/--settings`.
- **Frame order** (main.zig): Inbox (own + pipe-forwarded argument lists) -> `Dialogs.dispatch` each ->
  requests: `.open_main` to main.zig (create `MainWindow` in place or `open(path)`, then `ctx.raise()`), the rest to
  `MainWindow.handle` (dropped when there is none) -> `MainWindow.draw` (false = closed) -> `Dialogs.draw` ->
  MaybeExit: no main window and `Dialogs.idle()` -> `app.quit()`.
- **Requests** (`ctx.post`, UI thread, own their strings, handled next frame before anything draws): open_main,
  open_path, locate, refresh, release_archive, detach_archive, replace_archive, reopen, opened, ready, temp_ready,
  confirmed, text, status, settings_changed. Async answers carry a G1-chosen `Token`; cancel posts nothing.
- **Archive ownership**: the main window owns its open `*engine.Archive`; dialog entry points borrow it while
  `Dialogs.modal()` is true (the main window then takes no input, defers `open`, never closes/replaces it). Edits
  (delete/rename/add) take it over with `.detach_archive` and always end with `.reopen`; EnsurePassword's new
  instance arrives as `.replace_archive`; convert of the open archive / AfterExtract ask for `.release_archive`.
- **Close button**: never under a modal; with a main window it closes the main window and the process ends only if
  the dialogs are idle (else the OS window stays for them); without one, `Dialogs.closeRequested()` decides.
- **Drops**: `Dialogs.filesDropped` first (the compress dialog), else `MainWindow.filesDropped`.
- **Exit code**: `ctx.exit_code` (Program._exit), written by the dialogs.
- **Tests**: `MAKEPACK_INSTANCE`, `MAKEPACK_SETTINGS`, `MAKEPACK_REGROOT` (an HKCU subkey such as
  `Software\MakePackTest-<random>` that stands in for HKCU in every Assoc read/write: the `--register/--unregister/
  --addmenu` verbs via `cli.Env.hive`, the GUI via `ctx.hive`, Heal; main.zig `testHive`, older name
  `MAKEPACK_HIVE`), `MAKEKIT_AUTOMATION=1`, `MAKEKIT_DISPLAY=\\.\DISPLAY1`; click by `##id`; `ctx.raise()` does
  nothing under automation.
- Boot check (2026-11-10, automation): no args -> main window with `###mfile`..`###mhelp`; a second process forwards
  and exits 0, one process; `quit` exit 0; `x`, `--assoc`, `--settings` exit at once with the stub dialogs.

## Rules
- Core (`src/core/**`, `src/platform/**`) never imports kit.im / kit.ui / kit.app; prompts are callbacks.
- Tests: files only in `testutil.TempDir`, registry only under `testutil.regTestKey`, settings via
  MAKEPACK_SETTINGS, Recycle Bin only for files in the temp dir (put back), GUI only with
  `MAKEKIT_DISPLAY=\\.\DISPLAY1`, kill only your own PIDs.
- Non-ASCII text only via Write/Edit; check with `LC_ALL=C.UTF-8 grep -rnE "Р[°ѕµ‡]|С[–‚”]|Ã[¤¶¼Ÿ©¨]|Å[‚›º¼]" src shell`
  (in a non-UTF-8 locale grep matches bytes and flags the genuine word "Рівень" in src/i18n/uk.zig).

## Contract changes
- engine: `friendly()` returns a threadlocal buffer valid until the next `friendly()` on that thread.
- engine: a 7z.dll E_INVALIDARG during create/update is `OperationFailed` (exit 2), not `InvalidOption` (exit 7).
- engine: `canEncryptHeaders` requires a non-empty next header that fits inside the file.
- engine: `Archive.io`, `fileExists/dirExists/fullPath`, `runIn`, close-on-NotSupported are public.
- engine.compress (integration): files named `<out_path>.makepack~*` are never packed into `out_path` (cli's `a -y`
  backup sits next to the archive; C#: `a -y x.7z .` worked because the old archive was already deleted).
- selftest prints `gui: deferred` instead of `SKIP gui`; new checks `registry` and `single`.
- build.zig: `test` also runs shell.zig's tests; `test-shell` = shell unit tests + harness; new step `shell`.
- main.zig (MP-T): `MAKEPACK_REGROOT` (alias `MAKEPACK_HIVE`) is read once in `main` (`testHive`) and passed to
  `cli.Env.hive` and `gui(..., hive)` -> `ctx.hive`; with it set the server process heals that root (not the real
  HKCU). dlg_assoc skips `assoc.notify()` under a test root.
- Tooling (MP-T): `tools/bugtest.ps1` drives the Zig app over MakeKit automation (old UIA cases ported, same
  assertions; registry cases under MAKEPACK_REGROOT); `guismoke.ps1` / `settingstest.ps1` use automation;
  `dragtest.ps1` is manual-only (real SendInput); `build.ps1` = zig build ReleaseSafe -> `dist\app` -> build_shell
  -> ISCC (`-NoSign` passes through); `publish.ps1`, `bom.ps1`, `invoke_btn.ps1` (.NET/UIA only) removed.
- Kit adoption (2026-11-10): `sevenzip.InArchive.open(gpa, path, password, cancel)` and `engine.open(gpa, io, path,
  password, progress, diag)` stop on the cancel flag (open callback, nested unpack, .001 glue): the GUI's open job
  joins on Cancel instead of orphaning the work (`Dialogs.orphans` gone). `engine.openWarning(props)` = the text for
  kpidErrorFlags / kpidWarningFlags (truncated, bad headers, data after the end); every GUI open alerts with it.
  `engine.sweepStaleTemps` (GUI startup, own thread): `%TEMP%\MakePack\<hash>` untouched for a day and not in use.
  engine/sevenzip long paths = `kit.win.longPathW`; `engine.fileExists/dirExists` = `kit.win.isFile/isDir`.
- GUI (2026-11-10): `Model.goWith` never opens an archive (always `NeedOpen` -> `Dialogs.openArchive` on a job, also
  for Back/Forward, "..", nested archives and `.reopen`, whose status line rides in `Model.Want.status`; the folder
  shows while it opens). `D.textItem` -> `kit.ui.text` (same `text##id` labels, `value` = the full text);
  `D.combo` = ImGui `BeginCombo` (automation: `##<id>` with `value` = the current item, rows `<item>##<id>_<n>`);
  `Dialogs.isOpen` and main.zig's stub-check `comptime` block removed; `zig build test` runs the ui files' tests.
- Tooling (2026-11-10): the milestone scripts `gui_g1fix.ps1`, `gui_g2fix.ps1`, `gui_dialogs.ps1` are folded into
  `bugtest.ps1` (what bugtest lacked became cases 22-31: layout, Test's password, damaged 7z header, viewer states,
  Esc on a drop-down, open Cancel, compress guards, Find in an archive, password windows, Assoc footer; the
  queue's conflict question now runs as `readonly_target_overwrite` instead of a SKIP). Combo values are read from
  the item's `value` (`Value-Of`); screenshots go through `Save-AutoScreenshot -Png`.
- 2026-11-11: `types.globIgnoreCase` (the CLI's glob, moved; mw_model uses it too), `sevenzip.restoreDir`,
  `single.createPipe` returns an overlapped first-instance handle (`accept` reads it with a timeout).

## Open items (reviewed 2026-11-11)

Closed 2026-11-11:
- Error text: `engine.friendly` gives Windows' localized message (FormatMessageW) for std's errors; the code table and
  FormatMessageW moved to `kit.win.errorCode/sysMessage/errorText` (MakeCleaner uses them too).
- Case folding: buildDict/append conflict maps and the report sort fold UTF-16 (Cyrillic included, done earlier); the
  main window's / Find's masks (`mw_model.matches`) now use `types.globIgnoreCase` (CompareStringOrdinal per unit),
  the same glob as the CLI.
- Extracted folders get their mtime and READONLY/HIDDEN/SYSTEM/ARCHIVE bits back (`sevenzip.restoreDir`, after the
  files are in); selftest `empty_dirs` checks the time for 7z, zip and tar.
- Device names: an entry named CON/PRN/AUX/NUL/COM0-9/LPT0-9/CONIN$/CONOUT$ (any extension) extracts as `_<name>`
  (7-Zip's rule) instead of opening the device (bare NUL still is one inside a folder on Windows 11) or being
  reported as a path-traversal attempt. Selftest `extract_options` + engine unit test.
- single: the pipe is created with FILE_FLAG_FIRST_PIPE_INSTANCE (a name someone else holds fails instead of sharing
  its clients) and read overlapped with a 5 s limit from connect to close (a client that never closes is dropped).
- MakePack.exe has a VERSIONINFO resource (app.rc; numbers from build.zig.zon through build.zig `versionDefines`).
- convert already moves the new archive in place before recycling the source (this list was stale).

Left deliberately (each needs a real environment, fixtures or a design decision; none is a reported bug):
- recycle() long paths: SHFileOperationW cannot take `\\?\`; IFileOperation is the upgrade path.
- sevenzip: no last-resort open pass (signature-less handlers under a foreign extension, zip/rar SFX = PE); a
  truncated .gz opens clean (Test reports it); extract() does not dedupe indices; multi-volume RAR / .z01 through
  IArchiveOpenVolumeCallback untested.
- Kept from C#: convert target==source without delete_original replaces in place (callers forbid it); an in-place
  edit drops the archive's own Zone.Identifier. Entry names with trailing dots/spaces are not renamed (Windows
  strips them).
- CLI: interactive-console output (AttachConsole) and exit 255 (Ctrl+C) need a real console; DOS mask corner cases
  (`?` before a dot); numeric QuickFormat not accepted; "Пропущено 2 записів" has no plural form (as Strings.cs).
- `main_window.zig` `version` (About) is still kept by hand next to build.zig.zon.
- GUI: drag-and-drop (`tools/dragtest.ps1`, real SendInput, manual only) and OS file dialogs are not automated.
- Shell: not run in a real Explorer (sparse package install forbidden in tests); no panic containment inside the
  host; `dir()` ignores a GetModuleHandleExW failure; 64 KB arena per launch (grows with huge selections).
