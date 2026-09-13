#pragma once
#include <windows.h>
#include <msctf.h>
#include <wrl/client.h>

namespace rq {
// Unregister the language profile through TSF's profile manager so its profile
// enumeration is updated as well as persistent registration. Tests use the
// documented process-only scope; the installed TIP uses the default global scope.
inline HRESULT unregisterProfile(REFCLSID classId, LANGID languageId, REFGUID profileId, DWORD flags = 0) {
    Microsoft::WRL::ComPtr<ITfInputProcessorProfileMgr> manager;
    auto hr = CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&manager));
    return FAILED(hr) ? hr : manager->UnregisterProfile(classId, languageId, profileId, flags);
}
}
