# Remux MKV to MP4 for Plex (Windows Batch Scripts)

[![Windows](https://img.shields.io/badge/Windows-only-blue)](https://www.microsoft.com/windows/)
[![ffmpeg](https://img.shields.io/badge/requires-ffmpeg-green)](https://ffmpeg.org/)

Two Windows batch scripts that remux `.mkv` files to `.mp4` for better Plex Direct Play behavior, with safety checks designed to prevent accidental media loss.

This repo is split into two workflows:

- **`remux_media.bat`** → primary media (movies/episodes)
- **`remux_extras.bat`** → Plex extras (featurettes, trailers, interviews, etc.)

Run both against the same library root if you want complete coverage. Each script intentionally handles a different content type.

---

## Why this exists

Some Plex clients (notably Apple ecosystem clients and some console app scenarios) are picky about container/codec combinations and subtitle behavior. These scripts aim to:

- Keep video untouched (stream copy)
- Maximize Direct Play compatibility
- Preserve subtitle data outside the container (for main media)
- Verify output before any delete action is allowed

---

## What the scripts do

## Shared behavior (both scripts)

- Recursively process `.mkv` files when given a folder.
- Skip files when output `.mp4` already exists (safe re-runs).
- Video is always stream-copied (`-c:v copy`) — no re-encode, no quality loss.
- HEVC/H.265 video is tagged as `hvc1` in MP4 (`-tag:v hvc1`) for Apple compatibility.
- Audio:
  - Copied if already MP4-friendly (`aac`, `ac3`, `eac3`)
  - Otherwise transcoded to E-AC-3 with channel-aware bitrate:
    - mono → 128k
    - stereo → 256k
    - 5.1+ → 640k
- Chapters are preserved (`-map_chapters 0`).
- `+faststart` is applied so MP4 metadata is front-loaded for better seeking/start.
- Output is validated by duration check (`DURATION_TOLERANCE`) before deletion is considered.
- `DELETE_MODE` controls how originals are handled (`keep`, `recycle`, `permanent`).

---

## `remux_media.bat` (movies / episodes)

This is the **main script** for normal library content.

### Subtitle behavior (main differentiator)

- Extracts subtitle tracks to sidecar files named for Plex conventions:
  - `Movie.eng.srt`
  - `Movie.eng.forced.srt`
  - `Movie.eng.sdh.srt`
  - etc.
- Handles collision-safe naming if multiple tracks would map to the same target name.
- Subtitle extraction is done in **batched passes** for performance:
  - single ffmpeg pass for supported text/image tracks
  - single mkvextract pass for VobSub/DVD subtitles when needed

### Subtitle format handling

- **Text subtitles**
  - `subrip` / `srt` → `.srt` (copy)
  - `mov_text`, `webvtt`, `text` → converted to `.srt`
  - `ass` / `ssa`:
    - kept as `.ass` if `SUB_ASS_MODE=ass` (default, styling preserved)
    - converted to `.srt` if `SUB_ASS_MODE=srt` (styling lost, broader compatibility)
- **Image subtitles**
  - PGS / DVB subtitle streams can be saved as `.sup` (if enabled)
  - VobSub/DVD subtitles require **mkvextract** and are saved as `.idx/.sub` artifacts
- If a subtitle track fails extraction, the script marks that file as subtitle-failed and **will not delete original MKV**.

### Extras handling

`remux_media.bat` **skips files** inside Plex extras folders:
- Behind The Scenes
- Deleted Scenes
- Featurettes
- Interviews
- Scenes
- Shorts
- Trailers
- Other

Those are handled by `remux_extras.bat`.

---

## `remux_extras.bat` (Plex extras only)

This script processes only files whose immediate parent folder is one of the Plex extras folder names above.

### Key differences from media script

- No subtitle sidecar extraction.
- All subtitle streams are dropped from output (`-sn`).
- Same video/audio remux policy and duration safety checks as main script.
- Intended for featurettes/trailers/interviews where sidecar subtitle handling is often less useful/unreliable in Plex extras contexts.

---

## Safety model

The scripts are intentionally conservative.

For a file to be eligible for original removal:

1. ffmpeg must exit successfully
2. output file must exist
3. output duration must be readable
4. output/source duration delta must be within `DURATION_TOLERANCE`
5. (`remux_media.bat`) subtitle extraction must not have unresolved failures

If any check fails, original is kept.

---

## Requirements

## Required

- Windows (`cmd.exe` batch scripts)
- `ffmpeg` on `PATH`
- `ffprobe` on `PATH`

Quick check:

```bat
ffmpeg -version
ffprobe -version
```

## Optional (only for certain subtitle tracks in `remux_media.bat`)

- `mkvextract` (from [MKVToolNix](https://mkvtoolnix.download/))

Needed for VobSub/DVD subtitle extraction (`dvd_subtitle`), because ffmpeg cannot write VobSub outputs directly.

You can either:

- put `mkvextract` on `PATH`, or
- set `MKVEXTRACT_PATH` in `remux_media.bat` to full `mkvextract.exe` path

---

## Usage

## Basic

- Drag and drop:
  - a single `.mkv` file, or
  - a folder
  onto either script.

## Typical full-library workflow

- Run `remux_media.bat` on your library root.
- Run `remux_extras.bat` on the same root.

They are designed not to overlap destructively:
- media script skips extras folders
- extras script only touches extras folders

---

## Configuration options

Edit variables at top of each script.

## Common options (both scripts)

| Variable | Default | Meaning |
|---|---|---|
| `DELETE_MODE` | `keep` | `keep` = keep MKV, `recycle` = send MKV to Recycle Bin, `permanent` = hard delete |
| `KEEP_ALL_AUDIO` | `0` | `0` = first audio track only, `1` = keep all audio tracks |
| `STOPFILE` | `script_dir\STOP` | Create this empty file next to script to stop cleanly after current file |
| `DURATION_TOLERANCE` | `2` | Max allowed duration mismatch in seconds |

## `remux_media.bat` only

| Variable | Default | Meaning |
|---|---|---|
| `EXTRACT_SUBS` | `1` | `1` = extract subtitle sidecars, `0` = skip subtitle extraction |
| `SUB_ASS_MODE` | `ass` | `ass` = keep ASS/SSA styling, `srt` = convert ASS/SSA to SRT |
| `EXTRACT_IMAGE_SUBS` | `1` | `1` = save image subtitles (`.sup`, `.idx/.sub`), `0` = skip image subtitles |
| `MKVEXTRACT_PATH` | *(blank)* | Full path to `mkvextract.exe` if not on `PATH` |

---

## Runtime controls / stopping safely

While script is running:

- **Ctrl+C**: abort immediately (may interrupt active ffmpeg process)
- **STOP file**: create empty file named `STOP` next to script for graceful stop after current file
- **Esc / QuickEdit caution**: clicking in cmd window can freeze output in QuickEdit mode
- **Pause / Ctrl+S**: pauses console output

---

## Important path limitation (`!` exclamation mark)

Both scripts perform a pre-flight scan for paths containing `!`.

Reason: delayed expansion in `cmd` can mangle paths containing `!`, causing false “missing file” behavior.  
Scripts warn and let you abort before processing. Files with `!` are skipped safely (not deleted), but should be renamed for reliable conversion.

---

## Output summary

At end of run, scripts print totals for converted/skipped/failed.  
`remux_media.bat` additionally reports extracted text/image subtitle counts and writes an OCR reminder list when image subs were saved.

---

## OCR note for image subtitles

Image-based subtitles (PGS, VobSub, DVB) are not text and cannot become `.srt` without OCR.

If you need searchable/editable text subtitles, OCR them with a tool such as Subtitle Edit:
- https://www.nikse.dk/subtitleedit

---

## Suggested first run strategy

1. Leave `DELETE_MODE=keep`
2. Test on a small sample set
3. Verify playback behavior in your Plex clients
4. Then consider `recycle` or `permanent`

---

## Limitations

- Windows batch scripting environment only.
- Non-MP4-native audio codecs are transcoded (lossy) to E-AC-3.
- Subtitle extraction success depends on source track validity and available tools.
- VobSub extraction requires mkvextract.

---

## External resources

- FFmpeg: https://ffmpeg.org/
- MKVToolNix: https://mkvtoolnix.download/
- Subtitle Edit: https://www.nikse.dk/subtitleedit
