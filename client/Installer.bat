@echo off
chcp 65001 >nul
rem Browz Forever : installe le client pont (BrowzClient.exe) et le lance a chaque demarrage du PC.
rem Mets ce fichier dans le meme dossier que BrowzClient.exe (et config.json / etat.json si tu les as deja).
cd /d "%~dp0"
if not exist "BrowzClient.exe" (
  echo BrowzClient.exe est introuvable dans ce dossier.
  pause
  exit /b 1
)
set "DEST=%LOCALAPPDATA%\BrowzForever\Client"
taskkill /im BrowzClient.exe /f >nul 2>&1
if not exist "%DEST%" mkdir "%DEST%"
copy /y "BrowzClient.exe" "%DEST%\BrowzClient.exe" >nul
if exist "config.json" if not exist "%DEST%\config.json" copy /y "config.json" "%DEST%\config.json" >nul
if exist "etat.json" if not exist "%DEST%\etat.json" copy /y "etat.json" "%DEST%\etat.json" >nul
powershell -NoProfile -Command "$s=(New-Object -ComObject WScript.Shell).CreateShortcut([Environment]::GetFolderPath('Startup')+'\Browz Forever.lnk'); $s.TargetPath='%DEST%\BrowzClient.exe'; $s.WorkingDirectory='%DEST%'; $s.Description='Browz Forever - client pont'; $s.Save()"
rem raccourci sur le bureau pour changer la cle ou l adresse (relance le client avec la fenetre de reglages)
powershell -NoProfile -Command "$s=(New-Object -ComObject WScript.Shell).CreateShortcut([Environment]::GetFolderPath('Desktop')+'\Browz Forever - reglages.lnk'); $s.TargetPath='%DEST%\BrowzClient.exe'; $s.Arguments='--config'; $s.WorkingDirectory='%DEST%'; $s.Description='Browz Forever - changer la cle de pont ou l adresse du bot'; $s.Save()"
start "" "%DEST%\BrowzClient.exe"
echo.
echo Client Browz Forever installe dans %DEST%
echo Il se lancera tout seul a chaque demarrage du PC (aucune fenetre).
echo Journal : %DEST%\browz_client.log
echo Pour changer ta cle de pont : raccourci « Browz Forever - reglages » sur le bureau.
pause
