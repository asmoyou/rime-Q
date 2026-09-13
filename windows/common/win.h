#pragma once
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <shlobj.h>
#include <sddl.h>
#include <filesystem>
#include <string>
#include <vector>
#include <stdexcept>
#include "protocol.h"

namespace rq {
namespace fs = std::filesystem;
struct Handle {
    HANDLE value = INVALID_HANDLE_VALUE;
    Handle() = default; explicit Handle(HANDLE h) : value(h) {}
    ~Handle() { reset(); }
    Handle(const Handle&) = delete; Handle& operator=(const Handle&) = delete;
    void reset(HANDLE h = INVALID_HANDLE_VALUE) { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); value = h; }
    explicit operator bool() const { return value && value != INVALID_HANDLE_VALUE; }
};
inline std::wstring wide(const std::string& s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(), static_cast<int>(s.size()), nullptr, 0);
    if (!n) throw std::runtime_error("Invalid UTF-8");
    std::wstring out(n, 0); MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(), static_cast<int>(s.size()), out.data(), n); return out;
}
inline std::string utf8(const std::wstring& s) {
    if (s.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, s.data(), static_cast<int>(s.size()), nullptr, 0, nullptr, nullptr);
    if (!n) throw std::runtime_error("Invalid UTF-16");
    std::string out(n, 0); WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, s.data(), static_cast<int>(s.size()), out.data(), n, nullptr, nullptr); return out;
}
inline fs::path modulePath(HMODULE module = nullptr) {
    std::wstring s(32768, 0); auto n = GetModuleFileNameW(module, s.data(), static_cast<DWORD>(s.size()));
    if (!n || n == s.size()) throw std::runtime_error("Module path unavailable"); s.resize(n); return fs::path(s);
}
inline fs::path dataRoot() {
    PWSTR raw = nullptr;
    if (FAILED(SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr, &raw))) throw std::runtime_error("User directory unavailable");
    fs::path p(raw); CoTaskMemFree(raw); return p / L"RimeQ";
}
inline std::wstring sid() {
    Handle token; HANDLE h = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &h)) throw std::runtime_error("User token unavailable");
    token.reset(h); DWORD size = 0; GetTokenInformation(h, TokenUser, nullptr, 0, &size);
    std::vector<uint8_t> data(size);
    if (!GetTokenInformation(h, TokenUser, data.data(), size, &size)) throw std::runtime_error("User identity unavailable");
    LPWSTR text = nullptr;
    if (!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(data.data())->User.Sid, &text)) throw std::runtime_error("Invalid user identity");
    std::wstring value(text); LocalFree(text); return value;
}
inline std::wstring pipeName() {
    return L"\\\\.\\pipe\\RimeQ.v1." + sid();
}
// Child GUIs inherit a small ordinary Windows environment, never development credentials.
inline bool launch(const fs::path& executable, const std::wstring& arguments) {
    if (!fs::is_regular_file(executable)) return false;
    std::wstring env;
    for (auto name : {L"APPDATA", L"LOCALAPPDATA", L"SystemRoot", L"TEMP", L"TMP", L"USERPROFILE", L"WINDIR"}) {
        DWORD n = GetEnvironmentVariableW(name, nullptr, 0); if (!n) continue;
        std::wstring value(n, 0); GetEnvironmentVariableW(name, value.data(), n); value.resize(n - 1);
        env += name; env += L"="; env += value; env += wchar_t(0);
    }
    env += wchar_t(0);
    std::wstring command = L"\"" + executable.wstring() + L"\" " + arguments;
    STARTUPINFOW startup{sizeof(startup)}; startup.dwFlags = STARTF_USESHOWWINDOW; startup.wShowWindow = SW_SHOWNORMAL;
    PROCESS_INFORMATION process{};
    bool ok = CreateProcessW(executable.c_str(), command.data(), nullptr, nullptr, FALSE,
        CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW, env.data(), executable.parent_path().c_str(), &startup, &process) != FALSE;
    if (ok) { CloseHandle(process.hThread); CloseHandle(process.hProcess); } return ok;
}
inline int preference(const wchar_t* key, int fallback, const fs::path& root = dataRoot()) {
    return GetPrivateProfileIntW(L"RimeQ", key, fallback, (root / L"settings.ini").c_str());
}
// One deadline bounds the entire exchange, including all partial reads and writes.
inline bool transfer(HANDLE pipe, void* buffer, DWORD size, bool writing, ULONGLONG deadline) {
    auto bytes = static_cast<uint8_t*>(buffer);
    while (size) {
        Handle event(CreateEventW(nullptr, TRUE, FALSE, nullptr)); if (!event) return false;
        OVERLAPPED ov{}; ov.hEvent = event.value; DWORD done = 0;
        BOOL ok = writing ? WriteFile(pipe, bytes, size, &done, &ov) : ReadFile(pipe, bytes, size, &done, &ov);
        if (!ok) {
            if (GetLastError() != ERROR_IO_PENDING) return false;
            auto now = GetTickCount64(); DWORD remaining = now < deadline ? static_cast<DWORD>(deadline - now) : 0;
            if (WaitForSingleObject(event.value, remaining) != WAIT_OBJECT_0) {
                CancelIoEx(pipe, &ov); GetOverlappedResult(pipe, &ov, &done, TRUE); return false;
            }
            if (!GetOverlappedResult(pipe, &ov, &done, FALSE)) return false;
        }
        if (!done) return false; bytes += done; size -= done;
    }
    return true;
}
inline bool sendFrame(HANDLE pipe, const std::vector<uint8_t>& bytes, ULONGLONG deadline) {
    if (bytes.empty() || bytes.size() > maxFrame) return false;
    uint32_t size = static_cast<uint32_t>(bytes.size());
    return transfer(pipe, &size, 4, true, deadline) && transfer(pipe, const_cast<uint8_t*>(bytes.data()), size, true, deadline);
}
inline bool receiveFrame(HANDLE pipe, std::vector<uint8_t>& bytes, ULONGLONG deadline) {
    uint32_t size = 0;
    if (!transfer(pipe, &size, 4, false, deadline) || !size || size > maxFrame) return false;
    bytes.resize(size); return transfer(pipe, bytes.data(), size, false, deadline);
}
class Client {
    Handle pipe_;
public:
    void close() { pipe_.reset(); }
    bool connected() const { return bool(pipe_); }
    bool connect() {
        if (pipe_) return true;
        pipe_.reset(CreateFileW(pipeName().c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
            FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr));
        return bool(pipe_);
    }
    bool exchange(const Request& request, State& result, DWORD timeout = 100) {
        try {
            if (!connect()) return false;
            auto deadline = GetTickCount64() + timeout; std::vector<uint8_t> bytes;
            if (!sendFrame(pipe_.value, encode(request), deadline) || !receiveFrame(pipe_.value, bytes, deadline)) { close(); return false; }
            result = state(bytes); return true;
        } catch (...) { close(); return false; }
    }
};
} // namespace rq
