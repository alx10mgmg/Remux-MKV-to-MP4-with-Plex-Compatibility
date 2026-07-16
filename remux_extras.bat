@echo off
setlocal enabledelayedexpansion

REM ================================================================
REM  MKV -> MP4 remux for PLEX EXTRAS
REM  (featurettes, trailers, interviews, deleted scenes, etc.)
REM
REM  Pair script: remux_media.bat  (movies / episodes)
REM  Point BOTH at the same folder. This one ONLY touches files
REM  inside a Plex extras folder; the other one skips them.
REM  Nothing needs to be moved.
REM
REM  - Video ALWAYS stream-copied: no quality loss
REM  - HEVC tagged hvc1 so Apple clients will direct play
REM  - Audio copied when already MP4-native, else -> E-AC-3
REM  - NO subtitle sidecars. Plex does not reliably detect sidecar
REM    subtitles on extras, so writing them is wasted effort. Any
REM    subtitle tracks in the source are simply dropped.
REM  - Output VERIFIED against source duration before any delete
REM ================================================================

REM ---------------- Options ----------------
REM DELETE_MODE:  recycle | permanent | keep
set "DELETE_MODE=keep"

REM KEEP_ALL_AUDIO: 0 = first audio track only, 1 = every audio track
set "KEEP_ALL_AUDIO=0"

REM STOPFILE: create an empty file with this name next to the
REM   script to stop cleanly after the current file finishes.
set "STOPFILE=%~dp0STOP"

REM Max allowed source/output duration difference, in seconds
set "DURATION_TOLERANCE=2"
REM -----------------------------------------

if "%~1"=="" (
    echo Drag an MKV file OR a folder onto this script.
    echo.
    echo This script ONLY processes files inside these folders:
    echo   Behind The Scenes  Deleted Scenes  Featurettes  Interviews
    echo   Scenes  Shorts  Trailers  Other
    echo.
    echo Everything else is skipped - use remux_media.bat for that.
    echo.
    echo   DELETE_MODE    = %DELETE_MODE%
    echo   KEEP_ALL_AUDIO = %KEEP_ALL_AUDIO%
    echo.
REM ---- runtime controls (see also: STOP file, below) ----
REM   Ctrl+C          stop now. Kills ffmpeg mid-write; the partial
REM                   .mp4 is cleaned up and the MKV is kept. Answer
REM                   Y to "Terminate batch job".
REM   STOP file       stop CLEANLY after the current file finishes.
REM                   Create an empty file named STOP next to this
REM                   script. Checked before each file.
REM   Esc             un-freeze the window if you clicked in it.
REM                   QuickEdit mode pauses ALL output on click and
REM                   looks exactly like a hang.
REM   Pause / Ctrl+S  pause output. Any key / Ctrl+Q resumes.
    pause
    exit /b
)

where ffmpeg >nul 2>&1
if errorlevel 1 (
    echo ERROR: ffmpeg is not on your PATH.
    pause
    exit /b 1
)
where ffprobe >nul 2>&1
if errorlevel 1 (
    echo ERROR: ffprobe is not on your PATH.
    pause
    exit /b 1
)

REM ================================================================
REM  Pre-flight: find any path containing '!' before doing real work.
REM
REM  Why this cannot live in :process - the rest of this script needs
REM  delayed expansion, and in
REM      for /R "%~1" %%F in (*.mkv) do call :process "%%F"
REM  cmd substitutes %%F FIRST and runs delayed expansion SECOND. The
REM  '!' is stripped before :process is ever called, so by then the
REM  path is already wrong and there is nothing left to detect. The
REM  check has to happen here, with delayed expansion OFF - that is
REM  the only state in which a literal '!' survives at all.
REM
REM  Such files fail SAFE: ffprobe cannot open the mangled path, the
REM  file is skipped, and the MKV is never deleted. But the error is
REM  misleading and would scroll past unnoticed in a big run.
REM
REM  Nothing here touches the conversion path, so it cannot break a
REM  file that already works. Cost is one directory walk per run.
REM ================================================================
setlocal disabledelayedexpansion
set "BANGLIST=%TEMP%\bang_%RANDOM%.txt"
set "ALLLIST=%TEMP%\all_%RANDOM%.txt"
if exist "%~1\" (
    dir /b /s "%~1\*.mkv" > "%ALLLIST%" 2>nul
) else (
    dir /b /s "%~1" > "%ALLLIST%" 2>nul
)
findstr /L /C:"!" "%ALLLIST%" > "%BANGLIST%" 2>nul
set "BANGSIZE=0"
for %%S in ("%BANGLIST%") do set "BANGSIZE=%%~zS"
del /f /q "%ALLLIST%" >nul 2>&1
if %BANGSIZE% EQU 0 goto :bang_clear

echo.
echo ================================================================
echo   WARNING - these paths contain an exclamation mark:
echo ================================================================
type "%BANGLIST%"
echo.
echo   cmd strips '!' from a path before this script can open it, so
echo   these CANNOT be converted. Nothing is lost - each one is
echo   skipped and its MKV is never deleted - but they will not
echo   convert, and the error they produce looks like a missing file.
echo.
echo   Rename them without the '!' and re-run.
echo.
choice /C YN /N /M "  Continue anyway, skipping them? [Y/N] "
if errorlevel 2 goto :bang_abort
goto :bang_clear

:bang_abort
del /f /q "%BANGLIST%" >nul 2>&1
endlocal
echo.
echo Aborted - nothing was changed.
pause
exit /b

:bang_clear
del /f /q "%BANGLIST%" >nul 2>&1
endlocal


set /a COUNT_OK=0
set /a COUNT_FAIL=0
set /a COUNT_SKIP=0

if exist "%~1\" (
    echo Folder detected - scanning "%~1" and all subfolders for extras...
    echo.
    for /R "%~1" %%F in (*.mkv) do call :process "%%F"
) else (
    call :process "%~1"
)

echo.
echo ================================================
echo   Extras converted : !COUNT_OK!
echo   Skipped          : !COUNT_SKIP!
echo   Failed           : !COUNT_FAIL!
echo ================================================
if exist "%STOPFILE%" (
    del /f /q "%STOPFILE%" >nul 2>&1
    echo.
    echo NOTE: STOP file was found and has been removed.
)
if /I "%DELETE_MODE%"=="recycle" (
    echo.
    echo NOTE: originals went to the Recycle Bin. Disk space is NOT
    echo       reclaimed until you empty it.
)
if /I "%DELETE_MODE%"=="keep" (
    echo.
    echo NOTE: DELETE_MODE=keep - no originals were removed.
)
pause
exit /b


REM ================================================================
:process
if exist "%STOPFILE%" (
    if not defined STOP_ANNOUNCED (
        set "STOP_ANNOUNCED=1"
        echo.
        echo ================================================
        echo   STOP file found - skipping all remaining files.
        echo ================================================
    )
    exit /b
)
set "input=%~1"
set "output=%~dpn1.mp4"
set "psinput=%input:'=''%"

REM ---- only act on files inside a Plex extras folder ----
call :check_extra "%input%"
if "!IS_EXTRA!"=="0" (
    exit /b
)

REM Delayed expansion, not %~nx1: percent expansion happens before
REM cmd parses special characters, so "Fast & Furious.mkv" would
REM echo "Processing extra: Fast" and then try to RUN the rest.
set "fname=%~nx1"
echo ------------------------------------------------
echo Processing extra: !fname!   [!pdir!]

if exist "%output%" (
    echo   SKIP: "%~n1.mp4" already exists.
    set /a COUNT_SKIP+=1
    exit /b
)

REM ---------------- probe source ----------------
set "vcodec="
set "acodec="
set "achans="
set "indur="

for /f "usebackq tokens=*" %%A in (`ffprobe -v error -select_streams v:0 -show_entries stream^=codec_name -of csv^=p^=0 "%input%"`) do set "vcodec=%%A"
for /f "usebackq tokens=*" %%A in (`ffprobe -v error -select_streams a:0 -show_entries stream^=codec_name -of csv^=p^=0 "%input%"`) do set "acodec=%%A"
for /f "usebackq tokens=*" %%A in (`ffprobe -v error -select_streams a:0 -show_entries stream^=channels -of csv^=p^=0 "%input%"`) do set "achans=%%A"
for /f "usebackq delims=." %%A in (`ffprobe -v error -show_entries format^=duration -of csv^=p^=0 "%input%"`) do set "indur=%%A"

if not defined vcodec (
    echo   ERROR: no video stream found - skipping.
    set /a COUNT_FAIL+=1
    exit /b
)
if not defined indur (
    echo   ERROR: could not read source duration - skipping.
    set /a COUNT_FAIL+=1
    exit /b
)
if "!indur!"=="N/A" (
    echo   ERROR: source duration unavailable - skipping.
    set /a COUNT_FAIL+=1
    exit /b
)

REM ---------------- video tagging ----------------
REM ffmpeg defaults HEVC-in-MP4 to the hev1 tag. Apple TV / iOS /
REM macOS refuse to direct play hev1 and will force a transcode.
REM hvc1 is the same bitstream with a different fourcc.
set "vtag="
if /I "!vcodec!"=="hevc" set "vtag=-tag:v hvc1"

REM ---------------- audio decision ----------------
set "aopts="
if /I "!acodec!"=="eac3" set "aopts=-c:a copy"
if /I "!acodec!"=="ac3"  set "aopts=-c:a copy"
if /I "!acodec!"=="aac"  set "aopts=-c:a copy"

if not defined aopts (
    if not defined achans set "achans=6"
    set "aopts=-c:a eac3 -ac 1 -b:a 128k"
    if !achans! GEQ 2 set "aopts=-c:a eac3 -ac 2 -b:a 256k"
    if !achans! GEQ 6 set "aopts=-c:a eac3 -ac 6 -b:a 640k"
)

set "amap=-map 0:a:0"
if "%KEEP_ALL_AUDIO%"=="1" set "amap=-map 0:a"

echo   Video : !vcodec! (stream copy) !vtag!
echo   Audio : !acodec! / !achans!ch  ==^>  !aopts!

echo   Remuxing. Progress reaches 100%% and then goes SILENT for a
echo   while - that is +faststart's second pass moving the moov atom
echo   to the front, which re-reads and rewrites the whole output.
echo   Minutes on a large file. This is normal. Do not kill it.
REM ---------------- remux ----------------
REM -sn: no subtitles at all, in the container or beside it.
ffmpeg -y -hide_banner -loglevel warning -stats -i "%input%" ^
    -map 0:v:0 !amap! ^
    -c:v copy !vtag! ^
    !aopts! ^
    -sn ^
    -map_chapters 0 ^
    -movflags +faststart ^
    "%output%"

if errorlevel 1 (
    echo   ERROR: ffmpeg failed - original kept.
    if exist "%output%" del /f /q "%output%" >nul 2>&1
    set /a COUNT_FAIL+=1
    exit /b
)

if not exist "%output%" (
    echo   ERROR: output file missing - original kept.
    set /a COUNT_FAIL+=1
    exit /b
)

REM ---------------- verify ----------------
set "outdur="
for /f "usebackq delims=." %%A in (`ffprobe -v error -show_entries format^=duration -of csv^=p^=0 "%output%"`) do set "outdur=%%A"

if not defined outdur (
    echo   ERROR: output unreadable - original kept.
    set /a COUNT_FAIL+=1
    exit /b
)
if "!outdur!"=="N/A" (
    echo   ERROR: output duration unavailable - original kept.
    set /a COUNT_FAIL+=1
    exit /b
)

set /a ddiff=indur-outdur
if !ddiff! LSS 0 set /a ddiff=0-ddiff
if !ddiff! GTR %DURATION_TOLERANCE% (
    echo   ERROR: duration mismatch ^(source !indur!s vs output !outdur!s^)
    echo          Original kept, suspect MP4 left in place for inspection.
    set /a COUNT_FAIL+=1
    exit /b
)

echo   Verified: !outdur!s, durations match.

REM ---------------- dispose of original ----------------
if /I "%DELETE_MODE%"=="keep" (
    echo   Original kept ^(DELETE_MODE=keep^).
    goto :process_done
)
if /I "%DELETE_MODE%"=="permanent" (
    del /f /q "%input%"
    echo   Original permanently deleted - space reclaimed.
    goto :process_done
)
powershell -NoProfile -Command "Add-Type -AssemblyName Microsoft.VisualBasic; [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile('%psinput%', 'OnlyErrorDialogs', 'SendToRecycleBin')"
echo   Original sent to Recycle Bin.

:process_done
set /a COUNT_OK+=1
echo   Done: "%~n1.mp4"
exit /b


REM ================================================================
REM  Decide whether a file lives inside a Plex "extras" folder.
REM  Plex recognises exactly these eight directory names, and they
REM  always sit directly above the extra itself:
REM      Movie (Year)\Featurettes\Making Of.mkv
REM      Show (Year)\Season 01\Behind The Scenes\Look Back.mkv
REM  So the file's immediate parent is all we need to test.
REM  Sets IS_EXTRA=1 or 0, and pdir to the parent folder name.
REM ================================================================
:check_extra
set "IS_EXTRA=0"
set "pd=%~dp1"
set "pd=!pd:~0,-1!"
for %%P in ("!pd!") do set "pdir=%%~nxP"

if /I "!pdir!"=="Behind The Scenes" set "IS_EXTRA=1"
if /I "!pdir!"=="Deleted Scenes"    set "IS_EXTRA=1"
if /I "!pdir!"=="Featurettes"       set "IS_EXTRA=1"
if /I "!pdir!"=="Interviews"        set "IS_EXTRA=1"
if /I "!pdir!"=="Scenes"            set "IS_EXTRA=1"
if /I "!pdir!"=="Shorts"            set "IS_EXTRA=1"
if /I "!pdir!"=="Trailers"          set "IS_EXTRA=1"
if /I "!pdir!"=="Other"             set "IS_EXTRA=1"
exit /b
