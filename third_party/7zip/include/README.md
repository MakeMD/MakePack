# 7-Zip 26.03 interface headers (reference only)

Copied unchanged from the official source archive `7z2603-src.7z` (https://www.7-zip.org/a/7z2603-src.7z),
keeping the original folder layout:

| File | What MakePack takes from it |
|---|---|
| `CPP/7zip/Archive/IArchive.h` | IInArchive, IOutArchive, ISetProperties, IArchiveOpenCallback, IArchiveOpenVolumeCallback, IArchiveExtractCallback, IArchiveUpdateCallback; NHandlerPropID, NExtract::NAskMode / NOperationResult, NArcInfoFlags; the DLL export typedefs |
| `CPP/7zip/IStream.h` | ISequentialInStream, ISequentialOutStream, IInStream, IOutStream, IStreamGetSize |
| `CPP/7zip/IProgress.h` | IProgress (base of the extract / update callbacks) |
| `CPP/7zip/IPassword.h` | ICryptoGetTextPassword, ICryptoGetTextPassword2 |
| `CPP/7zip/IDecl.h` | the IID scheme `{23170F69-40C1-278A-0000-00gg00ii0000}` (gg = group, ii = interface) |
| `CPP/7zip/PropID.h` | kpid* property ids, kpv_ErrorFlags_* |
| `CPP/Common/MyWindows.h`, `MyUnknown.h`, `MyTypes.h`, `Common0.h` | PROPVARIANT / BSTR / IUnknown as 7-Zip sees them (on Windows the real `windows.h` types are used) |

Nothing here is compiled. `src/core/sevenzip.zig` declares the same interfaces in Zig; the vtable order there is
the order of each `Z7_IFACEM_<name>` macro list, after IUnknown's QueryInterface/AddRef/Release (and, for an
interface declared with `Z7_IFACE_CONSTR_*_SUB(i, base, n)`, after the base interface's methods).
When 7z.dll is upgraded, diff these files against the new source first.

## License

7-Zip Copyright (C) 1999-2026 Igor Pavlov. These files are under the GNU LGPL (version 2.1 or later), see
`../License.txt` (the license shipped with 7z.dll) and http://www.gnu.org/licenses/lgpl-2.1.html. They are
distributed here unmodified, for reference.
