@echo off
setlocal enabledelayedexpansion

REM ================================================================
REM  MKV -> MP4 remux + subtitle sidecar extraction for Plex  (v3)
REM
REM  - Video ALWAYS stream-copied: no quality loss, 4K/HDR safe
REM  - HEVC tagged hvc1 so Apple clients will direct play
REM  - Audio copied when already MP4-native, else -> E-AC-3
REM  - ALL subtitle tracks extracted to sidecars, Plex-named
REM  - Output VERIFIED against source duration before any delete
REM  - Original is NEVER deleted if a subtitle track failed to
REM    extract (those subs would be gone forever)
REM ================================================================

REM ---------------- Options ----------------
REM DELETE_MODE:  recycle | permanent | keep
REM   keep      = leave originals alone (use for your first run)
REM   recycle   = safe, but space is NOT freed until you empty the bin
REM   permanent = frees space immediately, no undo
set "DELETE_MODE=keep"

REM KEEP_ALL_AUDIO: 0 = first audio track only, 1 = every audio track
set "KEEP_ALL_AUDIO=0"

REM EXTRACT_SUBS: 1 = write subtitle sidecars, 0 = skip entirely
set "EXTRACT_SUBS=1"

REM SUB_ASS_MODE: ass | srt
REM   ass = keep ASS/SSA as .ass sidecar (lossless, keeps styling
REM         and positioning; some clients render it poorly)
REM   srt = convert ASS/SSA to .srt (max compatibility, DESTROYS
REM         all styling, positioning and karaoke typesetting)
set "SUB_ASS_MODE=ass"

REM EXTRACT_IMAGE_SUBS: 1 = save PGS/VobSub tracks as .sup/.idx
REM   These CANNOT become .srt without OCR. Saving them means the
REM   data survives so you can OCR later with Subtitle Edit.
REM   Set to 0 only if you truly do not want them.
set "EXTRACT_IMAGE_SUBS=1"

REM Max allowed source/output duration difference, in seconds
set "DURATION_TOLERANCE=2"
REM -----------------------------------------

if "%~1"=="" (
    echo Drag an MKV file OR a folder onto this script.
    echo.
    echo   DELETE_MODE        = %DELETE_MODE%
    echo   KEEP_ALL_AUDIO     = %KEEP_ALL_AUDIO%
    echo   EXTRACT_SUBS       = %EXTRACT_SUBS%
    echo   SUB_ASS_MODE       = %SUB_ASS_MODE%
    echo   EXTRACT_IMAGE_SUBS = %EXTRACT_IMAGE_SUBS%
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

REM mkvextract is optional - only needed for DVD/VobSub subtitles,
REM which ffmpeg physically cannot write (it has no vobsub muxer).
set "HAVE_MKVEXTRACT=1"
where mkvextract >nul 2>&1
if errorlevel 1 set "HAVE_MKVEXTRACT=0"
if "%HAVE_MKVEXTRACT%"=="0" (
    echo NOTE: mkvextract not found. DVD/VobSub subtitle tracks cannot
    echo       be extracted and those MKVs will be kept, not deleted.
    echo       Install MKVToolNix if your rips are from DVD.
    echo.
)

set /a COUNT_OK=0
set /a COUNT_FAIL=0
set /a COUNT_SKIP=0
set /a TOTAL_TEXT_SUBS=0
set /a TOTAL_IMAGE_SUBS=0
set "OCR_LIST=%TEMP%\needs_ocr_%RANDOM%.txt"
if exist "%OCR_LIST%" del /f /q "%OCR_LIST%" >nul 2>&1

if exist "%~1\" (
    echo Folder detected - scanning "%~1" and all subfolders for .mkv files...
    echo.
    for /R "%~1" %%F in (*.mkv) do call :process "%%F"
) else (
    call :process "%~1"
)

echo.
echo ================================================
echo   Converted OK        : !COUNT_OK!
echo   Skipped             : !COUNT_SKIP!
echo   Failed              : !COUNT_FAIL!
echo   Text subs extracted : !TOTAL_TEXT_SUBS!
echo   Image subs saved    : !TOTAL_IMAGE_SUBS!
echo ================================================

if !TOTAL_IMAGE_SUBS! GTR 0 (
    echo.
    echo !TOTAL_IMAGE_SUBS! image-based subtitle track^(s^) were saved as
    echo .sup / .idx sidecars. These are BITMAPS - Plex must burn them
    echo in, which forces a full transcode. To get real .srt files you
    echo must OCR them with Subtitle Edit ^(free^):
    echo     https://www.nikse.dk/subtitleedit
    echo.
    echo A list of the affected files was written to:
    echo     %OCR_LIST%
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
set "input=%~1"
set "output=%~dpn1.mp4"
set "subbase=%~dpn1"
set "psinput=%input:'=''%"

echo ------------------------------------------------
echo Processing: %~nx1

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

REM ---------------- subtitles FIRST ----------------
REM Done before the remux so that a subtitle failure can veto the
REM delete before we have spent 20 minutes muxing.
set /a SUB_FAILED=0
if "%EXTRACT_SUBS%"=="1" call :extract_subs

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

REM ---------------- remux ----------------
REM -sn: no subtitles in the MP4 at all. They live in sidecars now.
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
REM Exit code 0 alone is not proof of a good file. Compare durations
REM so a truncated or half-written mux can never trigger a delete.
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
if !SUB_FAILED! GTR 0 (
    echo   Original KEPT: !SUB_FAILED! subtitle track^(s^) failed to
    echo   extract. Deleting the MKV would lose them permanently.
    set /a COUNT_OK+=1
    echo   Done: "%~n1.mp4"
    exit /b
)

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
REM  Extract every subtitle track to a Plex-named sidecar.
REM
REM  Plex wants:  <video basename>.<lang>[.forced][.sdh].<ext>
REM  Language is ISO-639-1 (2 letter) or ISO-639-2/B (3 letter).
REM  ffprobe reports 639-2/B, so it is used verbatim.
REM ================================================================
:extract_subs
set /a sidx=0

:subloop
set "scodec="
set "slang="
set "sindex="
set "sforced=0"
set "ssdh=0"

for /f "usebackq tokens=1,* delims==" %%A in (`ffprobe -v error -select_streams s:!sidx! -show_entries stream^=index^,codec_name:stream_tags^=language:stream_disposition^=forced^,hearing_impaired -of default^=noprint_wrappers^=1 "%input%"`) do (
    if /I "%%A"=="index"                      set "sindex=%%B"
    if /I "%%A"=="codec_name"                 set "scodec=%%B"
    if /I "%%A"=="TAG:language"               set "slang=%%B"
    if /I "%%A"=="DISPOSITION:forced"         set "sforced=%%B"
    if /I "%%A"=="DISPOSITION:hearing_impaired" set "ssdh=%%B"
)

REM No codec returned means we have run past the last subtitle track.
if not defined scodec goto :subloop_done

if not defined slang set "slang=und"
if /I "!slang!"=="unknown" set "slang=und"

REM ---- Plex flag suffixes ----
set "sflag="
if "!sforced!"=="1" set "sflag=!sflag!.forced"
if "!ssdh!"=="1" set "sflag=!sflag!.sdh"

REM ---- decide container + codec per subtitle format ----
set "sext="
set "senc="
set "simage=0"

REM Text formats that are already SubRip: copy out losslessly.
if /I "!scodec!"=="subrip" set "sext=srt"
if /I "!scodec!"=="subrip" set "senc=-c:s copy"
if /I "!scodec!"=="srt"    set "sext=srt"
if /I "!scodec!"=="srt"    set "senc=-c:s copy"

REM Text formats that must be converted to SubRip.
if /I "!scodec!"=="mov_text" set "sext=srt"
if /I "!scodec!"=="mov_text" set "senc=-c:s srt"
if /I "!scodec!"=="webvtt"   set "sext=srt"
if /I "!scodec!"=="webvtt"   set "senc=-c:s srt"
if /I "!scodec!"=="text"     set "sext=srt"
if /I "!scodec!"=="text"     set "senc=-c:s srt"

REM ASS/SSA: behaviour depends on SUB_ASS_MODE.
set "isass=0"
if /I "!scodec!"=="ass" set "isass=1"
if /I "!scodec!"=="ssa" set "isass=1"
if "!isass!"=="1" if /I "%SUB_ASS_MODE%"=="srt" set "sext=srt"
if "!isass!"=="1" if /I "%SUB_ASS_MODE%"=="srt" set "senc=-c:s srt"
if "!isass!"=="1" if /I not "%SUB_ASS_MODE%"=="srt" set "sext=ass"
if "!isass!"=="1" if /I not "%SUB_ASS_MODE%"=="srt" set "senc=-c:s copy"

REM Image formats. These are bitmaps - there is no text in them to
REM extract. ffmpeg has no OCR. Copy them out raw so the data
REM survives the MKV being deleted, then OCR later.
if /I "!scodec!"=="hdmv_pgs_subtitle" set "sext=sup"
if /I "!scodec!"=="hdmv_pgs_subtitle" set "senc=-c:s copy"
if /I "!scodec!"=="hdmv_pgs_subtitle" set "simage=1"
if /I "!scodec!"=="dvb_subtitle" set "sext=sup"
if /I "!scodec!"=="dvb_subtitle" set "senc=-c:s copy"
if /I "!scodec!"=="dvb_subtitle" set "simage=1"

REM VobSub (DVD) is a special case: ffmpeg has NO vobsub muxer, so
REM it physically cannot write .idx/.sub. mkvextract can. If it is
REM not installed we refuse and keep the MKV rather than lose them.
set "svobsub=0"
if /I "!scodec!"=="dvd_subtitle" set "svobsub=1"
if /I "!scodec!"=="dvd_subtitle" set "sext=idx"
if /I "!scodec!"=="dvd_subtitle" set "simage=1"
if "!svobsub!"=="1" if "%EXTRACT_IMAGE_SUBS%"=="1" if "%HAVE_MKVEXTRACT%"=="0" (
    echo   Sub s:!sidx! [!slang!] VobSub - NEEDS mkvextract ^(MKVToolNix^), not found
    set /a SUB_FAILED+=1
    goto :subnext
)

if not defined sext (
    echo   Sub s:!sidx! [!slang!] - unhandled format "!scodec!" - SKIPPED
    set /a SUB_FAILED+=1
    goto :subnext
)

if "!simage!"=="1" if "%EXTRACT_IMAGE_SUBS%"=="0" (
    echo   Sub s:!sidx! [!slang!] !scodec! - image sub, skipped by config
    goto :subnext
)

REM ---- build target filename, avoiding collisions ----
set "starget=!subbase!.!slang!!sflag!.!sext!"
set /a dupn=1
:dupcheck
if exist "!starget!" (
    set /a dupn+=1
    set "starget=!subbase!.!slang!!sflag!.!dupn!.!sext!"
    goto :dupcheck
)

if "!svobsub!"=="1" (
    mkvextract tracks "%input%" !sindex!:"!starget!" >nul 2>&1
) else (
    ffmpeg -y -hide_banner -loglevel error -i "%input%" -map 0:s:!sidx! !senc! "!starget!" >nul 2>&1
)

if errorlevel 1 (
    echo   Sub s:!sidx! [!slang!] !scodec! - EXTRACT FAILED
    if exist "!starget!" del /f /q "!starget!" >nul 2>&1
    set /a SUB_FAILED+=1
    goto :subnext
)
if not exist "!starget!" (
    echo   Sub s:!sidx! [!slang!] !scodec! - EXTRACT FAILED ^(no output^)
    set /a SUB_FAILED+=1
    goto :subnext
)

REM Discard empty tracks - some MKVs carry placeholder subtitle
REM streams with no actual cues in them.
set "ssize=0"
for %%S in ("!starget!") do set "ssize=%%~zS"
if !ssize! LSS 32 (
    echo   Sub s:!sidx! [!slang!] !scodec! - empty track, discarded
    del /f /q "!starget!" >nul 2>&1
    goto :subnext
)

for %%N in ("!starget!") do echo   Sub s:!sidx! [!slang!] !scodec! -^> %%~nxN
if "!simage!"=="1" (
    set /a TOTAL_IMAGE_SUBS+=1
    echo !starget!>>"%OCR_LIST%"
) else (
    set /a TOTAL_TEXT_SUBS+=1
)

:subnext
set /a sidx+=1
goto :subloop

:subloop_done
exit /b
