// Media Foundation's source reader (video playback spec §8), one row per run, named by the first argument. Also built
// as x64-media-mf.exe, which runs under FEX: games are x64. Each stage that passes prints a line; the last line is
// PASS <name>, or FAIL <name>: stage=<stage> hr=0x<HRESULT>.
//   open <test.mp4>  Wine's dlls/mfreadwrite/tests/test.mp4 (H.264 + AAC) by its Z: path: open it, select its first
//                    video and audio streams, ask for NV12 video and PCM audio, read the first video sample. Stages:
//                    open, video-type, audio-type, read.
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <stdio.h>
#include <string.h>

#ifdef __aarch64__
#define NAME "arm64-media-mf"
#else
#define NAME "x64-media-mf"
#endif

static int fail(const char *stage, HRESULT hr) {
  printf("FAIL " NAME ": stage=%s hr=0x%08lx\n", stage, (unsigned long)hr);
  return 1;
}

// Selects the stream and asks for <subtype> out of it (the source reader adds a decoder if it needs one).
static HRESULT want(IMFSourceReader *reader, DWORD stream, const GUID *major, const GUID *subtype) {
  IMFMediaType *type;
  HRESULT hr = IMFSourceReader_SetStreamSelection(reader, stream, TRUE);
  if (FAILED(hr) || FAILED(hr = MFCreateMediaType(&type))) return hr;
  IMFMediaType_SetGUID(type, &MF_MT_MAJOR_TYPE, major);
  IMFMediaType_SetGUID(type, &MF_MT_SUBTYPE, subtype);
  hr = IMFSourceReader_SetCurrentMediaType(reader, stream, NULL, type);
  IMFMediaType_Release(type);
  return hr;
}

static int row_open(const char *path) {
  WCHAR url[MAX_PATH];
  IMFSourceReader *reader;
  IMFSample *sample = NULL;
  DWORD index, flags = 0;
  LONGLONG time = 0;
  HRESULT hr;

  MultiByteToWideChar(CP_ACP, 0, path, -1, url, MAX_PATH);
  if (FAILED(hr = MFCreateSourceReaderFromURL(url, NULL, &reader))) return fail("open", hr);
  printf("open ok\n");
  if (FAILED(hr = want(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, &MFMediaType_Video, &MFVideoFormat_NV12)))
    return fail("video-type", hr);
  printf("video-type ok\n");
  if (FAILED(hr = want(reader, MF_SOURCE_READER_FIRST_AUDIO_STREAM, &MFMediaType_Audio, &MFAudioFormat_PCM)))
    return fail("audio-type", hr);
  printf("audio-type ok\n");
  hr = IMFSourceReader_ReadSample(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &index, &flags, &time, &sample);
  if (SUCCEEDED(hr) && !sample) hr = E_FAIL;  // flags say why: end of stream, error, a type change
  if (FAILED(hr)) {
    printf("read: flags 0x%lx\n", flags);
    return fail("read", hr);
  }
  printf("read ok: stream %lu, time %lld\n", index, time);
  IMFSample_Release(sample);
  IMFSourceReader_Release(reader);
  return 0;
}

int main(int argc, char **argv) {
  HRESULT hr;
  int rc;
  setvbuf(stdout, NULL, _IONBF, 0);  // a crash keeps what was printed before it
  if (argc != 3 || strcmp(argv[1], "open")) {
    printf("FAIL " NAME ": usage: " NAME ".exe open <Z: path to test.mp4>\n");
    return 1;
  }
  if (FAILED(hr = CoInitializeEx(NULL, COINIT_MULTITHREADED)) || FAILED(hr = MFStartup(MF_VERSION, MFSTARTUP_FULL)))
    return fail("open", hr);
  rc = row_open(argv[2]);
  MFShutdown();
  if (rc == 0) printf("PASS " NAME "\n");
  return rc;
}
