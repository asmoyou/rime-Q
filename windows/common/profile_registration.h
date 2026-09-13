#pragma once
#include <windows.h>
#include <msctf.h>
#include <wrl/client.h>
#include <string>

namespace rq {
// Unregister the language profile through TSF's profile manager so its profile
// enumeration is updated as well as persistent registration. Tests use the
// documented process-only scope; the installed TIP uses the default global scope.
inline HRESULT unregisterProfile(REFCLSID classId, LANGID languageId, REFGUID profileId, DWORD flags = 0) {
    Microsoft::WRL::ComPtr<ITfInputProcessorProfileMgr> manager;
    auto hr = CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&manager));
    if (FAILED(hr)) return hr;
    auto removed = manager->UnregisterProfile(classId, languageId, profileId, flags);
    if (SUCCEEDED(removed)) return removed;
    // The other architecture may already have removed the shared profile.
    // Accept that case only when TSF enumeration proves it is absent.
    Microsoft::WRL::ComPtr<IEnumTfInputProcessorProfiles> list;
    hr = manager->EnumProfiles(languageId, &list);
    if (FAILED(hr)) return hr;
    for (;;) {
        TF_INPUTPROCESSORPROFILE item{}; ULONG fetched = 0;
        hr = list->Next(1, &item, &fetched);
        if (FAILED(hr)) return hr;
        if (hr == S_FALSE) return S_OK;
        if (fetched != 1) return E_FAIL;
        if (item.clsid == classId && item.guidProfile == profileId) return removed;
    }
}
inline HRESULT removeServiceRegistry(REFCLSID classId, bool sharedCtf = true) {
    wchar_t identity[40]{};
    if (!StringFromGUID2(classId, identity, _countof(identity))) return E_INVALIDARG;
    const wchar_t* prefixes[] = {L"Software\\Microsoft\\CTF\\TIP\\", L"Software\\Classes\\CLSID\\"};
    for (unsigned i = sharedCtf ? 0 : 1; i < _countof(prefixes); ++i) {
        auto path = std::wstring(prefixes[i]) + identity;
        auto error = RegDeleteTreeW(HKEY_LOCAL_MACHINE, path.c_str());
        if (error != ERROR_SUCCESS && error != ERROR_FILE_NOT_FOUND && error != ERROR_PATH_NOT_FOUND)
            return HRESULT_FROM_WIN32(error);
    }
    return S_OK;
}
}
