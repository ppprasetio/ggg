@echo off
rem Jalankan dari "x64 Native Tools Command Prompt for VS". Tidak butuh header ReShade lagi.
set OUT=%~dp0..\SiderAddons\modules\LiveSpeedOverlay\livespeed_overlay.dll
cd /d "%~dp0"
cl /nologo /LD /O2 /MT /std:c++17 /EHsc /DNDEBUG LiveSpeedOverlay.cpp /Fe:livespeed_overlay.dll /link user32.lib ole32.lib windowscodecs.lib uuid.lib d3d11.lib dxgi.lib
if errorlevel 1 (echo BUILD GAGAL & exit /b 1)
move /Y livespeed_overlay.dll "%OUT%"
echo OK: %OUT%
