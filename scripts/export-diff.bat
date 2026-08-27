@echo off
setlocal enabledelayedexpansion
rem ===========================================================================
rem  export-diff.bat
rem
rem  현재 브랜치를 base 브랜치로 PR 할 때 포함되는 변경 파일만 골라서
rem  원본 폴더 구조를 유지한 채 ZIP 으로 묶습니다.
rem  비교 범위는 GitHub PR 의 "Files changed" 와 동일한 merge-base 기준입니다.
rem
rem  사용법:
rem    export-diff.bat                              브랜치 목록에서 대화형 선택
rem    export-diff.bat main                         base 브랜치 직접 지정
rem    export-diff.bat origin/main export\pr.zip    출력 경로까지 지정
rem    export-diff.bat main /y                      덮어쓰기 확인 없이 진행
rem
rem  주의: 이 스크립트는 한글 경로 대응을 위해 코드페이지를 65001 로 바꿉니다.
rem        cmd 의 알려진 제약으로 65001 에서는 파이프/리다이렉트로 넘긴 입력을
rem        set /p 이 읽지 못합니다. 비대화형 실행 시에는 반드시 base 브랜치를
rem        인수로 넘기고, 필요하면 /y 를 함께 지정하세요.
rem ===========================================================================

rem --- 코드페이지를 UTF-8 로 전환 - 한글 경로 대응, 종료 시 원복 ---
set "ORIGCP="
for /f "tokens=2 delims=:" %%C in ('chcp') do set "ORIGCP=%%C"
set "ORIGCP=%ORIGCP: =%"
set "ORIGCP=%ORIGCP:.=%"
chcp 65001 >nul

set "EXITCODE=0"
set "STAGE="
set "LIST="
set "PUSHED="

rem --- git 및 저장소 확인 ---
where git >nul 2>&1
if errorlevel 1 (
    echo [ERROR] git 을 찾을 수 없습니다. PATH 를 확인하세요.
    set "EXITCODE=1"
    goto :cleanup
)

git rev-parse --is-inside-work-tree >nul 2>&1
if errorlevel 1 (
    echo [ERROR] 여기는 git 저장소가 아닙니다: %CD%
    set "EXITCODE=1"
    goto :cleanup
)

rem --- 인수 파싱. 상대 경로는 pushd 이전 기준으로 확정해야 함 ---
set "BASE="
set "OUT="
set "FORCE="
:parse_args
if "%~1"=="" goto :args_done
if /i "%~1"=="/y" set "FORCE=1" & shift & goto :parse_args
if /i "%~1"=="-y" set "FORCE=1" & shift & goto :parse_args
if not defined BASE set "BASE=%~1" & shift & goto :parse_args
if not defined OUT set "OUT=%~f1" & shift & goto :parse_args
echo  [WARN] 알 수 없는 인수는 무시합니다: %~1
shift
goto :parse_args
:args_done

rem --- 저장소 루트로 이동 - diff 경로가 루트 기준이므로 ---
set "REPO="
for /f "delims=" %%R in ('git rev-parse --show-toplevel') do set "REPO=%%R"
set "REPO=%REPO:/=\%"
if "%OUT%"=="" set "OUT=%REPO%\export\changed-files.zip"
pushd "%REPO%" || (
    echo [ERROR] 저장소 루트로 이동할 수 없습니다: %REPO%
    set "EXITCODE=1"
    goto :cleanup
)
set "PUSHED=1"

set "CURBR="
for /f "delims=" %%B in ('git rev-parse --abbrev-ref HEAD') do set "CURBR=%%B"

rem ---------------------------------------------------------------------------
rem  1. base 브랜치 결정
rem ---------------------------------------------------------------------------
if defined BASE goto :base_ready

echo.
echo  현재 브랜치 : %CURBR%
echo  저장소      : %REPO%
echo  ---------------------------------------------------------------
set /a N=0
for /f "tokens=*" %%B in ('git --no-pager branch --list --no-color') do call :add_branch "%%B"
for /f "tokens=*" %%B in ('git --no-pager branch -r --no-color') do call :add_branch "%%B"
echo  ---------------------------------------------------------------
if %N%==0 (
    echo [ERROR] 선택할 수 있는 브랜치가 없습니다.
    set "EXITCODE=1"
    goto :cleanup
)
echo.
set "SEL="
set /p "SEL=  base 브랜치 번호 선택 [Enter = 취소] : "
if "!SEL!"=="" (
    echo  취소했습니다.
    goto :cleanup
)
set "BASE="
for /f "delims=" %%V in ("!SEL!") do if defined BR[%%V] set "BASE=!BR[%%V]!"
if not defined BASE (
    echo [ERROR] 1 부터 !N! 사이의 번호를 입력하세요. 입력값: !SEL!
    set "EXITCODE=1"
    goto :cleanup
)
echo.

:base_ready
rem --- 원격 추적 브랜치면 먼저 fetch - 실패해도 계속 진행 ---
set "REMOTE="
git rev-parse --verify --quiet "refs/remotes/%BASE%" >nul 2>&1
if not errorlevel 1 for /f "tokens=1 delims=/" %%R in ("%BASE%") do set "REMOTE=%%R"
if defined REMOTE (
    echo  [1/4] !REMOTE! fetch 중...
    git fetch !REMOTE! --quiet
    if errorlevel 1 echo    [WARN] fetch 실패 - 로컬에 캐시된 원격 정보로 계속합니다.
) else (
    echo  [1/4] base 브랜치 확인 중...
)

git rev-parse --verify --quiet "%BASE%^{commit}" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] 브랜치 또는 커밋을 찾을 수 없습니다: %BASE%
    set "EXITCODE=1"
    goto :cleanup
)

rem ---------------------------------------------------------------------------
rem  2. merge-base 계산 + 변경 파일 목록 추출
rem ---------------------------------------------------------------------------
echo  [2/4] 변경 파일 목록 추출 중...
set "MB="
for /f "delims=" %%M in ('git merge-base "%BASE%" HEAD 2^>nul') do set "MB=%%M"
if "%MB%"=="" (
    echo [ERROR] %BASE% 와 %CURBR% 사이에 공통 조상이 없습니다.
    set "EXITCODE=1"
    goto :cleanup
)

set "LIST=%TEMP%\export-diff-%RANDOM%%RANDOM%.lst"
git -c core.quotepath=false --no-pager diff --name-only --diff-filter=ACMR %MB% HEAD > "%LIST%"
if errorlevel 1 (
    echo [ERROR] git diff 실행에 실패했습니다.
    set "EXITCODE=1"
    goto :cleanup
)

set /a TOTAL=0
for /f "usebackq delims=" %%L in ("%LIST%") do set /a TOTAL+=1
if %TOTAL%==0 (
    echo.
    echo  %BASE% 대비 추가/수정된 파일이 없습니다. 만들 것이 없어 종료합니다.
    goto :cleanup
)
echo        대상 %TOTAL% 개 파일

rem ---------------------------------------------------------------------------
rem  3. 스테이징 폴더로 구조 유지 복사 + 변경 목록 문서 생성
rem ---------------------------------------------------------------------------
echo  [3/4] 폴더 구조 유지 복사 중...
set "STAGE=%TEMP%\export-diff-%RANDOM%%RANDOM%"
md "%STAGE%" 2>nul
if not exist "%STAGE%\" (
    echo [ERROR] 임시 폴더를 만들 수 없습니다: %STAGE%
    set "EXITCODE=1"
    goto :cleanup
)

set "MANIFEST=%STAGE%\_changed-files.txt"
> "%MANIFEST%" echo # PR 변경 파일 목록
>>"%MANIFEST%" echo # base branch : %BASE%
>>"%MANIFEST%" echo # head branch : %CURBR%
>>"%MANIFEST%" echo # merge-base  : %MB%
>>"%MANIFEST%" echo # generated   : %DATE% %TIME%
>>"%MANIFEST%" echo # status      : A=추가 C=복사 M=수정 D=삭제 R=이름변경
>>"%MANIFEST%" echo #   D 항목은 ZIP 에 포함되지 않고 이 목록에만 기록됩니다.
>>"%MANIFEST%" echo.
git -c core.quotepath=false --no-pager diff --name-status %MB% HEAD >> "%MANIFEST%"

set /a COPIED=0
set /a MISSING=0
for /f "usebackq delims=" %%L in ("%LIST%") do call :copy_one "%%L"

rem ---------------------------------------------------------------------------
rem  4. ZIP 생성
rem ---------------------------------------------------------------------------
echo  [4/4] ZIP 생성 중...
for %%F in ("%OUT%") do if not exist "%%~dpF" md "%%~dpF" 2>nul
if exist "%OUT%" if not defined FORCE (
    set "ANS="
    set /p "ANS=  이미 파일이 있습니다. 덮어쓸까요? [y/N] : "
    if /i not "!ANS!"=="y" (
        echo  취소했습니다.
        goto :cleanup
    )
)

set "PSEXE=powershell"
where pwsh >nul 2>&1 && set "PSEXE=pwsh"
set "PSSRC=%STAGE%\*"
set "PSDST=%OUT%"
"%PSEXE%" -NoProfile -NonInteractive -Command "Compress-Archive -Path $env:PSSRC -DestinationPath $env:PSDST -Force"
if errorlevel 1 (
    echo [ERROR] 압축에 실패했습니다.
    set "EXITCODE=1"
    goto :cleanup
)

echo.
echo  ===============================================================
echo   base   : %BASE%
echo   head   : %CURBR%   merge-base %MB:~0,10%
echo   복사   : %COPIED% 개 / 대상 %TOTAL% 개
if not %MISSING%==0 echo   누락   : %MISSING% 개 - 위 WARN 메시지를 확인하세요
echo   결과   : %OUT%
echo  ===============================================================
echo.
goto :cleanup

rem ===========================================================================
rem  서브루틴
rem ===========================================================================

rem --- 브랜치 목록에 한 줄 추가. 현재 브랜치와 HEAD 별칭은 제외 ---
:add_branch
set "L=%~1"
if "%L%"=="" goto :eof
if "%L:~0,1%"=="*" goto :eof
if not "%L%"=="%L:->=%" goto :eof
set /a N+=1
echo    [!N!] %L%
set "BR[!N!]=%L%"
goto :eof

rem --- 파일 한 개를 스테이징 폴더로 구조 유지 복사 ---
:copy_one
set "GP=%~1"
set "REL=%GP:/=\%"
for %%F in ("%STAGE%\%REL%") do if not exist "%%~dpF" md "%%~dpF" >nul 2>&1
if exist "%REL%" (
    copy /y "%REL%" "%STAGE%\%REL%" >nul 2>&1
    if errorlevel 1 goto :copy_fail
    set /a COPIED+=1
    goto :eof
)
rem 작업 트리에 없으면 HEAD 커밋 내용으로 대체 추출
git --no-pager show "HEAD:%GP%" > "%STAGE%\%REL%" 2>nul
if errorlevel 1 goto :copy_fail
set /a COPIED+=1
goto :eof
:copy_fail
if not exist "%REL%" if exist "%STAGE%\%REL%" del /q "%STAGE%\%REL%" >nul 2>&1
echo    [WARN] 추출 실패: %GP%
set /a MISSING+=1
goto :eof

rem ===========================================================================
:cleanup
if defined STAGE if exist "%STAGE%\" rd /s /q "%STAGE%" >nul 2>&1
if defined LIST if exist "%LIST%" del /q "%LIST%" >nul 2>&1
if defined PUSHED popd
if defined ORIGCP chcp %ORIGCP% >nul
endlocal & exit /b %EXITCODE%
