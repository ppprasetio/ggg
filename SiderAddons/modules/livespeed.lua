-- livespeed.lua - standalone LIVE player-speed card for SP Football Life 2027.
-- No dependency on Goal_Replay, handball.lua, offside.lua or any other module.
-- Reads the live player table and live ball directly, projects the card with the
-- game's camera, and writes GR[] into livespeed_overlay.dll (standalone, hooks Present
-- itself, no ReShade needed; the old speedcard_overlay.addon64 + LiveSpeed.fx still work).
--
-- FL27 offsets (from base 0x140000000):
--   players = [base + 0x36F3FC0][0..21] -> +0x7E8 -> +8 -> capsule[6] +0x3C/40/44
--   ball    = [[base + 0x36F3DC8] + 0x40] +0x2954/+0x2958/+0x295c
--   camera  = base + 0x37F4A40 (+0 look-at, +0xc eye, +0x18 up, +0x30 fov)

local m = { version = "1.5.0-dll" }
local ctx_global = nil

-- Only two gates: the carrier must be inside his team's ATTACK zone, and the
-- live direction must be valid. No speed / crowd / headcount gate at all.
local S = {
    RVA_PLAYERS    = 0x36F3FC0,
    RVA_MATCH      = 0x36F3DC8,
    RVA_CAMERA     = 0x37F4A40,

    NEAR_BALL      = 1.8,    -- m: a NEW player must be this close to take the ball
    KEEP_BALL      = 2.5,    -- m: current carrier kept only while the ball is NOT moving
    SWITCH_MARGIN  = 0.4,    -- m: a newcomer must be this much closer to steal the carrier
    CARRIER_GRACE  = 0.55,   -- s: bridge FL27's bursty ball reads without killing the card
    BALL_MAX_Y     = 1.5,    -- m: a lofted pass has no carrier
    FADE           = 0.25,   -- s: card fade-in
    CARD_Y         = 1.75,   -- m above the player's hips (his head)
    POS_SMOOTH     = 0.35,   -- card anchor smoothing (0..1 per frame)
    SPEED_SMOOTH   = 0.06,   -- displayed number smoothing (0..1 per frame)
    MAX_SPEED_KMH  = 45.0,   -- sanity cap: FL27 bursty positions faked 80 km/h

    ATTACK_DIST    = 50.0,   -- m: carrier must be this close to the goal his team attacks
    ZONE_SLACK     = 5.0,    -- m: extra radius ONLY while visible (no flicker at the edge)
    GOAL_X         = 52.5,   -- m: goal line
    HOLD_GRACE     = 0.8,    -- s: bridge a brief zone dip caused by bursty position updates
    LOST_GRACE     = 0.6,    -- s: but hide when carrier / direction is really gone
}

local X = {
    base = 0x140000000,
    state_tried = -100,
    cap = 128,
    shown = false,
    state_warn_t = 0,
    name_t = 0,
    names_sig = nil,
    names_pending = nil,
    names_pending_t = 0,
    names_retry_t = 0,
    colors_loaded = false,

    locked_dir = nil,     -- +1/-1: home ATTACKS this end this period
    dead_on = false,      -- foul / out-of-play / restart pending: no speed card
    dead_t = 0,
    match_over = false,   -- latched at the full-time whistle: never show again
    match_over_t = 0,     -- when the latch was set (guards an early set_teams)
    break_on = false,     -- half-time whistle: hidden until the second-half kick-off
    break_t = 0,
    pause_on = false,     -- in-game pause menu: no card while the match is frozen
    break_period = nil,   -- period seen at the whistle (FL27 flips it BEFORE tu_half loads)
    oop = nil,            -- last out-of-play reason (3 goal, 4 ball out, 5 foul)
    dir_key = nil,        -- match registry: reset direction on a new match
    period = nil,         -- Sider match.stats().period: 1 first half, 2 second half
    base_dir = nil,       -- home ATTACK direction in the FIRST half
    dir_src = "default",  -- default only; keeper/depth are diagnostic
    dir_depth = 0,        -- diagnostic only: live deepest-player gap (m)
    dir_candidate = nil,  -- weak first reading waiting 0.15 s
    dir_candidate_t = 0,
    gate_t = 0,
    dbg_t = 0,

    prev_pos = {},
    prev_t = nil,
    carrier = nil,
    carrier_t = 0,
    carrier_src = "?",  -- "engine" (+0x2910) / "nearest" fallback
    pos_t = {},           -- per-player time of the LAST REAL position update
    speeds = {},          -- per-player km/h, valid immediately on a carrier swap

    show_t0 = nil,
    show_i = nil,
    drop_t = nil,
    swap_t = 0,
    ax = nil,
    ay = nil,
    disp = nil,

    pls = {},
    ids = {},
    last_id = {},
}

local function logf(fmt, ...)
    log("[livespeed] " .. string.format(fmt, ...))
end

-- ---------------------------------------------------------------------------
-- FFI: VirtualQuery (safe reads) + the addon's shared state.
-- ---------------------------------------------------------------------------
if not ffi.__livespeed_vq_cdef then
    ffi.cdef[[
    typedef struct {
        void* BaseAddress; void* AllocationBase; uint32_t AllocationProtect; uint16_t PartitionId;
        size_t RegionSize; uint32_t State; uint32_t Protect; uint32_t Type;
    } livespeed_MBI;
    size_t livespeed_VirtualQuery(const void* p, livespeed_MBI* mbi, size_t len) __asm__("VirtualQuery");
    ]]
    ffi.__livespeed_vq_cdef = true
end
local mbi = ffi.new("livespeed_MBI")
local MBI_SIZE = ffi.sizeof(mbi)

if not ffi.__livespeed_state_cdef then
    ffi.cdef[[
    typedef struct { uint32_t seq; uint32_t count; float v[128]; } livespeed_state;
    void* livespeed_GetModuleHandleA(const char* name) __asm__("GetModuleHandleA");
    void* livespeed_GetProcAddress(void* module, const char* name) __asm__("GetProcAddress");
    ]]
    ffi.__livespeed_state_cdef = true
end

-- v1.5: standalone overlay DLL (livespeed_overlay.dll). Same idea as goalreplay_overlay.dll: it hooks
-- Present and draws the card itself, so ReShade / LiveSpeed.fx are not needed. It is loaded here;
-- find_state() below then finds its exported state by module name.
local LSDLL = nil
if not ffi.__livespeed_dll_cdef then
    if pcall(ffi.cdef, "int livespeed_status(void);") then ffi.__livespeed_dll_cdef = true end
end
if ffi.__livespeed_dll_cdef then
    local dirs = {}
    local srcp = debug and debug.getinfo and debug.getinfo(1, "S").source
    if type(srcp) == "string" then
        local d = srcp:gsub("^@", ""):match("^(.*[\\/])")
        if d then dirs[#dirs + 1] = d .. "LiveSpeedOverlay" end
    end
    dirs[#dirs + 1] = ".\\SiderAddons\\modules\\LiveSpeedOverlay"
    dirs[#dirs + 1] = ".\\modules\\LiveSpeedOverlay"
    for _, d in ipairs(dirs) do
        local okl, lib = pcall(ffi.load, d .. "\\livespeed_overlay.dll")
        if okl and lib then
            LSDLL = lib
            local oks, st = pcall(function() return lib.livespeed_status() end)
            logf("overlay DLL loaded from %s (status %s)", d, oks and tostring(st) or "?")
            break
        end
    end
    if not LSDLL then logf("livespeed_overlay.dll not loaded (LiveSpeedOverlay folder missing?) - trying the old addon") end
end

local state = nil

local function num(p)
    if type(p) == "number" then return p end
    if type(p) == "string" then return tonumber(p) end
    return tonumber(ffi.cast("uint64_t", p))
end
local function hex(p) return string.format("0x%X", p or 0) end
local function unpack_num(fmt, s)
    local v = memory.unpack(fmt, s)
    if type(v) ~= "number" then v = tonumber(v) end
    return v
end
local function u64at(a) return unpack_num("u64", memory.read(a, 8)) end
local function u32at(a) return unpack_num("u32", memory.read(a, 4)) end
local function u8at(a) return unpack_num("u8", memory.read(a, 1)) end
local function f32at(a) return unpack_num("f", memory.read(a, 4)) end
local function valid(p) return p and p > 0x10000 and p < 0x7fffffffffff end
local function readable(p, n)
    if not valid(p) then return false end
    if ffi.C.livespeed_VirtualQuery(ffi.cast("void*", p), mbi, MBI_SIZE) == 0 then return false end
    if mbi.State ~= 0x1000 or bit.band(mbi.Protect, 0x101) ~= 0 or bit.band(mbi.Protect, 0xEE) == 0 then
        return false
    end
    return p + n <= num(mbi.BaseAddress) + tonumber(mbi.RegionSize)
end

-- Same match-global signature goalreplay uses. From it: out-of-play reason at
-- MatchInfo+0x1574 (3 goal, 4 ball out, 5 foul) and restart-pending flag at
-- MatchInfo+0x116C == 3. Both mean a dead ball, so no speed card.
local MATCH_GLOBAL_SIG = "\x83\x79\x2c\x05\x4c\x8b\xfa\x48\x8b\x05"
local match_global
local function find_match_global()
    if match_global then return match_global end
    local mg = memory.search_process(MATCH_GLOBAL_SIG)
    if mg then
        local p = num(mg)
        match_global = p + 14 + unpack_num("i32", memory.read(p + 10, 4))
    end
    return match_global
end

local function match_info_ptr()
    local mg = find_match_global()
    local g = mg and valid(mg) and u64at(mg) or u64at(X.base + S.RVA_MATCH)
    if not valid(g) or not readable(g + 0x270, 8) then return nil end
    local mi = u64at(g + 0x270)
    return valid(mi) and readable(mi + 0x1580, 1) and mi or nil
end

-- Sider's match library (enabled by match-stats.enabled=1 in sider.ini) gives the
-- half directly, so the end swap never has to be guessed from shifting players.
-- It is REQUIRED for the second-half end swap. Without it the direction stays at
-- the first-half default; a loud one-time warning is logged so a bad install is
-- obvious instead of silently showing the wrong end.
local function match_period()
    -- Sider's Lua sandbox has NO pcall/xpcall. Never wrap this in pcall: the
    -- error itself aborts display_frame before the card can be written.
    if type(match) ~= "table" or type(match.stats) ~= "function" then return nil end
    local st = match.stats()
    if type(st) ~= "table" then return nil end
    local p = tonumber(st.period)
    return (p and p >= 1 and p <= 5) and p or nil
end

local function dead_ball(now)
    local mi = match_info_ptr()
    local reason = mi and u8at(mi + 0x1574) or nil
    -- ONLY the three documented out-of-play reasons. Treating any non-zero byte
    -- as a foul made some matches read e.g. 1/2/16 forever -> no card at all.
    local bad = (reason == 3 or reason == 4 or reason == 5)
    local prev_reason, prev_dead = X.oop, X.dead_on
    X.oop = reason
    if bad then
        X.dead_on, X.dead_t = true, now
    elseif X.dead_on then
        -- nil means MatchInfo itself could not be read, NOT that play resumed.
        -- Requiring an explicit reason=0 (or a long 3 s failsafe) stops the card
        -- coming back in the middle of a foul / throw-in when the pointer blips.
        local wait = 0.8
        if reason == 0 then wait = 0.25
        elseif reason == nil then wait = 3.0 end
        if now - X.dead_t > wait then X.dead_on = false end
    end
    if bad or X.dead_on ~= prev_dead then
        logf("dead diag reason=%s mi=%s dead=%s", tostring(reason),
            mi and hex(mi) or "nil", tostring(X.dead_on))
    end
    return X.dead_on
end

-- The addon FILE can be renamed: ReShade loads it under its own file name, so
-- look it up by every supported name. A wrong addon (e.g. the real Goal Replay
-- one) simply has no livespeed_overlay_state export and is skipped safely.
local ADDON_NAMES = {
    "livespeed_overlay.dll",
    "speedcard_overlay.addon64",
    "livespeed_overlay.addon64",
    "goalreplay_overlay.addon64",
}
local function find_state(now)
    if state then return state end
    if now - X.state_tried < 2 then return state end
    X.state_tried = now
    for i = 1, #ADDON_NAMES do
        local name = ADDON_NAMES[i]
        local h = ffi.C.livespeed_GetModuleHandleA(name)
        if h ~= nil then
            local p = ffi.C.livespeed_GetProcAddress(h, "livespeed_overlay_state")
            local cap = p ~= nil and ffi.C.livespeed_GetProcAddress(h, "livespeed_overlay_capacity") or nil
            if p and cap then
                local n = tonumber(ffi.cast("uint32_t*", cap)[0]) or 0
                -- Never write 128 floats into a smaller/unrelated buffer.
                if n >= 128 then
                    X.cap = n
                    state = ffi.cast("livespeed_state*", p)
                    logf("overlay addon found (%d values, %s)", X.cap, name)
                    return state
                end
            end
        end
    end
    if now - X.state_warn_t > 5 then
        X.state_warn_t = now
        logf("overlay not loaded - put the LiveSpeedOverlay folder in SiderAddons\\modules")
    end
    return state
end

local function write_state(v)
    if not state then return end
    for i = 0, 127 do state.v[i] = v[i + 1] or 0 end
    state.count = 128
    state.seq = state.seq + 1
    X.shown = true
end

local function hide()
    if not X.shown then return end
    local v = {}
    for i = 1, 128 do v[i] = 0 end
    write_state(v)
    X.shown = false
end

-- ---------------------------------------------------------------------------
-- Player-name font (same glyph atlas shipped with this mod).
-- ---------------------------------------------------------------------------
local NAME_GLYPH = {
    [32] = 0, [65] = 1, [97] = 1, [66] = 2, [98] = 2, [67] = 3, [99] = 3, [68] = 4, [100] = 4, [69] = 5,
    [101] = 5, [70] = 6, [102] = 6, [71] = 7, [103] = 7, [72] = 8, [104] = 8, [73] = 9, [105] = 9, [74] = 10,
    [106] = 10, [75] = 11, [76] = 12, [108] = 12, [77] = 13, [109] = 13, [78] = 14, [110] = 14, [79] = 15,
    [111] = 15, [80] = 16, [112] = 16, [81] = 17, [113] = 17, [82] = 18, [114] = 18, [83] = 19, [115] = 19, [84] = 20,
    [116] = 20, [85] = 21, [117] = 21, [86] = 22, [118] = 22, [87] = 23, [119] = 23, [88] = 24, [120] = 24, [89] = 25,
    [121] = 25, [90] = 26, [122] = 26, [48] = 27, [49] = 28, [50] = 29, [51] = 30, [52] = 31, [53] = 32, [54] = 33,
    [55] = 34, [56] = 35, [57] = 36, [45] = 37, [46] = 38, [39] = 39, [38] = 40, [47] = 41, [40] = 42, [41] = 43,
    [192] = 44, [224] = 44, [193] = 45, [225] = 45, [194] = 46, [226] = 46, [195] = 47, [227] = 47, [196] = 48, [228] = 48,
    [197] = 49, [229] = 49, [198] = 50, [230] = 50, [199] = 51, [231] = 51, [200] = 52, [232] = 52, [201] = 53, [233] = 53,
    [202] = 54, [234] = 54, [203] = 55, [235] = 55, [204] = 56, [236] = 56, [205] = 57, [237] = 57, [206] = 58, [238] = 58,
    [207] = 59, [239] = 59, [208] = 60, [240] = 60, [209] = 61, [241] = 61, [210] = 62, [242] = 62, [211] = 63, [243] = 63,
    [212] = 64, [244] = 64, [213] = 65, [245] = 65, [214] = 66, [246] = 66, [216] = 67, [248] = 67, [217] = 68, [249] = 68,
    [218] = 69, [250] = 69, [219] = 70, [251] = 70, [220] = 71, [252] = 71, [221] = 72, [253] = 72, [222] = 73, [254] = 73,
    [260] = 74, [261] = 74, [262] = 75, [263] = 75, [268] = 76, [269] = 76, [270] = 77, [271] = 77, [280] = 78, [281] = 78,
    [282] = 79, [283] = 79, [286] = 80, [287] = 80, [304] = 81, [321] = 82, [322] = 82, [323] = 83, [324] = 83, [327] = 84,
    [328] = 84, [336] = 85, [337] = 85, [338] = 86, [339] = 86, [344] = 87, [345] = 87, [346] = 88, [347] = 88, [350] = 89,
    [351] = 89, [352] = 90, [353] = 90, [356] = 91, [357] = 91, [366] = 92, [367] = 92, [368] = 93, [369] = 93, [376] = 94,
    [255] = 94, [377] = 95, [378] = 95, [379] = 96, [380] = 96, [381] = 97, [382] = 97, [223] = 19,
}
local NAME_ADV = { 0.1979, 0.4896, 0.4792, 0.4688, 0.4896, 0.4479, 0.4167, 0.4896, 0.5104, 0.2083, 0.3750, 0.4792, 0.4271, 0.5833, 0.5208, 0.4792, 0.4688, 0.4896, 0.4896, 0.4583, 0.3646, 0.4896, 0.4375, 0.6354, 0.4271, 0.3750, 0.4062, 0.4167, 0.2500, 0.3854, 0.3958, 0.4271, 0.4062, 0.3854, 0.3750, 0.4271, 0.3854, 0.3646, 0.1667, 0.1354, 0.4896, 0.2812, 0.2500, 0.2500, 0.4896, 0.4896, 0.4896, 0.4896, 0.4896, 0.4896, 0.7292, 0.4688, 0.4479, 0.4479, 0.4479, 0.4479, 0.2083, 0.2083, 0.2083, 0.2083, 0.5104, 0.5208, 0.4792, 0.4792, 0.4792, 0.4792, 0.4792, 0.4792, 0.4896, 0.4896, 0.4896, 0.4896, 0.3750, 0.4688, 0.4896, 0.4688, 0.4688, 0.4896, 0.4479, 0.4479, 0.4896, 0.2083, 0.4583, 0.5208, 0.5208, 0.4792, 0.7500, 0.4896, 0.4583, 0.4583, 0.4583, 0.3646, 0.4896, 0.4896, 0.3750, 0.4062, 0.4062, 0.4062 }
local NAME_CELL_W = 0.6667
local POSITIONS = { [0] = "GK", "CB", "LB", "RB", "DMF", "CMF", "LMF", "RMF", "AMF", "LWF", "RWF", "SS", "CF" }

local names, rosters = nil, {}

local function load_names()
    if not ctx_global then return end
    local f = io.open(ctx_global.sider_dir .. "livespeed_players.cache", "rb")
    if not f then return end
    local sz = f:seek("end")
    f:seek("set", 0)
    local t, a, n, na = {}, {}, 0, 0
    for line in f:lines() do
        local kind, x, y, z, w = line:match("^(%a)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t?([^\t]*)")
        if kind == "P" then
            local id = tonumber(x)
            if id then t[id] = { z, w, tonumber(y) or 0 } n = n + 1 end
        elseif kind == "A" then
            local team, id = tonumber(x), tonumber(y)
            if team and id then
                a[team] = a[team] or {}
                a[team][id] = tonumber(z) or 0
                na = na + 1
            end
        end
    end
    f:close()
    if n > 0 then
        names, rosters, X.names_sig = t, a, sz
        X.ids = {}
        logf("player names loaded (%d players, %d assignments)", n, na)
    end
end

-- Own player database, taken from the game's own DB at startup (standalone: no
-- Goal Replay needed). FL27 reads common/etc/pesdb/Player.bin and
-- PlayerAssignment.bin through a CPK; we observe that read and write the SAME
-- cache format next to sider.dll, so every PC builds a cache from its own
-- option file / game DB. A shipped cache is never needed.
--   Player.bin: 312-byte records: id +8, name +68 (61 bytes UTF-8), print name
--     +190, registered position = bits 434..437 (byte 54, from bit 2).
--   PlayerAssignment.bin: 16-byte records: player id +4, team id +8, packed +12;
--     shirt number = (packed & 0x3ff) + 1.
local db_players, db_numbers, db_parts = nil, nil, {}
local function db_cache_path(ctx)
    return (ctx and ctx.sider_dir or ctx_global.sider_dir) .. "livespeed_players.cache"
end
local function unwesys(data)
    if #data >= 16 and data:sub(4, 8) == "WESYS" then
        if type(zlib) ~= "table" or type(zlib.uncompress) ~= "function" then return nil end
        return zlib.uncompress(data:sub(17), unpack_num("u32", data:sub(13, 16)))
    end
    return data
end
local function cstr(s) return s:match("^[^%z]*") end
local function db_save(ctx)
    if not (db_players and db_numbers) then return end
    local f = io.open(db_cache_path(ctx), "wb")
    if not f then return end
    local t = {}
    for id, pl in pairs(db_players) do
        t[#t + 1] = string.format("P\t%d\t%d\t%s\t%s\n", id, pl[3] or 0, pl[1], pl[2])
    end
    for team, ns in pairs(db_numbers) do
        for id, num in pairs(ns) do
            t[#t + 1] = string.format("A\t%d\t%d\t%d\n", team, id, num)
        end
    end
    f:write(table.concat(t))
    f:close()
    logf("player database cached (%d lines)", #t)
    X.names_retry_t = os.clock()
    X.names_pending, X.names_pending_t = nil, 0
    load_names()
end
local function db_take(ctx, which, data)
    data = unwesys(data)
    if not data then return end
    if which == "Player" then
        local players = {}
        for o = 0, #data - 312, 312 do
            local id = unpack_num("u32", data:sub(o + 9, o + 12))
            if id ~= 0 then
                local pos = bit.band(bit.rshift(data:byte(o + 55), 2), 15)
                players[id] = { cstr(data:sub(o + 69, o + 129)), cstr(data:sub(o + 191, o + 251)), pos }
            end
        end
        db_players = players
    else
        local numbers = {}
        for o = 0, #data - 16, 16 do
            local id = unpack_num("u32", data:sub(o + 5, o + 8))
            local team = unpack_num("u32", data:sub(o + 9, o + 12))
            if team and team ~= 0 then
                numbers[team] = numbers[team] or {}
                numbers[team][id] = bit.band(unpack_num("u32", data:sub(o + 13, o + 16)), 0x3ff) + 1
            end
        end
        db_numbers = numbers
    end
    logf("player database: %s.bin taken from game", which)
    db_save(ctx)
end

function m.livecpk_read(ctx, filename, addr, len, total_size, offset)
    if type(filename) ~= "string" then return end
    local which = filename:match("[/\\]pesdb[/\\](Player)%.bin$")
        or filename:match("[/\\]pesdb[/\\](PlayerAssignment)%.bin$")
    if not which then return end
    if offset == 0 then db_parts[which] = {} end
    local parts = db_parts[which]
    if not parts then return end
    parts[#parts + 1] = memory.read(addr, len)
    if offset + len >= total_size then
        db_parts[which] = nil
        db_take(ctx, which, table.concat(parts))
    end
end

local function cache_size()
    if not ctx_global then return nil end
    local f = io.open(ctx_global.sider_dir .. "livespeed_players.cache", "rb")
    if not f then return nil end
    local sz = f:seek("end")
    f:close()
    return sz
end

local function refresh_names(now)
    if now - X.name_t <= 0.25 then return end
    X.name_t = now
    local sig = cache_size()
    if sig and sig ~= X.names_sig then
        if X.names_pending ~= sig then
            X.names_pending, X.names_pending_t = sig, now
        elseif now - X.names_pending_t > 0.5 then
            X.names_pending, X.names_pending_t = nil, 0
            load_names()
        end
    elseif not names and now - X.names_retry_t > 5 then
        X.names_retry_t = now
        load_names()
    else
        X.names_pending, X.names_pending_t = nil, 0
    end
end

local function utf8_codes(s)
    local t, i = {}, 1
    while i <= #s do
        local c = s:byte(i)
        local k = c < 0x80 and 1 or c < 0xE0 and 2 or c < 0xF0 and 3 or 4
        local cp = k == 1 and c or bit.band(c, k == 2 and 0x1F or k == 3 and 0x0F or 0x07)
        for j = 1, k - 1 do cp = cp * 64 + bit.band(s:byte(i + j) or 0x80, 0x3F) end
        t[#t + 1] = cp
        i = i + k
    end
    return t
end

local function glyphs(s)
    local codes, out, pen = utf8_codes(s), {}, 0
    for k, cp in ipairs(codes) do
        if k > 20 then break end
        local g = NAME_GLYPH[cp] or NAME_GLYPH[32]
        local adv = NAME_ADV[g + 1]
        out[#out + 1] = g * 65536 + math.floor((pen + adv / 2 - NAME_CELL_W / 2 + 1) * 1000 + 0.5)
        pen = pen + adv
    end
    return out, pen
end

local function player_id(i)
    if not names then return nil end
    if X.ids[i] then return X.ids[i] end
    local team = ctx_global and tonumber(i < 11 and ctx_global.home_team or ctx_global.away_team)
    local roster = team and rosters[team]
    local base = X.pls[i]
    local found
    if roster and valid(base) and readable(base, 0x400) then
        for o = 0, 0x400, 4 do
            local q = u32at(base + o)
            if names[q] and roster[q] then
                found = q
                break
            end
        end
    end
    -- Cache successes only. A bursty bad read used to cache `false` forever and
    -- leave the card nameless for the rest of the match.
    if found then X.ids[i] = found end
    return found
end

local TEAM_RGB = {
    red = { 225, 25, 35 }, red2 = { 190, 15, 30 }, brightred = { 255, 45, 45 }, claret = { 150, 30, 65 },
    orange = { 255, 125, 20 }, yellow = { 255, 215, 30 }, yellow2 = { 240, 190, 0 }, green = { 30, 170, 80 },
    blue = { 30, 80, 220 }, navyblue = { 35, 55, 130 }, skyblue = { 110, 190, 255 },
    white = { 240, 240, 240 }, white2 = { 230, 228, 215 }, black = { 200, 200, 210 },
}
local team_colors = {}
local function load_team_colors()
    if X.colors_loaded then return end
    X.colors_loaded = true
    local f = io.open(ctx_global.sider_dir .. "content\\scoreboards\\team_colors.ini", "r")
    if not f then return end
    for line in f:lines() do
        local id, name = line:match("^(%d+)%s*=%s*([%w_]+)")
        if id then team_colors[tonumber(id)] = name:lower() end
    end
    f:close()
end
local function hex_rgb(s)
    if type(s) == "string" and s:match("^#%x%x%x%x%x%x$") then
        return tonumber(s:sub(2, 3), 16), tonumber(s:sub(4, 5), 16), tonumber(s:sub(6, 7), 16)
    end
end
local function kit_rgb(team, home)
    local k = ctx_global and ctx_global.kits
    if team and k and k.get_current_kit_id and k.get then
        local kid = k.get_current_kit_id(home and 0 or 1)
        local cfg = type(kid) == "number" and k.get(team, kid)
        if type(cfg) == "table" then
            local any
            for _, name in ipairs({ "ShirtColor1", "ShirtColor2", "UniColor_Color1" }) do
                local r, g, b = hex_rgb(cfg[name])
                any = any or r
                if r and r + g + b > 180 then return r * 65536 + g * 256 + b end
            end
            if any then return 200 * 65536 + 200 * 256 + 210 end
        end
    end
    local c = team and TEAM_RGB[team_colors[team] or ""]
    return c and c[1] * 65536 + c[2] * 256 + c[3]
end
local function card_color(i)
    local team = ctx_global and tonumber(i < 11 and ctx_global.home_team or ctx_global.away_team)
    local c = kit_rgb(team, i < 11)
    return c or 0, c and 1 or 0
end

-- ---------------------------------------------------------------------------
-- Live memory reads.
-- ---------------------------------------------------------------------------
-- The ball-info block is only valid on some frames (its pointer flips to 0, and the
-- position itself is briefly (0,0,0) right after a restart). Keep the last real fix
-- and reuse it for a short grace period so the carrier logic still sees the ball.
local last_ball, last_ball_t = nil, 0
local ball_speed, ball_jump = 0, 0
local ball_stale, ball_high = false, false
local ball_owner = nil   -- ball-info +0x2910: engine's player in contact (0..21)
local function live_ball()
    local g = u64at(X.base + S.RVA_MATCH)
    if valid(g) and readable(g + 0x40, 8) then
        local bi = u64at(g + 0x40)
        if valid(bi) then
            -- Read the engine's player-in-contact INDEPENDENTLY of the ball
            -- position. FL27 can blank the coords for a frame while +0x2910
            -- still says who has the ball; dropping both made the old carrier
            -- survive a turnover -> card on the wrong player / wrong team.
            ball_owner = readable(bi + 0x2910, 4) and u32at(bi + 0x2910) or nil
            if readable(bi + 0x2954, 12) then
                local x, y, z = f32at(bi + 0x2954), f32at(bi + 0x2958), f32at(bi + 0x295c)
                if x == x and y == y and z == z and
                   math.abs(x) <= 60 and math.abs(z) <= 40 and y >= -2 and y <= 20 and
                   not (x == 0 and y == 0 and z == 0) then
                    local now = os.clock()
                    if last_ball and last_ball_t > 0 then
                        local dt = now - last_ball_t
                        local dx, dz = x - last_ball[1], z - last_ball[3]
                        ball_jump = math.sqrt(dx * dx + dz * dz)
                        ball_speed = dt > 0.008 and (ball_jump / dt) or 0
                    else
                        ball_speed, ball_jump = 0, 0
                    end
                    ball_stale = false
                    ball_high = y > S.BALL_MAX_Y
                    last_ball, last_ball_t = { x, y, z }, now
                    return x, y, z
                end
            end
        else
            ball_owner = nil
        end
    end
    -- FL27 drops the ball pointer for ~0.4 s at a time. Reuse the last real fix
    -- briefly, but mark it STALE: no nearest-player guess from a stale ball.
    -- ball_owner is deliberately NOT cleared here (see above).
    ball_stale = true
    ball_speed, ball_jump = 0, 0
    if last_ball and os.clock() - last_ball_t < 0.55 then
        ball_high = false
        return last_ball[1], last_ball[2], last_ball[3]
    end
    return nil
end

local function players()
    local pa = X.base + S.RVA_PLAYERS
    local out, n = {}, 0
    for i = 0, 21 do
        local pl = u64at(pa + 8 * i)
        -- A substitution / new match gives the slot a different player object.
        -- The old cached id was the real cause of "the card says MBAPPE even
        -- though he is not on the ball" after a sub: the name never refreshed.
        if X.pls[i] ~= pl then X.ids[i] = nil end
        X.pls[i] = nil
        if valid(pl) and readable(pl + 0x7E8, 8) then
            local ac = u64at(pl + 0x7E8)
            local hum = valid(ac) and readable(ac + 8, 8) and u64at(ac + 8) or nil
            if valid(hum) and readable(hum + 0x20, 4) and u32at(hum + 0x20) >= 11 then
                local arr = u64at(hum + 0x10)
                local hips = valid(arr) and readable(arr + 6 * 8, 8) and u64at(arr + 6 * 8) or nil
                if valid(hips) and readable(hips + 0x3C, 12) then
                    local x, y, z = f32at(hips + 0x3C), f32at(hips + 0x40), f32at(hips + 0x44)
                    if x == x and y == y and z == z and math.abs(x) < 70 and math.abs(z) < 50 then
                        X.pls[i] = pl
                        out[i] = { x, y, z }
                        n = n + 1
                    end
                end
            end
        end
    end
    return n, out
end

-- Which goal HOME attacks is a MATCH property. In FL27 the keeper's collision
-- body is often parked / stale, so it must NOT steer the card. Use the proven
-- default (home attacks +x in the first half) and swap on every Sider period.
-- Keeper positions are logged only, never used as a direction source.

local function keeper_x(idx)
    local pa = X.base + S.RVA_PLAYERS
    local pl = u64at(pa + 8 * idx)
    if not valid(pl) or not readable(pl + 0x7E8, 8) then return nil end
    local ac = u64at(pl + 0x7E8)
    local hum = valid(ac) and u64at(ac + 8)
    if not valid(hum) or not readable(hum + 0x20, 4) or u32at(hum + 0x20) < 11 then return nil end
    local arr = u64at(hum + 0x10)
    local hips = valid(arr) and u64at(arr + 6 * 8)
    if not valid(hips) or not readable(hips + 0x3C, 12) then return nil end
    local x, z = f32at(hips + 0x3C), f32at(hips + 0x44)
    -- Same filter as handball.lua: parked keeper bodies sit at z = 40/45 m.
    if x ~= x or z ~= z or math.abs(x) > 58 or math.abs(z) > 34.5 then return nil end
    return x
end

-- +1: home attacks +x in the FIRST half. Every later period swaps ends.
local function base_for_period(dir, period)
    return (period and period % 2 == 0) and -dir or dir
end

local last_kh, last_ka
local period_warn_t, period_warned
local function update_attack_dir(pl, now)
    -- Home attacks +x in the first half, away -x. Ends swap on every period.
    -- Keeper / outfield positions are NOT used: FL27 parks them at stale x and
    -- that made the card land on the wrong goal in the second half.
    local key = u64at(X.base + S.RVA_MATCH)
    -- FL27 briefly drops this pointer to 0. That is NOT a new match; resetting
    -- on it wiped base_dir every few frames and no direction ever locked.
    if valid(key) and key ~= X.dir_key then
        X.dir_key = key
        X.base_dir = 1
        X.locked_dir = 1
        X.dir_src = "default"
        last_kh, last_ka = nil, nil
        period_warn_t, period_warned = nil, false
        X.dir_candidate, X.dir_candidate_t = nil, 0
        logf("attack dir reset: home attacks +x goal (default)")
    end
    if not X.base_dir then
        X.base_dir = 1
        X.locked_dir = 1
        X.dir_src = "default"
    end

    local period = match_period()
    if period then
        period_warn_t, period_warned = nil, false
    else
        period_warn_t = period_warn_t or now
        if not period_warned and now - period_warn_t > 5 then
            period_warned = true
            logf("WARNING: match-stats disabled (period=nil): ends will NOT swap at half-time - add match-stats.enabled = 1")
        end
    end
    local flipped = false
    if period and period ~= X.period then
        local old = X.period
        X.period = period
        X.locked_dir = base_for_period(X.base_dir, period)
        logf("attack dir period %s -> %d: home attacks %s goal (base %s)",
            tostring(old or "?"), period,
            X.locked_dir > 0 and "+x" or "-x",
            X.base_dir > 0 and "+x" or "-x")
        flipped = true
    end

    -- Deepest-player gap: diagnostic ONLY, never used to choose the goal.
    local lo, hi, n = { 1e9, 1e9 }, { -1e9, -1e9 }, { 0, 0 }
    for i = 0, 21 do
        local p = pl[i]
        if p and i ~= 0 and i ~= 11 then
            local t = i >= 11 and 2 or 1
            lo[t] = math.min(lo[t], p[1])
            hi[t] = math.max(hi[t], p[1])
            n[t] = n[t] + 1
        end
    end
    if n[1] >= 2 and n[2] >= 2 then
        X.dir_depth = (hi[1] - hi[2]) + (lo[1] - lo[2])
    end

    -- Logged for debugging only; never overrides the period-based direction.
    local kh, ka = keeper_x(0), keeper_x(11)
    if kh then last_kh = kh end
    if ka then last_ka = ka end

    return X.locked_dir, flipped
end

-- Goal attacked by the TEAM of i. Home and away always get opposite ends, so a
-- defending player is automatically far from HIS attack goal -> no card for him.
local function attack_goal(i, dir)
    if not dir then return nil end
    return (i < 11 and dir or -dir) * S.GOAL_X
end

local cam = {}
local function set_camera()
    local o = X.base + S.RVA_CAMERA
    if not readable(o, 0x3c) then return false end
    local ex, ey, ez = f32at(o + 0x0c), f32at(o + 0x10), f32at(o + 0x14)
    local lx, ly, lz = f32at(o), f32at(o + 4), f32at(o + 8)
    local ux, uy, uz = f32at(o + 0x18), f32at(o + 0x1c), f32at(o + 0x20)
    local fov = f32at(o + 0x30)
    local fx, fy, fz = lx - ex, ly - ey, lz - ez
    local n = math.sqrt(fx * fx + fy * fy + fz * fz)
    if not (n > 1e-4 and fov > 0.001 and fov < 3) then return false end
    fx, fy, fz = fx / n, fy / n, fz / n
    if not (ux * ux + uy * uy + uz * uz > 0.25) then ux, uy, uz = 0, 1, 0 end
    local rx, ry, rz = fy * uz - fz * uy, fz * ux - fx * uz, fx * uy - fy * ux
    n = math.sqrt(rx * rx + ry * ry + rz * rz)
    if n < 1e-4 then return false end
    rx, ry, rz = rx / n, ry / n, rz / n
    cam.e = { ex, ey, ez }
    cam.f = { fx, fy, fz }
    cam.u = { ry * fz - rz * fy, rz * fx - rx * fz, rx * fy - ry * fx }
    cam.r = { rx, ry, rz }
    cam.k = 1 / math.tan(fov / 2)
    return true
end

local function project(x, y, z)
    local dx, dy, dz = x - cam.e[1], y - cam.e[2], z - cam.e[3]
    local d = dx * cam.f[1] + dy * cam.f[2] + dz * cam.f[3]
    if d < 0.3 then return nil end
    local s = cam.k / d
    return (dx * cam.r[1] + dy * cam.r[2] + dz * cam.r[3]) * s,
           (dx * cam.u[1] + dy * cam.u[2] + dz * cam.u[3]) * s
end

local function in_match()
    local h = ctx_global and tonumber(ctx_global.home_team)
    local a = ctx_global and tonumber(ctx_global.away_team)
    return h ~= nil and a ~= nil and h ~= 131071 and a ~= 131071
end

local function clear_card(do_hide)
    X.show_t0, X.show_i = nil, nil
    X.drop_t, X.swap_t = nil, 0
    X.ax, X.ay, X.disp = nil, nil, nil
    X.carrier, X.carrier_t = nil, 0
    -- Speed history stays: one bad ball/camera read must not make the next card
    -- start from spd=0. Samples expire on their own ~0.35 s window.
    if do_hide then hide() end
end

-- ---------------------------------------------------------------------------
-- Whistle latches. match.stats() has no "match over" flag, but FL27 loads its
-- walk-off cutscene at the referee's whistle. Watch those files with Sider's
-- own livecpk_data_ready event (standalone: no common/audio.lua needed), hide
-- the card on that exact frame and keep it hidden:
--   half-time: until the second-half kick-off cutscene (FL27 flips period BEFORE
--              tu_half loads, so the period flip alone cannot reset the latch)
--   full-time: until the next match is set up
-- ---------------------------------------------------------------------------
local function norm_path(s)
    s = type(s) == "string" and s or tostring(s or "")
    local n = string.gsub(s, "\\", "/")
    return string.lower(n)
end

local function is_halftime_file(n)
    return string.find(n, "fixdemo/timeup/cut_data/tu_half", 1, true) ~= nil
end

local function is_fulltime_file(n)
    return string.find(n, "fixdemo/timeup/cut_data/tu_full", 1, true) ~= nil
        or string.find(n, "fixdemo/end/cut_data/end_timeup", 1, true) ~= nil
        or string.find(n, "fixdemo/end/cut_data/end_pk_win_", 1, true) ~= nil
end

-- FL27 plays a goal_celebrate cutscene when the teams walk out for the second
-- half. This is the reliable "kick-off happened" signal after the half-time
-- whistle; goal_ files in open play are harmless because break_on is false then.
local function is_kickoff_file(n)
    return string.find(n, "fixdemo/goal/cut_data/goal", 1, true) ~= nil
end

local function reset_break(tag, immediate)
    if not X.break_on then return end
    -- Never let a same-frame period read kill the half-time hide.
    if not immediate and os.clock() - X.break_t < 3 then return end
    X.break_on = false
    -- Walk-out/tunnel teleports must not become a fake first sprint of the half.
    X.speeds, X.pos_t = {}, {}
    logf("half-time latch reset (%s)", tag)
end

local function reset_match_over(tag, immediate)
    if not X.match_over then return end
    -- Master League can fire set_teams right after the final whistle while the
    -- walk-off cutscene is still playing. Ignore that early reset; MatchSetup
    -- and context_reset are unambiguous and may clear the latch at once.
    if not immediate and os.clock() - X.match_over_t < 20 then return end
    X.match_over = false
    X.speeds, X.pos_t = {}, {}
    logf("full-time latch reset (%s)", tag)
end

function m.data_ready(ctx, filename)
    if not filename then return end
    local n = norm_path(filename)
    -- MatchSetup / MatchSetupRematch is loaded only while preparing a new game.
    if string.find(n, "matchsetup", 1, true) then
        reset_match_over("new match", true)
        reset_break("new match", true)
        X.pause_on = false
        return
    end
    -- Sider docs: MatchPrePause.json loads when the in-game pause menu opens,
    -- MatchPostPause.json when play resumes. The carrier freezes in place, so
    -- without this latch the card stayed on top of the paused menu.
    if string.find(n, "matchprepause", 1, true) then
        if not X.pause_on then
            X.pause_on = true
            logf("pause menu - card hidden")
            clear_card(true)
        end
        return
    end
    if string.find(n, "matchpostpause", 1, true) then
        if X.pause_on then
            X.pause_on = false
            -- A frozen player must not turn into a fake full-speed sprint.
            X.speeds, X.pos_t, X.prev_pos, X.prev_t = {}, {}, {}, nil
            logf("pause menu closed - card resumes")
        end
        return
    end
    if is_halftime_file(n) and not X.match_over then
        if not X.break_on then
            X.break_on, X.break_t = true, os.clock()
            X.break_period = X.period
            logf("half-time whistle detected (%s, per=%s) - card hidden",
                tostring(filename), tostring(X.period or "?"))
            clear_card(true)
        end
        return
    end
    -- Period flips BEFORE tu_half loads in FL27, so the old period reset ran too
    -- early and the latch stayed on for the whole second half. The walk-out
    -- cutscene at the second-half kick-off is the real end of the break.
    if X.break_on and is_kickoff_file(n) then
        reset_break("kickoff", true)
        return
    end
    if not is_fulltime_file(n) or X.match_over then return end
    X.match_over, X.match_over_t = true, os.clock()
    reset_break("full-time", true)
    logf("full-time whistle detected (%s) - card hidden", tostring(filename))
    clear_card(true)
end

function m.set_teams(ctx, home, away)
    reset_match_over("set_teams", false)
    reset_break("set_teams", false)
    X.pause_on = false
end

function m.context_reset(ctx)
    ctx_global = ctx
    reset_match_over("context_reset", true)
    reset_break("context_reset", true)
    X.pause_on = false
end

local function frame()
    local now = os.clock()
    local function early(tag)
        if now - X.dbg_t > 3 then
            X.dbg_t = now
            logf("early %s (oop=%s dead=%s per=%s)", tag,
                X.oop and tostring(X.oop) or "nil", tostring(X.dead_on),
                tostring(X.period or "?"))
        end
    end
    refresh_names(now)
    if not find_state(now) then return end

    -- Pause menu: the game stops updating players/ball, so the old carrier and
    -- his frozen speed kept the card alive on the pause screen. Hide it until
    -- MatchPostPause says play resumed.
    if X.pause_on then
        early("paused")
        clear_card(true)
        return
    end

    -- Full-time whistle: the latch is set by m.data_ready. Kill the card before
    -- any carrier / zone logic can put it back on a player walking off the pitch.
    if X.match_over then
        early("match_over")
        clear_card(true)
        return
    end

    local info = memory.get_process_info()
    local base = info and tonumber(info.base) or X.base
    X.base = type(base) == "number" and base or X.base

    if not in_match() then
        early("in_match")
        clear_card(true) return
    end
    -- Foul / throw-in / goal / free-kick setup are dead balls: the nearest
    -- player to a stationary ball is NOT a carrier (Tchouameni case).
    if dead_ball(now) then
        early("dead_ball")
        clear_card(true) return
    end
    if not set_camera() then early("camera") return end

    local n, pl = players()
    if n < 1 then early("players") clear_card(true) return end
    local dir, flipped, contradicting = update_attack_dir(pl, now)
    if flipped then
        -- Immediate: in some stadiums the period flip is the only late signal.
        -- break_period guards a whistle that lands on the same period read.
        if not X.break_period or X.period ~= X.break_period then
            reset_break("period", true)
        end
        if X.show_t0 then
            clear_card(true) return    -- real end swap: kill the card immediately
        end
    end
    -- Half-time whistle: hidden through the tunnel. Normally cleared by the
    -- kick-off cutscene above; the timeout is a failsafe if that file is named
    -- differently. Full-time uses the permanent latch instead.
    if X.break_on then
        if now - X.break_t > 20 then
            reset_break("timeout", true)
        else
            early("halftime")
            clear_card(true)
            return
        end
    end
    local side_ready = dir ~= nil and not contradicting
    local bx, by, bz = live_ball()
    if not bx then
        -- One bad ball read must NOT kill the carrier or the card. by=99 simply
        -- blocks a new carrier pick; CARRIER_GRACE then covers the dropout.
        bx, by, bz = 0, 99, 0
    end

    -- NOTE: the "frozen table = replay" guard was removed. FL27's live player
    -- slots only refresh in bursts, so a 2 s stillness test killed real gameplay.

    -- Carrier = the ENGINE's player in contact (ball info +0x2910), not merely
    -- the nearest player. A chaser within 1.8 m is NOT a carrier: that was the
    -- false "Jude Bellingham is only chasing the ball" card.
    local moving = ball_speed > 6 or ball_jump > 1.5
    local strict = moving or ball_stale or ball_high
    local best, bd, csrc, no_contact = nil, 1e9, "?", false

    local owner = ball_owner
    local owner_ok = owner and owner <= 21 and owner ~= 0xFF and
                     owner ~= 0 and owner ~= 11 and pl[owner] ~= nil
    if owner and not owner_ok then
        -- 0xFF = nobody in contact, or a keeper has the ball: no speed card.
        no_contact, strict = true, true
    elseif owner_ok then
        -- Engine contact is authoritative even while ball coords are stale or
        -- the ball is moving. `strict` only blocks the nearest-player guess and
        -- the old-carrier stickiness below.
        local dx, dz = pl[owner][1] - bx, pl[owner][3] - bz
        local d2 = dx * dx + dz * dz
        if d2 <= S.KEEP_BALL * S.KEEP_BALL then
            best, bd, csrc = owner, d2, "engine"
        else
            -- Last toucher is no longer with a slow ball = loose ball. Do NOT
            -- guess a carrier from whichever player happens to be chasing it.
            no_contact, strict = true, true
        end
    end

    -- Fall back to nearest-player ONLY while a pass is actually in flight /
    -- the ball is moving and +0x2910 gave no owner. A slow loose ball with a
    -- missing owner must NOT pick whichever player happens to be chasing it.
    if not no_contact and not best and (moving or ball_high) and not ball_stale then
        for i = 0, 21 do
            local p = pl[i]
            if p and i ~= 0 and i ~= 11 then
                local dx, dz = p[1] - bx, p[3] - bz
                local d2 = dx * dx + dz * dz
                if d2 < bd then best, bd, csrc = i, d2, "nearest" end
            end
        end
    end
    local nd = best and math.sqrt(bd) or 1e9
    local cur = X.carrier
    if cur == 0 or cur == 11 then cur, X.carrier = nil, nil end
    -- Stickiness is ONLY for a missing/unreadable owner. When the engine names
    -- a different player, that owner wins immediately: the old carrier must not
    -- survive because he happens to be marginally closer to the ball. This was
    -- the "card stuck on Vini while someone else had the ball" bug.
    if not strict and not owner_ok and cur and pl[cur] then
        local dx, dz = pl[cur][1] - bx, pl[cur][3] - bz
        local cd = math.sqrt(dx * dx + dz * dz)
        if cd <= S.KEEP_BALL and (nd + S.SWITCH_MARGIN >= cd) then
            best, nd = cur, cd
        end
    end
    local limit = (not strict and best == cur) and S.KEEP_BALL or S.NEAR_BALL
    if best and nd <= limit and (not ball_stale or csrc == "engine") and by <= S.BALL_MAX_Y then
        X.carrier, X.carrier_t, X.carrier_src = best, now, csrc
    end
    -- Explicit invalid owner (255 / keeper / >21) and lofted passes drop fast.
    -- A missing owner on a slow ball gets only 0.25 s so a chaser cannot wear
    -- the card for half a second; a true pointer dropout keeps 0.55 s.
    local grace = S.CARRIER_GRACE
    if ball_high and not ball_stale then grace = 0.2
    elseif owner and not owner_ok then grace = 0.15
    elseif owner == nil and not ball_stale and not moving and not ball_high then grace = 0.25 end
    if X.carrier and (now - X.carrier_t > grace or not pl[X.carrier]) then
        X.carrier = nil
    end

    -- FL27 refreshes player slots in BURSTS. Divide each real position jump by
    -- the time since the previous jump, not by the 16 ms display frame: one
    -- 4 m jump after 0.4 s of stale coords is 36 km/h, not 900 km/h. Outlier
    -- jumps (>45 km/h) are bad reads/teleports and keep the last good speed.
    for i = 0, 21 do
        local p, q = pl[i], X.prev_pos[i]
        if p and q then
            local dx, dy, dz = p[1] - q[1], p[2] - q[2], p[3] - q[3]
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            if d > 0.0005 then
                local t0 = X.pos_t[i] or (now - 0.1)
                local gap = now - t0
                if gap > 0.02 and gap < 0.8 then
                    local kmh = d / gap * 3.6
                    if kmh <= S.MAX_SPEED_KMH then
                        local old = X.speeds[i]
                        X.speeds[i] = old and (old * 0.6 + kmh * 0.4) or kmh
                    end
                end
                X.pos_t[i] = now
            elseif not X.pos_t[i] then
                X.pos_t[i] = now
            elseif now - X.pos_t[i] > 0.6 then
                X.speeds[i] = 0
            end
        else
            X.speeds[i], X.pos_t[i] = 0, nil
        end
    end
    X.prev_pos, X.prev_t = pl, now

    local carrier = X.carrier
    local spd = carrier and X.speeds[carrier] or 0

    -- Zone gate: the carrier must be within 50 m of the goal HIS team attacks.
    -- The goal comes from the per-frame live direction, so right after a turnover
    -- the new team's carrier is measured against the OPPOSITE goal. A defender
    -- sitting near the goal he guards is ~100 m from his own attack goal, so he
    -- can never trigger a card. There is deliberately NO speed / crowd gate.
    local goal = carrier and attack_goal(carrier, dir) or nil
    local visible = X.show_t0 ~= nil
    local zone_radius = S.ATTACK_DIST +
        (visible and carrier == X.show_i and S.ZONE_SLACK or 0)
    local r2 = zone_radius * zone_radius
    local in_zone = false
    if carrier and goal and pl[carrier] then
        local dx, dz = pl[carrier][1] - goal, pl[carrier][3]
        in_zone = (dx * dx + dz * dz) <= r2
    end

    local show = carrier ~= nil and in_zone and side_ready

    -- Compact trace every 3 s. If the card still blinks, this tells us exactly
    -- which gate killed it: dir / zone / carrier.
    if now - X.gate_t > 3 then
        X.gate_t = now
        if carrier then
            local dist = (goal and pl[carrier]) and
                math.sqrt((pl[carrier][1] - goal) ^ 2 + pl[carrier][3] ^ 2) or -1
            logf("gate %s%d dir=%s per=%s base=%s src=%s depth=%.1f owner=%s csrc=%s oop=%s bspd=%.1f stale=%s kH=%s kA=%s goal=%s dist=%.1f zone=%s ready=%s show=%s",
                carrier < 11 and "H" or "A", carrier % 11,
                dir and (dir > 0 and "+1" or "-1") or "nil",
                tostring(X.period or "?"), X.base_dir and (X.base_dir > 0 and "+1" or "-1") or "nil",
                X.dir_src, X.dir_depth,
                ball_owner and tostring(ball_owner) or "nil", X.carrier_src,
                X.oop and tostring(X.oop) or "nil", ball_speed, tostring(ball_stale),
                last_kh and string.format("%.1f", last_kh) or "nil",
                last_ka and string.format("%.1f", last_ka) or "nil",
                goal and tostring(goal) or "nil", dist,
                tostring(in_zone), tostring(side_ready), tostring(show))
        else
            logf("gate NO-CARRIER dir=%s per=%s base=%s src=%s depth=%.1f owner=%s oop=%s dead=%s bspd=%.1f stale=%s kH=%s kA=%s ball=(%.1f,%.1f,%.1f)",
                dir and (dir > 0 and "+1" or "-1") or "nil",
                tostring(X.period or "?"), X.base_dir and (X.base_dir > 0 and "+1" or "-1") or "nil",
                X.dir_src, X.dir_depth, ball_owner and tostring(ball_owner) or "nil",
                X.oop and tostring(X.oop) or "nil",
                tostring(X.dead_on), ball_speed, tostring(ball_stale),
                last_kh and string.format("%.1f", last_kh) or "nil",
                last_ka and string.format("%.1f", last_ka) or "nil", bx, by, bz)
        end
    end

    -- Anchor to the CURRENT carrier on every frame, with no switch delay. On a
    -- swap we also stamp X.swap_t: even if the new carrier is out of zone, the
    -- previous team's card must die on this frame, not linger for a grace period.
    if carrier and carrier ~= X.show_i then
        if X.show_t0 then
            logf("anchor -> %s%d (ball %.1f %.1f)",
                carrier < 11 and "H" or "A", carrier % 11, bx, bz)
        end
        X.show_i = carrier
        X.swap_t = now
        X.ax, X.ay, X.disp = nil, nil, nil   -- snap anchor + speed to the new carrier
    end

    if show then
        X.drop_t = nil
        if not X.show_t0 then
            X.show_t0 = now
            local pid = player_id(carrier)
            local rec = pid and names[pid]
            if pid and X.last_id[carrier] and pid ~= X.last_id[carrier] then
                logf("player id changed %s%d: %s -> %s",
                    carrier < 11 and "H" or "A", carrier % 11,
                    tostring(X.last_id[carrier]), tostring(pid))
            end
            X.last_id[carrier] = pid or X.last_id[carrier]
            logf("card ON %s%d id=%s name=%s in %dm zone spd=%.1f",
                carrier < 11 and "H" or "A", carrier % 11,
                tostring(pid), rec and rec[1] or "?", S.ATTACK_DIST, spd)
        end
    elseif X.show_t0 then
        X.drop_t = X.drop_t or now
        -- Long grace ONLY for a brief zone dip on the same, verified carrier.
        -- No grace right after a swap; carrier/direction loss uses the short one.
        local steady = carrier == X.show_i and side_ready and goal and
                       (now - X.swap_t) > 0.05
        local grace = steady and S.HOLD_GRACE or S.LOST_GRACE
        if (now - X.swap_t) < 0.05 or (now - X.drop_t) > grace then
            logf("card OFF %s (drop=%.2f grace=%.2f)",
                (now - X.swap_t) < 0.05 and "swap" or (steady and "zone-dip" or "lost"),
                now - X.drop_t, grace)
            clear_card(true)
            return
        end
    end
    if not X.show_t0 then hide() return end

    -- Keep drawing on the last carrier during a grace window. Using `carrier`
    -- directly here bypassed HOLD_GRACE / LOST_GRACE and cleared the card
    -- instantly on every one-frame ball dropout -> the visible on/off flicker.
    local di = carrier or X.show_i
    if not di or not pl[di] then clear_card(true) return end
    local p = pl[di]
    local tx, ty = project(p[1], p[2] + S.CARD_Y, p[3])
    if not tx then hide() return end
    if X.ax then
        X.ax = X.ax * (1 - S.POS_SMOOTH) + tx * S.POS_SMOOTH
        X.ay = X.ay * (1 - S.POS_SMOOTH) + ty * S.POS_SMOOTH
    else
        X.ax, X.ay = tx, ty
    end

    local alpha = math.min(1, (now - X.show_t0) / S.FADE)
    local shown_spd = X.speeds[di] or spd or 0
    X.disp = X.disp and (X.disp * (1 - S.SPEED_SMOOTH) + shown_spd * S.SPEED_SMOOTH) or shown_spd

    local v = {}
    for i = 1, 128 do v[i] = 0 end
    local color, has_color = card_color(di)
    v[1], v[3], v[4] = alpha, color, has_color       -- GR[0].x alpha, .z kit colour, .w known
    v[5], v[6], v[7], v[8] = X.ax, X.ay, X.disp, 1    -- GR[1]: anchor, speed, kind 1
    v[9], v[10] = 1, alpha                           -- GR[2]: card reveal
    v[29] = 1                                        -- GR[7].x: card alpha (full; fade is v[1] only, avoid alpha^2)

    if names then
        local id = player_id(di)
        local rec = id and names[id]
        if rec then
            local nm = rec[1]
            if #utf8_codes(nm) > 20 and rec[2] ~= "" then nm = rec[2] end
            local g, w = glyphs(nm)
            local pos = tonumber(rec[3])
            local pg, pw = glyphs(pos and POSITIONS[pos] or "")
            local team = ctx_global and tonumber(di < 11 and ctx_global.home_team or ctx_global.away_team)
            local num = 0
            local roster = team and rosters[team]
            if roster and id then num = roster[id] or 0 end
            v[65], v[66], v[67], v[68] = #g, w, num, #pg
            for j = 1, #g do v[68 + j] = g[j] end
            for j = 1, #pg do v[116 + j] = pg[j] end
            v[121] = pw
        end
    end
    if not X.card_logged then
        X.card_logged = true
        logf("first card: speed=%.1f km/h", X.disp)
    end
    write_state(v)
end

function m.display_frame()
    frame()
end

function m.init(ctx)
    ctx_global = ctx
    load_team_colors()
    load_names()
    logf("livespeed %s ready (players %s, ball %s, camera %s, match_global %s)", m.version,
        hex(X.base + S.RVA_PLAYERS), hex(X.base + S.RVA_MATCH), hex(X.base + S.RVA_CAMERA),
        find_match_global() and hex(find_match_global()) or "NOT FOUND")
    ctx.register("display_frame", m.display_frame)
    ctx.register("livecpk_data_ready", m.data_ready)
    ctx.register("livecpk_read", m.livecpk_read)
    ctx.register("set_teams", m.set_teams)
    ctx.register("context_reset", m.context_reset)
end

return m
