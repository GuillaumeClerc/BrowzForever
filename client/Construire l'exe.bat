@echo off
chcp 65001 >nul
rem Browz Forever : fabrique BrowzClient.exe (un seul fichier, sans fenetre, sans Python chez les officiers).
rem A lancer une fois par Bellock apres chaque mise a jour du client. Il faut Python (py) sur ce PC.
cd /d "%~dp0"
echo Installation de PyInstaller...
py -m pip install --user --upgrade pyinstaller
if errorlevel 1 goto err
echo Fabrication de BrowzClient.exe...
py -m PyInstaller --onefile --noconsole --clean --name BrowzClient browz_client.py
if errorlevel 1 goto err
copy /y "dist\BrowzClient.exe" "BrowzClient.exe" >nul
rmdir /s /q build 2>nul
del /q BrowzClient.spec 2>nul
echo.
echo OK : BrowzClient.exe est pret dans ce dossier.
pause
exit /b 0
:err
echo.
echo ERREUR pendant la fabrication. Envoie une capture de cette fenetre a Claude.
pause
exit /b 1
