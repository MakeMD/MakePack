// Drives MakePackShell.dll the way Explorer does, without installing anything. Not shipped.
// Usage: harness.exe <MakePackShell.dll> <fake_makepack.exe>      exit code = number of failed checks
// Isolation: HKCU is redirected (RegOverridePredefKey) to a throw-away HKCU\Software\MakePackTest-<random> for this
// whole process - the in-process DLL reads HKCU\Software\MakePack through it - and every file lives in a fresh
// %TEMP%\makepack-test-<random>. Both are removed on exit; the user's real MakePack keys are never read or written.
#include <windows.h>
#include <shlobj.h>
#include <wrl/client.h>
#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

using Microsoft::WRL::ComPtr;
namespace fs = std::filesystem;
static int g_fails;

// The MakePack command CLSID {21DB9173-64FA-4183-A08E-E073FEBB7B8D} (shell/shell.zig, shell/package/AppxManifest.xml).
static const CLSID kClsid = { 0x21DB9173, 0x64FA, 0x4183, { 0xA0, 0x8E, 0xE0, 0x73, 0xFE, 0xBB, 0x7B, 0x8D } };

struct Sandbox
{
    std::wstring id = L"shell-" + std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64());
    std::wstring key = L"Software\\MakePackTest-" + id;
    fs::path dir = fs::temp_directory_path() / (L"makepack-test-" + id);
    HKEY hkcu = nullptr;
    std::vector<HMODULE> modules;   // DLLs loaded by Load(), freed before the folder is removed
    bool ok = false;

    Sandbox()
    {
        ok = RegCreateKeyExW(HKEY_CURRENT_USER, key.c_str(), 0, nullptr, 0, KEY_ALL_ACCESS, nullptr, &hkcu, nullptr) == ERROR_SUCCESS
             && RegOverridePredefKey(HKEY_CURRENT_USER, hkcu) == ERROR_SUCCESS;
    }
    ~Sandbox()
    {
        RegOverridePredefKey(HKEY_CURRENT_USER, nullptr);
        if (hkcu) RegCloseKey(hkcu);
        RegDeleteTreeW(HKEY_CURRENT_USER, key.c_str());
        for (HMODULE m : modules) FreeLibrary(m);
        std::error_code ec;
        for (int i = 0; i < 50 && fs::exists(dir, ec); i++)   // the fakes may still be exiting
        {
            fs::remove_all(dir, ec);
            if (ec) Sleep(100);
        }
    }
};
static Sandbox* g_box;

static void Out(const std::wstring& s)
{
    std::string u(WideCharToMultiByte(CP_UTF8, 0, s.c_str(), -1, nullptr, 0, nullptr, nullptr) - 1, '\0');
    WideCharToMultiByte(CP_UTF8, 0, s.c_str(), -1, u.data(), static_cast<int>(u.size()) + 1, nullptr, nullptr);
    fwrite(u.data(), 1, u.size(), stdout);
    fputc('\n', stdout);
}

static void Check(bool ok, const std::wstring& what)
{
    if (!ok) { Out(L"FAIL " + what); g_fails++; }
}

static ComPtr<IExplorerCommand> Load(const fs::path& dll)
{
    HMODULE m = LoadLibraryW(dll.c_str());
    if (m) g_box->modules.push_back(m);
    auto get = m ? reinterpret_cast<decltype(&DllGetClassObject)>(GetProcAddress(m, "DllGetClassObject")) : nullptr;
    ComPtr<IClassFactory> factory;
    ComPtr<IExplorerCommand> root;
    if (!get || FAILED(get(kClsid, IID_PPV_ARGS(&factory)))
        || FAILED(factory->CreateInstance(nullptr, IID_PPV_ARGS(&root))))
        Out(L"FAIL cannot load " + dll.wstring());
    return root;
}

static ComPtr<IShellItemArray> Items(const std::vector<fs::path>& paths)
{
    std::vector<PIDLIST_ABSOLUTE> ids;
    for (auto& p : paths)
    {
        PIDLIST_ABSOLUTE id;
        if (SUCCEEDED(SHParseDisplayName(p.c_str(), nullptr, &id, 0, nullptr))) ids.push_back(id);
    }
    ComPtr<IShellItemArray> a;
    SHCreateShellItemArrayFromIDLists(static_cast<UINT>(ids.size()), const_cast<LPCITEMIDLIST*>(ids.data()), &a);
    for (auto id : ids) CoTaskMemFree(id);
    return a;
}

static std::vector<ComPtr<IExplorerCommand>> Subs(IExplorerCommand* root)
{
    std::vector<ComPtr<IExplorerCommand>> v;
    ComPtr<IEnumExplorerCommand> e;
    ComPtr<IExplorerCommand> c;
    if (SUCCEEDED(root->EnumSubCommands(&e)))
        while (e->Next(1, &c, nullptr) == S_OK) v.push_back(std::move(c));
    return v;
}

static std::wstring TitleOf(IExplorerCommand* c, IShellItemArray* a)
{
    PWSTR t = nullptr;
    std::wstring s = SUCCEEDED(c->GetTitle(a, &t)) ? t : L"<no title>";
    CoTaskMemFree(t);
    return s;
}

static bool VisibleOf(IExplorerCommand* c, IShellItemArray* a)
{
    EXPCMDSTATE st = ECS_HIDDEN;
    c->GetState(a, TRUE, &st);
    return st == ECS_ENABLED;
}

static std::wstring Name(const std::vector<fs::path>& sel)
{
    std::wstring s = L"{";
    for (auto& p : sel) s += (s.size() > 1 ? L", " : L"") + p.filename().wstring();
    return s + L"}";
}

// Prints root + subcommands; returns the visibility pattern of the subcommands, e.g. "HVVV".
static std::wstring List(IExplorerCommand* root, const std::vector<fs::path>& sel)
{
    auto a = Items(sel);
    EXPCMDFLAGS flags = 0;
    root->GetFlags(&flags);
    PWSTR icon = nullptr;
    root->GetIcon(a.Get(), &icon);
    Out(Name(sel));
    Out(L"  root \"" + TitleOf(root, a.Get()) + L"\" " + (VisibleOf(root, a.Get()) ? L"visible" : L"HIDDEN")
        + ((flags & ECF_HASSUBCOMMANDS) ? L" HASSUBCOMMANDS" : L"") + L" icon=" + (icon ? icon : L"-"));
    CoTaskMemFree(icon);
    std::wstring pattern;
    for (auto& c : Subs(root))
    {
        bool v = VisibleOf(c.Get(), a.Get());
        pattern += v ? L'V' : L'H';
        Out(std::wstring(L"    ") + (v ? L"visible  " : L"hidden   ") + TitleOf(c.Get(), a.Get()));
    }
    return pattern;
}

static void InvokeVisible(IExplorerCommand* root, const std::vector<fs::path>& sel)
{
    auto a = Items(sel);
    for (auto& c : Subs(root))
        if (VisibleOf(c.Get(), a.Get()))
        {
            HRESULT hr = c->Invoke(a.Get(), nullptr);
            Check(SUCCEEDED(hr), L"Invoke " + TitleOf(c.Get(), a.Get()));
        }
}

static std::vector<std::wstring> ReadLog(const fs::path& log, size_t expect)
{
    std::vector<std::wstring> lines;
    for (int i = 0; i < 200 && lines.size() < expect; i++)   // async fakes; AV scans the fresh exe copy first
    {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        std::ifstream f(log, std::ios::binary);
        std::stringstream ss;
        ss << f.rdbuf();
        std::string all = ss.str();
        lines.clear();
        for (size_t pos = 0, nl; (nl = all.find('\n', pos)) != std::string::npos; pos = nl + 1)
        {
            std::string u = all.substr(pos, nl - pos);
            std::wstring w(MultiByteToWideChar(CP_UTF8, 0, u.c_str(), static_cast<int>(u.size()), nullptr, 0), L'\0');
            MultiByteToWideChar(CP_UTF8, 0, u.c_str(), static_cast<int>(u.size()), w.data(), static_cast<int>(w.size()));
            lines.push_back(w);
        }
    }
    return lines;
}

static size_t Count(const std::vector<std::wstring>& lines, const std::wstring& what)
{
    size_t n = 0;
    for (auto& l : lines) n += l.find(what) != std::wstring::npos;
    return n;
}

int wmain(int argc, wchar_t** argv)
{
    if (argc < 3) { Out(L"usage: harness.exe <MakePackShell.dll> <fake_makepack.exe>"); return 1; }
    Sandbox box;   // first: destroyed last, after every ComPtr below
    g_box = &box;
    if (!box.ok) { Out(L"FAIL cannot redirect HKCU to HKCU\\" + box.key); return 1; }
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    fs::path dll = fs::absolute(argv[1]), fake = fs::absolute(argv[2]);

    fs::path root = box.dir;
    fs::create_directories(root / L"folder");
    fs::create_directories(root / L"app");
    auto touch = [&](const wchar_t* n) { std::ofstream(root / n) << "x"; return root / n; };
    fs::path zip = touch(L"a.zip"), tgz = touch(L"b.tar.gz"), txt = touch(L"c.txt"), dir = root / L"folder";
    fs::path uk = touch(L"Звіт за травень 2026.tar.gz");

    // ---- 1. what the menu shows (the DLL from dist\shell) ----
    auto cmd = Load(dll);
    if (!cmd) return 1;
    Out(L"== menu (UI language " + std::to_wstring(GetUserDefaultUILanguage()) + L") ==");
    // Open, Here, To, Add, Quick. Assumes no MenuItems value in HKCU\Software\MakePack (= every item on).
    Check(List(cmd.Get(), { zip }) == L"VVVVV", L"{a.zip} pattern");
    Check(List(cmd.Get(), { zip, tgz }) == L"HVVVV", L"{a.zip, b.tar.gz} pattern");
    Check(List(cmd.Get(), { txt }) == L"HHHVV", L"{c.txt} pattern");
    Check(List(cmd.Get(), { dir }) == L"HHHVV", L"{folder} pattern");
    Check(List(cmd.Get(), { zip, txt }) == L"HHHVV", L"{a.zip, c.txt} pattern");
    Check(List(cmd.Get(), { uk }) == L"VVVVV", L"{uk} pattern");
    Check(TitleOf(Subs(cmd.Get())[2].Get(), Items({ uk }).Get()).find(L"Звіт за травень 2026\\") != std::wstring::npos,
          L"Extract-to title strips .tar.gz");
    // "Add to name.ext" names the archive the way MakePack will (Engine.DefaultArchivePath), ext from QuickExt (.7z).
    auto quick = [&](const std::vector<fs::path>& sel) { return TitleOf(Subs(cmd.Get())[4].Get(), Items(sel).Get()); };
    Check(quick({ dir }).find(L"folder.7z") != std::wstring::npos, L"quick title for a folder: " + quick({ dir }));
    Check(quick({ uk }).find(L"Звіт за травень 2026.tar.7z") != std::wstring::npos, L"quick title for a file: " + quick({ uk }));
    Check(quick({ zip, txt }).find(root.filename().wstring() + L".7z") != std::wstring::npos, L"quick title for several: " + quick({ zip, txt }));

    // The user's switches (HKCU\Software\MakePack MenuItems) hide items. The value is put back exactly as it was.
    {
        HKEY k = nullptr;
        RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\MakePack", 0, nullptr, 0, KEY_QUERY_VALUE | KEY_SET_VALUE, nullptr, &k, nullptr);
        DWORD old = 0, size = sizeof old, only = 8;   // MenuItems.Add
        bool had = RegQueryValueExW(k, L"MenuItems", nullptr, nullptr, reinterpret_cast<BYTE*>(&old), &size) == ERROR_SUCCESS;
        RegSetValueExW(k, L"MenuItems", 0, REG_DWORD, reinterpret_cast<const BYTE*>(&only), sizeof only);
        Check(List(cmd.Get(), { zip }) == L"HHHVH", L"MenuItems = Add only");
        if (had) RegSetValueExW(k, L"MenuItems", 0, REG_DWORD, reinterpret_cast<const BYTE*>(&old), sizeof old);
        else RegDeleteValueW(k, L"MenuItems");
        RegCloseKey(k);
    }

    // ---- 2. what it runs (a copy of the DLL next to a fake MakePack.exe) ----
    fs::copy_file(dll, root / L"app" / L"MakePackShell.dll");
    fs::copy_file(fake, root / L"app" / L"MakePack.exe");
    auto app = Load(root / L"app" / L"MakePackShell.dll");
    if (!app) return 1;
    fs::path log = root / L"app" / L"makepack_shell_log.txt";   // fake_makepack.cpp writes it next to itself
    fs::remove(log);

    InvokeVisible(app.Get(), { zip, tgz, uk });   // Here x3, To x3, Add x1, Quick x1
    InvokeVisible(app.Get(), { txt, dir, uk });   // Add x1, Quick x1
    std::vector<fs::path> many;                   // 300 x ~150 chars > 30 000: Add must split
    fs::create_directories(root / L"many");
    for (int i = 0; i < 300; i++)
    {
        many.push_back(root / L"many" / (std::wstring(100, L'x') + std::to_wstring(i) + L".txt"));
        std::ofstream(many.back()) << "x";
    }
    InvokeVisible(app.Get(), many);               // Add x2, Quick x2

    auto lines = ReadLog(log, 14);
    Out(L"== command lines (" + std::to_wstring(lines.size()) + L") ==");
    for (auto& l : lines) Out(l.size() > 400 ? l.substr(0, 200) + L" ...[" + std::to_wstring(l.size()) + L" chars]" : l);

    std::wstring q = L"\"" + uk.wstring() + L"\"";
    Check(lines.size() == 14, L"14 processes expected");
    Check(Count(lines, L" --here") == 3 && Count(lines, L" --sub") == 3, L"one x process per archive, per verb");
    Check(Count(lines, L"MakePack.exe\" x " + q + L" --here") == 1, L"quoted Ukrainian path in x --here");
    Check(Count(lines, L"MakePack.exe\" a \"" + zip.wstring() + L"\" \"" + tgz.wstring() + L"\" " + q) == 1, L"one a for 3 archives");
    Check(Count(lines, L"MakePack.exe\" a \"" + txt.wstring() + L"\" \"" + dir.wstring() + L"\" " + q) == 1, L"one a for file+folder+uk");
    Check(Count(lines, L"MakePack.exe\" a \"" + (root / L"many").wstring()) == 2, L"300 long paths split into 2 a processes");
    Check(Count(lines, L"MakePack.exe\" a --quick \"" + (root / L"many").wstring()) == 2, L"...and into 2 a --quick processes");
    Check(Count(lines, L"MakePack.exe\" a --quick \"" + zip.wstring() + L"\" \"" + tgz.wstring() + L"\" " + q) == 1, L"one a --quick for 3 archives");
    Check(Count(lines, (root / L"app" / L"MakePack.exe").wstring()) == lines.size(), L"MakePack.exe taken from the DLL's folder");
    size_t total = 0;
    for (auto& l : lines)
        for (size_t p = 0; (p = l.find(L"\\many\\", p)) != std::wstring::npos; p++) total++;
    Check(total == 600, L"every one of the 300 paths passed exactly once per verb (Add, Quick)");

    // ---- 3. profiles marked "in menu" (HKCU\Software\MakePack\MenuProfiles, written by Assoc.ApplyProfiles) ----
    // Put there for this check only and removed again (HKCU is the sandbox key, so the skip below never fires).
    HKEY probe = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\MakePack\\MenuProfiles", 0, KEY_READ, &probe) == ERROR_SUCCESS)
    {
        RegCloseKey(probe);
        Out(L"SKIP profiles: HKCU\\Software\\MakePack\\MenuProfiles already exists");
    }
    else
    {
        auto put = [](const wchar_t* sub, const wchar_t* name, const wchar_t* ext, const wchar_t* separate)
        {
            std::wstring key = std::wstring(L"Software\\MakePack\\MenuProfiles\\") + sub;
            for (auto [n, v] : { std::pair{ L"Name", name }, std::pair{ L"Ext", ext }, std::pair{ L"Separate", separate } })
                RegSetKeyValueW(HKEY_CURRENT_USER, key.c_str(), n, REG_SZ, v, static_cast<DWORD>((wcslen(v) + 1) * sizeof(wchar_t)));
        };
        put(L"01", L"Backup", L".zip", L"0");
        put(L"02", L"Each", L".7z", L"1");
        Check(List(cmd.Get(), { dir }) == L"HHHVVVV", L"{folder} with two menu profiles");
        auto subs = Subs(cmd.Get());
        auto a = Items({ dir });
        Check(subs.size() == 7 && TitleOf(subs[5].Get(), a.Get()).find(L"folder.zip") != std::wstring::npos
              && TitleOf(subs[5].Get(), a.Get()).find(L"Backup") != std::wstring::npos, L"profile title: " + TitleOf(subs[5].Get(), a.Get()));
        Check(subs.size() == 7 && TitleOf(subs[6].Get(), a.Get()).find(L"(Each)") != std::wstring::npos, L"separate profile title: " + TitleOf(subs[6].Get(), a.Get()));

        fs::remove(log);
        auto appSubs = Subs(app.Get());
        if (appSubs.size() == 7) Check(SUCCEEDED(appSubs[5]->Invoke(Items({ txt, dir }).Get(), nullptr)), L"Invoke the Backup profile");
        auto plines = ReadLog(log, 1);
        Check(plines.size() == 1 && Count(plines, L"MakePack.exe\" a --profile \"Backup\" \"" + txt.wstring() + L"\" \"" + dir.wstring() + L"\"") == 1,
              L"one a --profile \"Backup\" for both items");
        RegDeleteTreeW(HKEY_CURRENT_USER, L"Software\\MakePack\\MenuProfiles");
        Check(List(cmd.Get(), { dir }) == L"HHHVV", L"no profile items once MenuProfiles is gone");
    }

    cmd.Reset();
    app.Reset();
    // Explorer (the COM surrogate) unloads the DLL only when it says so: every object released -> S_OK.
    for (HMODULE m : box.modules)
    {
        auto can = reinterpret_cast<HRESULT(WINAPI*)()>(reinterpret_cast<void*>(GetProcAddress(m, "DllCanUnloadNow")));
        Check(can && can() == S_OK, L"DllCanUnloadNow = S_OK after the last Release");
    }
    Out(g_fails ? std::to_wstring(g_fails) + L" FAILED" : L"ALL OK");
    return g_fails;
}
