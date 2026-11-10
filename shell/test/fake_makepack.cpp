// Stand-in for MakePack.exe in the harness: appends its own command line to makepack_shell_log.txt next to itself
// (UTF-8; the harness copies it into its own temp folder).
#include <windows.h>
#include <string>

int wmain()
{
    std::wstring line = GetCommandLineW();
    line += L"\n";
    std::string utf8(WideCharToMultiByte(CP_UTF8, 0, line.c_str(), -1, nullptr, 0, nullptr, nullptr) - 1, '\0');
    WideCharToMultiByte(CP_UTF8, 0, line.c_str(), -1, utf8.data(), static_cast<int>(utf8.size()) + 1, nullptr, nullptr);

    std::wstring log(32768, L'\0');
    log.resize(GetModuleFileNameW(nullptr, log.data(), static_cast<DWORD>(log.size())));
    log = log.substr(0, log.rfind(L'\\') + 1) + L"makepack_shell_log.txt";
    HANDLE f = INVALID_HANDLE_VALUE;
    for (int i = 0; i < 100 && f == INVALID_HANDLE_VALUE; i++)   // a sibling or the harness may hold it for a moment
        if ((f = CreateFileW(log.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                             OPEN_ALWAYS, 0, nullptr)) == INVALID_HANDLE_VALUE) Sleep(20);
    if (f == INVALID_HANDLE_VALUE) return 1;
    DWORD written;
    WriteFile(f, utf8.data(), static_cast<DWORD>(utf8.size()), &written, nullptr);   // one append = one atomic line
    CloseHandle(f);
    return 0;
}
