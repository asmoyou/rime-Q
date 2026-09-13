#include "profile_registration.h"
#include <iostream>
#include <stdexcept>
using Microsoft::WRL::ComPtr;
namespace {
void check(HRESULT hr) { if (FAILED(hr)) throw std::runtime_error("TSF profile API failed"); }
bool present(ITfInputProcessorProfileMgr* manager, REFCLSID clsid, REFGUID profile) {
    ComPtr<IEnumTfInputProcessorProfiles> list; check(manager->EnumProfiles(0x0804, &list));
    for (;;) {
        TF_INPUTPROCESSORPROFILE item{}; ULONG fetched = 0;
        auto hr = list->Next(1, &item, &fetched); check(hr);
        if (hr == S_FALSE) return false;
        if (fetched != 1) throw std::runtime_error("Invalid profile enumeration");
        if (item.clsid == clsid && item.guidProfile == profile) return true;
    }
}
struct Fixture {
    GUID clsid{}, profile{};
    bool global;
    explicit Fixture(bool system) : global(system) { check(CoCreateGuid(&clsid)); check(CoCreateGuid(&profile)); }
    DWORD scope() const { return global ? 0 : TF_URP_LOCALPROCESS; }
    ~Fixture() { rq::unregisterProfile(clsid, 0x0804, profile, scope()); if (global) rq::removeServiceRegistry(clsid); }
    void add(ITfInputProcessorProfileMgr* manager) {
        const wchar_t description[] = L"Rime Q process-only regression fixture";
        if (global) {
            ComPtr<ITfInputProcessorProfiles> legacy; check(manager->QueryInterface(IID_PPV_ARGS(&legacy)));
            wchar_t module[32768]{}; auto length = GetModuleFileNameW(nullptr, module, _countof(module));
            check(legacy->Register(clsid));
            check(legacy->AddLanguageProfile(clsid, 0x0804, profile, description, _countof(description) - 1, module, length, 0));
            check(legacy->EnableLanguageProfile(clsid, 0x0804, profile, TRUE));
            check(legacy->EnableLanguageProfile(clsid, 0x0804, profile, FALSE));
            return;
        }
        check(manager->RegisterProfile(clsid, 0x0804, profile, description, _countof(description) - 1,
            nullptr, 0, 0, nullptr, 0, FALSE, (global ? 0 : TF_RP_LOCALPROCESS) | TF_RP_HIDDENINSETTINGUI));
    }
};
bool registryPresent(REFCLSID classId) {
    wchar_t identity[40]{}; StringFromGUID2(classId, identity, _countof(identity));
    HKEY key = nullptr;
    auto path = std::wstring(L"Software\\Microsoft\\CTF\\TIP\\") + identity;
    auto result = RegOpenKeyExW(HKEY_LOCAL_MACHINE, path.c_str(), 0, KEY_READ, &key);
    if (result == ERROR_FILE_NOT_FOUND || result == ERROR_PATH_NOT_FOUND) return false;
    check(HRESULT_FROM_WIN32(result)); RegCloseKey(key); return true;
}
}
int main(int argc, char** argv) {
    bool global = argc == 2 && std::string(argv[1]) == "--global";
    if (argc > 1 && !global) return 2;
    if (global) {
        wchar_t actions[8]{}, ci[8]{};
        GetEnvironmentVariableW(L"GITHUB_ACTIONS", actions, _countof(actions));
        GetEnvironmentVariableW(L"CI", ci, _countof(ci));
        if (std::wstring(actions) != L"true" || std::wstring(ci) != L"true") {
            std::cerr << "Global registration tests require a disposable GitHub runner\n"; return 2;
        }
    }
    auto init = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (FAILED(init)) return 2;
    int result = 0;
    try {
        ComPtr<ITfInputProcessorProfileMgr> manager;
        check(CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&manager)));
        Fixture owned(global), other(global); owned.add(manager.Get()); other.add(manager.Get());
        if (!present(manager.Get(), owned.clsid, owned.profile)) throw std::runtime_error("Fixture was not registered");
        check(rq::unregisterProfile(owned.clsid, 0x0804, owned.profile, owned.scope()));
        if (global) {
            check(rq::removeServiceRegistry(owned.clsid));
            if (registryPresent(owned.clsid)) throw std::runtime_error("Service registration remains");
            if (!registryPresent(other.clsid)) throw std::runtime_error("Another service registration changed");
        }
        if (present(manager.Get(), owned.clsid, owned.profile)) throw std::runtime_error("Unregistered profile remains in TSF enumeration");
        check(rq::unregisterProfile(owned.clsid, 0x0804, owned.profile, owned.scope()));
        if (!present(manager.Get(), other.clsid, other.profile)) throw std::runtime_error("Unregister changed another text service");
        std::cout << "PASS real TSF " << (global ? "global" : "process-only") << " profile registration, removal from enumeration, repeated removal and other profile retention\n";
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; result = 1; }
    CoUninitialize(); return result;
}
