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
    Fixture() { check(CoCreateGuid(&clsid)); check(CoCreateGuid(&profile)); }
    ~Fixture() { rq::unregisterProfile(clsid, 0x0804, profile, TF_URP_LOCALPROCESS); }
    void add(ITfInputProcessorProfileMgr* manager) {
        const wchar_t description[] = L"Rime Q process-only regression fixture";
        check(manager->RegisterProfile(clsid, 0x0804, profile, description, _countof(description) - 1,
            nullptr, 0, 0, nullptr, 0, FALSE, TF_RP_LOCALPROCESS | TF_RP_HIDDENINSETTINGUI));
    }
};
}
int main() {
    auto init = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (FAILED(init)) return 2;
    int result = 0;
    try {
        ComPtr<ITfInputProcessorProfileMgr> manager;
        check(CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&manager)));
        Fixture owned, other; owned.add(manager.Get()); other.add(manager.Get());
        if (!present(manager.Get(), owned.clsid, owned.profile)) throw std::runtime_error("Fixture was not registered");
        check(rq::unregisterProfile(owned.clsid, 0x0804, owned.profile, TF_URP_LOCALPROCESS));
        if (present(manager.Get(), owned.clsid, owned.profile)) throw std::runtime_error("Unregistered profile remains in TSF enumeration");
        check(rq::unregisterProfile(owned.clsid, 0x0804, owned.profile, TF_URP_LOCALPROCESS));
        if (!present(manager.Get(), other.clsid, other.profile)) throw std::runtime_error("Unregister changed another text service");
        std::cout << "PASS real TSF process-only profile registration, removal from enumeration, repeated removal and other profile retention\n";
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; result = 1; }
    CoUninitialize(); return result;
}
