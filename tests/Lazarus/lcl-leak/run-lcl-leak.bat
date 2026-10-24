@echo off
rem run-lcl-leak.bat - build (lazbuild) + run the LCL leak test, 3 passes.
rem Edit LAZBUILD/PCP for Lazarus 3.2 if you prefer that install.
setlocal

set "LAZBUILD=C:\Lazarus\Lazarus_4_8\lazbuild.exe"
set "PCP=C:\lazarus\cfg_4_8"
set "LPI=HorseMormotLclLeakTest.lpi"
set "EXE=HorseMormotLclLeakTest.exe"

cd /d "%~dp0"

if exist "%LAZBUILD%" (
  echo Building: "%LAZBUILD%" --pcp=%PCP% %LPI%
  "%LAZBUILD%" --pcp=%PCP% "%LPI%"
  if errorlevel 1 (
    echo lazbuild failed - build in the Lazarus IDE instead ^(see README^).
    exit /b 1
  )
)

if not exist "%EXE%" (
  echo %EXE% not found - build it in the Lazarus IDE with Use Heaptrc unit ^(-gh^).
  exit /b 2
)

set "HEAPTRC=log=issue.log"
"%EXE%" --nostop
set "HEAPTRC=log=fixed.log"
"%EXE%"
set "HEAPTRC=log=cycles.log"
"%EXE%" --cycles 20

echo.
echo === unfreed memory blocks at exit =====================================
echo [ISSUE  --nostop]
findstr /C:"unfreed memory blocks" issue.log
echo [FIXED  StopListen]
findstr /C:"unfreed memory blocks" fixed.log
echo [CYCLES 20x stop]
findstr /C:"unfreed memory blocks" cycles.log
echo =======================================================================
echo issue.log should show MORE blocks than fixed.log; fixed.log near 0;
echo cycles.log about the same as fixed.log. The difference is the leak.
endlocal
