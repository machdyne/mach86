@echo off
if "%1"=="" goto usage
shsucdx /q /u >nul
shsucdhd /q /u >nul
set CDIMG=%1
if exist %1 goto have
if exist d:\%1 set CDIMG=d:\%1
:have
shsucdhd /q /f:%CDIMG%
if errorlevel 1 goto failed
shsucdx /q /d:SHSU-CDH,E
echo %CDIMG% is on E:
set CDIMG=
goto end
:usage
echo usage: MOUNT file.ISO   (the CD image appears as drive E:;
echo        a file not found here is looked for on D:)
goto end
:failed
echo MOUNT: could not use %CDIMG%
set CDIMG=
:end
