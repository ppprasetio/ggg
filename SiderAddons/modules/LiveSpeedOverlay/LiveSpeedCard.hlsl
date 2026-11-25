// LiveSpeedCard.hlsl  -  native port of the live speed card from LiveSpeed.fx
// Only the code the Lua actually feeds is kept: card_box (kind 1 = player speed) + name_plate.
// It is drawn into a small viewport around the card (see LiveSpeedOverlay.cpp), NOT fullscreen.
// GR[] layout is unchanged (same floats livespeed.lua writes):
//   GR[0] = alpha, -, kit colour (r*65536+g*256+b), colour known 1/0
//   GR[1] = card anchor x, y, speed value, kind(1)
//   GR[2].x = card reveal   GR[7].x = card alpha
//   floats 64..67 = name glyph count, name width, shirt number, position glyph count
//   floats 68..87 = name glyphs, floats 116..119 = position glyphs, float 120 = position width

cbuffer CB : register(b0)
{
    float4 GR[32];
    float4 P0;   // x = width px, y = height px, z = 1/width, w = 1/height
    float4 P1;   // x = CardHeight, y = CardOpacity, z = layout 0..3, w = style 0..4
    float4 P2;   // xyz = Accent colour, w = use team colour as accent (1/0)
    float4 P3;   // x = 1 when the render target is sRGB (convert output), yzw unused
};

Texture2D FontTex  : register(t0);   // livespeed_font.png  (1024 x 1024)
Texture2D NamesTex : register(t1);   // livespeed_names.png (1024 x 768)
Texture2D SceneTex : register(t2);   // copy of the back buffer (only the card area is refreshed)
SamplerState LinSamp : register(s0); // linear, clamp

static const float CELL = 80.0 / 128.0;
static const float3 INK = float3(0.82, 0.84, 0.88);
static const float NCELL = 64.0 / 96.0;
static const float NCAP = 0.52, NBASE = 0.29;
static const float DCAP = 0.66, DBASE = 0.17;
static const float3 WHITE = float3(0.96, 0.97, 1.0);
static const float3 DARK = float3(0.05, 0.05, 0.06);
static const float NEED_TEXT = 4.5, NEED_ACCENT = 3.0;

float gr(int k) { return GR[k >> 2][k & 3]; }
float sm(float t) { t = saturate(t); return t * t * (3.0 - 2.0 * t); }

float lum(float3 c) { c = saturate(c); return dot(c * c, float3(0.2126, 0.7152, 0.0722)); }
float ratio(float a, float b) { return (max(a, b) + 0.05) / (min(a, b) + 0.05); }

float3 legible(float3 c, float3 bg, float need)
{
    float lb = lum(bg);
    if (ratio(lum(c), lb) >= need)
        return c;
    float3 to = ratio(lum(WHITE), lb) >= ratio(lum(DARK), lb) ? WHITE : DARK;
    float lo = 0.0, hi = 1.0;
    [unroll] for (int i = 0; i < 6; ++i)
    {
        float m = (lo + hi) * 0.5;
        if (ratio(lum(lerp(c, to, m)), lb) >= need) hi = m; else lo = m;
    }
    return lerp(c, to, hi);
}
float3 ink_for(float3 bg) { float lb = lum(bg); return ratio(lum(WHITE), lb) >= ratio(lum(DARK), lb) ? WHITE : DARK; }
float4 scrim(float4 bg, float3 scene, float3 ink, float need)
{
    float li = lum(ink);
    if (ratio(li, lum(lerp(scene, bg.rgb, bg.a))) >= need)
        return bg;
    if (ratio(li, lum(bg.rgb)) < need)
        return float4(bg.rgb, 1.0);
    float lo = bg.a, hi = 1.0;
    [unroll] for (int i = 0; i < 6; ++i)
    {
        float m = (lo + hi) * 0.5;
        if (ratio(li, lum(lerp(scene, bg.rgb, m))) >= need) hi = m; else lo = m;
    }
    return float4(bg.rgb, hi);
}

int style_id() { return (int)(P1.w + 0.5); }
float3 kit_colour()
{
    float c = GR[0].z;
    float r = floor(c / 65536.0), g = floor((c - r * 65536.0) / 256.0);
    return float3(r, g, c - r * 65536.0 - g * 256.0) / 255.0;
}
float3 accent() { return (P2.w > 0.5 && GR[0].w > 0.5) ? kit_colour() : P2.xyz; }
float3 speed_colour() { return GR[0].w > 0.5 ? kit_colour() : P2.xyz; }

float4 style_bg(float3 frost, float u)
{
    int st = style_id();
    if (st == 1)
        return float4(lerp(frost, float3(0.03, 0.035, 0.045), 0.5) + 0.03, P1.y);
    if (st == 2)
        return float4(0.0, 0.0, 0.0, P1.y * 0.6 * (1.0 - 0.85 * saturate(u)));
    if (st == 3)
        return float4(0.94, 0.95, 0.96, P1.y);
    if (st == 4)
        return float4(accent() * 0.92, P1.y);
    return float4(0.06, 0.065, 0.075, P1.y);
}
float3 style_txt() { int st = style_id(); return st == 3 ? float3(0.07, 0.08, 0.09) : (st == 4 ? ink_for(accent() * 0.92) : WHITE); }
float3 style_num() { return style_id() == 4 ? ink_for(accent() * 0.92) : accent(); }
float3 style_bar() { return style_id() == 4 ? ink_for(accent() * 0.92) : accent(); }

float4 box_bg(float2 q, float w, int lay, float3 frost)
{
    float4 bg = style_bg(frost, q.x / w);
    if (lay == 2)
        bg.a *= 0.75;
    else if (lay == 3)
        bg.a *= 0.45 * (1.0 - 0.7 * saturate(q.x / w));
    return scrim(bg, frost, style_txt(), NEED_TEXT);
}
float3 behind(float4 bg, float3 frost) { return lerp(frost, bg.rgb, bg.a); }

float4 box_deco(float2 q, float w, float h, int lay, float3 frost)
{
    if (lay == 4)
        return float4(0.0, 0.0, 0.0, 0.0);
    float4 bg = box_bg(q, w, lay, frost);
    if (lay == 0)
        return q.x < 0.045 ? float4(style_bar(), 1.0) : bg;
    if (lay == 1)
    {
        float b = 0.03;
        return (q.x < b || q.y < b || q.x > w - b || q.y > h - b) ? float4(style_bar(), 1.0) : bg;
    }
    if (lay == 2)
    {
        float arm = min(0.3, h * 0.35), t = 0.045;
        bool cx = q.x < arm || q.x > w - arm, cy = q.y < arm || q.y > h - arm;
        bool edge = ((q.x < t || q.x > w - t) && cy) || ((q.y < t || q.y > h - t) && cx);
        return edge ? float4(style_bar(), 1.0) : bg;
    }
    return q.y < 0.04 ? float4(style_bar(), 1.0) : bg;
}

float glyph(float2 q, int g)
{
    if (any(q < 0.0) || any(q > 1.0))
        return 0.0;
    return FontTex.SampleLevel(LinSamp, float2((g + q.x) * 80.0 / 1024.0, (1.0 - q.y) * 128.0 / 1024.0), 0).a;
}
float strip(float2 q, int row, float w)
{
    if (any(q < 0.0) || any(q > 1.0))
        return 0.0;
    return FontTex.SampleLevel(LinSamp, float2(q.x * w / 1024.0, (128.0 + 64.0 * row + (1.0 - q.y) * 64.0) / 1024.0), 0).a;
}
float put(float2 p, inout float x, float a, float h, int g)
{
    float w = CELL * h;
    float c = glyph(float2((p.x - x + (w - a) * 0.5) / w, p.y / h), g);
    x += a;
    return c;
}
float number(float2 p, float v, float h, int dec, bool deg, out float end)
{
    float adv = CELL * h * 0.82, adv_dot = CELL * h * 0.45, x = 0.0, c = 0.0;
    int scale = dec == 2 ? 100 : (dec == 1 ? 10 : 1);
    int n = (int)(clamp(v, 0.0, 999.0) * scale + 0.5);
    int whole = n / scale, frac1 = n % scale;
    int hund = (whole / 100) % 10, tens = (whole / 10) % 10, ones = whole % 10;
    if (hund > 0)
        c = max(c, put(p, x, adv, h, hund));
    if (hund > 0 || tens > 0)
        c = max(c, put(p, x, adv, h, tens));
    c = max(c, put(p, x, adv, h, ones));
    if (dec > 0)
    {
        c = max(c, put(p, x, adv_dot, h, 10));
        if (dec == 2)
            c = max(c, put(p, x, adv, h, (frac1 / 10) % 10));
        c = max(c, put(p, x, adv, h, frac1 % 10));
    }
    if (deg)
        c = max(c, put(p, x, adv * 0.6, h, 12));
    end = x;
    return c;
}

float name_text(float2 p, int k0, int n, float h)
{
    float2 q = p / h;
    if (q.y < 0.0 || q.y > 1.0 || q.x < -NCELL)
        return 0.0;
    float c = 0.0;
    [loop] for (int j = 0; j < n; ++j)
    {
        float f = gr(k0 + j);
        float g = floor(f / 65536.0);
        float u = (q.x - ((f - g * 65536.0) / 1000.0 - 1.0)) / NCELL;
        if (u >= 0.0 && u <= 1.0)
            c = max(c, NamesTex.SampleLevel(LinSamp, float2((g - floor(g / 16.0) * 16.0 + u) * 64.0 / 1024.0,
                                                          (floor(g / 16.0) + 1.0 - q.y) * 96.0 / 768.0), 0).a);
    }
    return c;
}

float line_width(float cap, int k, int kw)
{
    float hn = cap / NCAP, hd = cap / DCAP, num = gr(k + 2), x = 0.0;
    if (num > 0.5)
        x = (num >= 99.5 ? 3.0 : (num >= 9.5 ? 2.0 : 1.0)) * CELL * hd * 0.82 + cap * 0.45;
    x += gr(k + 1) * hn;
    if (gr(k + 3) > 0.5)
        x += cap * 0.6 + gr(kw) * hn;
    return x;
}
float3 player_line(float2 q, float cap, int k, int kp, int kw)
{
    float hn = cap / NCAP, hd = cap / DCAP, num = gr(k + 2), x = 0.0, end = 0.0;
    float3 c = float3(0.0, 0.0, 0.0);
    if (num > 0.5)
    {
        c.x = number(float2(q.x, q.y + DBASE * hd), num, hd, 0, false, end);
        x = end + cap * 0.45;
    }
    c.y = name_text(float2(q.x - x, q.y + NBASE * hn), k + 4, (int)(gr(k) + 0.5), hn);
    x += gr(k + 1) * hn + cap * 0.6;
    c.z = name_text(float2(q.x - x, q.y + NBASE * hn), kp, (int)(gr(k + 3) + 0.5), hn);
    return c;
}
bool has_player(int k) { return gr(k) > 0.5 || gr(k + 2) > 0.5; }

float4 name_plate(float2 p, float2 corner, float reveal, float H, float pw, float ph, float cap,
                  int k, int kp, int kw, float3 frost, int lay)
{
    float r = sm(reveal);
    corner.x -= (1.0 - r) * 2.4 * H * 0.12;
    float2 q = (p - corner) / H;
    if (q.x < 0.0 || q.y < 0.0 || q.x > pw || q.y > ph)
        return float4(0.0, 0.0, 0.0, 0.0);
    float cut = saturate((r * (pw + 0.3) - q.x) / 0.3);
    if (cut <= 0.0)
        return float4(0.0, 0.0, 0.0, 0.0);
    float4 box = lay == 1 ? float4(style_bar(), max(P1.y, 0.9)) : box_deco(q, pw, ph, lay, frost);
    float3 t = player_line(q - float2(lay == 1 ? 0.12 : 0.14, (ph - cap) * 0.5), cap, k, kp, kw);
    float3 back = behind(lay == 1 ? box : box_bg(q, pw, lay, frost), frost);
    float3 txt = lay == 1 ? ink_for(back) : legible(style_txt(), back, NEED_TEXT);
    float3 num = lay == 1 ? txt : legible(style_num(), back, NEED_ACCENT);
    float3 c = box.rgb;
    c = lerp(c, num, t.x);
    c = lerp(c, txt, t.y);
    c = lerp(c, num, t.z);
    return float4(c, max(box.a, max(t.x, max(t.y, t.z))) * cut);
}

// the speed card: panel in the carrier's kit colour, label PLAYER SPEED, value with one decimal, km/h
float4 card_box(float2 p, float2 corner, float value, float reveal, float H, float3 frost, float wcard, int lay)
{
    float W = H * wcard;
    float r = sm(reveal);
    corner.x -= (1.0 - r) * W * 0.12;
    float2 q = (p - corner) / H;
    float wq = W / H;
    if (q.x < 0.0 || q.y < 0.0 || q.x > wq || q.y > 1.0)
        return float4(0.0, 0.0, 0.0, 0.0);
    float cut = saturate((r * (wq + 0.3) - q.x) / 0.3);
    if (cut <= 0.0)
        return float4(0.0, 0.0, 0.0, 0.0);
    float4 box = box_deco(q, wq, 1.0, lay, frost);
    float lx = (lay == 1 || lay == 4) ? 0.12 : 0.14;
    float ly = lay == 2 ? 0.1 : 0.68, vy = lay == 2 ? 0.34 : 0.1;
    float lab = strip(float2((q.x - lx) / 1.6, (q.y - ly) / 0.2), 0, 512.0);
    float end;
    float num = number(float2(q.x - lx, q.y - vy), value, 0.54, 1, false, end);
    float un = strip(float2((q.x - lx - end - 0.06) / 0.8, (q.y - vy - 0.02) / 0.2), 1, 256.0);

    float3 kb = speed_colour() * 0.92;
    float3 ki = ink_for(kb);
    float4 kb_bg = scrim(float4(kb, P1.y), frost, ki, NEED_TEXT);
    box.rgb = kb_bg.rgb;
    box.a = max(box.a, kb_bg.a);
    float3 back = lerp(frost, kb_bg.rgb, kb_bg.a);
    float3 txtc = legible(ki, back, NEED_TEXT);

    float3 c = box.rgb;
    c = lerp(c, txtc, lab);
    c = lerp(c, txtc, num);
    c = lerp(c, txtc, un);
    return float4(c, max(box.a, max(lab, max(num, un))) * cut);
}

float2 on_screen(float2 corner, float W, float Ht, float aspect)
{
    float m = 0.03;
    return float2(clamp(corner.x, -aspect + m, aspect - W - m), clamp(corner.y, -1.0 + m, 1.0 - Ht - m));
}

float3 srgb_to_linear(float3 c)
{
    float3 lo = c / 12.92;
    float3 hi = pow((c + 0.055) / 1.055, 2.4);
    return lerp(hi, lo, step(c, float3(0.04045, 0.04045, 0.04045)));
}

float3 scene_at(float2 pix) { return SceneTex.SampleLevel(LinSamp, pix * P0.zw, 0).rgb; }

struct VSOut { float4 pos : SV_Position; };

VSOut VSMain(uint id : SV_VertexID)
{
    float2 t = float2((id << 1) & 2, id & 2);
    VSOut o;
    o.pos = float4(t * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    return o;
}

float4 PSMain(VSOut i) : SV_Target
{
    float2 pix = i.pos.xy;                       // pixel centre, same as uv * size in the .fx
    float2 uv = pix * P0.zw;
    float aspect = P0.x / P0.y;
    float2 p = float2((uv.x - 0.5) * 2.0 * aspect, (0.5 - uv.y) * 2.0);

    // the frosted scene behind the card: 16 taps, but only for pixels inside the card's viewport
    float3 frost = float3(0.0, 0.0, 0.0);
    [unroll] for (int k = 0; k < 8; ++k)
    {
        float an = k * 0.7853982;
        float2 d = float2(cos(an), sin(an));
        frost += scene_at(pix + d * 7.0) + scene_at(pix + d * 16.0);
    }
    frost /= 16.0;

    float H1 = P1.x * 2.0;
    bool named = has_player(64);
    float ph = 0.46, cap = 0.22, gap = 0.05;
    float pw = named ? max(2.4, line_width(cap, 64, 120) + 0.26) : 2.4;
    float ht = named ? 1.0 + gap + ph : 1.0;
    float2 at = on_screen(GR[1].xy + float2(0.0, -H1 * 0.5), pw * H1, ht * H1, aspect);
    int lay = (int)(P1.z + 0.5);

    float4 c = card_box(p, at, GR[1].z, GR[2].x, H1, frost, 2.4, lay);
    if (named && c.a <= 0.0)
        c = name_plate(p, at + float2(0.0, (1.0 + gap) * H1), GR[2].x, H1, pw, ph, cap, 64, 116, 120, frost, lay);

    float a = c.a * GR[7].x * GR[0].x;
    if (a <= 0.0)
        discard;
    float3 rgb = P3.x > 0.5 ? srgb_to_linear(c.rgb) : c.rgb;
    return float4(rgb, a);                       // blended onto the back buffer (SRC_ALPHA / INV_SRC_ALPHA)
}
