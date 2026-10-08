# Video playback in games (Apple-first media backend) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Windows games on MacNeutron play their videos and compressed audio: Media Foundation, xWMA, wmvcore and
DirectShow decode through Apple's VideoToolbox/AudioToolbox where Apple can, and a small LGPL FFmpeg for the rest.

**Architecture:** Wine's media front ends stay upstream. winedmo (upstream) demuxes Media Foundation file sources with
our FFmpeg. winegstreamer's PE side (upstream) is built without GStreamer and talks to our own macOS unix side behind
its 37-call ABI: decoders route H.264 to a `VTDecompressionSession`, AAC to `aac_at`, everything else to libavcodec;
phase 2 adds a libavformat parser for DirectShow and wmvcore.

**Tech Stack:** C (Wine unix side), VideoToolbox/CoreMedia/CoreVideo, FFmpeg 8.1.3 (libavformat, libavcodec, libavutil,
libswscale, libswresample), llvm-mingw test programs (ARM64, ARM64EC, x64), shell build/check scripts, Objective-C for
one host reference tool.

**Spec:** `docs/superpowers/specs/2026-10-08-macneutron-video-playback-design.md`

**Code maps (read the relevant one before each task; file:line references are at Wine tree HEAD = patch 0030):**
`.superpowers/brainstorm-video/maps/seam.md` (winegstreamer ABI, call semantics, media types, wine.inf, configure),
`maps/pipeline.md` (deps/build/bundle/licences/source archive), `maps/harness.md` (test programs, check.sh, clips,
today's failure codes), `maps/ffmpeg.md` (FFmpeg component names, config macros, dylib names). Research:
`.superpowers/brainstorm-video/best-solution.md`, `seams.md`, `build.md`.

## Global Constraints

- macOS 27 minimum, arm64 only; Wine 11.19 tree `build/wine-arm64-src/wine` (branch `macneutron`); patch series
  `wine-arm64/patches/wine`: new commits only, never rewrite an exported patch; export with `make wine-arm64-export`
  (afterwards `git status` shows only the new patch files); prove the series applies from a fresh fetch (shallow clone of
  wine-11.19, `git am` all patches N/N, `HEAD^{tree}` equals the applied tree's).
- FFmpeg 8.1.3, LGPL-2.1 only: never `--enable-gpl`/`--enable-nonfree`; never compiled in: FFmpeg's `h264`, `hevc` and
  `aac` decoders and the `videotoolbox` hwaccel. The compiled-in decoder set is exactly: `aac_at h263 indeo5 mp1float
  mp2float mp3float mpeg1video pcm_f32le pcm_s16le pcm_s24le pcm_s32le pcm_u8 vc1 wmalossless wmapro wmav1 wmav2
  wmavoice wmv1 wmv2 wmv3` (21). Demuxers: `asf avi mov mp3 mpegps mpegvideo wav`. Parsers: `h264 mpegaudio mpegvideo`.
  Bitstream filters: `aac_adtstoasc h264_mp4toannexb null`.
- H.264 decodes through `VTDecompressionSession` called directly; AAC through FFmpeg's `aac_at` (AudioToolbox).
- PE-side Wine changes are limited to: `dlls/winegstreamer/Makefile.in` (unix source swap), `loader/wine.inf.in`
  (`HKCU,Software\Wine\MediaFoundation,"DisableGstByteStreamHandler",0x10003,1` in `[Misc]`), the D3D11-awareness line
  in `dlls/winegstreamer/video_decoder.c` (~1659), and upstream's fix making `wg_transform_create_quartz` return errors.
- Errors: a format we don't decode or a stream VideoToolbox refuses yields the normal Media Foundation/DirectShow/wmvcore
  failure; never a crash or hang; each distinct failure logged once (`WARN` behind a once-flag).
- No new entitlements; builds need `MACNEUTRON_SIGN_IDENTITY="Developer ID Application: Chad Cormier Roussel (49QMZXLR8S)"`
  and `MACNEUTRON_PROVISIONING_PROFILE="$HOME/Downloads/Mac_Neutron.provisionprofile"`; the bundle gates (signing,
  minos 27.0, `@rpath`-only, x18 scan) stay green.
- Licences: FFmpeg's LGPL notice ships (`wine-arm64/licenses/NOTICES.md`, the licences README, `licences_test.sh`), its
  source is in the release source archive; our Wine patches are LGPL-2.1+.
- Test media: Wine's own clips read in place by `Z:` path, or clips generated at test time; nothing copyrighted
  committed; nothing downloaded without the maintainer's OK.
- Never push, tag, `gh`, notarize; never open MacNeutron.app, start/quit Steam, touch `~/Library/Application
  Support/MacNeutron/`, any game install or `steamapps/compatdata/`; no `pkill -f`; never use the maintainer's Terminal
  panel; games are launched only by the controller. Commits end with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **A cutscene skipped mid-way** (flush, then new data or destroy): no stale frame comes out after a flush, and the
   transform is reusable. Test: `media-mf` row `seek` (Task 3 audio, Task 4 video) checks the first frame after a seek.
2. **Truncated or corrupt video data**: decoding stops with an error or end of stream, never a crash or hang. Test:
   `media-mf` row `truncated` (Task 4) reads a copy of `test.mp4` cut to 60 % and expects a clean end/error within 5 s.
3. **A codec we don't ship (HEVC, VP9 in MP4)**: a clean `MF_E_TOPO_CODEC_NOT_FOUND`-class failure. Test: `media-mf`
   row `hevc` (Task 3) on an HEVC clip generated by `media-ref` (Task 3) expects the failure code, no crash.
4. **Long 1080p playback**: real-time decode and no memory growth (CVPixelBuffer/VT session leaks). Test: `media-mf`
   row `1080p` (Task 4) decodes a generated 1080p60 10 s clip three times: ≥ 60 fps and RSS growth < 32 MB from run 2 to 3.
5. **Two videos back to back in one transform** (a new SPS/resolution): a second `MF_E_TRANSFORM_STREAM_CHANGE`, correct
   new dimensions. Test: `media-mf` row `two-clips` (Task 4) drains after clip A (160x120) and pushes clip B (generated
   320x240), expects the stream change and 320x240 output.

---

### Task 1: FFmpeg in the build, winedmo demuxing, and the media check harness

**Files:**
- Modify: `wine-arm64/deps.pins` (FFmpeg pin), `wine-arm64/build.sh` (FFmpeg dep build ~171-236, Wine configure
  ~245-251, load-command check ~225-229), `wine-arm64/lib.sh` (~99 pin list), `wine-arm64/bundle.sh` (~83-86 `put`
  lines), `wine-arm64/licenses/NOTICES.md`, `wine-arm64/licenses/README`, `wine-arm64/tests/licences_test.sh`
  (~53-66, ~119-129), `release/source-archive.sh` (~74-76), `release/verify-sources.sh` (~93), `Makefile`,
  `wine-arm64/check.sh`
- Create: `wine-arm64/tests/arm64-media-mf.c` (+ x64 twin via a new `x64-media-%` pattern rule), `wine-arm64/tests/media-ref.m`

**Interfaces:**
- Produces: five dylibs in `wine.app/Contents/Resources/lib/wine/aarch64-unix/`: `libavutil.60.dylib`,
  `libavcodec.62.dylib`, `libavformat.62.dylib`, `libswscale.9.dylib`, `libswresample.6.dylib` (install names
  `@rpath/<name>`); Wine configured `--with-ffmpeg --without-gstreamer`; `FFMPEG_LIBS` plus `-lswscale -lswresample` for
  later tasks. Test program contract (all later media tests): prints stage lines then exactly `PASS <exe basename>` or
  `FAIL <exe basename>: stage=<stage> hr=0x%08x`; rows are selected by argv[1]. check.sh steps `media-mf`, `media-engine`,
  `media-xwma`, `media-wm`, `media-ds` in a `MEDIA` list (accepted by name, excluded from the full run while red);
  `make media-check`. Host tool `media-ref` (built for macOS): `media-ref hash-nv12 <file>` prints the hex SHA-256 of all
  decoded frames' visible Y then UV rows via AVAssetReader; `media-ref make-clip <h264|hevc> <w>x<h> <fps> <frames> <out.mp4>`
  writes a synthetic clip with AVAssetWriter (frame n: a gradient with a moving bar).

- [ ] **Step 1: Write the failing check.** `wine-arm64/tests/licences_test.sh`: an FFmpeg row requiring `libavcodec*`
  etc. in the bundle to be matched by an FFmpeg section in NOTICES.md and the README (own `FFmpeg` string; "Intel"/other
  strings don't satisfy it). `arm64-media-mf.c` row `open`: MFCreateSourceReaderFromURL on
  `Z:<B>/wine-arm64-src/wine/dlls/mfreadwrite/tests/test.mp4`, select video + audio, set video output NV12 and audio PCM,
  read the first video sample; stages `open`, `video-type`, `audio-type`, `read`.
- [ ] **Step 2: Run it to see it fail.** `make media-check` (only `media-mf` exists yet; `media-wm` joins in Task 2, `media-xwma` in Task 3,
  `media-engine` in Task 4, `media-ds` in Task 5). Expected:
  `FAIL arm64-media-mf.exe: stage=open hr=0xc00d36c4` (and the x64 twin the same); licences_test passes (no FFmpeg yet).
- [ ] **Step 3: Implement the FFmpeg dep.** Pin `https://ffmpeg.org/releases/ffmpeg-8.1.3.tar.xz` (SHA-256 taken at pin
  time with `shasum -a 256` after a gpg check of its `.asc`). Configure one option per word: `--arch=aarch64
  --target-os=darwin --cc=clang --enable-shared --disable-static --disable-programs --disable-doc --disable-network
  --disable-autodetect --disable-everything --disable-iconv --disable-videotoolbox --disable-stripping
  --enable-audiotoolbox --enable-swscale --enable-swresample` plus the `--enable-decoder=`/`--enable-demuxer=`/
  `--enable-parser=`/`--enable-bsf=` lists from Global Constraints, `--extra-cflags=-mmacosx-version-min=27.0` and
  `--extra-ldflags=-mmacosx-version-min=27.0`, `--prefix=$DEPS`. After configure: `sed "s|$SRC/|/|g"` on `config.h`;
  fail the step on configure output containing `did not match anything` or `not all dependencies are satisfied`. After
  `make install`: per library `mv lib<x>.<major>.*.*.dylib lib<x>.<major>.dylib` and `ln -sfn lib<x>.<major>.dylib
  lib<x>.dylib`, then the existing `deps_post` (`@rpath` names). Checks that fail the build:
  `grep -x '#define CONFIG_GPL 0'` and `'#define CONFIG_VIDEOTOOLBOX 0'` in `config.h`; in `config_components.h`
  `'#define CONFIG_H264_DECODER 0'`, `CONFIG_HEVC_DECODER 0`, `CONFIG_AAC_DECODER 0` (whole lines); the set of
  `#define CONFIG_*_DECODER 1` names equals the 21-name list (likewise demuxers, parsers, bsfs); `grep -a -c -F "$B"` is
  0 in each dylib. Allow `@rpath/libavutil.60.dylib`, `@rpath/libavcodec.62.dylib`, `@rpath/libswresample.6.dylib`
  (whatever libavformat/libavcodec/libswscale actually link) in the load-command check for the FFmpeg dylibs only.
  Bundle: one `put` per dylib beside `winedmo.so`. Licences: an FFmpeg section (LGPL-2.1-or-later, version, source URL)
  in NOTICES.md and the README; FFmpeg in `lib.sh`'s pin list, `source-archive.sh`'s copy loop and `verify-sources.sh`.
- [ ] **Step 4: Configure Wine** with `--with-ffmpeg --without-gstreamer`, `FFMPEG_CFLAGS`/`FFMPEG_LIBS` from `$DEPS`
  pkg-config only; no `$DEPS` rpath (winedmo.so already has `@loader_path/`). check.sh `media-mf` sets
  `HKCU\Software\Wine\MediaFoundation\DisableGstByteStreamHandler=1` in its prefix before running (Task 2 replaces this
  with a query of the wine.inf default).
- [ ] **Step 5: Run it to see the transition.** `make wine-arm64 && make media-check`. Expected:
  `FAIL arm64-media-mf.exe: stage=video-type hr=0xc00d5212` (demux works, no decoder yet), x64 the same;
  `make wine-arm64-check` (bundle gates incl. x18 and minos), licences_test, `make test`, `make smoke` 15/15,
  `make bridge-check` all pass. Record the five dylib sizes.
- [ ] **Step 6: Commit** (repo): `media: FFmpeg 8.1.3 (LGPL, demux + non-Apple codecs) and the media check harness`.
  No Wine patch yet (configure flags only live in build.sh).

### Task 2: winegstreamer with our macOS unix side (skeleton), the registry default and the PE line

**Files:**
- Modify (Wine tree): `dlls/winegstreamer/Makefile.in` (SOURCES: drop `unixlib.c wg_allocator.c wg_format.c
  wg_media_type.c wg_muxer.c wg_parser.c wg_transform.c`, add ours; `UNIX_LIBS = $(FFMPEG_LIBS) -lswscale -lswresample
  -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework CoreFoundation`), `loader/wine.inf.in`
  (`[Misc]`), `dlls/winegstreamer/video_decoder.c` (~1659), `dlls/winegstreamer/main.c` (upstream's quartz error fix)
- Create (Wine tree): `dlls/winegstreamer/mac_private.h`, `mac_unixlib.c`, `mac_transform.c`, `mac_parser.c`
- Modify (repo): `wine-arm64/build.sh` (`--enable-winegstreamer`), `wine-arm64/check.sh`, `Makefile`
- Create (repo): `wine-arm64/tests/arm64-media-wm.c` (+ x64 twin)

**Interfaces:**
- Consumes: Task 1's `FFMPEG_LIBS`, the harness contract.
- Produces (`mac_private.h`, used by Tasks 3-5):
  ```c
  struct mac_transform;                       /* behind wg_transform_t */
  struct mac_decoder_ops
  {
      HRESULT (*open)(struct mac_transform *t);   /* lazy: called once the input type carries what the codec needs */
      HRESULT (*send)(struct mac_transform *t, struct mac_packet *packet);
      HRESULT (*receive)(struct mac_transform *t, struct wg_sample *sample, BOOL *format_changed);
      void (*drain)(struct mac_transform *t);
      void (*flush)(struct mac_transform *t);
      void (*close)(struct mac_transform *t);
  };
  struct mac_packet { BYTE *data; UINT32 size; INT64 pts, duration; UINT32 flags; struct list entry; };
  const struct mac_decoder_ops *mac_decoder_for(const struct wg_media_type *input);  /* NULL = unsupported */
  ```
  `mac_transform.c` owns the input queue (packets copied at push; `MF_E_NOTACCEPTING`/`accepts_input` from queue length
  per seam.md §4.4), output type state and the two-call `get_output_type` protocol, `align_video_info_planes`-compatible
  plane layout (copied from upstream `wg_transform.c:106-196`), and dispatch to `mac_decoder_ops`. `mac_unixlib.c` holds
  both dispatch tables in upstream's order (the wow64 block copied from `wg_parser.c:2000-2396`) and `init`.
  `mac_parser.c`: in this task every `wg_parser_*` returns failure from `wg_parser_create` (callers then return
  `E_OUTOFMEMORY` without starting a read thread); muxer/other calls return `STATUS_NOT_SUPPORTED`.

- [ ] **Step 1: Write the failing tests.** `arm64-media-wm.c` row `open`: `LoadLibrary("wmvcore")`, `WMCreateSyncReader`,
  `IWMSyncReader_Open` on `Z:<B>/wine-arm64-src/wine/dlls/wmvcore/tests/test.wmv` under `__try`; PASS when Open returns
  a failure HRESULT (phase 1), FAIL on an exception (`stage=open hr=<exception code>`). `media-mf` row `wine-inf`: the
  prefix's `DisableGstByteStreamHandler` is 1 without check.sh setting it.
- [ ] **Step 2: Run to see them fail.** Expected: `FAIL arm64-media-wm.exe: stage=open hr=0x80000100` (delay-load
  exception), `media-mf wine-inf` fails.
- [ ] **Step 3: Implement** the Makefile swap, `--enable-winegstreamer` in build.sh, the skeleton files (transform calls
  return `MF_E_TOPO_CODEC_NOT_FOUND`-class failure via `mac_decoder_for` returning NULL for everything in this task;
  `wg_transform_create` rejects the NV12→H.264 encoder pair), the wine.inf line, `MF_SA_D3D11_AWARE` no longer set by the
  video decoder, the quartz fix. Remove check.sh's own registry write.
- [ ] **Step 4: Run.** Expected: `media-wm open` PASS (clean `E_OUTOFMEMORY`-class failure), `media-mf wine-inf` PASS,
  `media-mf open` still `stage=video-type hr=0xc00d5212`. Gates: `make wine-arm64-check`, `make test`, `make smoke`, `make bridge-check`.
- [ ] **Step 5: Commit** in the Wine tree (one commit per logical change: the unix skeleton + Makefile, the wine.inf
  default, the D3D11 line, the quartz fix), export (only the new patches), fresh-fetch proof, repo commit.

### Task 3: Decoders on libavcodec and AudioToolbox (everything except H.264)

**Files:**
- Create (Wine tree): `dlls/winegstreamer/mac_av.c` (libavcodec decoders, `aac_at`, swscale/swresample),
  `dlls/winegstreamer/mac_media_type.c` (`wg_media_type` ↔ `AVCodecParameters`/output formats; GUIDs via
  `DEFINE_MEDIATYPE_GUID` as upstream `wg_media_type.c:58-64`)
- Modify (Wine tree): `mac_transform.c` (`mac_decoder_for` routes the codecs below), `mac_private.h`
- Create (repo): `wine-arm64/tests/arm64-media-xwma.c` (+ x64 twin)
- Modify (repo): `wine-arm64/tests/arm64-media-mf.c`, `wine-arm64/check.sh`, `Makefile` (`media-xwma` in `media-check`)

**Interfaces:**
- Consumes: Task 2's `mac_decoder_ops`, `mac_packet`, `mac_transform`.
- Produces: `extern const struct mac_decoder_ops mac_av_ops;` serving: audio WMA v1/v2/Pro/Lossless/Voice (`wmav1 wmav2
  wmapro wmalossless wmavoice`), MP1/2/3 (`mp*float`), PCM, AAC (`aac_at`, with `aac_adtstoasc` when the input is ADTS);
  video WMV1/2/3, VC-1 (`wmv1 wmv2 wmv3 vc1`), MPEG-1 (`mpeg1video`, from `struct mpeg_video_format`), Indeo 5.
  Output via libswresample to the negotiated `WAVEFORMATEX` (S16/S32/Float32) and via libswscale to the negotiated video
  subtype (NV12, I420, YV12, YUY2, UYVY, RGB32) in upstream's plane layout. Codec data location per codec: seam.md §4.2
  table. Decoders open lazily (`open`) when codec data/dimensions arrive (create must succeed on probe types).

- [ ] **Step 1: Write the failing tests.** `arm64-media-xwma.c` row `play`: XAudio2 `CreateSourceVoice` with the xWMA
  format of entry 2 of `Z:<B>/wine-arm64-src/wine/dlls/xactengine3_7/tests/test.xwb` (stereo 44100 Hz, block align
  2230, 6000 B/s, data at offset 25600, 4460 bytes, seek table {57344, 92160}), submit the buffer with the seek table,
  count decoded frames through a submix/voice callback: 23040 samples ±1024 (today: `stage=create hr=0xfffffffe`, wmadmod
  can't load; after Task 2: a clean create failure). `media-mf` row `aac`:
  the audio stream of `test.mp4` to PCM S16: total 44100 samples ±1024 at 44100 Hz stereo. `media-mf` row `wmv`: the same
  reader on `test.wmv`: WMV1 64x48 frames whose count equals the duration 20460000 × frame rate (pin on first GREEN, stated
  in the report) and per-colour-bar means ±8 against `media-ref`-independent expectations from Wine's `wmvcore/tests`;
  WMA v1 mono samples > 0. `media-mf` row `seek` (audio): seek to 0.5 s, the first sample's time is within one frame of
  0.5 s and no sample from before the seek arrives. `media-mf` row `hevc`: an HEVC clip made by `media-ref make-clip hevc
  160x120 25 25` expects `stage=video-type` with `0xc00d5212`, no crash (Review Focus 3).
- [ ] **Step 2: Run to see them fail** (expected: `play` fails at `create`, `aac`/`wmv` at their type/decode stage; `hevc`
  already passes — it guards, it isn't a RED row).
- [ ] **Step 3: Implement `mac_av_ops`** and the routing; drain returns remaining frames then
  `MF_E_TRANSFORM_NEED_MORE_INPUT`; flush discards decoder state and queued packets (`avcodec_flush_buffers`); output
  type changes are reported as `MF_E_TRANSFORM_STREAM_CHANGE` with the new type available from `get_output_type`.
- [ ] **Step 4: Run.** All rows PASS on ARM64 and x64; `media-wm open` still PASS; gates as Task 2.
- [ ] **Step 5: Commit** (Wine tree), export, fresh-fetch proof, repo commit.

### Task 4: H.264 on VideoToolbox, and Media Engine playback into a DXMT texture

**Files:**
- Create (Wine tree): `dlls/winegstreamer/mac_vt.c`
- Modify (Wine tree): `mac_transform.c` (route H.264), `mac_private.h`
- Create (repo): `wine-arm64/tests/arm64ec-media-engine.c` (+ explicit x64 rule; runs with `dxmt_run`, added to
  `NEEDS_DXMT` before check.sh:45)
- Modify (repo): `wine-arm64/tests/arm64-media-mf.c`, `wine-arm64/check.sh`, `wine-arm64/tests/media-ref.m`

**Interfaces:**
- Consumes: Task 2's `mac_decoder_ops`; `media-ref hash-nv12`, `make-clip`.
- Produces: `extern const struct mac_decoder_ops mac_vt_h264_ops;`: input H.264 Annex B (from winedmo's
  `h264_mp4toannexb`) converted to length-prefixed NALs with the SPS/PPS kept in a `CMVideoFormatDescription` (rebuilt and
  the session recreated when they change); `VTDecompressionSessionDecodeFrame` with no flags (synchronous output
  callback); a display-order queue keyed on PTS, depth from the SPS's `max_num_reorder_frames`/`max_dec_frame_buffering`
  (fallback 16); output pixel format requested from VideoToolbox per negotiated subtype (`420v` NV12, `y420` I420, `yuvs`
  YUY2, `2vuy` UYVY; libswscale from NV12 for others); each `CVPixelBuffer` locked, copied into the `wg_sample` in
  upstream's plane layout, unlocked and released before `receive` returns. First output: `MF_E_TRANSFORM_STREAM_CHANGE`
  with dimensions rounded up to 16 and the real-size aperture (seam.md §4.4). A refused session/format: the once-logged
  WARN and an `MF_E_INVALIDMEDIATYPE`-class failure.

- [ ] **Step 1: Write the failing tests.** `media-mf` row `h264`: 25 frames, aperture 160x120, and the SHA-256 of all
  visible Y then UV rows equals `media-ref hash-nv12 test.mp4` (computed by check.sh at run time). Rows `seek` (video:
  first frame after a seek to 0.5 s is the frame at 0.5 s per its PTS), `truncated` (Review Focus 2), `two-clips`
  (Review Focus 5, clip B from `make-clip h264 320x240 30 30`), `1080p` (Review Focus 4, clip from `make-clip h264
  1920x1080 60 600`). `arm64ec-media-engine.c`: `IMFMediaEngine` with a DXMT D3D11 device plays `test.mp4` and
  `TransferVideoFrame`s each frame into a B8G8R8A8 texture; PASS when ≥ 20 frames arrive and the first frame's centre
  pixel is within ±8 of the AVAssetReader frame's (converted) colour.
- [ ] **Step 2: Run to see them fail** (expected: `stage=video-type hr=0xc00d5212` for the H.264 rows; media-engine at
  its playback stage with the error event's code).
- [ ] **Step 3: Implement `mac_vt_h264_ops`** and the routing.
- [ ] **Step 4: Run.** All rows PASS on ARM64 and x64 (media-engine on ARM64EC and x64); record the `1080p` fps and RSS
  numbers and the Media Engine 1080p cost in the report. Gates as Task 2.
- [ ] **Step 5: Commit** (Wine tree), export, fresh-fetch proof, repo commit.

### Task 5: The parser on libavformat (DirectShow and wmvcore playback)

**Files:**
- Modify (Wine tree): `dlls/winegstreamer/mac_parser.c` (the 19 `wg_parser_*` calls), `mac_private.h`
- Create (repo): `wine-arm64/tests/arm64-media-ds.c` (+ x64 twin)
- Modify (repo): `wine-arm64/tests/arm64-media-wm.c`, `wine-arm64/check.sh`, `Makefile` (`media-ds` in `media-check`)

**Interfaces:**
- Consumes: Task 3/4 decoders through `mac_decoder_for` (the parser's output streams feed them; no second decoder path).
- Produces: `wg_parser_*` per seam.md §5.3 on an `AVIOContext` fed by `get_next_read_offset`/`push_data` (the read
  request blocks on a condition variable like upstream — never spins); streams expose their `wg_media_type`, seeking via
  `av_seek_frame`, EOS reported per stream.

- [ ] **Step 1: Write the failing tests.** `media-wm` row `play`: sync reader reads `test.wmv` to the end: video frames
  64x48 RGB (count and per-bar means as Task 3's `wmv`), audio samples > 0, clean `NS_E_NO_MORE_SAMPLES`. `media-ds`:
  qasf's WM ASF Reader + sample grabbers on `test.wmv`, and quartz on an MPEG-1 clip if Wine's tree has one (else the
  WMV graph only): graph runs to `EC_COMPLETE`, frames > 0.
- [ ] **Step 2: Run to see them fail** (`media-wm play` fails at open with Task 2's clean error; `media-ds` at graph
  build).
- [ ] **Step 3: Implement the parser.**
- [ ] **Step 4: Run.** All media rows PASS; gates as Task 2.
- [ ] **Step 5: Commit** (Wine tree), export, fresh-fetch proof, repo commit.

### Task 6: VC-1 and WMA Pro rows, docs, and the in-game check

**Files:**
- Modify (repo): `wine-arm64/tests/arm64-media-mf.c`, `arm64-media-xwma.c`, `wine-arm64/check.sh`, `README.md`,
  `docs/testing/acceptance-arm64-release.md`

- [ ] **Step 1: Pick the clips.** From the pinned FFmpeg source's `tests/fate/vc1.mak` and `tests/fate/wma.mak`, choose one
  VC-1/WMV3 sample and one WMA Pro sample of the FATE suite; name the exact URLs and sizes in the report and STOP for the
  controller to get the maintainer's OK before any download. Downloaded clips live under `build/media-samples/` (git-ignored),
  never committed; the rows print `SKIP` (not PASS) when the files are absent.
- [ ] **Step 2: Rows.** `media-mf` row `vc1` (frame count and dimensions from the sample's FATE reference, `.framecrc`
  first-frame dimensions), `media-xwma` or `media-mf` row `wmapro` (sample count within ±1 frame of FATE's reference).
- [ ] **Step 3: Docs.** README: video playback support and its formats; the acceptance note: the media rows, dylib sizes,
  the 1080p numbers. Privacy scan before the doc commit.
- [ ] **Step 4: In-game check (controller with the maintainer).** A game whose videos go through Media Foundation:
  videos play; a Metal System Trace shows VideoToolbox decode work and no libavcodec H.264 symbols. Record in the
  acceptance note.
- [ ] **Step 5: Commit** (repo).
