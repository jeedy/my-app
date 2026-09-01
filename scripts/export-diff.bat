@echo off
setlocal enabledelayedexpansion
rem ==== ASCII-only relaunch block ===========================================
rem cmd tracks batch-file offsets while decoding with the console codepage.
rem Changing the codepage MID-RUN desyncs that bookkeeping wherever the file
rem contains multi-byte (Korean UTF-8) text: fragments of lines get executed
rem and other lines are silently lost (README 5.7 defect B - reproduced).
rem Therefore: if the console is not already 65001, switch and re-run self,
rem so the actual work below is parsed under 65001 from the very start.
rem Keep this block and everything above it strictly ASCII.
set "ORIGCP="
for /f "tokens=2 delims=:" %%C in ('chcp') do set "ORIGCP=%%C"
set "ORIGCP=%ORIGCP: =%"
set "ORIGCP=%ORIGCP:.=%"
if "%ORIGCP%"=="65001" goto :main
if defined EXPORTDIFF_RELAUNCHED goto :main
set "EXPORTDIFF_RELAUNCHED=1"
chcp 65001 >nul
cmd /d /c ""%~f0" %*"
exit /b %ERRORLEVEL%
rem ===========================================================================
rem  export-diff.bat
rem
rem  현재 브랜치를 base 브랜치로 PR 할 때 포함되는 변경 파일만 골라서
rem  원본 폴더 구조를 유지한 채 ZIP 으로 묶습니다.
rem  비교 범위는 GitHub PR 의 "Files changed" 와 동일한 merge-base 기준입니다.
rem  사용법은 export-diff.bat /h 를 참고하세요.
rem
rem  base 해석:
rem    로컬 브랜치명을 주면 그 브랜치의 upstream 으로 자동 전환합니다. GitHub 은 항상
rem    현재 base 브랜치 tip 으로 merge-base 를 다시 계산하는데, 로컬 브랜치는 pull 전까지
rem    과거에 머물러 있어 그대로 쓰면 이미 base 에 머지된 커밋까지 딸려 나옵니다.
rem
rem  기본 출력 경로: %USERPROFILE%\Downloads\<저장소이름>-changed-files.zip
rem
rem  이식성: 저장소 위치를 실행 시점의 현재 폴더에서 git 으로 찾으므로, 어떤
rem  프로젝트에 복사해도 수정 없이 동작합니다. 하위 폴더에서 실행해도 됩니다.
rem
rem  지원하지 않는 경우 - 조용히 빠지지 않고 WARN 과 함께 누락으로 집계되며,
rem  누락이 하나라도 있으면 종료 코드 1 로 끝납니다:
rem    - 경로에 ! 또는 % 가 들어간 파일. cmd 변수 확장 한계입니다.
rem    - 서브모듈 경로. 파일이 아니라 gitlink 이므로 건너뜁니다.
rem    - 260자를 넘는 경로.
rem    - 작업 트리에 없는 git LFS 파일. 폴백이 실제 내용 대신 포인터 파일을 넣습니다.
rem
rem  hidden 속성 파일은 cmd 의 copy 가 읽지 못해 HEAD 커밋 내용으로 대체 추출됩니다.
rem  커밋하지 않은 작업 트리 변경은 그대로 ZIP 에 담기므로 시작 시 경고를 띄웁니다.
rem  주의: 코드페이지는 실행 후 65001 로 남습니다 - 원복하면 콘솔 화면이 지워져
rem        출력이 사라집니다. chcp 뒤에는 파일 리다이렉트 입력을 set /p 이 못
rem        읽습니다. 파이프는 동작합니다. 비대화형은 base 인수 + /y 를 쓰세요.
rem ===========================================================================
:main

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
set "USELOCAL="
set "VERBOSE="
:parse_args
if "%~1"=="" goto :args_done
if "%~1"=="/?" goto :usage
if /i "%~1"=="/h" goto :usage
if /i "%~1"=="-h" goto :usage
if /i "%~1"=="--help" goto :usage
if /i "%~1"=="/y" set "FORCE=1" & shift & goto :parse_args
if /i "%~1"=="-y" set "FORCE=1" & shift & goto :parse_args
if /i "%~1"=="/local" set "USELOCAL=1" & shift & goto :parse_args
if /i "%~1"=="/v" set "VERBOSE=1" & shift & goto :parse_args
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

rem --- 기본 출력은 저장소 밖 Downloads 로. 작업 트리를 오염시키지 않으려고 ---
for %%I in ("%REPO%") do set "REPONAME=%%~nxI"
if not defined REPONAME set "REPONAME=repo"
if not defined OUT (
    set "OUTDIR=%USERPROFILE%\Downloads"
    if not exist "!OUTDIR!\" set "OUTDIR=%USERPROFILE%"
    set "OUT=!OUTDIR!\!REPONAME!-changed-files.zip"
)

pushd "%REPO%" || (
    echo [ERROR] 저장소 루트로 이동할 수 없습니다: %REPO%
    set "EXITCODE=1"
    goto :cleanup
)
set "PUSHED=1"

set "CURBR="
for /f "delims=" %%B in ('git rev-parse --abbrev-ref HEAD') do set "CURBR=%%B"

rem --- HEAD 가 원격과 어긋나 있으면 경고. PR 은 푸시된 커밋만 본다 ---
set "HEADUP="
for /f "delims=" %%U in ('git rev-parse --abbrev-ref --symbolic-full-name "HEAD@{upstream}" 2^>nul') do set "HEADUP=%%U"
if defined HEADUP (
    set "HAHEAD=0"
    set "HBEHIND=0"
    for /f "tokens=1,2" %%A in ('git rev-list --left-right --count "HEAD...!HEADUP!" 2^>nul') do (
        set "HAHEAD=%%A"
        set "HBEHIND=%%B"
    )
    if not "!HAHEAD!"=="0" echo  [WARN] 푸시하지 않은 커밋이 !HAHEAD!개 있습니다. PR 에는 반영되지 않은 변경입니다.
    if not "!HBEHIND!"=="0" echo  [WARN] !HEADUP! 에 안 받은 커밋이 !HBEHIND!개 있습니다. PR 과 결과가 다를 수 있습니다.
)

rem --- 작업 트리가 dirty 면 경고. 복사가 작업 트리 우선이라 ZIP 내용이 PR 과 다를 수 있다 ---
set "NDIRTY=0"
for /f %%C in ('git status --porcelain -uno 2^>nul ^| find /c /v ""') do set "NDIRTY=%%C"
if not "%NDIRTY%"=="0" echo  [WARN] 커밋하지 않은 변경이 %NDIRTY%건 있습니다. ZIP 은 작업 트리 내용을 담으므로 PR 과 다를 수 있습니다.

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
rem 파이프 입력 등으로 딸려 오는 공백을 제거 - 유효 입력은 숫자뿐이다
if defined SEL set "SEL=!SEL: =!"
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
git rev-parse --verify --quiet "%BASE%^{commit}" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] 브랜치 또는 커밋을 찾을 수 없습니다: %BASE%
    set "EXITCODE=1"
    goto :cleanup
)

rem ---------------------------------------------------------------------------
rem  base 를 PR 과 동일한 기준으로 맞춘다.
rem  GitHub 은 항상 *현재* base 브랜치 tip 으로 merge-base 를 다시 계산한다.
rem  로컬 브랜치는 pull 하기 전까지 과거에 머물러 있으므로, 그대로 쓰면
rem  이미 base 에 머지된 남의 커밋까지 diff 에 딸려 들어와 파일이 더 많아진다.
rem ---------------------------------------------------------------------------
echo  [1/4] base 브랜치 확인 중...
set "BASEREF=%BASE%"
set "SWITCHED="
set "UPSTREAM="
set "REMOTE="

rem 지정한 ref 자체가 원격 추적 ref 인지 - 예: origin/main
git rev-parse --verify --quiet "refs/remotes/%BASE%" >nul 2>&1
if not errorlevel 1 (
    for /f "tokens=1 delims=/" %%R in ("%BASE%") do set "REMOTE=%%R"
    goto :base_fetch
)

rem 로컬 브랜치면 upstream 을 찾아 그쪽으로 전환
for /f "delims=" %%U in ('git rev-parse --abbrev-ref --symbolic-full-name "%BASE%@{upstream}" 2^>nul') do set "UPSTREAM=%%U"
if not defined UPSTREAM (
    echo    [WARN] '%BASE%' 에 upstream 이 없어 최신 여부를 확인할 수 없습니다.
    echo           오래된 ref 라면 PR 보다 파일이 많게 나올 수 있습니다.
    goto :base_ready_done
)
git rev-parse --verify --quiet "refs/remotes/!UPSTREAM!" >nul 2>&1
if errorlevel 1 goto :base_ready_done
for /f "tokens=1 delims=/" %%R in ("!UPSTREAM!") do set "REMOTE=%%R"
if defined USELOCAL goto :base_fetch
set "BASEREF=!UPSTREAM!"
set "SWITCHED=1"

:base_fetch
if defined REMOTE (
    echo    !REMOTE! fetch 중...
    git fetch !REMOTE! --quiet
    if errorlevel 1 echo    [WARN] fetch 실패 - 로컬에 캐시된 원격 정보로 계속합니다.
)

rem fetch 이후 값으로 뒤처짐 정도를 계산해 알린다
if defined UPSTREAM (
    set "AHEAD=0"
    set "BEHIND=0"
    for /f "tokens=1,2" %%A in ('git rev-list --left-right --count "%BASE%...!UPSTREAM!" 2^>nul') do (
        set "AHEAD=%%A"
        set "BEHIND=%%B"
    )
    if not "!BEHIND!"=="0" (
        echo    '%BASE%' 이 !UPSTREAM! 보다 !BEHIND!커밋 뒤처져 있습니다.
        if defined SWITCHED (
            echo    PR 과 같은 결과를 위해 !UPSTREAM! 을 기준으로 계산합니다.  [/local 로 끄기]
        ) else (
            echo    [WARN] /local 지정 - 오래된 '%BASE%' 기준이라 PR 보다 파일이 많을 수 있습니다.
        )
    )
)

:base_ready_done
git rev-parse --verify --quiet "%BASEREF%^{commit}" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] 브랜치 또는 커밋을 찾을 수 없습니다: %BASEREF%
    set "EXITCODE=1"
    goto :cleanup
)

rem ---------------------------------------------------------------------------
rem  2. merge-base 계산 + 변경 파일 목록 추출
rem ---------------------------------------------------------------------------
echo  [2/4] 변경 파일 목록 추출 중...
set "MB="
for /f "delims=" %%M in ('git merge-base "%BASEREF%" HEAD 2^>nul') do set "MB=%%M"
if "%MB%"=="" (
    echo [ERROR] %BASEREF% 와 %CURBR% 사이에 공통 조상이 없습니다.
    set "EXITCODE=1"
    goto :cleanup
)

rem eol=| 로 지정 - 기본값 ; 는 세미콜론으로 시작하는 경로를 조용히 건너뛴다.
rem | 는 Windows 파일명에 쓸 수 없으므로 어떤 경로도 걸리지 않는다.
set "LIST=%TEMP%\export-diff-%RANDOM%%RANDOM%.lst"
git -c core.quotepath=false --no-pager diff --name-only --diff-filter=ACMRT %MB% HEAD > "%LIST%"
if errorlevel 1 (
    echo [ERROR] git diff 실행에 실패했습니다.
    set "EXITCODE=1"
    goto :cleanup
)

rem git 이 직접 센 줄 수. 아래 for /f 집계와 대조해 파싱 손실을 잡는다
set "GITCOUNT=0"
for /f %%C in ('find /c /v "" ^< "%LIST%"') do set "GITCOUNT=%%C"

set /a TOTAL=0
for /f "usebackq delims= eol=|" %%L in ("%LIST%") do set /a TOTAL+=1
if not "%GITCOUNT%"=="%TOTAL%" (
    echo    [WARN] git 은 %GITCOUNT% 줄인데 스크립트는 %TOTAL% 개로 셌습니다.
    echo           경로에 배치가 다루지 못하는 문자가 있을 수 있습니다.
)
rem --- 상태별 개수. 삭제분이 왜 ZIP 에서 빠지는지 요약에 보여주기 위해.
rem     TOTAL==0 판정보다 먼저 세야 삭제-전용 PR 을 "변경 없음" 으로 오인하지 않는다 ---
set /a NDEL=0
for /f %%C in ('git --no-pager diff --name-only --diff-filter=D %MB% HEAD ^| find /c /v ""') do set /a NDEL=%%C
set /a PRTOTAL=%TOTAL%+%NDEL%

if %TOTAL%==0 (
    echo.
    if %NDEL%==0 (
        echo  %BASEREF% 대비 추가/수정된 파일이 없습니다. 만들 것이 없어 종료합니다.
    ) else (
        echo  %BASEREF% 대비 변경이 삭제 %NDEL%개뿐입니다. ZIP 에 담을 실체가 없어 종료합니다.
        echo  삭제 목록은 다음으로 확인하세요: git diff --name-status %MB% HEAD
    )
    goto :cleanup
)
echo        대상 %TOTAL% 개 파일

if defined VERBOSE (
    echo.
    echo  --- 진단 -----------------------------------------------------
    echo   지정한 base   : %BASE%
    echo   실제 사용 ref : %BASEREF%
    if defined UPSTREAM echo   upstream      : !UPSTREAM!  ^(ahead !AHEAD! / behind !BEHIND!^)
    for /f "delims=" %%S in ('git rev-parse "%BASEREF%"') do echo   base commit   : %%S
    for /f "delims=" %%S in ('git rev-parse HEAD') do echo   head commit   : %%S
    echo   merge-base    : %MB%
    for /f "delims=" %%S in ('git --no-pager show -s --format^=%%ci %MB%') do echo   분기 시각     : %%S
    echo   상태별 개수   :
    git -c core.quotepath=false --no-pager diff --name-status %MB% HEAD
    echo  --------------------------------------------------------------
    echo.
)

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
>>"%MANIFEST%" echo # base branch : %BASEREF%
>>"%MANIFEST%" echo # head branch : %CURBR%
>>"%MANIFEST%" echo # merge-base  : %MB%
>>"%MANIFEST%" echo # generated   : %DATE% %TIME%
>>"%MANIFEST%" echo # status      : A=추가 C=복사 M=수정 D=삭제 R=이름변경
>>"%MANIFEST%" echo #   D 항목은 ZIP 에 포함되지 않고 이 목록에만 기록됩니다.
>>"%MANIFEST%" echo.
git -c core.quotepath=false --no-pager diff --name-status %MB% HEAD >> "%MANIFEST%"

set /a COPIED=0
set /a MISSING=0
for /f "usebackq delims= eol=|" %%L in ("%LIST%") do call :copy_one "%%L"

rem ---------------------------------------------------------------------------
rem  4. ZIP 생성
rem ---------------------------------------------------------------------------
echo  [4/4] ZIP 생성 중...
for %%F in ("%OUT%") do if not exist "%%~dpF" md "%%~dpF" 2>nul
if exist "%OUT%" if not defined FORCE (
    set "ANS="
    set /p "ANS=  이미 파일이 있습니다. 덮어쓸까요? [y/N] : "
    if defined ANS set "ANS=!ANS: =!"
    if /i not "!ANS!"=="y" (
        echo  취소했습니다.
        goto :cleanup
    )
)

set "PSEXE=powershell"
where pwsh >nul 2>&1 && set "PSEXE=pwsh"
set "PSSRC=%STAGE%"
set "PSDST=%OUT%"

rem CreateFromDirectory 는 숨김 속성 파일까지 포함한다.
rem Compress-Archive -Path <dir>\* 는 와일드카드 열거라 숨김 파일을 조용히 빠뜨릴 수 있고,
rem 개별 파일 오류가 비종료 오류라 exit code 0 으로 지나가 버린다.
rem 압축 직후 ZIP 안 엔트리 수를 파일로 받아 복사 개수와 대조한다.
set "CNTFILE=%TEMP%\export-diff-cnt-%RANDOM%%RANDOM%.txt"
set "PSCNT=%CNTFILE%"
"%PSEXE%" -NoProfile -NonInteractive -Command "Add-Type -AssemblyName System.IO.Compression.FileSystem; if (Test-Path -LiteralPath $env:PSDST) { Remove-Item -LiteralPath $env:PSDST -Force }; [System.IO.Compression.ZipFile]::CreateFromDirectory($env:PSSRC, $env:PSDST); $a = [System.IO.Compression.ZipFile]::OpenRead($env:PSDST); $n = @($a.Entries | Where-Object { $_.Name -ne '' }).Count; $a.Dispose(); Set-Content -LiteralPath $env:PSCNT -Value $n"

set "ZIPCOUNT=0"
if exist "%CNTFILE%" for /f "usebackq delims=" %%Z in ("%CNTFILE%") do set "ZIPCOUNT=%%Z"
del /q "%CNTFILE%" >nul 2>&1

if not exist "%OUT%" (
    echo [ERROR] 압축에 실패했습니다.
    set "EXITCODE=1"
    goto :cleanup
)

rem ZIP 안에는 복사한 파일 + _changed-files.txt 가 들어 있어야 한다
set /a EXPECTED=%COPIED%+1
set "ZIPOK=검증 OK"
if not "%ZIPCOUNT%"=="%EXPECTED%" (
    set "ZIPOK=[ERROR] 불일치 - 기대 %EXPECTED%"
    set "EXITCODE=1"
)

echo.
echo  ===============================================================
if defined SWITCHED (
    echo   base   : %BASEREF%   [%BASE% 의 upstream 으로 자동 전환]
) else (
    echo   base   : %BASEREF%
)
echo   head   : %CURBR%   merge-base %MB:~0,10%
echo   PR 범위 : %PRTOTAL% 개  =  추출 %TOTAL% 개 + 삭제 %NDEL% 개
echo   복사   : %COPIED% 개 / 대상 %TOTAL% 개
if not %MISSING%==0 echo   누락   : %MISSING% 개 - 위 WARN 메시지를 확인하세요
echo   ZIP    : %ZIPCOUNT% 개 항목  ^(파일 %COPIED% + 목록 1^)  %ZIPOK%
echo   결과   : %OUT%
echo  ===============================================================
if not "%ZIPCOUNT%"=="%EXPECTED%" (
    echo.
    echo  [ERROR] ZIP 안 항목 수가 복사한 개수와 다릅니다. 압축 단계에서 누락된 파일이 있습니다.
)
if not %MISSING%==0 (
    echo.
    echo  [ERROR] 추출하지 못한 파일 %MISSING%개를 뺀 채 ZIP 을 만들었습니다. 위 WARN 을 확인하세요.
    set "EXITCODE=1"
)
echo.
goto :cleanup

rem ===========================================================================
rem  도움말
rem ===========================================================================
:usage
echo.
echo  현재 브랜치를 base 브랜치로 PR 할 때 포함되는 변경 파일만 골라
echo  폴더 구조를 유지한 채 ZIP 으로 묶습니다.
echo  비교 범위는 GitHub PR 의 Files changed 와 동일한 merge-base 기준입니다.
echo.
echo  사용법:
echo    export-diff.bat                       브랜치 목록에서 대화형 선택
echo    export-diff.bat ^<base^>                base 브랜치 직접 지정
echo    export-diff.bat ^<base^> ^<out.zip^>     출력 경로까지 지정
echo.
echo  옵션:
echo    /y            기존 ZIP 을 덮어쓸 때 확인하지 않음
echo    /local        base 를 upstream 으로 자동 전환하지 않고 지정한 ref 그대로 사용
echo    /v            진단 정보 출력 - PR 과 개수가 다를 때 원인 확인용
echo    /h            이 도움말
echo.
echo  base 를 로컬 브랜치명으로 주면 그 브랜치의 upstream^(예: origin/main^)으로
echo  자동 전환합니다. 로컬 브랜치는 pull 전까지 과거에 머물러 있어서, 그대로 쓰면
echo  이미 base 에 머지된 남의 커밋까지 딸려 나와 PR 보다 파일이 많아집니다.
echo.
echo  기본 출력:
echo    %%USERPROFILE%%\Downloads\^<저장소이름^>-changed-files.zip
echo.
echo  예:
echo    export-diff.bat main
echo    export-diff.bat origin/main D:\share\pr.zip /y
echo.
echo  ZIP 안에는 변경 파일과 함께 _changed-files.txt 가 들어갑니다.
echo  삭제된 파일은 ZIP 에 담기지 않고 이 목록에 D 로만 기록됩니다.
echo.
echo  비대화형 실행 시에는 base 브랜치를 반드시 인수로 넘기세요.
echo  자세한 제약은 스크립트 상단 주석을 참고하세요.
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
rem 다른 worktree 에 체크아웃된 브랜치는 "+ 이름" 으로 나오므로 접두를 벗겨 선택 가능하게 한다
if "%L:~0,2%"=="+ " set "L=%L:~2%"
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
rem 디렉터리는 서브모듈 gitlink - copy 가 안의 파일들을 이어 붙인 가짜 파일을 만들므로 차단
if exist "%REL%\" goto :copy_fail
if exist "%REL%" (
    copy /y "%REL%" "%STAGE%\%REL%" >nul 2>&1
    if not errorlevel 1 (
        set /a COPIED+=1
        goto :eof
    )
)
rem 작업 트리에 없거나 copy 가 읽지 못하면(hidden 속성 등) HEAD 커밋 내용으로 대체 추출
git --no-pager show "HEAD:%GP%" > "%STAGE%\%REL%" 2>nul
if errorlevel 1 goto :copy_fail
set /a COPIED+=1
goto :eof
:copy_fail
if exist "%STAGE%\%REL%" del /q "%STAGE%\%REL%" >nul 2>&1
echo    [WARN] 추출 실패 - 건너뜁니다: %GP%
echo           경로에 ^^! 나 %% 가 있는지, 서브모듈인지, 260자를 넘는지 확인하세요.
set /a MISSING+=1
goto :eof

rem ===========================================================================
:cleanup
if defined STAGE if exist "%STAGE%\" rd /s /q "%STAGE%" >nul 2>&1
if defined LIST if exist "%LIST%" del /q "%LIST%" >nul 2>&1
if defined CNTFILE if exist "%CNTFILE%" del /q "%CNTFILE%" >nul 2>&1
if defined PUSHED popd
rem 코드페이지는 의도적으로 원복하지 않는다 - 949 및 65001 간 전환이 화면을 지운다 (README 5.7)
endlocal & exit /b %EXITCODE%
