@echo off
chcp 65001 >nul
rem Browz Forever : arrete le client pont et le retire du demarrage de Windows.
taskkill /im BrowzClient.exe /f >nul 2>&1
del /q "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Browz Forever.lnk" 2>nul
echo Client arrete et retire du demarrage. Le dossier %LOCALAPPDATA%\BrowzForever\Client est garde
echo (config et etat) : supprime-le a la main si tu veux tout effacer.
pause
