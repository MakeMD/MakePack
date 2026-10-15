// MakePackShell.dll - the "MakePack" submenu of the Windows 11 (top-level) Explorer context menu.
// One IExplorerCommand class, registered by the sparse package in shell\package. The classic registry verbs
// (src\MakePack\Assoc.cs) stay as they are for Windows 10 and "Show more options".
// Every action just starts MakePack.exe from this DLL's folder with the same CLI the classic verbs use.
#include <windows.h>
#include <shlobj.h>
#include <shlwapi.h>
#include <wrl/client.h>
#include <new>
#include <string>
#include <vector>
#include "clsid.h"

#pragma comment(linker, "/export:DllGetClassObject,PRIVATE")
#pragma comment(linker, "/export:DllCanUnloadNow,PRIVATE")

using Microsoft::WRL::ComPtr;
extern "C" IMAGE_DOS_HEADER __ImageBase;

static long g_refs;   // live objects + IClassFactory::LockServer locks

// ---- what is selected ---------------------------------------------------------------------------

// Same list as Assoc.All in src\MakePack\Assoc.cs - keep in sync.
static const wchar_t* const kArchiveExts[] = {
    L"7z", L"zip", L"zipx", L"jar", L"rar", L"tar", L"gz", L"tgz", L"bz2", L"tbz2", L"tbz", L"xz", L"txz", L"lzma", L"z",
    L"taz", L"cab", L"iso", L"wim", L"swm", L"esd", L"arj", L"lzh", L"lha", L"cpio", L"rpm", L"deb", L"udeb", L"ar",
    L"xar", L"dmg", L"vhd", L"001", L"ova",
};
// Same as Engine.TarballExts in src\MakePack\Engine.cs - keep in sync.
static const wchar_t* const kTarballExts[] = { L".tar.gz", L".tar.bz2", L".tar.xz", L".tgz", L".tbz2", L".txz" };

// ponytail: extension only, no disk access - a folder named "x.zip" counts as an archive, like the classic verbs.
static bool IsArchive(const std::wstring& path)
{
    const wchar_t* ext = PathFindExtensionW(path.c_str());
    if (*ext != L'.') return false;
    for (auto e : kArchiveExts)
        if (_wcsicmp(ext + 1, e) == 0) return true;
    return false;
}

// Engine.BaseName: "a.tar.gz" -> "a", "b.zip" -> "b".
static std::wstring BaseName(const std::wstring& path)
{
    std::wstring name = PathFindFileNameW(path.c_str());
    for (auto e : kTarballExts)
    {
        size_t n = wcslen(e);
        if (name.size() >= n && _wcsicmp(name.c_str() + name.size() - n, e) == 0) return name.substr(0, name.size() - n);
    }
    size_t dot = name.rfind(L'.');
    return dot == std::wstring::npos ? name : name.substr(0, dot);
}

struct Selection
{
    DWORD count = 0;                  // everything selected
    std::vector<std::wstring> paths;  // ...of which these have a file-system path

    bool AllArchives() const
    {
        if (count == 0 || paths.size() != count) return false;
        for (auto& p : paths)
            if (!IsArchive(p)) return false;
        return true;
    }
};

// ponytail: re-read on every GetTitle/GetState call; cache per IShellItemArray if huge selections feel slow.
static Selection Read(IShellItemArray* items)
{
    Selection s;
    if (!items || FAILED(items->GetCount(&s.count))) return s;
    for (DWORD i = 0; i < s.count; i++)
    {
        ComPtr<IShellItem> item;
        PWSTR path = nullptr;
        if (SUCCEEDED(items->GetItemAt(i, &item)) && SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path)))
        {
            s.paths.push_back(path);
            CoTaskMemFree(path);
        }
    }
    return s;
}

// ---- the commands -------------------------------------------------------------------------------

enum Kind { Root, Open, Here, To, Add, Quick, Profile };
static const Kind kSubs[] = { Open, Here, To, Add, Quick };   // then one Profile command per MenuProfiles entry

// ---- the user's choices, written by MakePack (Assoc.Menu / Assoc.QuickKind in src\MakePack\Assoc.cs) ----

// MenuItems flags - same values as the C# enum. No value at all = everything on.
enum : DWORD { kOpen = 1, kHere = 2, kTo = 4, kAdd = 8, kQuick = 16, kProfiles = 64 };

static DWORD MenuFlags()
{
    DWORD v = 0, size = sizeof v;
    return RegGetValueW(HKEY_CURRENT_USER, L"Software\\MakePack", L"MenuItems", RRF_RT_REG_DWORD, nullptr, &v, &size) == ERROR_SUCCESS ? v : 0xFFFFFFFF;
}

static std::wstring QuickExt()
{
    wchar_t buf[32];
    DWORD size = sizeof buf;
    return RegGetValueW(HKEY_CURRENT_USER, L"Software\\MakePack", L"QuickExt", RRF_RT_REG_SZ, nullptr, buf, &size) == ERROR_SUCCESS ? buf : L".7z";
}

// The profiles marked "in menu": HKCU\Software\MakePack\MenuProfiles\01, 02... (Assoc.ApplyProfiles writes them).
struct MenuProfile { std::wstring name, ext; bool separate = false; };

static std::vector<MenuProfile> MenuProfiles()
{
    std::vector<MenuProfile> list;
    HKEY k;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\MakePack\\MenuProfiles", 0, KEY_READ, &k) != ERROR_SUCCESS) return list;
    auto text = [&](const wchar_t* sub, const wchar_t* value)
    {
        wchar_t buf[512];
        DWORD size = sizeof buf;
        return RegGetValueW(k, sub, value, RRF_RT_REG_SZ, nullptr, buf, &size) == ERROR_SUCCESS ? std::wstring(buf) : std::wstring();
    };
    wchar_t sub[32];
    for (DWORD i = 0, n = ARRAYSIZE(sub); RegEnumKeyExW(k, i, sub, &n, nullptr, nullptr, nullptr, nullptr) == ERROR_SUCCESS; i++, n = ARRAYSIZE(sub))
    {
        MenuProfile p{ text(sub, L"Name"), text(sub, L"Ext"), text(sub, L"Separate") == L"1" };
        if (!p.name.empty()) list.push_back(p);
    }
    RegCloseKey(k);
    return list;   // subkeys are zero-padded, so name order is their order
}

// Engine.DefaultArchivePath: one item -> its name (a file loses its last extension), several -> their folder's name.
static std::wstring ArchiveBase(const Selection& s)
{
    std::wstring name;
    if (s.paths.size() == 1)
    {
        name = PathFindFileNameW(s.paths[0].c_str());
        DWORD attr = GetFileAttributesW(s.paths[0].c_str());
        if (attr == INVALID_FILE_ATTRIBUTES || !(attr & FILE_ATTRIBUTE_DIRECTORY))
        {
            size_t dot = name.rfind(L'.');
            if (dot != std::wstring::npos && dot > 0) name.resize(dot);
        }
    }
    else if (!s.paths.empty())
    {
        std::wstring parent = s.paths[0].substr(0, s.paths[0].find_last_of(L'\\'));
        name = PathFindFileNameW(parent.c_str());
        if (name.find(L':') != std::wstring::npos) name.clear();   // the items sit in a drive root
    }
    return name.empty() ? L"MakePack" : name;
}

// <profile> is the MenuProfiles index of a Profile command, -1 for every other kind.
static bool Visible(Kind k, const Selection& s, int profile = -1)
{
    DWORD on = MenuFlags();
    switch (k)
    {
    case Open: return (on & kOpen) && s.count == 1 && s.AllArchives();
    case Here: return (on & kHere) && s.AllArchives();
    case To: return (on & kTo) && s.AllArchives();
    case Add: return (on & kAdd) && !s.paths.empty();
    case Quick: return (on & kQuick) && !s.paths.empty();
    case Profile: return (on & kProfiles) && !s.paths.empty() && profile >= 0 && profile < static_cast<int>(MenuProfiles().size());
    default:
        for (auto sub : kSubs)
            if (Visible(sub, s)) return true;
        return (on & kProfiles) && !s.paths.empty() && !MenuProfiles().empty();
    }
}

static std::wstring Title(Kind k, const Selection& s, int profile = -1)
{
    bool uk = PRIMARYLANGID(GetUserDefaultUILanguage()) == LANG_UKRAINIAN;   // everything else: English
    if (k == Profile)
    {
        auto list = MenuProfiles();
        if (profile < 0 || profile >= static_cast<int>(list.size())) return L"MakePack";
        auto& p = list[profile];
        if (p.separate) return (uk ? L"Кожен в окремий " : L"Each to its own ") + p.ext + L" (" + p.name + L")";
        return uk ? L"Додати в «" + ArchiveBase(s) + p.ext + L"» (" + p.name + L")"
                  : L"Add to \"" + ArchiveBase(s) + p.ext + L"\" (" + p.name + L")";
    }
    switch (k)
    {
    case Open: return uk ? L"Відкрити в MakePack" : L"Open with MakePack";
    case Here: return uk ? L"Розпакувати тут" : L"Extract here";
    case To:
        if (s.paths.size() != 1) return uk ? L"Розпакувати кожен в окрему теку" : L"Extract each to its own folder";
        return uk ? L"Розпакувати в «" + BaseName(s.paths[0]) + L"\\»" : L"Extract to \"" + BaseName(s.paths[0]) + L"\\\"";
    case Add: return uk ? L"Додати в архів…" : L"Add to archive…";
    case Quick: return uk ? L"Додати в «" + ArchiveBase(s) + QuickExt() + L"»" : L"Add to \"" + ArchiveBase(s) + QuickExt() + L"\"";
    default: return L"MakePack";
    }
}

static std::wstring Dir()   // the folder this DLL (and MakePack.exe) lives in
{
    std::wstring p(32768, L'\0');
    p.resize(GetModuleFileNameW(reinterpret_cast<HMODULE>(&__ImageBase), p.data(), static_cast<DWORD>(p.size())));
    return p.substr(0, p.rfind(L'\\'));
}

static std::wstring Quote(std::wstring p)
{
    if (!p.empty() && p.back() == L'\\') p += L'\\';   // "C:\" would otherwise escape the closing quote
    return L"\"" + p + L"\"";
}

static HRESULT Launch(const std::wstring& args)
{
    std::wstring exe = Dir() + L"\\MakePack.exe";
    std::wstring cmd = Quote(exe) + L" " + args;
    STARTUPINFOW si{ sizeof si };
    PROCESS_INFORMATION pi{};
    if (!CreateProcessW(exe.c_str(), cmd.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr, &si, &pi))
        return HRESULT_FROM_WIN32(GetLastError());
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return S_OK;
}

static HRESULT Run(Kind k, const Selection& s, int profile = -1)
{
    if (s.paths.empty()) return S_OK;
    HRESULT hr = S_OK, one;
    std::wstring verb = k == Add ? L"a" : k == Quick ? L"a --quick" : L"";
    if (k == Profile)
    {
        auto list = MenuProfiles();
        if (profile < 0 || profile >= static_cast<int>(list.size())) return E_INVALIDARG;
        verb = L"a --profile " + Quote(list[profile].name);
    }
    switch (k)
    {
    case Open:
        return Launch(Quote(s.paths[0]));
    case Here:
    case To:   // one process per archive; MakePack is single-instance and queues them into one progress window
        for (auto& p : s.paths)
            if (FAILED(one = Launch(L"x " + Quote(p) + (k == Here ? L" --here" : L" --sub")))) hr = one;
        return hr;
    case Add:
    case Quick:
    case Profile:
    {   // one process for everything; a huge selection is split and MakePack merges the parts (dialog or archive)
        std::wstring args;
        for (auto& p : s.paths)
        {
            std::wstring q = L" " + Quote(p);
            if (!args.empty() && args.size() + q.size() > 30000)   // CreateProcess caps the command line at 32767
            {
                if (FAILED(one = Launch(verb + args))) hr = one;
                args.clear();
            }
            args += q;
        }
        if (FAILED(one = Launch(verb + args))) hr = one;
        return hr;
    }
    default:
        return E_NOTIMPL;
    }
}

// ---- COM plumbing -------------------------------------------------------------------------------

template <class I> struct Unknown : I
{
    long m_refs = 1;
    Unknown() { InterlockedIncrement(&g_refs); }
    virtual ~Unknown() { InterlockedDecrement(&g_refs); }

    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) override
    {
        if (!ppv) return E_POINTER;
        *ppv = nullptr;
        if (riid != __uuidof(IUnknown) && riid != __uuidof(I)) return E_NOINTERFACE;
        *ppv = static_cast<I*>(this);
        AddRef();
        return S_OK;
    }
    IFACEMETHODIMP_(ULONG) AddRef() override { return InterlockedIncrement(&m_refs); }
    IFACEMETHODIMP_(ULONG) Release() override
    {
        long r = InterlockedDecrement(&m_refs);
        if (r == 0) delete this;
        return r;
    }
};

struct Command final : Unknown<IExplorerCommand>
{
    Kind m_kind;
    int m_profile;   // MenuProfiles index for a Profile command
    explicit Command(Kind k, int profile = -1) : m_kind(k), m_profile(profile) {}

    IFACEMETHODIMP GetTitle(IShellItemArray* items, LPWSTR* name) override
    {
        return SHStrDupW(Title(m_kind, Read(items), m_profile).c_str(), name);
    }
    IFACEMETHODIMP GetIcon(IShellItemArray*, LPWSTR* icon) override
    {
        *icon = nullptr;
        if (m_kind != Root) return E_NOTIMPL;   // ponytail: icon on the root only, like Notepad++
        return SHStrDupW((Dir() + L"\\MakePack.exe,0").c_str(), icon);
    }
    IFACEMETHODIMP GetToolTip(IShellItemArray*, LPWSTR* tip) override { *tip = nullptr; return E_NOTIMPL; }
    IFACEMETHODIMP GetCanonicalName(GUID* guid) override
    {
        *guid = m_kind == Root ? __uuidof(MakePackCommand) : GUID_NULL;
        return S_OK;
    }
    IFACEMETHODIMP GetState(IShellItemArray* items, BOOL, EXPCMDSTATE* state) override
    {
        *state = Visible(m_kind, Read(items), m_profile) ? ECS_ENABLED : ECS_HIDDEN;
        return S_OK;
    }
    IFACEMETHODIMP Invoke(IShellItemArray* items, IBindCtx*) override { return Run(m_kind, Read(items), m_profile); }
    IFACEMETHODIMP GetFlags(EXPCMDFLAGS* flags) override
    {
        *flags = m_kind == Root ? ECF_HASSUBCOMMANDS : ECF_DEFAULT;
        return S_OK;
    }
    IFACEMETHODIMP EnumSubCommands(IEnumExplorerCommand** out) override;
};

struct SubCommands final : Unknown<IEnumExplorerCommand>
{
    ULONG m_pos = 0;
    ULONG m_total = ARRAYSIZE(kSubs) + static_cast<ULONG>(MenuProfiles().size());   // fixed for this menu's lifetime

    IFACEMETHODIMP Next(ULONG want, IExplorerCommand** out, ULONG* got) override
    {
        ULONG n = 0;
        while (n < want && m_pos < m_total)
        {
            out[n] = m_pos < ARRAYSIZE(kSubs) ? new (std::nothrow) Command(kSubs[m_pos])
                                              : new (std::nothrow) Command(Profile, static_cast<int>(m_pos - ARRAYSIZE(kSubs)));
            if (!out[n]) break;
            m_pos++;
            n++;
        }
        if (got) *got = n;
        return n == want ? S_OK : S_FALSE;
    }
    IFACEMETHODIMP Skip(ULONG n) override
    {
        m_pos = min(m_pos + n, m_total);
        return S_OK;
    }
    IFACEMETHODIMP Reset() override { m_pos = 0; return S_OK; }
    IFACEMETHODIMP Clone(IEnumExplorerCommand** out) override { *out = nullptr; return E_NOTIMPL; }
};

IFACEMETHODIMP Command::EnumSubCommands(IEnumExplorerCommand** out)
{
    *out = nullptr;
    if (m_kind != Root) return E_NOTIMPL;
    *out = new (std::nothrow) SubCommands();
    return *out ? S_OK : E_OUTOFMEMORY;
}

struct Factory final : Unknown<IClassFactory>
{
    IFACEMETHODIMP CreateInstance(IUnknown* outer, REFIID riid, void** ppv) override
    {
        *ppv = nullptr;
        if (outer) return CLASS_E_NOAGGREGATION;
        auto c = new (std::nothrow) Command(Root);
        if (!c) return E_OUTOFMEMORY;
        HRESULT hr = c->QueryInterface(riid, ppv);
        c->Release();
        return hr;
    }
    IFACEMETHODIMP LockServer(BOOL lock) override
    {
        lock ? InterlockedIncrement(&g_refs) : InterlockedDecrement(&g_refs);
        return S_OK;
    }
};

STDAPI DllGetClassObject(REFCLSID clsid, REFIID riid, void** ppv)
{
    *ppv = nullptr;
    if (clsid != __uuidof(MakePackCommand)) return CLASS_E_CLASSNOTAVAILABLE;
    auto f = new (std::nothrow) Factory();
    if (!f) return E_OUTOFMEMORY;
    HRESULT hr = f->QueryInterface(riid, ppv);
    f->Release();
    return hr;
}

STDAPI DllCanUnloadNow() { return g_refs == 0 ? S_OK : S_FALSE; }
