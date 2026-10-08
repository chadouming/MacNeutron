# MacNeutron: video playback in games (Apple-first media backend)

Status: draft for the maintainer's review (2026-10-08).

## 1. Goal

Windows games on MacNeutron play their videos and compressed audio: intros, cutscenes, in-game video panels and
XAudio2 xWMA sound. Apple's frameworks decode what they can (H.264 on VideoToolbox, AAC on AudioToolbox, in hardware
where Apple does); a small LGPL FFmpeg covers the containers and codecs Apple can't. Games keep calling the Windows
APIs they call on Windows; nothing changes for them. This is future-proofing: no known game fails today because of it.

First of three coverage sub-projects (video → 32-bit games → D3D9); Vulkan comes after them.

## 2. Where we are (Wine 11.19 on our runtime)

- Wine is configured without FFmpeg and GStreamer. Wine's media front ends work (Media Foundation's source reader,
  media engine and session; DirectShow/quartz; wmvcore; XAudio2/FAudio), but nothing under them decodes.
- `winedmo` (FFmpeg) only demuxes: its API is the 8 `winedmo_demuxer_*` calls. Every decoder — H.264, WMV, AAC, WMA,
  DirectShow's splitters and MPEG decoders, Indeo — goes through `winegstreamer`, which our build doesn't build.
- Today Media Foundation fails to open an MP4 (`MF_E_UNSUPPORTED_BYTESTREAM_TYPE`), H.264/AAC decoder creation fails,
  and wmvcore (which delay-imports winegstreamer) raises a non-continuable exception instead of failing cleanly.
- Upstream keeps winegstreamer (2026 fixes from several authors); its 37 unix calls (`dlls/winegstreamer/unixlib.h`)
  pass Windows types (MFVIDEOFORMAT, WAVEFORMATEX), not GStreamer types — a stable seam. winedmo isn't gaining
  decoders upstream.
- DXMT has no NV12/P010 textures and no `ID3D11VideoDevice`.

## 3. Decisions (maintainer, 2026-10-08)

- Apple frameworks first: H.264 through `VTDecompressionSession` called directly (we ship no H.264/HEVC decoder code
  of our own); AAC through AudioToolbox (FFmpeg's `aac_at`).
- A small LGPL-2.1 FFmpeg for what Apple can't do. FFmpeg's own H.264, HEVC and AAC decoders are never compiled in.
- WMV3/VC-1 is included: the maintainer's position is that a free GitHub download doesn't count as a "unit" under
  Via LA's VC-1 terms. WMA Pro, WMA Lossless and WMA Voice are included too (maintainer's call). This spec records
  those decisions; it is not legal advice.
- Not Microsoft's own Media Foundation DLLs (not redistributable, and x64 software decoding under emulation).
- Not GStreamer (would still need FFmpeg for WMV/WMA, and a large bundle). Not Madeira's GPL-3 code (reference only).

## 4. Architecture

```
game ──► Windows APIs (Wine, unchanged): Media Foundation · DirectShow (quartz) · wmvcore · XAudio2/FAudio (xWMA)
            │ file sources (MF)                         │ decoders (MFTs, DMOs, DirectShow filters)
            ▼                                           ▼
   winedmo (upstream, + our FFmpeg)        winegstreamer PE side (upstream) ──37 unix calls──► OUR mac unix side
     libavformat demux                                                                         ├─ H.264 → VideoToolbox
                                                                                               ├─ AAC   → AudioToolbox (aac_at)
                                                                                               └─ rest  → libavcodec (+ swscale/swresample)
```

- **winedmo**, unchanged upstream code built with our FFmpeg, serves Media Foundation's file sources. A Wine patch makes
  it the default (`HKCU\Software\Wine\MediaFoundation` `DisableGstByteStreamHandler`=1 in the prefix's default
  registry, wine.inf).
- **winegstreamer**: upstream's PE side stays as it is; its build file swaps the GStreamer unix files for ours (upstream's
  stay in the tree, unbuilt, so a rebase conflicts only on `Makefile.in`). Built with `--enable-winegstreamer` and no
  GStreamer (if configure refuses, a configure patch).
- **Our unix side** implements:
  - the 10 `wg_transform_*` calls (phase 1): one transform object routing by input type. H.264: a `VTDecompressionSession`
    used synchronously (no decode flags, so the output callback runs before `DecodeFrame` returns: no stray threads),
    Annex B → length-prefixed NAL conversion, a display-order queue, output in the format the PE side negotiated (NV12,
    I420, YUY2, UYVY straight from VideoToolbox), copied into Wine's sample buffer (one copy per plane). AAC: libavcodec
    `aac_at`. Everything else: libavcodec, with libswscale/libswresample for output-format conversion.
  - the 19 `wg_parser_*` calls: stubs that fail cleanly in phase 1 (so wmvcore returns an error instead of crashing);
    implemented on libavformat in phase 2, reusing the phase-1 decoders.
  - the remaining calls: clean "unsupported".
- **One PE-side change**: the H.264 decoder stops advertising D3D11 awareness (`MF_SA_D3D11_AWARE`,
  `dlls/winegstreamer/video_decoder.c` ~1659), so frames stay in system memory; Media Engine converts NV12 to BGRA and
  uploads to a B8G8R8A8 texture, which DXMT supports.
- Callers: 64-bit games (ARM64 and x64 under FEX through ARM64X DLLs). 32-bit callers come with the 32-bit sub-project
  (the WoW64 thunks exist).

## 5. Formats in v1

| Format | Engine | Basis |
|---|---|---|
| H.264 video | VideoToolbox (direct) | Apple-licensed decoder; no H.264 decoder code of ours |
| AAC audio | AudioToolbox (`aac_at`) | Apple-licensed decoder |
| MP4/MOV, ASF, AVI, WAV, MPEG-PS, MP3 containers | FFmpeg (libavformat) | containers; ASF's patent expired 2017 |
| WMV1, WMV2, H.263 (pulled in by WMV1/2), MPEG-1 video, Indeo 5 | FFmpeg | expired or pre-2001 |
| WMV3 / VC-1 | FFmpeg | maintainer's decision (§3) |
| WMA v1/v2 | FFmpeg | pre-2001 |
| WMA Pro, WMA Lossless, WMA Voice | FFmpeg | maintainer's decision (§3) |
| MP1/MP2/MP3, PCM | FFmpeg | expired |

Not in v1: HEVC (Wine has no HEVC decoder MFT; needs Wine patches — later), VP8/VP9/Theora/Vorbis/Opus/AV1 (no Wine
11.19 front end reaches them; add when one does), `ID3D11VideoDevice`/D3D11VA and NV12 in DXMT. Bink, CRI Sofdec and
similar middleware decode inside the game and need nothing from us.

## 6. Build and ship

- FFmpeg 8.1.3 pinned in `wine-arm64/deps.pins`, built into `$DEPS` like gnutls: `--disable-everything`, LGPL only (no
  `--enable-gpl`/`--enable-nonfree`), the demuxers and decoders of §5, the `h264` parser and the `h264_mp4toannexb` and
  `null` bitstream filters (winedmo uses them; they don't decode), `--enable-audiotoolbox` for `aac_at`, swscale and
  swresample, no encoders, network, devices, programs or `videotoolbox` hwaccel; macOS 27 minimum, arm64.
- Build checks (fail the build): `CONFIG_H264_DECODER`, `CONFIG_HEVC_DECODER`, `CONFIG_AAC_DECODER` and
  `CONFIG_VIDEOTOOLBOX` are 0; the set of `CONFIG_*_DECODER 1` lines equals the expected list; FFmpeg's embedded
  configure line carries no build path (scrubbed after configure; the release build-path check stays green).
- `@rpath` install names (FFmpeg's versioned-name symlink resolved before `deps_post`), the five dylibs (avutil, avcodec,
  avformat, swscale, swresample) beside `winedmo.so`/`winegstreamer.so` in `aarch64-unix/`, the nested `@rpath` links
  allowed in build.sh's load-command check, signed with the hardened runtime and a timestamp, the x18 scan clean.
  About 3-5 MB.
- `winegstreamer.so` links VideoToolbox, CoreMedia and CoreVideo (system frameworks; no new entitlement).
- Licences: FFmpeg's LGPL notice in `wine-arm64/licenses/NOTICES.md` and the licences README, a `licences_test.sh` check
  that fails without it, FFmpeg's source in the release source archive (`release/source-archive.sh`,
  `verify-sources.sh`, `lib.sh` pin lists). Our Wine patches stay LGPL-2.1+.
- `wine-arm64/build.sh`: pkg-config limited to `$DEPS`, `--with-ffmpeg`, `--enable-winegstreamer`.

## 7. Errors

- A format we don't decode, or a stream VideoToolbox refuses: the normal Media Foundation/DirectShow/wmvcore failure
  (e.g. `MF_E_TOPO_CODEC_NOT_FOUND`, a failed `SetOutputType`), so the game can skip the video. Never a crash or hang;
  each distinct failure logged once (`WARN` behind a once-flag).
- xWMA formats we can't decode: FAudio's existing failure path (silence on that voice).
- No silent software fallback for H.264/AAC (none is shipped).

## 8. Testing

- New Windows test programs, built for ARM64 and x64, run by a new `make media-check`; each fails first on today's build
  with its recorded error, then passes:
  - `media-mf`: Media Foundation source reader on Wine's synthetic `mfreadwrite/tests/test.mp4` (H.264 + AAC, 160x120, 25
    frames): frame count, dimensions, a bit-exact hash of the visible Y/UV rows, audio sample count (±1024 for
    priming), one seek.
  - `media-engine`: Media Engine playback of the same clip into a DXMT texture (frames arrive, BGRA).
  - `media-xwma`: XAudio2 playing xWMA in WMA v2 and WMA Pro.
  - `media-wm`: wmvcore on Wine's `wmvcore/tests/test.wmv` (WMV1 + WMA v1): phase 1 a clean error (today a crash);
    phase 2 frames and samples (per-colour-bar means ±8, sample counts).
  - `media-ds` (phase 2): DirectShow playback of `.wmv`/`.mpg` through a sample grabber.
- Test media is read in place from the Wine tree by `Z:` path; nothing copyrighted is committed. WMV3/VC-1 and WMA Pro
  have no FFmpeg encoder and no Wine clip: one small freely licensed sample is picked during planning, and fetched only
  with the maintainer's OK.
- The bundle, licences, smoke and bridge checks keep passing.
- In-game acceptance (the maintainer): a game whose videos go through Media Foundation (MP4/H.264), checked for playback
  and hardware decode (a GPU trace shows VideoToolbox, not CPU decoding).

## 9. Phases

0. FFmpeg built, bundled, licensed and in the source archive (2-3 days).
1. `wg_transform` on VideoToolbox/AudioToolbox/libavcodec; parser stubs; the registry default; the one-line PE change;
   `media-mf`, `media-engine`, `media-xwma`, `media-wm` (clean error) (2-4 weeks).
2. `wg_parser` on libavformat: DirectShow and wmvcore playback; `media-wm` frames, `media-ds` (2-3 weeks).

## 10. Risks

- `--enable-winegstreamer` without GStreamer may need a configure patch (ship the regenerated `configure`).
- Which output formats VideoToolbox accepts for each negotiated type is known only at the first run (NV12 is certain).
- The display-order queue depth for H.264 (read from the stream or let VideoToolbox reorder) — settled in phase 1.
- The H.264 reorder and VideoToolbox's buffer pool must never hand Wine a frame VideoToolbox may still reuse (copy
  before releasing the `CVPixelBuffer`).
- FFmpeg's NEON code for the decoders we enable isn't yet x18-scanned (FFmpeg's assembly maps x18 to an error, and
  Steam's arm64 FFmpeg scans clean); the bundle gate checks it at the first build.
- Media Engine's three copies (VideoToolbox → NV12, NV12 → BGRA, upload) at 1080p: measured in phase 1.

## 11. Out of scope

32-bit callers (next sub-project), D3D9 (the one after), Vulkan, HEVC, NV12/D3D11VA in DXMT, VP8/VP9/Theora/Vorbis/
Opus/AV1 until a Wine front end reaches them, Bink/Sofdec (in-game decoders), Microsoft's own media DLLs.
