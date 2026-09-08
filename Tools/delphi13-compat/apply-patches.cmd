@echo off
rem Reapply the Delphi 13 compatibility patches on this fork.
rem Run this FROM the repository root:
rem     tools\delphi13-compat\apply-patches.cmd
setlocal
set SCRIPT=%~dp0
set REPO=%CD%

if not exist "%REPO%\.git" (
  echo Repo not found. Run this from the repository root:  %CD%
  exit /b 1
)

set JCLINC=External\jcl\jcl\source\include
if exist "%JCLINC%" (
  copy /Y "%SCRIPT%jcl-includes\jcld29win32.inc" "%JCLINC%\" >nul
  copy /Y "%SCRIPT%jcl-includes\jcld29win64.inc" "%JCLINC%\" >nul
  echo [ok] jcl includes copied
)

git -C "%REPO%\External\SynEdit" apply --ignore-whitespace "%SCRIPT%synedit-ver370.inc.diff" 2>nul && echo [ok] synedit-ver370 || echo [skip/fail] synedit-ver370 (may already be applied)
git -C "%REPO%\External\SynEdit" apply --ignore-whitespace "%SCRIPT%synedit-highlighter-E2197.diff" 2>nul && echo [ok] synedit-highlighter || echo [skip/fail] synedit-highlighter (may already be applied)
git -C "%REPO%\External\jvcl" apply --ignore-whitespace "%SCRIPT%jvcl-jvexextctrls-shadow.diff" 2>nul && echo [ok] jvcl-jvexextctrls || echo [skip/fail] jvcl-jvexextctrls (may already be applied)

echo.
echo Done. Open xEdit.dproj in Delphi and Build (LiteDebug / Win64).
