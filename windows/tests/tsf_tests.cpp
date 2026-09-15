// Integration fixture: real TSF manager/context/write locks, the production TIP DLL,
// and real librime in an isolated directory. This is not an external-host acceptance test.
#include "win.h"
#include "identity.h"
#include "../broker/engine.h"
#include <msctf.h>
#include <ctffunc.h>
#include <ctfutb.h>
#include <textstor.h>
#include <olectl.h>
#include <wrl/client.h>
#include <atomic>
#include <thread>
#include <iostream>
#include <fstream>
#include "thread_manager.h"
using Microsoft::WRL::ComPtr;
namespace {
void require(bool condition, const char* message) { if (!condition) throw std::runtime_error(message); }
void check(HRESULT result, const char* message) {
    if (FAILED(result)) { std::cerr << message << " hr=0x" << std::hex << result << std::dec << '\n'; throw std::runtime_error(message); }
}
class Store final : public ITextStoreACP {
    long references_ = 1;
    DWORD lock_ = 0;
public:
    std::wstring text;
    TS_SELECTION_ACP selection{0,0,{TS_AE_NONE,FALSE}};
    ComPtr<ITextStoreACPSink> sink;
    bool denyWrite = false;
    HWND window = nullptr;
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
        if (!out) return E_POINTER; *out = nullptr;
        if (iid != IID_IUnknown && iid != IID_ITextStoreACP) return E_NOINTERFACE;
        *out = static_cast<ITextStoreACP*>(this); AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&references_); }
    ULONG STDMETHODCALLTYPE Release() override { auto n = InterlockedDecrement(&references_); if (!n) delete this; return n; }
    HRESULT STDMETHODCALLTYPE AdviseSink(REFIID iid, IUnknown* object, DWORD) override {
        if (iid != IID_ITextStoreACPSink) return E_NOINTERFACE; return object->QueryInterface(IID_PPV_ARGS(&sink));
    }
    HRESULT STDMETHODCALLTYPE UnadviseSink(IUnknown*) override { sink.Reset(); return S_OK; }
    HRESULT STDMETHODCALLTYPE RequestLock(DWORD flags, HRESULT* result) override {
        if (!result) return E_POINTER;
        if (lock_ || (denyWrite && (flags & TS_LF_READWRITE) == TS_LF_READWRITE)) { *result = TS_E_SYNCHRONOUS; return S_OK; }
        lock_ = flags; *result = sink ? sink->OnLockGranted(flags) : E_UNEXPECTED; lock_ = 0; return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetStatus(TS_STATUS* status) override { if (!status) return E_POINTER; *status = {0,TS_SS_NOHIDDENTEXT}; return S_OK; }
    HRESULT STDMETHODCALLTYPE QueryInsert(LONG start, LONG end, ULONG, LONG* outStart, LONG* outEnd) override {
        if (start < 0 || end < start || end > static_cast<LONG>(text.size())) return TS_E_INVALIDPOS;
        *outStart = start; *outEnd = end; return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetSelection(ULONG index, ULONG count, TS_SELECTION_ACP* out, ULONG* fetched) override {
        *fetched = 0; if (!lock_) return TS_E_NOLOCK;
        if (count && (index == TS_DEFAULT_SELECTION || index == 0)) { *out = selection; *fetched = 1; } return S_OK;
    }
    HRESULT STDMETHODCALLTYPE SetSelection(ULONG count, const TS_SELECTION_ACP* value) override {
        if ((lock_ & TS_LF_READWRITE) != TS_LF_READWRITE) return TS_E_NOLOCK;
        if (count != 1 || value->acpStart < 0 || value->acpEnd < value->acpStart || value->acpEnd > static_cast<LONG>(text.size())) return E_INVALIDARG;
        selection = *value; return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetText(LONG start, LONG end, WCHAR* plain, ULONG capacity, ULONG* length,
        TS_RUNINFO* runs, ULONG runCapacity, ULONG* runCount, LONG* next) override {
        if (!lock_) return TS_E_NOLOCK; if (end == -1) end = static_cast<LONG>(text.size());
        if (start < 0 || end < start || end > static_cast<LONG>(text.size())) return TS_E_INVALIDPOS;
        ULONG count = std::min(capacity, static_cast<ULONG>(end - start));
        if (plain && count) memcpy(plain, text.data() + start, count * sizeof(wchar_t));
        *length = count; *runCount = runCapacity && count ? 1 : 0;
        if (*runCount) *runs = {count, TS_RT_PLAIN}; *next = start + count; return S_OK;
    }
    HRESULT STDMETHODCALLTYPE SetText(DWORD, LONG start, LONG end, const WCHAR* value, ULONG count, TS_TEXTCHANGE* change) override {
        if ((lock_ & TS_LF_READWRITE) != TS_LF_READWRITE) return TS_E_NOLOCK;
        if (start < 0 || end < start || end > static_cast<LONG>(text.size())) return TS_E_INVALIDPOS;
        text.replace(start, end - start, value, count); *change = {start,end,start + static_cast<LONG>(count)};
        selection.acpStart = selection.acpEnd = start + static_cast<LONG>(count); return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetFormattedText(LONG, LONG, IDataObject**) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetEmbedded(LONG, REFGUID, REFIID, IUnknown**) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE QueryInsertEmbedded(const GUID*, const FORMATETC*, BOOL* insertable) override { *insertable = FALSE; return S_OK; }
    HRESULT STDMETHODCALLTYPE InsertEmbedded(DWORD, LONG, LONG, IDataObject*, TS_TEXTCHANGE*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE InsertTextAtSelection(DWORD flags, const WCHAR* value, ULONG count, LONG* start, LONG* end, TS_TEXTCHANGE* change) override {
        if (!lock_) return TS_E_NOLOCK;
        if (start) *start = selection.acpStart; if (end) *end = selection.acpEnd;
        if (flags & TS_IAS_QUERYONLY) return S_OK;
        return SetText(0, selection.acpStart, selection.acpEnd, value, count, change);
    }
    HRESULT STDMETHODCALLTYPE InsertEmbeddedAtSelection(DWORD, IDataObject*, LONG*, LONG*, TS_TEXTCHANGE*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE RequestSupportedAttrs(DWORD, ULONG, const TS_ATTRID*) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE RequestAttrsAtPosition(LONG, ULONG, const TS_ATTRID*, DWORD) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE RequestAttrsTransitioningAtPosition(LONG, ULONG, const TS_ATTRID*, DWORD) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE FindNextAttrTransition(LONG, LONG halt, ULONG, const TS_ATTRID*, DWORD, LONG* next, BOOL* found, LONG* offset) override {
        *next = halt; *found = FALSE; *offset = 0; return S_OK;
    }
    HRESULT STDMETHODCALLTYPE RetrieveRequestedAttrs(ULONG, TS_ATTRVAL*, ULONG* fetched) override { *fetched = 0; return S_OK; }
    HRESULT STDMETHODCALLTYPE GetEndACP(LONG* end) override { *end = static_cast<LONG>(text.size()); return S_OK; }
    HRESULT STDMETHODCALLTYPE GetActiveView(TsViewCookie* view) override { *view = 0; return S_OK; }
    HRESULT STDMETHODCALLTYPE GetACPFromPoint(TsViewCookie, const POINT*, DWORD, LONG* position) override { *position = selection.acpEnd; return S_OK; }
    HRESULT STDMETHODCALLTYPE GetTextExt(TsViewCookie, LONG start, LONG end, RECT* rect, BOOL* clipped) override {
        *rect = {100 + start * 12,100,102 + end * 12,128}; *clipped = FALSE; return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetScreenExt(TsViewCookie, RECT* rect) override { *rect = {0,0,800,600}; return S_OK; }
    HRESULT STDMETHODCALLTYPE GetWnd(TsViewCookie, HWND* out) override { *out = window; return S_OK; }
};
void pump() { MSG message; while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) { TranslateMessage(&message); DispatchMessageW(&message); } }
struct Fixture {
    ComPtr<Store> store;
    ComPtr<ITfDocumentMgr> document;
    ComPtr<ITfContext> context;
    Fixture(ITfThreadMgr* manager, TfClientId id, HWND window) {
        store.Attach(new Store()); store->window = window;
        check(manager->CreateDocumentMgr(&document), "CreateDocumentMgr");
        TfEditCookie cookie; check(document->CreateContext(id, 0, store.Get(), &context, &cookie), "CreateContext");
        check(document->Push(context.Get()), "Push context");
    }
    ~Fixture() { document->Pop(TF_POPF_ALL); }
};
}
int wmain(int argc, wchar_t** argv) {
    if (argc == 4 && std::wstring(argv[1]) == L"--serve-fixture") {
        try {
            rq::Engine engine; engine.start(rq::fs::absolute(argv[2]), rq::fs::absolute(argv[3]), false);
            rq::Handle pipe(CreateNamedPipeW(rq::pipeName().c_str(), PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 1, rq::maxFrame, rq::maxFrame, 0, nullptr));
            require(bool(pipe), "Refused to replace an existing Rime Q service");
            std::ofstream(rq::fs::path(argv[3]) / L"fixture.ready") << "ready\n";
            rq::Handle event(CreateEventW(nullptr,TRUE,FALSE,nullptr)); OVERLAPPED ov{}; ov.hEvent = event.value;
            bool connected = ConnectNamedPipe(pipe.value,&ov) != FALSE;
            if (!connected) {
                auto error = GetLastError();
                if (error == ERROR_PIPE_CONNECTED) connected = true;
                else if (error == ERROR_IO_PENDING) {
                    DWORD count = 0;
                    if (WaitForSingleObject(event.value,10000) == WAIT_OBJECT_0) connected = GetOverlappedResult(pipe.value,&ov,&count,FALSE) != FALSE;
                    else { CancelIoEx(pipe.value,&ov); GetOverlappedResult(pipe.value,&ov,&count,TRUE); }
                }
            }
            require(connected,"Fixture client did not connect");
            for (;;) {
                std::vector<uint8_t> bytes; if (!rq::receiveFrame(pipe.value,bytes,GetTickCount64()+10000)) break;
                auto state = engine.process(1,rq::request(bytes)); if (!rq::sendFrame(pipe.value,rq::encode(state),GetTickCount64()+2000)) break;
            }
            engine.disconnect(1); return 0;
        } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
    }
    if (argc != 4 && argc != 5) return 2;
    bool remote = argc == 5 && std::wstring(argv[4]) == L"--remote";
    std::atomic<bool> stop{false}; std::thread server;
    rq::Engine engine;
    rq::Handle pipe;
    try {
        CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
        if (!remote) {
        engine.start(rq::fs::absolute(argv[2]), rq::fs::absolute(argv[3]), false);
        // Refuse to replace an existing broker. This fixture must never share a live input service.
        pipe.reset(CreateNamedPipeW(rq::pipeName().c_str(), PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 1, rq::maxFrame, rq::maxFrame, 0, nullptr));
        require(bool(pipe), "A live Rime Q broker exists; isolated TSF test refused");
        server = std::thread([&] {
            rq::Handle event(CreateEventW(nullptr, TRUE, FALSE, nullptr)); OVERLAPPED ov{}; ov.hEvent = event.value;
            bool connected = ConnectNamedPipe(pipe.value, &ov) != FALSE;
            if (!connected && GetLastError() == ERROR_IO_PENDING) { WaitForSingleObject(event.value, 5000); DWORD n; connected = GetOverlappedResult(pipe.value, &ov, &n, FALSE) != FALSE; }
            else if (!connected && GetLastError() == ERROR_PIPE_CONNECTED) connected = true;
            if (!connected) { CancelIoEx(pipe.value, &ov); return; }
            try {
                while (!stop) {
                    std::vector<uint8_t> data;
                    if (!rq::receiveFrame(pipe.value, data, GetTickCount64() + 5000)) break;
                    auto request = rq::request(data); auto state = engine.process(1, request);
                    if (!rq::sendFrame(pipe.value, rq::encode(state), GetTickCount64() + 1000)) break;
                }
            } catch (const std::exception& e) { std::cerr << "server error " << e.what() << "\n"; }
            engine.disconnect(1);
        });
        }
        rq::Handle moduleGuard; auto library = LoadLibraryW(rq::fs::absolute(argv[1]).c_str()); require(library != nullptr, "Load production TIP DLL");
        auto getFactory = reinterpret_cast<HRESULT(__stdcall*)(REFCLSID,REFIID,void**)>(GetProcAddress(library, "DllGetClassObject")); require(getFactory != nullptr, "COM exports");
        ComPtr<IClassFactory> factory; check(getFactory(rq::clsid, IID_PPV_ARGS(&factory)), "Get class factory");
        ComPtr<ITfTextInputProcessorEx> tip; check(factory->CreateInstance(nullptr, IID_PPV_ARGS(&tip)), "Create production TIP");
        ComPtr<ITfThreadMgr> manager; check(CoCreateInstance(CLSID_TF_ThreadMgr, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&manager)), "Create TSF manager");
        TfClientId id; check(manager->Activate(&id), "Activate TSF manager");
        HWND window = CreateWindowExW(0, L"STATIC", L"Rime Q 隔离 TSF 验证", WS_OVERLAPPEDWINDOW, 0, 0, 800, 600, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
        Fixture first(manager.Get(), id, window), second(manager.Get(), id, window);
        check(manager->SetFocus(first.document.Get()), "Focus first TSF document");
        ComPtr<TestThreadManager> testManager; testManager.Attach(new TestThreadManager(manager.Get()));
        check(tip->ActivateEx(testManager.Get(), id, 0), "Activate production TIP");
        ComPtr<ITfKeyEventSink> keys; check(tip.As(&keys), "Key sink");
        ComPtr<ITfLangBarItemMgr> bar;check(CoCreateInstance(CLSID_TF_LangBarItemMgr,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&bar)),"Language bar manager");ComPtr<ITfLangBarItem> modeItem;
        check(bar->GetItem(GUID_LBI_INPUTMODE,&modeItem),"Rime Q system input-mode item");
        TF_LANGBARITEMINFO modeInfo{};check(modeItem->GetInfo(&modeInfo),"Mode bar info");
        require(modeInfo.guidItem==GUID_LBI_INPUTMODE&&(modeInfo.dwStyle&TF_LBI_STYLE_SHOWNINTRAY),"Mode bar must use the Windows taskbar identity");
        ComPtr<ITfLangBarItemButton> modeButton;check(modeItem.As(&modeButton),"Mode bar button");
        auto modeText=[&](){BSTR raw=nullptr;check(modeButton->GetText(&raw),"Mode bar text");std::wstring value(raw,SysStringLen(raw));SysFreeString(raw);return value;};
        HICON modeIcon=nullptr;check(modeButton->GetIcon(&modeIcon),"Mode bar icon");require(modeIcon!=nullptr&&modeText()==L"中","Initial mode bar presentation");DestroyIcon(modeIcon);
        ComPtr<ITfCompartmentMgr> compartmentManager;check(manager.As(&compartmentManager),"Compartment manager");
        ComPtr<ITfCompartment> openClose,conversionMode;check(compartmentManager->GetCompartment(GUID_COMPARTMENT_KEYBOARD_OPENCLOSE,&openClose),"Open/close compartment");
        check(compartmentManager->GetCompartment(GUID_COMPARTMENT_KEYBOARD_INPUTMODE_CONVERSION,&conversionMode),"Conversion compartment");
        auto compartment=[&](ITfCompartment* item){VARIANT value;VariantInit(&value);check(item->GetValue(&value),"Read mode compartment");require(value.vt==VT_I4,"Mode compartment type");auto result=value.lVal;VariantClear(&value);return result;};
        require(compartment(openClose.Get())==1&&(compartment(conversionMode.Get())&TF_CONVERSIONMODE_NATIVE),"Initial Chinese mode compartments");
        auto key = [&](Fixture& field, WPARAM vk, bool expected = true, LPARAM lparam = 0) {
            BOOL test = FALSE, repeated = FALSE, eaten = FALSE;
            auto before = field.store->text;
            check(keys->OnTestKeyDown(field.context.Get(), vk, lparam, &test), "Test key");
            check(keys->OnTestKeyDown(field.context.Get(), vk, lparam, &repeated), "Repeated test key");
            require(field.store->text == before && test == repeated, "Test-key callback changed document");
            if (test) check(keys->OnKeyDown(field.context.Get(), vk, lparam, &eaten), "Key down");
            if (expected != (eaten != FALSE)) { std::cerr << "vk=" << LOWORD(vk) << " test=" << test << " eaten=" << eaten << '\n'; throw std::runtime_error("Unexpected key handling"); }
            pump();
        };
        auto packet = [&](Fixture& field, wchar_t value, bool expected = true) {
            key(field, (static_cast<WPARAM>(value) << 16) | VK_PACKET, expected);
        };
        BYTE keyboard[256]{}; SetKeyboardState(keyboard);
        for (char c : std::string("NIHAO")) key(first, c);
        require(first.store->text == L"ni hao", "TSF preedit mismatch");
        require(first.store->selection.acpStart == static_cast<LONG>(first.store->text.size()), "Preedit caret not at end");
        key(first, VK_SPACE); require(first.store->text == L"你好", "TSF space commit failed");
        for (auto value : std::wstring(L"nihao")) packet(first,value);
        packet(first,L' ');require(first.store->text==L"你好你好","Remote Unicode packet input failed");
        key(first, 'N'); key(first, 'I'); key(first, VK_ESCAPE); require(first.store->text == L"你好你好", "Escape left preedit");
        key(first, 'N'); key(first, 'I');
        check(manager->SetFocus(second.document.Get()), "Switch TSF focus"); pump();
        ComPtr<ITfThreadMgrEventSink> focusEvents; check(tip.As(&focusEvents), "Focus event sink");
        check(focusEvents->OnSetFocus(second.document.Get(), first.document.Get()), "Deliver focus event for unregistered fixture"); pump();
        require(first.store->text == L"你好你好", "Focus change did not cancel old composition");
        for (char c : std::string("HAO")) key(second, c);
        key(second, '1'); require(second.store->text == L"好", "Number selection or first key after focus failed");
        second.store->denyWrite = true; key(second, 'N', false); second.store->denyWrite = false;
        key(second, 'H'); key(second, 'A'); key(second, 'O'); key(second, VK_SPACE); require(second.store->text == L"好好", "Write-lock failure advanced engine");
        for (char c : std::string("NIHAO")) key(second,c);
        key(second,VK_CAPITAL,false);
        require(second.store->text == L"好好你好" && modeText()==L"中", "Caps Lock did not complete composition in the same mode");
        keyboard[VK_CAPITAL]=1;SetKeyboardState(keyboard);
        key(second,'A',false);require(second.store->text == L"好好你好", "Caps Lock swallowed host uppercase key");
        keyboard[VK_CAPITAL]=0;SetKeyboardState(keyboard);
        key(second,'N');key(second,'I');key(second,'H');key(second,'A');key(second,'O');key(second,VK_SPACE);
        require(second.store->text == L"好好你好你好" && modeText()==L"中", "Caps Lock release did not restore Chinese input");
        key(second, VK_SHIFT); BOOL shiftEaten = FALSE; keys->OnKeyUp(second.context.Get(), VK_SHIFT, 0, &shiftEaten);
        key(second, 'A', false); require(second.store->text == L"好好"&&compartment(openClose.Get())==0&&modeText()==L"英","English key or mode presentation mismatch");
        BOOL preservedEaten=FALSE;check(keys->OnPreservedKey(second.context.Get(),rq::modeToggleKey,&preservedEaten),"Ctrl+Space mode toggle");
        require(preservedEaten&&compartment(openClose.Get())==1&&(compartment(conversionMode.Get())&TF_CONVERSIONMODE_NATIVE)&&modeText()==L"中","Preserved key did not restore Chinese mode");
        POINT point{};RECT rect{};check(modeButton->OnClick(TF_LBI_CLK_LEFT,point,&rect),"Mode bar click to English");
        require(compartment(openClose.Get())==0&&modeText()==L"英","Mode bar click did not select English");
        check(modeButton->OnClick(TF_LBI_CLK_LEFT,point,&rect),"Mode bar click to Chinese");require(compartment(openClose.Get())==1&&modeText()==L"中","Mode bar click did not select Chinese");
        key(second, 'N'); key(second, 'I'); key(second, VK_ESCAPE);
        VARIANT mode;VariantInit(&mode);mode.vt=VT_I4;mode.lVal=0;check(openClose->SetValue(id,&mode),"Set external English mode");pump();key(second,'A',false);
        mode.lVal=1;check(openClose->SetValue(id,&mode),"Set external Chinese mode");pump();key(second,'N');key(second,'I');key(second,VK_ESCAPE);VariantClear(&mode);
        tip->Deactivate(); keys.Reset(); tip.Reset(); factory.Reset(); pump();
        check(manager->SetFocus(nullptr), "Clear TSF focus");
        stop = true; if (server.joinable()) server.join(); DestroyWindow(window); manager->Deactivate();
        std::cout << "PASS real TSF context/write locks + production TIP: composition, remote Unicode packets, cancel, focus, Shift/Ctrl+Space, mode compartments, taskbar item and isolated librime\n";
        return 0;
    } catch (const std::exception& error) {
        stop = true; if (server.joinable()) server.join(); std::cerr << error.what() << '\n'; return 1;
    }
}
