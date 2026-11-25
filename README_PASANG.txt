LIVE SPEED CARD v2 - DLL standalone (tanpa ReShade), pendekatan sama kayak goalreplay_overlay.dll
=================================================================================================
STATUS JUJUR: source DLL ini BELUM pernah di-compile atau dites (pembuatnya nggak punya compiler Windows).
Jadi folder LiveSpeedOverlay\ belum berisi livespeed_overlay.dll. Lo harus build dulu (5 menit, di bawah).
Kalau error compile / kartu nggak muncul, kirim pesan error atau isi livespeed_overlay.log.

CARA KERJA (sama kayak Goal Replay)
- livespeed.lua (sudah dipatch) memuat livespeed_overlay.dll lewat ffi.load.
- DLL nge-hook IDXGISwapChain::Present sendiri (swapchain dummy + patch vtable), compile LiveSpeedCard.hlsl
  waktu start, lalu gambar kartu di satu kotak kecil sekitar kartu. Kartu nggak tampil = hook langsung return.
- Lua tetap nulis array GR[] ke export livespeed_overlay_state di DLL. Logika Lua tidak berubah.
- ReShade, LiveSpeed.fx, dan speedcard_overlay.addon64 tidak dipakai lagi.

BUILD LEWAT GITHUB (tanpa install apa-apa)
 1. Buat repo baru di GitHub, upload SEMUA isi folder ini (termasuk folder .github).
 2. Buka tab Actions, tunggu job selesai (hijau). Kalau tidak jalan sendiri: Run workflow.
 3. Di halaman run, bagian Artifacts, download LiveSpeedOverlay_MSVC_siap_copy (atau _MinGW_ kalau MSVC gagal).
    Isinya folder SiderAddons lengkap dengan livespeed_overlay.dll, tinggal copy ke folder game.
    (livespeed.lua patch-nya sudah ada di dalamnya.)
 4. Kalau job merah, kirim log error-nya ke sini.

BUILD LOKAL (alternatif, sekali saja)
Opsi A - mingw-w64 (gratis):
 1. Install MSYS2 (msys2.org). Buka "MSYS2 MINGW64", jalankan:  pacman -S mingw-w64-x86_64-gcc
 2. Di terminal itu, masuk ke folder "src" dari zip ini, lalu:  cmd //c build_mingw.bat
Opsi B - Visual Studio (Build Tools): buka "x64 Native Tools Command Prompt", masuk ke folder src, jalankan build_msvc.bat
Hasil: SiderAddons\modules\LiveSpeedOverlay\livespeed_overlay.dll
Tidak butuh header ReShade atau SDK lain.

PASANG
 1. Backup livespeed.lua lama. Copy isi folder SiderAddons\modules\ dari zip ini ke <folder game>\SiderAddons\modules\
    (livespeed.lua ditimpa; folder LiveSpeedOverlay\ ikut, lengkap dengan DLL hasil build, HLSL, ini, Textures).
 2. sider.ini tetap:  match-stats.enabled = 1  dan  lua.module = "livespeed.lua"
 3. Hapus / pindahkan speedcard_overlay.addon64 dari folder game, dan matikan technique LiveSpeed di ReShade
    (hapus LiveSpeed.fx). Kalau ReShade nggak dipakai mod lain, ReShade-nya sendiri boleh dicopot.
 4. Jalankan game lewat Sider.

CEK BERHASIL
 - sider.log : "livespeed: overlay DLL loaded from ... (status N)"
 - SiderAddons\modules\LiveSpeedOverlay\livespeed_overlay.log :
      "Present hook installed", lalu "ready: shader ..., textures ..."
   status: 1 = hook jalan, 2 = shader+texture siap, -1 = hook gagal, -2 = shader/texture gagal.
 - Ubah tampilan lewat LiveSpeedOverlay\LiveSpeedOverlay.ini (kebaca otomatis, tanpa restart).

BATASAN
 - Hanya D3D11 dan backbuffer non-MSAA. Opsi "random tiap gol" dari LiveSpeed.fx diganti Layout/Style di .ini.
 - Wedge/trail/tabel yang "inert" tidak dibawa.
 - Dua mod yang sama-sama patch Present lewat vtable (misal ReShade aktif) bisa saling nge-chain; kalau ada
   masalah, matikan salah satunya dulu untuk tes.
