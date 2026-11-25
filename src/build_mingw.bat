@echo off
rem Butuh mingw-w64 g++ (MSYS2: pacman -S mingw-w64-x86_64-gcc). Tidak butuh header ReShade lagi.
rem Hasil: ..\SiderAddons\modules\LiveSpeedOverlay\livespeed_overlay.dll
if "%CXX%"=="" set CXX=g++
set OUT=%~dp0..\SiderAddons\modules\LiveSpeedOverlay\livespeed_overlay.dll
%CXX% -shared -O2 -std=c++17 -static -static-libgcc -static-libstdc++ "%~dp0LiveSpeedOverlay.cpp" -o "%OUT%" -ld3d11 -ldxgi -lole32 -lwindowscodecs -luuid -luser32
if errorlevel 1 (echo BUILD GAGAL & exit /b 1)
echo OK: %OUT%
