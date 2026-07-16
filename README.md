# Remux-MKV-to-MP4-with-Plex-Compatibility

[![Windows](https://img.shields.io/badge/Windows-only-blue)](https://www.microsoft.com/windows/)
[![ffmpeg](https://img.shields.io/badge/requires-ffmpeg-green)](https://ffmpeg.org/)


This .bat file uses ffmpeg to remux .mkv files with proper audio and video codecs, containing them in a .mp4 container, extracting all subtitle tracks into appropriate sidecar .srt files, and finally deleting the main .mkv file after verification that the process was completed successfully.

There are variables to change the delete mode (keep, recycle, permanant), number of audio tracks kept, subtitle extraction preference, subtitle extraction type, image subtitle extraction preference, and tolerance between the input and output duration. The AI explanation below delves into this further as well as how to edit these variables.

FFMpeg is required, follow the instalation instructions on how to instal that before running. To validate ffmpeg is installed properly for the script run the following in an administer privalaged command prompt.

ffmpeg -version

MKVToolNix is used, but only for bitmap subtitles (PGS or VodSub). This is a somewhat rare edge case and is an optional requirement. That said, it is still recommended.

This remuxing script was created to properly remux .mkv files for Plex, the Playstation 5 Plex app specifically. Not only is this turning unsupported .mkv files into .mp4's, but it is also editing the audio codecs into a supported format; this script turns non-supported audio codecs into EAC3. Supported codecs like AAC are recognized and audio remuxing copies the original audio file directly into the new container.

**A deeper AI generated explaination of the .bat file is as follows:**

A single-file Windows batch script that repackages MKV files into MP4 **without re-encoding the video**, and pulls every subtitle track out into Plex-named sidecar files.

The goal is Direct Play: MP4 + a codec your client already speaks means Plex streams the file untouched instead of burning CPU on a transcode.

## Truncated Instructions

1. Install ffmpeg
2. Drag .mkv media file onto .bat file script
3. Check output

## What it does

- **Video is always stream-copied.** No quality loss, no re-encode. 4K and HDR pass through intact.
- **HEVC gets tagged `hvc1`.** ffmpeg defaults to `hev1`, which Apple TV / iOS / macOS refuse to direct play. Same bitstream, different fourcc.
- **Audio is copied** when it's already MP4-native (AAC / AC-3 / E-AC-3). Anything else (DTS, TrueHD, FLAC, Opus…) is converted to E-AC-3 at a bitrate matched to the channel count.
- **Every subtitle track is extracted** to a sidecar named the way Plex expects: `Movie.eng.forced.srt`, `Movie.jpn.ass`, etc. Text subs become `.srt` or `.ass`; bitmap subs (PGS/VobSub) are saved raw as `.sup`/`.idx`.
- **Chapters are preserved**, and `+faststart` is applied for instant seeking.
- **Output is verified** against the source duration before anything is deleted.

## Requirements

- **ffmpeg** and **ffprobe** on your `PATH` (required)
- **mkvextract** from [MKVToolNix](https://mkvtoolnix.download/) (optional — only needed for DVD/VobSub subtitles, which ffmpeg cannot write)

## Usage

Drag an MKV file **or a folder** onto the script. Folders are scanned recursively for `.mkv`.

Existing `.mp4` outputs are skipped, so re-running over a partially processed library is safe.

## Configuration

Edit the variables at the top of the file.

| Option | Default | Meaning |
|---|---|---|
| `DELETE_MODE` | `keep` | `keep` = never touch originals · `recycle` = send to Recycle Bin · `permanent` = delete outright |
| `KEEP_ALL_AUDIO` | `0` | `0` = first audio track only · `1` = all tracks |
| `EXTRACT_SUBS` | `1` | Write subtitle sidecars |
| `SUB_ASS_MODE` | `ass` | `ass` = keep styling losslessly · `srt` = convert (destroys typesetting) |
| `EXTRACT_IMAGE_SUBS` | `1` | Save PGS/VobSub tracks as `.sup`/`.idx` |
| `DURATION_TOLERANCE` | `2` | Max source/output duration difference, in seconds |

**Run with `DELETE_MODE=keep` first** and check the results before enabling deletion.

## Safety

Originals are only removed when *every* check passes:

1. ffmpeg exits clean
2. The output file exists and is readable
3. Output duration matches the source within `DURATION_TOLERANCE`
4. No subtitle track failed to extract

That last rule matters most — subtitles that fail to come out are gone forever once the MKV is deleted, so any failure vetoes the delete for that file. On mismatch, the suspect MP4 is left in place for inspection.

## Note on image subtitles

PGS and VobSub tracks are bitmaps, not text. Plex has to burn them in, which forces a full transcode — exactly what this script exists to avoid. They're saved so the data survives; run them through [Subtitle Edit](https://www.nikse.dk/subtitleedit) (free) to OCR them into real `.srt` files. A list of affected files is written to `%TEMP%` at theend of each run.

## Limitations

- Windows only.
- Lossy audio conversion for non-MP4-native codecs. Lossless tracks (TrueHD, FLAC) lose their lossless-ness; if that matters, keep the MKV.
- MP4 has no DTS/TrueHD support, hence the E-AC-3 fallback.

## External Resources

- FFmpeg: https://ffmpeg.org/
- MKVToolNix: https://mkvtoolnix.download/
