#include "win.h"
#include "identity.h"
#include <msctf.h>
#include <wrl/client.h>
#include <iostream>
using Microsoft::WRL::ComPtr;
namespace {
HRESULT enable(bool value) {
    ComPtr<ITfInputProcessorProfiles> profiles;
    HRESULT hr = CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&profiles));
    if (FAILED(hr)) return hr;
    hr = profiles->EnableLanguageProfile(rq::clsid, rq::language, rq::profile, value);
    if (FAILED(hr)) return hr;
    // Apply the one profile to this user's current session through the documented
    // Windows input API. Never use CLEANINSTALL or change the default profile.
    auto input = LoadLibraryExW(L"input.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!input) return HRESULT_FROM_WIN32(GetLastError());
    auto install = reinterpret_cast<BOOL(WINAPI*)(LPCWSTR,DWORD)>(GetProcAddress(input, "InstallLayoutOrTip"));
    wchar_t profile[40]{}; StringFromGUID2(rq::profile, profile, 40);
    std::wstring specification = std::wstring(L"0x0804:") + rq::clsidString + profile;
    BOOL applied = install && install(specification.c_str(), value ? 0 : 1); FreeLibrary(input);
    if (!applied) return E_FAIL;
    BOOL enabled = FALSE; hr = profiles->IsEnabledLanguageProfile(rq::clsid, rq::language, rq::profile, &enabled);
    return SUCCEEDED(hr) && (enabled != FALSE) == value ? S_OK : E_FAIL;
}
HRESULT leave() {
    ComPtr<ITfInputProcessorProfileMgr> manager;
    HRESULT hr = CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&manager));
    if (FAILED(hr)) return hr;
    TF_INPUTPROCESSORPROFILE active{};
    hr = manager->GetActiveProfile(GUID_TFCAT_TIP_KEYBOARD, &active);
    if (FAILED(hr)) return hr;
    if (SUCCEEDED(hr) && active.clsid == rq::clsid) {
        ComPtr<ITfInputProcessorProfiles> profiles; manager.As(&profiles); LANGID* languages = nullptr; ULONG count = 0;
        if (FAILED(profiles->GetLanguageList(&languages, &count))) return E_FAIL;
        bool switched = false;
        for (ULONG i = 0; i < count && !switched; ++i) {
            ComPtr<IEnumTfInputProcessorProfiles> list;
            if (FAILED(manager->EnumProfiles(languages[i], &list))) continue;
            TF_INPUTPROCESSORPROFILE candidate{}; ULONG fetched = 0;
            while (list->Next(1, &candidate, &fetched) == S_OK && fetched) {
                if (candidate.clsid == rq::clsid || !(candidate.dwFlags & TF_IPP_FLAG_ENABLED)) continue;
                if (candidate.dwProfileType == TF_PROFILETYPE_INPUTPROCESSOR && candidate.catid != GUID_TFCAT_TIP_KEYBOARD) continue;
                hr = manager->ActivateProfile(candidate.dwProfileType, candidate.langid, candidate.clsid, candidate.guidProfile,
                    candidate.hkl, TF_IPPMF_FORSESSION | TF_IPPMF_DONTCARECURRENTINPUTLANGUAGE);
                if (SUCCEEDED(hr)) { switched = true; break; }
            }
        }
        CoTaskMemFree(languages);
        if (!switched) return E_FAIL;
    }
    return enable(false);
}
}
int wmain(int argc, wchar_t** argv) {
    if (argc != 2) return 2;
    HRESULT init = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED); if (FAILED(init)) return 2;
    HRESULT hr = E_INVALIDARG;
    auto action = std::wstring(argv[1]);
    if (action == L"--enable") hr = enable(true);
    else if (action == L"--deactivate") hr = leave();
    else if (action == L"--verify") {
        ComPtr<ITfInputProcessorProfiles> profiles;
        hr = CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&profiles));
        BOOL value = FALSE;
        if (SUCCEEDED(hr)) hr = profiles->IsEnabledLanguageProfile(rq::clsid, rq::language, rq::profile, &value);
        if (SUCCEEDED(hr) && !value) hr = E_FAIL;
    }
    else if (action == L"--verify-absent") {
        ComPtr<ITfInputProcessorProfileMgr> profiles;
        hr = CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&profiles));
        const char* stage = "create-manager";
        ComPtr<IEnumTfInputProcessorProfiles> list;
        if (SUCCEEDED(hr)) { stage = "enum-profiles"; hr = profiles->EnumProfiles(rq::language, &list); }
        if (SUCCEEDED(hr)) {
            TF_INPUTPROCESSORPROFILE item{}; ULONG fetched = 0;
            stage = "next-profile";
            while ((hr = list->Next(1, &item, &fetched)) == S_OK && fetched) {
                if (item.clsid == rq::clsid) {
                    wchar_t profile[40]{}; StringFromGUID2(item.guidProfile, profile, _countof(profile));
                    std::wcout << L"tsf-profile type=" << std::dec << item.dwProfileType << L" lang=0x" << std::hex << item.langid
                        << L" clsid=" << rq::clsidString << L" profile=" << profile << L" flags=0x" << item.dwFlags << L'\n';
                    stage = "profile-remains"; hr = E_FAIL; break;
                }
            }
            if (hr == S_FALSE) { stage = "absent"; hr = S_OK; }
        }
        std::cout << "tsf-absence stage=" << stage << " hr=0x" << std::hex << static_cast<unsigned long>(hr) << '\n';
    }
    CoUninitialize();
    std::cout << (SUCCEEDED(hr) ? "enabled-or-completed" : "pending-or-failed") << " hr=0x" << std::hex << static_cast<unsigned long>(hr) << '\n';
    return SUCCEEDED(hr) ? 0 : 1;
}
