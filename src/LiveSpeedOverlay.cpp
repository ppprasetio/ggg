// LiveSpeedOverlay.cpp  (v2 - standalone, NO ReShade)
// livespeed_overlay.dll for SP Football Life 2027, same idea as goalreplay_overlay.dll:
//
//  * livespeed.lua (Sider) loads this DLL with ffi.load. The DLL hooks IDXGISwapChain::Present itself
//    (vtable patch through a dummy swap chain), so ReShade / LiveSpeed.fx are not needed any more.
//  * Exports livespeed_overlay_state / livespeed_overlay_capacity: the Lua writes its GR[] floats there
//    exactly like before. livespeed_status() tells the Lua how far the start-up got.
//  * Draws the card with D3D11 in ONE small viewport around the card (no fullscreen pass).
//    When no card is shown the hook returns immediately.
//  * Pixel shader = LiveSpeedCard.hlsl (compiled at start-up from the file next to this DLL).
//  * Textures = livespeed_font.png / livespeed_names.png (loaded with WIC).
//  * Settings = LiveSpeedOverlay.ini (reloaded automatically when saved).
//
// D3D11 only. Build: see README_BUILD.txt (no extra SDK needed, just mingw-w64 or Visual Studio).

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <wincodec.h>

#include <algorithm>
#include <cmath>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------------------------
// Shared state with livespeed.lua (layout must match the Lua cdef: uint32 seq; uint32 count; float v[128])
// ---------------------------------------------------------------------------------------------
struct LiveSpeedState
{
    uint32_t seq;
    uint32_t count;
    float v[128];
};

extern "C"
{
__declspec(dllexport) LiveSpeedState livespeed_overlay_state = {};
__declspec(dllexport) uint32_t livespeed_overlay_capacity = 128;
}

// ---------------------------------------------------------------------------------------------
// Small helpers: paths, log, settings
// ---------------------------------------------------------------------------------------------
static std::wstring g_dir;      // folder of this DLL (with trailing backslash)
static std::wstring g_exeDir;   // folder of the game exe

static std::wstring dir_of(const wchar_t *path)
{
    std::wstring s(path);
    size_t p = s.find_last_of(L"\\/");
    return p == std::wstring::npos ? std::wstring() : s.substr(0, p + 1);
}

static void dbg_log(const char *fmt, ...)
{
    static int count = 0;
    if (++count > 200)
        return;
    std::wstring path = g_dir + L"livespeed_overlay.log";
    FILE *f = nullptr;
    if (_wfopen_s(&f, path.c_str(), L"ab") != 0 || !f)
        return;
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    fprintf(f, "%s\r\n", buf);
    fclose(f);
}

static bool read_file(const std::wstring &path, std::string &out)
{
    FILE *f = nullptr;
    if (_wfopen_s(&f, path.c_str(), L"rb") != 0 || !f)
        return false;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    out.resize(n > 0 ? (size_t)n : 0);
    if (n > 0 && fread(&out[0], 1, (size_t)n, f) != (size_t)n)
    {
        fclose(f);
        return false;
    }
    fclose(f);
    return true;
}

struct Settings
{
    bool enabled = true;
    float cardHeight = 0.055f;   // part of the screen height (same as the .fx CardHeight)
    float cardOpacity = 0.82f;
    int layout = 0;              // 0 bars, 1 framed, 2 tiles, 3 minimal
    int style = 0;               // 0 solid dark, 1 glass, 2 clear, 3 light, 4 accent
    float accent[3] = {1.0f, 0.58f, 0.12f};
    bool teamAccent = true;      // use the carrier's kit colour as accent when known
};
static Settings g_set;
static FILETIME g_iniTime = {};
static ULONGLONG g_iniCheck = 0;

static void load_ini()
{
    std::wstring f = g_dir + L"LiveSpeedOverlay.ini";
    auto rf = [&](const wchar_t *key, float def) -> float
    {
        wchar_t b[64] = {};
        GetPrivateProfileStringW(L"LiveSpeed", key, L"", b, 64, f.c_str());
        return b[0] ? (float)_wtof(b) : def;
    };
    Settings s;
    s.enabled = rf(L"Enabled", 1.0f) != 0.0f;
    s.cardHeight = std::min(0.15f, std::max(0.02f, rf(L"CardHeight", 0.055f)));
    s.cardOpacity = std::min(1.0f, std::max(0.0f, rf(L"CardOpacity", 0.82f)));
    s.layout = std::min(3, std::max(0, (int)rf(L"Layout", 0.0f)));
    s.style = std::min(4, std::max(0, (int)rf(L"Style", 0.0f)));
    s.accent[0] = rf(L"AccentR", 1.0f);
    s.accent[1] = rf(L"AccentG", 0.58f);
    s.accent[2] = rf(L"AccentB", 0.12f);
    s.teamAccent = rf(L"TeamAccent", 1.0f) != 0.0f;
    g_set = s;
}

static void poll_ini()
{
    ULONGLONG now = GetTickCount64();
    if (now - g_iniCheck < 1000)
        return;
    g_iniCheck = now;
    WIN32_FILE_ATTRIBUTE_DATA d;
    std::wstring f = g_dir + L"LiveSpeedOverlay.ini";
    if (!GetFileAttributesExW(f.c_str(), GetFileExInfoStandard, &d))
        return;
    if (CompareFileTime(&d.ftLastWriteTime, &g_iniTime) != 0)
    {
        g_iniTime = d.ftLastWriteTime;
        load_ini();
        dbg_log("settings loaded: height %.3f opacity %.2f layout %d style %d", g_set.cardHeight, g_set.cardOpacity,
             g_set.layout, g_set.style);
    }
}

// ---------------------------------------------------------------------------------------------
// D3D11 resources
// ---------------------------------------------------------------------------------------------
template <class T> static void rel(T *&p)
{
    if (p)
    {
        p->Release();
        p = nullptr;
    }
}

struct alignas(16) CBData
{
    float GR[128];
    float P0[4];
    float P1[4];
    float P2[4];
    float P3[4];
};

struct Gfx
{
    ID3D11Device *dev = nullptr;   // identity only (not ref-counted here)
    ID3D11VertexShader *vs = nullptr;
    ID3D11PixelShader *ps = nullptr;
    ID3D11BlendState *bs = nullptr;
    ID3D11RasterizerState *rs = nullptr;
    ID3D11DepthStencilState *dss = nullptr;
    ID3D11SamplerState *samp = nullptr;
    ID3D11Buffer *cb = nullptr;
    ID3D11ShaderResourceView *fontSrv = nullptr;
    ID3D11ShaderResourceView *namesSrv = nullptr;
    ID3D11Texture2D *scene = nullptr;
    ID3D11ShaderResourceView *sceneSrv = nullptr;
    UINT sw = 0, sh = 0;
    DXGI_FORMAT sfmt = DXGI_FORMAT_UNKNOWN;
    bool ready = false;
    bool failed = false;
};
static Gfx g;

static void release_scene()
{
    rel(g.sceneSrv);
    rel(g.scene);
    g.sw = g.sh = 0;
    g.sfmt = DXGI_FORMAT_UNKNOWN;
}

static void release_all()
{
    release_scene();
    rel(g.fontSrv);
    rel(g.namesSrv);
    rel(g.cb);
    rel(g.samp);
    rel(g.dss);
    rel(g.rs);
    rel(g.bs);
    rel(g.ps);
    rel(g.vs);
    g.dev = nullptr;
    g.ready = false;
    g.failed = false;
}

// back buffer format -> (typeless format for the scene copy, UNORM view format, is sRGB)
static bool format_family(DXGI_FORMAT f, DXGI_FORMAT &typeless, DXGI_FORMAT &unorm, bool &srgb)
{
    srgb = false;
    switch (f)
    {
    case DXGI_FORMAT_R8G8B8A8_TYPELESS:
        typeless = f; unorm = DXGI_FORMAT_R8G8B8A8_UNORM; return true;
    case DXGI_FORMAT_R8G8B8A8_UNORM:
        typeless = DXGI_FORMAT_R8G8B8A8_TYPELESS; unorm = f; return true;
    case DXGI_FORMAT_R8G8B8A8_UNORM_SRGB:
        typeless = DXGI_FORMAT_R8G8B8A8_TYPELESS; unorm = DXGI_FORMAT_R8G8B8A8_UNORM; srgb = true; return true;
    case DXGI_FORMAT_B8G8R8A8_TYPELESS:
        typeless = f; unorm = DXGI_FORMAT_B8G8R8A8_UNORM; return true;
    case DXGI_FORMAT_B8G8R8A8_UNORM:
        typeless = DXGI_FORMAT_B8G8R8A8_TYPELESS; unorm = f; return true;
    case DXGI_FORMAT_B8G8R8A8_UNORM_SRGB:
        typeless = DXGI_FORMAT_B8G8R8A8_TYPELESS; unorm = DXGI_FORMAT_B8G8R8A8_UNORM; srgb = true; return true;
    case DXGI_FORMAT_R10G10B10A2_TYPELESS:
        typeless = f; unorm = DXGI_FORMAT_R10G10B10A2_UNORM; return true;
    case DXGI_FORMAT_R10G10B10A2_UNORM:
        typeless = DXGI_FORMAT_R10G10B10A2_TYPELESS; unorm = f; return true;
    case DXGI_FORMAT_R16G16B16A16_FLOAT:
        typeless = f; unorm = f; return true;
    default:
        return false;
    }
}

// PNG -> RGBA8 shader resource view through WIC (built into Windows, no extra library)
static bool load_png(ID3D11Device *dev, const std::wstring &path, ID3D11ShaderResourceView **out)
{
    HRESULT hrc = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    (void)hrc;   // S_OK, S_FALSE or RPC_E_CHANGED_MODE are all fine: COM is usable on this thread

    IWICImagingFactory *fac = nullptr;
    IWICBitmapDecoder *dec = nullptr;
    IWICBitmapFrameDecode *frame = nullptr;
    IWICFormatConverter *conv = nullptr;
    bool ok = false;
    UINT w = 0, h = 0;
    std::vector<uint8_t> px;

    HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, __uuidof(IWICImagingFactory),
                                  (void **)&fac);
    if (SUCCEEDED(hr))
        hr = fac->CreateDecoderFromFilename(path.c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnDemand, &dec);
    if (SUCCEEDED(hr))
        hr = dec->GetFrame(0, &frame);
    if (SUCCEEDED(hr))
        hr = fac->CreateFormatConverter(&conv);
    if (SUCCEEDED(hr))
        hr = conv->Initialize(frame, GUID_WICPixelFormat32bppRGBA, WICBitmapDitherTypeNone, nullptr, 0.0,
                              WICBitmapPaletteTypeCustom);
    if (SUCCEEDED(hr))
        hr = conv->GetSize(&w, &h);
    if (SUCCEEDED(hr) && w > 0 && h > 0)
    {
        px.resize((size_t)w * h * 4);
        hr = conv->CopyPixels(nullptr, w * 4, (UINT)px.size(), px.data());
        if (SUCCEEDED(hr))
        {
            D3D11_TEXTURE2D_DESC td = {};
            td.Width = w;
            td.Height = h;
            td.MipLevels = 1;
            td.ArraySize = 1;
            td.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
            td.SampleDesc.Count = 1;
            td.Usage = D3D11_USAGE_IMMUTABLE;
            td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
            D3D11_SUBRESOURCE_DATA sd = {};
            sd.pSysMem = px.data();
            sd.SysMemPitch = w * 4;
            ID3D11Texture2D *tex = nullptr;
            hr = dev->CreateTexture2D(&td, &sd, &tex);
            if (SUCCEEDED(hr))
            {
                hr = dev->CreateShaderResourceView(tex, nullptr, out);
                ok = SUCCEEDED(hr);
                tex->Release();
            }
        }
    }
    if (!ok)
        dbg_log("PNG load failed (%ls) hr=0x%08lX", path.c_str(), (unsigned long)hr);
    rel(conv);
    rel(frame);
    rel(dec);
    rel(fac);
    return ok;
}

static std::wstring find_file(const wchar_t *name, bool texture)
{
    std::wstring cand[4];
    int n = 0;
    if (texture)
    {
        cand[n++] = g_dir + L"Textures\\" + name;
        cand[n++] = g_exeDir + L"reshade-shaders\\Textures\\" + name;
    }
    cand[n++] = g_dir + name;
    cand[n++] = g_exeDir + name;
    for (int i = 0; i < n; ++i)
        if (GetFileAttributesW(cand[i].c_str()) != INVALID_FILE_ATTRIBUTES)
            return cand[i];
    return std::wstring();
}

typedef HRESULT(WINAPI *PFN_D3DCOMPILE_)(LPCVOID, SIZE_T, LPCSTR, const D3D_SHADER_MACRO *, ID3DInclude *, LPCSTR, LPCSTR,
                                         UINT, UINT, ID3DBlob **, ID3DBlob **);

static bool compile(PFN_D3DCOMPILE_ fn, const std::string &src, const char *entry, const char *target, ID3DBlob **out)
{
    ID3DBlob *err = nullptr;
    HRESULT hr = fn(src.data(), src.size(), "LiveSpeedCard.hlsl", nullptr, nullptr, entry, target,
                    0x8000 /*OPTIMIZATION_LEVEL3*/, 0, out, &err);
    if (FAILED(hr))
    {
        dbg_log("HLSL %s failed hr=0x%08lX: %s", entry, (unsigned long)hr,
             err ? (const char *)err->GetBufferPointer() : "(no message)");
        rel(err);
        return false;
    }
    rel(err);
    return true;
}

static bool init_gfx(ID3D11Device *dev)
{
    // --- shaders
    std::wstring hp = find_file(L"LiveSpeedCard.hlsl", false);
    if (hp.empty())
    {
        dbg_log("LiveSpeedCard.hlsl not found next to the DLL");
        return false;
    }
    std::string src;
    if (!read_file(hp, src) || src.empty())
    {
        dbg_log("cannot read %ls", hp.c_str());
        return false;
    }
    HMODULE comp = LoadLibraryW(L"d3dcompiler_47.dll");
    PFN_D3DCOMPILE_ fn = comp ? (PFN_D3DCOMPILE_)GetProcAddress(comp, "D3DCompile") : nullptr;
    if (!fn)
    {
        dbg_log("d3dcompiler_47.dll not available");
        return false;
    }
    ID3DBlob *vsb = nullptr, *psb = nullptr;
    bool ok = compile(fn, src, "VSMain", "vs_5_0", &vsb) && compile(fn, src, "PSMain", "ps_5_0", &psb);
    if (ok)
    {
        ok = SUCCEEDED(dev->CreateVertexShader(vsb->GetBufferPointer(), vsb->GetBufferSize(), nullptr, &g.vs)) &&
             SUCCEEDED(dev->CreatePixelShader(psb->GetBufferPointer(), psb->GetBufferSize(), nullptr, &g.ps));
        if (!ok)
            dbg_log("CreateVertexShader / CreatePixelShader failed");
    }
    rel(vsb);
    rel(psb);
    if (!ok)
        return false;

    // --- fixed state
    D3D11_BLEND_DESC bd = {};
    bd.RenderTarget[0].BlendEnable = TRUE;
    bd.RenderTarget[0].SrcBlend = D3D11_BLEND_SRC_ALPHA;
    bd.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
    bd.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
    bd.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ZERO;
    bd.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_ONE;
    bd.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
    bd.RenderTarget[0].RenderTargetWriteMask =
        D3D11_COLOR_WRITE_ENABLE_RED | D3D11_COLOR_WRITE_ENABLE_GREEN | D3D11_COLOR_WRITE_ENABLE_BLUE;
    D3D11_RASTERIZER_DESC rd = {};
    rd.FillMode = D3D11_FILL_SOLID;
    rd.CullMode = D3D11_CULL_NONE;
    rd.DepthClipEnable = FALSE;
    D3D11_DEPTH_STENCIL_DESC dd = {};   // depth and stencil off
    D3D11_SAMPLER_DESC sd = {};
    sd.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    sd.AddressU = sd.AddressV = sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.MaxLOD = D3D11_FLOAT32_MAX;
    D3D11_BUFFER_DESC cbd = {};
    cbd.ByteWidth = (UINT)sizeof(CBData);
    cbd.Usage = D3D11_USAGE_DYNAMIC;
    cbd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    cbd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    if (FAILED(dev->CreateBlendState(&bd, &g.bs)) || FAILED(dev->CreateRasterizerState(&rd, &g.rs)) ||
        FAILED(dev->CreateDepthStencilState(&dd, &g.dss)) || FAILED(dev->CreateSamplerState(&sd, &g.samp)) ||
        FAILED(dev->CreateBuffer(&cbd, nullptr, &g.cb)))
    {
        dbg_log("creating fixed pipeline state failed");
        return false;
    }

    // --- textures
    std::wstring fp = find_file(L"livespeed_font.png", true);
    std::wstring np = find_file(L"livespeed_names.png", true);
    if (fp.empty() || np.empty())
    {
        dbg_log("livespeed_font.png / livespeed_names.png not found (looked in Textures\\ next to the DLL)");
        return false;
    }
    if (!load_png(dev, fp, &g.fontSrv) || !load_png(dev, np, &g.namesSrv))
        return false;

    dbg_log("ready: shader %ls, textures %ls + %ls", hp.c_str(), fp.c_str(), np.c_str());
    return true;
}

// the scene copy has the back buffer's size so pixel coordinates map 1:1
static bool ensure_scene(ID3D11Device *dev, UINT w, UINT h, DXGI_FORMAT typeless, DXGI_FORMAT unorm)
{
    if (g.scene && g.sw == w && g.sh == h && g.sfmt == typeless)
        return true;
    release_scene();
    D3D11_TEXTURE2D_DESC td = {};
    td.Width = w;
    td.Height = h;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = typeless;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    if (FAILED(dev->CreateTexture2D(&td, nullptr, &g.scene)))
    {
        dbg_log("scene texture failed (%ux%u fmt %d)", w, h, (int)typeless);
        return false;
    }
    D3D11_SHADER_RESOURCE_VIEW_DESC vd = {};
    vd.Format = unorm;
    vd.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
    vd.Texture2D.MipLevels = 1;
    if (FAILED(dev->CreateShaderResourceView(g.scene, &vd, &g.sceneSrv)))
    {
        dbg_log("scene SRV failed");
        release_scene();
        return false;
    }
    g.sw = w;
    g.sh = h;
    g.sfmt = typeless;
    return true;
}

// ---------------------------------------------------------------------------------------------
// Card geometry on the CPU (same maths as the shader; only used to find the small area to draw)
// ---------------------------------------------------------------------------------------------
static const float CELL = 80.0f / 128.0f;
static const float NCAP = 0.52f, DCAP = 0.66f;

static float line_width(const float *v, float cap)
{
    float hn = cap / NCAP, hd = cap / DCAP, num = v[66], x = 0.0f;
    if (num > 0.5f)
        x = (num >= 99.5f ? 3.0f : (num >= 9.5f ? 2.0f : 1.0f)) * CELL * hd * 0.82f + cap * 0.45f;
    x += v[65] * hn;
    if (v[67] > 0.5f)
        x += cap * 0.6f + v[120] * hn;
    return x;
}

// ---------------------------------------------------------------------------------------------
// Status for the Lua: 0 starting, 1 Present hooked, 2 shaders+textures ready (card can draw),
//                     -1 hook failed, -2 graphics init failed (see livespeed_overlay.log)
// ---------------------------------------------------------------------------------------------
static volatile LONG g_status = 0;
extern "C" __declspec(dllexport) int livespeed_status(void)
{
    return (int)g_status;
}

// tiny COM smart pointer
template <class T> struct Ref
{
    T *p = nullptr;
    ~Ref() { if (p) p->Release(); }
    T **operator&() { return &p; }
    T *operator->() const { return p; }
    operator T *() const { return p; }
};

// ---------------------------------------------------------------------------------------------
// The draw, called from inside Present (before the real Present)
// ---------------------------------------------------------------------------------------------
static void draw_overlay(IDXGISwapChain *sc)
{
    poll_ini();
    if (!g_set.enabled || g.failed)
        return;

    float v[128];
    memcpy(v, livespeed_overlay_state.v, sizeof(v));
    const bool visible = v[0] > 0.0f && v[7] > 0.0f && v[28] > 0.0f;
    if (g.ready && !visible)
        return;   // the common case: nothing to draw, nothing to do

    Ref<ID3D11Device> dev;
    if (FAILED(sc->GetDevice(__uuidof(ID3D11Device), (void **)&dev)) || !dev)
        return;   // some other (non D3D11) swap chain of this process: ignore it

    if (g.dev != (ID3D11Device *)dev)
    {
        release_all();
        g.dev = dev;
    }
    if (!g.ready)
    {
        // compile + load once, on the first Present after start-up, so the first card does not hitch
        if (!init_gfx(dev))
        {
            g.failed = true;
            InterlockedExchange(&g_status, -2);
            return;
        }
        g.ready = true;
        InterlockedExchange(&g_status, 2);
        if (!visible)
            return;
    }

    Ref<ID3D11Texture2D> bb;
    if (FAILED(sc->GetBuffer(0, __uuidof(ID3D11Texture2D), (void **)&bb)) || !bb)
        return;
    D3D11_TEXTURE2D_DESC bdsc;
    bb->GetDesc(&bdsc);
    if (bdsc.Width < 640 || bdsc.Height < 360)
        return;   // not the game's main swap chain
    DXGI_FORMAT typeless, unorm;
    bool srgb;
    if (bdsc.SampleDesc.Count != 1 || !format_family(bdsc.Format, typeless, unorm, srgb))
    {
        dbg_log("unsupported back buffer (format %d, samples %u)", (int)bdsc.Format, bdsc.SampleDesc.Count);
        g.failed = true;
        return;
    }
    const float W = (float)bdsc.Width, Hh = (float)bdsc.Height;

    // --- where is the card? (pixels)
    const float aspect = W / Hh;
    const float H1 = g_set.cardHeight * 2.0f;
    const bool named = v[64] > 0.5f || v[66] > 0.5f;
    const float ph = 0.46f, cap = 0.22f, gap = 0.05f, m = 0.03f;
    const float pw = named ? std::max(2.4f, line_width(v, cap) + 0.26f) : 2.4f;
    const float ht = named ? 1.0f + gap + ph : 1.0f;
    float ax = v[4], ay = v[5] - H1 * 0.5f;
    const float bw = pw * H1, bh = ht * H1;
    ax = std::min(std::max(ax, -aspect + m), aspect - bw - m);
    ay = std::min(std::max(ay, -1.0f + m), 1.0f - bh - m);
    const float padPx = 3.0f;
    const float left = (ax / (2.0f * aspect) + 0.5f) * W - padPx;
    const float right = ((ax + bw) / (2.0f * aspect) + 0.5f) * W + padPx;
    const float top = (0.5f - (ay + bh) * 0.5f) * Hh - padPx;
    const float bottom = (0.5f - ay * 0.5f) * Hh + padPx;
    const int x0 = std::max(0, (int)std::floor(left)), x1 = std::min((int)bdsc.Width, (int)std::ceil(right));
    const int y0 = std::max(0, (int)std::floor(top)), y1 = std::min((int)bdsc.Height, (int)std::ceil(bottom));
    if (x1 <= x0 || y1 <= y0)
        return;

    if (!ensure_scene(dev, bdsc.Width, bdsc.Height, typeless, unorm))
    {
        g.failed = true;
        return;
    }

    Ref<ID3D11DeviceContext> ctx;
    dev->GetImmediateContext(&ctx);
    if (!ctx)
        return;

    // render target view: created per frame and released at the end (a cached view would keep the back
    // buffer alive and make ResizeBuffers fail)
    Ref<ID3D11RenderTargetView> rtv;
    bool srgbOut = false;
    {
        D3D11_RENDER_TARGET_VIEW_DESC rvd = {};
        rvd.Format = unorm;
        rvd.ViewDimension = D3D11_RTV_DIMENSION_TEXTURE2D;
        if (FAILED(dev->CreateRenderTargetView(bb, &rvd, &rtv)))
        {
            rtv.p = nullptr;
            if (FAILED(dev->CreateRenderTargetView(bb, nullptr, &rtv)))
            {
                dbg_log("CreateRenderTargetView failed");
                g.failed = true;
                return;
            }
            srgbOut = srgb;
        }
    }

    // scene copy: the card area plus the 16 px the frost blur reaches
    {
        const int pad = 20;
        D3D11_BOX box;
        box.left = (UINT)std::max(0, x0 - pad);
        box.top = (UINT)std::max(0, y0 - pad);
        box.right = (UINT)std::min((int)bdsc.Width, x1 + pad);
        box.bottom = (UINT)std::min((int)bdsc.Height, y1 + pad);
        box.front = 0;
        box.back = 1;
        ctx->CopySubresourceRegion(g.scene, 0, box.left, box.top, 0, bb, 0, &box);
    }

    // constants
    CBData cbd;
    memcpy(cbd.GR, v, sizeof(v));
    cbd.P0[0] = W; cbd.P0[1] = Hh; cbd.P0[2] = 1.0f / W; cbd.P0[3] = 1.0f / Hh;
    cbd.P1[0] = g_set.cardHeight; cbd.P1[1] = g_set.cardOpacity; cbd.P1[2] = (float)g_set.layout; cbd.P1[3] = (float)g_set.style;
    cbd.P2[0] = g_set.accent[0]; cbd.P2[1] = g_set.accent[1]; cbd.P2[2] = g_set.accent[2]; cbd.P2[3] = g_set.teamAccent ? 1.0f : 0.0f;
    cbd.P3[0] = srgbOut ? 1.0f : 0.0f; cbd.P3[1] = cbd.P3[2] = cbd.P3[3] = 0.0f;
    D3D11_MAPPED_SUBRESOURCE mp;
    if (SUCCEEDED(ctx->Map(g.cb, 0, D3D11_MAP_WRITE_DISCARD, 0, &mp)))
    {
        memcpy(mp.pData, &cbd, sizeof(cbd));
        ctx->Unmap(g.cb, 0);
    }

    // --- save the game's state (only what we touch)
    ID3D11RenderTargetView *oldRtv[D3D11_SIMULTANEOUS_RENDER_TARGET_COUNT] = {};
    ID3D11DepthStencilView *oldDsv = nullptr;
    ctx->OMGetRenderTargets(D3D11_SIMULTANEOUS_RENDER_TARGET_COUNT, oldRtv, &oldDsv);
    ID3D11BlendState *oldBs = nullptr;
    FLOAT oldBf[4];
    UINT oldSm = 0;
    ctx->OMGetBlendState(&oldBs, oldBf, &oldSm);
    ID3D11DepthStencilState *oldDss = nullptr;
    UINT oldRef = 0;
    ctx->OMGetDepthStencilState(&oldDss, &oldRef);
    ID3D11RasterizerState *oldRs = nullptr;
    ctx->RSGetState(&oldRs);
    UINT nvp = D3D11_VIEWPORT_AND_SCISSORRECT_OBJECT_COUNT_PER_PIPELINE;
    D3D11_VIEWPORT oldVp[D3D11_VIEWPORT_AND_SCISSORRECT_OBJECT_COUNT_PER_PIPELINE];
    ctx->RSGetViewports(&nvp, oldVp);
    ID3D11VertexShader *oldVs = nullptr;
    ID3D11PixelShader *oldPs = nullptr;
    ID3D11GeometryShader *oldGs = nullptr;
    ID3D11HullShader *oldHs = nullptr;
    ID3D11DomainShader *oldDs = nullptr;
    ctx->VSGetShader(&oldVs, nullptr, nullptr);
    ctx->PSGetShader(&oldPs, nullptr, nullptr);
    ctx->GSGetShader(&oldGs);
    ctx->HSGetShader(&oldHs, nullptr, nullptr);
    ctx->DSGetShader(&oldDs, nullptr, nullptr);
    ID3D11InputLayout *oldIl = nullptr;
    D3D11_PRIMITIVE_TOPOLOGY oldTopo;
    ctx->IAGetInputLayout(&oldIl);
    ctx->IAGetPrimitiveTopology(&oldTopo);
    ID3D11Buffer *oldCb = nullptr;
    ID3D11ShaderResourceView *oldSrv[3] = {};
    ID3D11SamplerState *oldSamp = nullptr;
    ctx->PSGetConstantBuffers(0, 1, &oldCb);
    ctx->PSGetShaderResources(0, 3, oldSrv);
    ctx->PSGetSamplers(0, 1, &oldSamp);

    // --- draw: one triangle that covers only the card's viewport
    D3D11_VIEWPORT vp = {(FLOAT)x0, (FLOAT)y0, (FLOAT)(x1 - x0), (FLOAT)(y1 - y0), 0.0f, 1.0f};
    const FLOAT zero[4] = {0, 0, 0, 0};
    ID3D11ShaderResourceView *srvs[3] = {g.fontSrv, g.namesSrv, g.sceneSrv};
    ID3D11RenderTargetView *rt = rtv;
    ctx->OMSetRenderTargets(1, &rt, nullptr);
    ctx->OMSetBlendState(g.bs, zero, 0xFFFFFFFF);
    ctx->OMSetDepthStencilState(g.dss, 0);
    ctx->RSSetState(g.rs);
    ctx->RSSetViewports(1, &vp);
    ctx->IASetInputLayout(nullptr);
    ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ctx->VSSetShader(g.vs, nullptr, 0);
    ctx->GSSetShader(nullptr, nullptr, 0);
    ctx->HSSetShader(nullptr, nullptr, 0);
    ctx->DSSetShader(nullptr, nullptr, 0);
    ctx->PSSetShader(g.ps, nullptr, 0);
    ctx->PSSetConstantBuffers(0, 1, &g.cb);
    ctx->PSSetShaderResources(0, 3, srvs);
    ctx->PSSetSamplers(0, 1, &g.samp);
    ctx->Draw(3, 0);

    // --- restore
    ctx->PSSetSamplers(0, 1, &oldSamp);
    ctx->PSSetShaderResources(0, 3, oldSrv);
    ctx->PSSetConstantBuffers(0, 1, &oldCb);
    ctx->IASetPrimitiveTopology(oldTopo);
    ctx->IASetInputLayout(oldIl);
    ctx->DSSetShader(oldDs, nullptr, 0);
    ctx->HSSetShader(oldHs, nullptr, 0);
    ctx->GSSetShader(oldGs, nullptr, 0);
    ctx->PSSetShader(oldPs, nullptr, 0);
    ctx->VSSetShader(oldVs, nullptr, 0);
    ctx->RSSetViewports(nvp, oldVp);
    ctx->RSSetState(oldRs);
    ctx->OMSetDepthStencilState(oldDss, oldRef);
    ctx->OMSetBlendState(oldBs, oldBf, oldSm);
    ctx->OMSetRenderTargets(D3D11_SIMULTANEOUS_RENDER_TARGET_COUNT, oldRtv, oldDsv);

    rel(oldSamp);
    for (auto &s : oldSrv)
        rel(s);
    rel(oldCb);
    rel(oldIl);
    rel(oldDs);
    rel(oldHs);
    rel(oldGs);
    rel(oldPs);
    rel(oldVs);
    rel(oldRs);
    rel(oldDss);
    rel(oldBs);
    for (auto &r : oldRtv)
        rel(r);
    rel(oldDsv);
}

// ---------------------------------------------------------------------------------------------
// Present hook (vtable patch). IDXGISwapChain: Present = slot 8. IDXGISwapChain1: Present1 = slot 22.
// ---------------------------------------------------------------------------------------------
typedef HRESULT(STDMETHODCALLTYPE *PresentFn)(IDXGISwapChain *, UINT, UINT);
typedef HRESULT(STDMETHODCALLTYPE *Present1Fn)(IDXGISwapChain1 *, UINT, UINT, const DXGI_PRESENT_PARAMETERS *);

static PresentFn g_origPresent = nullptr;
static Present1Fn g_origPresent1 = nullptr;
static void **g_vt = nullptr;
static bool g_busy = false;   // draw once per frame even if Present1 calls Present

static HRESULT STDMETHODCALLTYPE hk_present(IDXGISwapChain *sc, UINT sync, UINT flags)
{
    if (!g_busy)
    {
        g_busy = true;
        draw_overlay(sc);
        g_busy = false;
    }
    return g_origPresent(sc, sync, flags);
}

static HRESULT STDMETHODCALLTYPE hk_present1(IDXGISwapChain1 *sc, UINT sync, UINT flags, const DXGI_PRESENT_PARAMETERS *pp)
{
    if (!g_busy)
    {
        g_busy = true;
        draw_overlay(sc);
        g_busy = false;
    }
    return g_origPresent1(sc, sync, flags, pp);
}

// swaps vtable slot `slot` for fn, returns the old pointer (nullptr on failure)
static void *patch_slot(void **slot, void *fn)
{
    DWORD old = 0;
    if (!VirtualProtect(slot, sizeof(void *), PAGE_READWRITE, &old))
        return nullptr;
    void *prev = InterlockedExchangePointer(slot, fn);
    VirtualProtect(slot, sizeof(void *), old, &old);
    return prev;
}

static std::string module_of(void *addr)
{
    HMODULE mod = nullptr;
    char path[MAX_PATH] = {};
    if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           (LPCSTR)addr, &mod) &&
        GetModuleFileNameA(mod, path, MAX_PATH))
        return path;
    return "?";
}

static HMODULE g_hMod = nullptr;

static DWORD WINAPI hook_thread(LPVOID)
{
    typedef HRESULT(WINAPI * CreateFn)(IDXGIAdapter *, D3D_DRIVER_TYPE, HMODULE, UINT, const D3D_FEATURE_LEVEL *, UINT, UINT,
                                       const DXGI_SWAP_CHAIN_DESC *, IDXGISwapChain **, ID3D11Device **,
                                       D3D_FEATURE_LEVEL *, ID3D11DeviceContext **);
    HMODULE d3d = LoadLibraryW(L"d3d11.dll");
    CreateFn create = d3d ? (CreateFn)GetProcAddress(d3d, "D3D11CreateDeviceAndSwapChain") : nullptr;
    if (!create)
    {
        dbg_log("ERROR: d3d11.dll / D3D11CreateDeviceAndSwapChain not available");
        InterlockedExchange(&g_status, -1);
        return 0;
    }

    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = DefWindowProcW;
    wc.hInstance = g_hMod;
    wc.lpszClassName = L"LiveSpeedDummyWnd";
    RegisterClassExW(&wc);
    HWND hw = CreateWindowExW(0, wc.lpszClassName, L"", WS_OVERLAPPED, 0, 0, 16, 16, nullptr, nullptr, g_hMod, nullptr);

    DXGI_SWAP_CHAIN_DESC sd = {};
    sd.BufferCount = 1;
    sd.BufferDesc.Width = 16;
    sd.BufferDesc.Height = 16;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hw;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    IDXGISwapChain *sc = nullptr;
    ID3D11Device *dev = nullptr;
    ID3D11DeviceContext *ctx = nullptr;
    HRESULT hr = hw ? create(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, nullptr, 0, D3D11_SDK_VERSION, &sd, &sc, &dev,
                             nullptr, &ctx)
                    : E_FAIL;
    if (FAILED(hr))
        hr = hw ? create(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, 0, nullptr, 0, D3D11_SDK_VERSION, &sd, &sc, &dev, nullptr,
                         &ctx)
                : E_FAIL;
    if (FAILED(hr) || !sc)
    {
        dbg_log("ERROR: dummy swapchain 0x%08lX", (unsigned long)hr);
        InterlockedExchange(&g_status, -1);
    }
    else
    {
        void **vt = *reinterpret_cast<void ***>(sc);
        dbg_log("swapchain vtable at %p, Present lives in %s", (void *)vt, module_of(vt[8]).c_str());
        void *prev = patch_slot(&vt[8], (void *)&hk_present);
        if (prev)
        {
            g_origPresent = (PresentFn)prev;
            g_vt = vt;
            dbg_log("Present hook installed");
            InterlockedExchange(&g_status, 1);
        }
        else
        {
            dbg_log("ERROR: Present hook failed");
            InterlockedExchange(&g_status, -1);
        }
        IDXGISwapChain1 *sc1 = nullptr;
        if (prev && SUCCEEDED(sc->QueryInterface(__uuidof(IDXGISwapChain1), (void **)&sc1)) && sc1)
        {
            void **vt1 = *reinterpret_cast<void ***>(sc1);
            void *prev1 = patch_slot(&vt1[22], (void *)&hk_present1);
            if (prev1)
            {
                g_origPresent1 = (Present1Fn)prev1;
                dbg_log("Present1 hooked too");
            }
            else
                dbg_log("note: Present1 not hooked");
            sc1->Release();
        }
    }
    if (ctx) ctx->Release();
    if (dev) dev->Release();
    if (sc) sc->Release();
    if (hw) DestroyWindow(hw);
    UnregisterClassW(L"LiveSpeedDummyWnd", g_hMod);
    return 0;
}

// ---------------------------------------------------------------------------------------------
// DLL entry (only starts a thread: no D3D / window work under the loader lock)
// ---------------------------------------------------------------------------------------------
BOOL APIENTRY DllMain(HMODULE hModule, DWORD reason, LPVOID reserved)
{
    switch (reason)
    {
    case DLL_PROCESS_ATTACH:
    {
        DisableThreadLibraryCalls(hModule);
        g_hMod = hModule;
        wchar_t buf[MAX_PATH * 2] = {};
        GetModuleFileNameW(hModule, buf, MAX_PATH * 2);
        g_dir = dir_of(buf);
        GetModuleFileNameW(nullptr, buf, MAX_PATH * 2);
        g_exeDir = dir_of(buf);
        {   // fresh log each start
            FILE *f = nullptr;
            if (_wfopen_s(&f, (g_dir + L"livespeed_overlay.log").c_str(), L"wb") == 0 && f)
                fclose(f);
        }
        load_ini();
        dbg_log("---- livespeed_overlay.dll start, dir=%ls ----", g_dir.c_str());
        HANDLE t = CreateThread(nullptr, 0, hook_thread, nullptr, 0, nullptr);
        if (t)
            CloseHandle(t);
        break;
    }
    case DLL_PROCESS_DETACH:
        if (!reserved && g_vt && g_vt[8] == (void *)&hk_present && g_origPresent)
            patch_slot(&g_vt[8], (void *)g_origPresent);
        break;
    }
    return TRUE;
}
