#include "win.h"
#include "identity.h"
#include "profile_registration.h"
#include <msctf.h>
#include <wrl/client.h>
#include <sstream>
using Microsoft::WRL::ComPtr;
extern HMODULE rqModule;
extern long rqObjects;
extern HRESULT createService(REFIID, void**);
namespace {
void traceRegistration(const char* stage, HRESULT hr) {
    std::ostringstream output;
    output << "tsf-" << stage << "-x" << (sizeof(void*) == 8 ? 64 : 86) << "-hr-" << std::hex << static_cast<unsigned long>(hr) << '\n';
    auto text = output.str(); DWORD written = 0;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), text.data(), static_cast<DWORD>(text.size()), &written, nullptr);
}
class Factory final : public IClassFactory {
    long references_ = 1;
public:
    Factory() { InterlockedIncrement(&rqObjects); }
    ~Factory() { InterlockedDecrement(&rqObjects); }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
        if (!out) return E_POINTER; *out = nullptr;
        if (iid != IID_IUnknown && iid != IID_IClassFactory) return E_NOINTERFACE;
        *out = static_cast<IClassFactory*>(this); AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&references_); }
    ULONG STDMETHODCALLTYPE Release() override { auto n = InterlockedDecrement(&references_); if (!n) delete this; return n; }
    HRESULT STDMETHODCALLTYPE CreateInstance(IUnknown* outer, REFIID iid, void** out) override {
        if (outer) return CLASS_E_NOAGGREGATION; return createService(iid, out);
    }
    HRESULT STDMETHODCALLTYPE LockServer(BOOL lock) override { lock ? InterlockedIncrement(&rqObjects) : InterlockedDecrement(&rqObjects); return S_OK; }
};
HRESULT setString(const std::wstring& path, const wchar_t* name, const std::wstring& value) {
    HKEY key = nullptr; auto error = RegCreateKeyExW(HKEY_LOCAL_MACHINE, path.c_str(), 0, nullptr, 0, KEY_WRITE, nullptr, &key, nullptr);
    if (error != ERROR_SUCCESS) return HRESULT_FROM_WIN32(error);
    error = RegSetValueExW(key, name, 0, REG_SZ, reinterpret_cast<const BYTE*>(value.c_str()), static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
    RegCloseKey(key); return HRESULT_FROM_WIN32(error);
}
const GUID categories[] = {GUID_TFCAT_TIP_KEYBOARD, GUID_TFCAT_DISPLAYATTRIBUTEPROVIDER,
    GUID_TFCAT_TIPCAP_UIELEMENTENABLED, GUID_TFCAT_TIPCAP_INPUTMODECOMPARTMENT,
    GUID_TFCAT_TIPCAP_SYSTRAYSUPPORT};
}
// Export aliases also preserve the COM ABI for 32-bit stdcall builds.
#ifdef _WIN64
#pragma comment(linker, "/EXPORT:DllGetClassObject,PRIVATE")
#pragma comment(linker, "/EXPORT:DllCanUnloadNow,PRIVATE")
#pragma comment(linker, "/EXPORT:DllRegisterServer,PRIVATE")
#pragma comment(linker, "/EXPORT:DllUnregisterServer,PRIVATE")
#else
#pragma comment(linker, "/EXPORT:DllGetClassObject=_DllGetClassObject@12,PRIVATE")
#pragma comment(linker, "/EXPORT:DllCanUnloadNow=_DllCanUnloadNow@0,PRIVATE")
#pragma comment(linker, "/EXPORT:DllRegisterServer=_DllRegisterServer@0,PRIVATE")
#pragma comment(linker, "/EXPORT:DllUnregisterServer=_DllUnregisterServer@0,PRIVATE")
#endif
extern "C" HRESULT __stdcall DllGetClassObject(REFCLSID clsid, REFIID iid, void** out) {
    if (clsid != rq::clsid) return CLASS_E_CLASSNOTAVAILABLE;
    auto factory = new (std::nothrow) Factory(); if (!factory) return E_OUTOFMEMORY;
    auto hr = factory->QueryInterface(iid, out); factory->Release(); return hr;
}
extern "C" HRESULT __stdcall DllCanUnloadNow() {
    if (rqObjects != 0) return S_FALSE;
    // No window may retain a procedure address after COM unloads this DLL.
    UnregisterClassW(L"RimeQ.Candidates.v1",rqModule);
    UnregisterClassW(L"RimeQ.TsfTimer.v1",rqModule);
    return S_OK;
}
extern "C" HRESULT __stdcall DllRegisterServer() {
    auto init = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    HRESULT hr = E_FAIL;
    try {
        auto path = rq::modulePath(rqModule).wstring();
        auto key = std::wstring(L"Software\\Classes\\CLSID\\") + rq::clsidString;
        hr = setString(key, nullptr, L"Rime Q Text Service");
        if (SUCCEEDED(hr)) hr = setString(key + L"\\InprocServer32", nullptr, path);
        if (SUCCEEDED(hr)) hr = setString(key + L"\\InprocServer32", L"ThreadingModel", L"Apartment");
#ifdef _WIN64
        // CTF\TIP is shared by WOW64; COM\CLSID is redirected. The x64
        // component owns shared profiles/categories, while x86 registers COM only.
        ComPtr<ITfInputProcessorProfiles> profiles;
        if (SUCCEEDED(hr)) hr = CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&profiles));
        if (SUCCEEDED(hr)) hr = profiles->Register(rq::clsid);
        if (SUCCEEDED(hr)) hr = profiles->AddLanguageProfile(rq::clsid, rq::language, rq::profile, rq::product,
            static_cast<ULONG>(wcslen(rq::product)), path.c_str(), static_cast<ULONG>(path.size()), 0);
        ComPtr<ITfCategoryMgr> categoriesManager;
        if (SUCCEEDED(hr)) hr = CoCreateInstance(CLSID_TF_CategoryMgr, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&categoriesManager));
        if (SUCCEEDED(hr)) for (const auto& category : categories) {
            hr = categoriesManager->RegisterCategory(rq::clsid, category, rq::clsid); if (FAILED(hr)) break;
        }
        if (SUCCEEDED(hr)) hr = profiles->EnableLanguageProfile(rq::clsid, rq::language, rq::profile, TRUE);
#endif
    } catch (...) { hr = E_FAIL; }
    if (SUCCEEDED(init)) CoUninitialize(); return hr;
}
extern "C" HRESULT __stdcall DllUnregisterServer() {
    auto init = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
#ifdef _WIN64
    HRESULT hr = rq::unregisterProfile(rq::clsid, rq::language, rq::profile);
    traceRegistration("unregister-profile", hr);
    ComPtr<ITfCategoryMgr> manager;
    if (SUCCEEDED(CoCreateInstance(CLSID_TF_CategoryMgr, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&manager))))
        for (const auto& category : categories) manager->UnregisterCategory(rq::clsid, category, rq::clsid);
    // Only our CTF/COM service keys remain after profile and category removal.
    if (SUCCEEDED(hr)) hr = rq::removeServiceRegistry(rq::clsid);
    traceRegistration("remove-service-keys", hr);
    manager.Reset();
#else
    HRESULT hr = rq::removeServiceRegistry(rq::clsid, false);
    traceRegistration("remove-com-keys", hr);
#endif
    if (SUCCEEDED(init)) CoUninitialize(); return hr;
}
