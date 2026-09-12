#pragma once
#include <msctf.h>
#include <wrl/client.h>
// Only OS key routing is substituted: an unregistered TIP cannot advise the system
// foreground sink. Contexts, compositions, focus events and edit locks are real TSF.
class TestThreadManager final : public ITfThreadMgr, public ITfKeystrokeMgr {
    long references_ = 1;
    Microsoft::WRL::ComPtr<ITfThreadMgr> real_;
    Microsoft::WRL::ComPtr<ITfKeystrokeMgr> keys_;
public:
    explicit TestThreadManager(ITfThreadMgr* real) : real_(real) { real_.As(&keys_); }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
        if (!out) return E_POINTER;
        if (iid == IID_IUnknown || iid == IID_ITfThreadMgr) *out = static_cast<ITfThreadMgr*>(this);
        else if (iid == IID_ITfKeystrokeMgr) *out = static_cast<ITfKeystrokeMgr*>(this);
        else return real_->QueryInterface(iid, out);
        AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&references_); }
    ULONG STDMETHODCALLTYPE Release() override { auto n = InterlockedDecrement(&references_); if (!n) delete this; return n; }
    HRESULT STDMETHODCALLTYPE Activate(TfClientId* id) override { return real_->Activate(id); }
    HRESULT STDMETHODCALLTYPE Deactivate() override { return real_->Deactivate(); }
    HRESULT STDMETHODCALLTYPE CreateDocumentMgr(ITfDocumentMgr** out) override { return real_->CreateDocumentMgr(out); }
    HRESULT STDMETHODCALLTYPE EnumDocumentMgrs(IEnumTfDocumentMgrs** out) override { return real_->EnumDocumentMgrs(out); }
    HRESULT STDMETHODCALLTYPE GetFocus(ITfDocumentMgr** out) override { return real_->GetFocus(out); }
    HRESULT STDMETHODCALLTYPE SetFocus(ITfDocumentMgr* out) override { return real_->SetFocus(out); }
    HRESULT STDMETHODCALLTYPE AssociateFocus(HWND window, ITfDocumentMgr* document, ITfDocumentMgr** previous) override { return real_->AssociateFocus(window, document, previous); }
    HRESULT STDMETHODCALLTYPE IsThreadFocus(BOOL* value) override { return real_->IsThreadFocus(value); }
    HRESULT STDMETHODCALLTYPE GetFunctionProvider(REFCLSID id, ITfFunctionProvider** out) override { return real_->GetFunctionProvider(id, out); }
    HRESULT STDMETHODCALLTYPE EnumFunctionProviders(IEnumTfFunctionProviders** out) override { return real_->EnumFunctionProviders(out); }
    HRESULT STDMETHODCALLTYPE GetGlobalCompartment(ITfCompartmentMgr** out) override { return real_->GetGlobalCompartment(out); }
    HRESULT STDMETHODCALLTYPE AdviseKeyEventSink(TfClientId, ITfKeyEventSink*, BOOL) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE UnadviseKeyEventSink(TfClientId) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE GetForeground(CLSID* out) override { return keys_->GetForeground(out); }
    HRESULT STDMETHODCALLTYPE TestKeyDown(WPARAM w, LPARAM l, BOOL* out) override { return keys_->TestKeyDown(w,l,out); }
    HRESULT STDMETHODCALLTYPE TestKeyUp(WPARAM w, LPARAM l, BOOL* out) override { return keys_->TestKeyUp(w,l,out); }
    HRESULT STDMETHODCALLTYPE KeyDown(WPARAM w, LPARAM l, BOOL* out) override { return keys_->KeyDown(w,l,out); }
    HRESULT STDMETHODCALLTYPE KeyUp(WPARAM w, LPARAM l, BOOL* out) override { return keys_->KeyUp(w,l,out); }
    HRESULT STDMETHODCALLTYPE GetPreservedKey(ITfContext* c, const TF_PRESERVEDKEY* p, GUID* g) override { return keys_->GetPreservedKey(c,p,g); }
    HRESULT STDMETHODCALLTYPE IsPreservedKey(REFGUID g, const TF_PRESERVEDKEY* p, BOOL* b) override { return keys_->IsPreservedKey(g,p,b); }
    HRESULT STDMETHODCALLTYPE PreserveKey(TfClientId id, REFGUID g, const TF_PRESERVEDKEY* p, const WCHAR* d, ULONG n) override { return keys_->PreserveKey(id,g,p,d,n); }
    HRESULT STDMETHODCALLTYPE UnpreserveKey(REFGUID g, const TF_PRESERVEDKEY* p) override { return keys_->UnpreserveKey(g,p); }
    HRESULT STDMETHODCALLTYPE SetPreservedKeyDescription(REFGUID g, const WCHAR* d, ULONG n) override { return keys_->SetPreservedKeyDescription(g,d,n); }
    HRESULT STDMETHODCALLTYPE GetPreservedKeyDescription(REFGUID g, BSTR* out) override { return keys_->GetPreservedKeyDescription(g,out); }
    HRESULT STDMETHODCALLTYPE SimulatePreservedKey(ITfContext* c, REFGUID g, BOOL* b) override { return keys_->SimulatePreservedKey(c,g,b); }
};
