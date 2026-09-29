// dxil-translate <folder>: translates every .dxil in <folder> with airconv and hands it to Metal (DXIL translator
// plan, Task 5). Compute: a compute pipeline; vertex: a vertex pipeline with rasterization off; pixel: a render
// pipeline with a pass-through vertex function. The root signature comes from each shader's own resources.
#import <Metal/Metal.h>
#define BOOL WIN_BOOL // airconv's Windows headers define BOOL as int; Objective-C's is signed char
#include "airconv_public.h"
#include "dxbc_converter.hpp"
#include "dxil/dxil_public.h"
#undef BOOL
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

using namespace dxmt::dxil;

namespace {

std::string ErrorText(sm50_error_t error) {
  char buffer[4096];
  SM50GetErrorMessage(error, buffer, sizeof(buffer));
  SM50FreeError(error);
  return buffer;
}

std::string FirstLine(std::string s) {
  auto end = s.find('\n');
  return end == std::string::npos ? s : s.substr(0, end);
}

// A DXBC container with an RTS0 (root signature 1.0) part: one descriptor table per resource range, visible to all
// stages, each range at offset 0 of its own table (so an unbounded range can't push another one out of place).
std::vector<uint32_t> RootSignature(const EntryInfo &entry) {
  const uint32_t header = 6, param = 3, table = 2, range = 5;
  uint32_t n = entry.resources.size();
  std::vector<uint32_t> rts0{1, n, header * 4, 0, 0, 0};
  for (uint32_t i = 0; i < n; i++) {
    uint32_t payload = (header + param * n + (table + range) * i) * 4;
    rts0.insert(rts0.end(), {0 /* table */, 0 /* all stages */, payload});
  }
  for (uint32_t i = 0; i < n; i++) {
    auto &r = entry.resources[i];
    uint32_t ranges = (header + param * n + (table + range) * i + table) * 4;
    uint32_t type = r.cls == ResourceClass::SRV ? 0 : r.cls == ResourceClass::UAV ? 1 : r.cls == ResourceClass::CBuffer ? 2 : 3;
    rts0.insert(rts0.end(), {1, ranges, type, r.size, r.lower_bound, r.space, 0});
  }
  uint32_t part = rts0.size() * 4, total = 36 + 8 + part;
  std::vector<uint32_t> container{0x43425844 /* DXBC */, 0, 0, 0, 0, 1, total, 1, 36, 0x30535452 /* RTS0 */, part};
  container.insert(container.end(), rts0.begin(), rts0.end());
  return container;
}

struct Result {
  bool ok = false;
  const char *stage = "";
  std::string reason;
};

Result Translate(id<MTLDevice> device, const std::vector<char> &bytes) {
  Result result;
  sm50_shader_t shader = nullptr;
  sm50_error_t error = nullptr;
  MTL_SHADER_REFLECTION refl{};
  if (SM50Initialize(bytes.data(), bytes.size(), &shader, &refl, &error)) {
    result.reason = FirstLine(ErrorText(error));
    return result;
  }
  auto internal = (dxmt::dxbc::SM50ShaderInternal *)shader;
  if (!internal->dxil) {
    SM50Destroy(shader);
    result.reason = "not a DXIL shader";
    return result;
  }
  auto &entry = internal->dxil->entry;
  result.stage = entry.kind == ShaderKind::Vertex ? "vs" : entry.kind == ShaderKind::Pixel ? "ps" : "cs";

  auto rootsig_blob = RootSignature(entry);
  SM50_SHADER_COMMON_DATA common{nullptr, SM50_SHADER_COMMON, SM50_SHADER_METAL_310, {}};
  std::vector<SM50_IA_INPUT_ELEMENT> elements;
  for (auto &e : entry.inputs)
    if (entry.kind == ShaderKind::Vertex && e.kind == SemanticKind::Arbitrary)
      for (uint32_t r = 0; r < e.rows; r++)
        elements.push_back({uint32_t(e.start_row) + r, 0, 16 * (uint32_t(e.start_row) + r), MTLAttributeFormatFloat4, 0, 0});
  SM50_SHADER_IA_INPUT_LAYOUT_DATA ia{&common, SM50_SHADER_IA_INPUT_LAYOUT, SM50_INDEX_BUFFER_FORMAT_NONE,
                                      elements.empty() ? 0u : 1u, (uint32_t)elements.size(), elements.data()};
  SM50_SHADER_PSO_PIXEL_SHADER_DATA pso{&common, SM50_SHADER_PSO_PIXEL_SHADER, 0xffffffff, false, false, 0, {}};
  for (uint32_t i = 0; i < 8; i++)
    if (refl.PixelShader.ValidRenderTargets & (1 << i))
      pso.pixel_formats[i] = MTLPixelFormatRGBA8Unorm;
  SM50_SHADER_ROOT_SIGNATURE_DATA rootsig{entry.kind == ShaderKind::Vertex  ? (void *)&ia
                                          : entry.kind == ShaderKind::Pixel ? (void *)&pso
                                                                            : (void *)&common,
                                          SM50_SHADER_ROOT_SIGNATURE, rootsig_blob.data(), rootsig_blob.size() * 4};

  auto library = [&](sm50_bitcode_t bitcode) -> id<MTLLibrary> {
    SM50_COMPILED_BITCODE data;
    SM50GetCompiledBitcode(bitcode, &data);
    auto dispatch = dispatch_data_create(data.Data, data.Size, nullptr, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    SM50DestroyBitcode(bitcode);
    NSError *err = nil;
    id<MTLLibrary> lib = [device newLibraryWithData:dispatch error:&err];
    if (!lib)
      result.reason = FirstLine(err.localizedDescription.UTF8String);
    return lib;
  };

  sm50_bitcode_t bitcode = nullptr;
  if (SM50Compile(shader, (SM50_SHADER_COMPILATION_ARGUMENT_DATA *)&rootsig, "main", &bitcode, &error)) {
    result.reason = FirstLine(ErrorText(error));
    SM50Destroy(shader);
    return result;
  }
  id<MTLLibrary> lib = library(bitcode);
  id<MTLFunction> function = [lib newFunctionWithName:@"main"];
  if (!function) {
    if (result.reason.empty())
      result.reason = "no function \"main\" in the library";
    SM50Destroy(shader);
    return result;
  }

  NSError *err = nil;
  id pipeline = nil;
  if (entry.kind == ShaderKind::Compute) {
    pipeline = [device newComputePipelineStateWithFunction:function error:&err];
  } else {
    auto desc = [MTLRenderPipelineDescriptor new];
    if (entry.kind == ShaderKind::Vertex) {
      // Metal rejects a non-void vertex function with rasterization off, so an empty fragment function stands in.
      desc.vertexFunction = function;
      static id<MTLFunction> empty = [[device newLibraryWithSource:@"fragment void ps_empty() {}" options:nil error:nil]
          newFunctionWithName:@"ps_empty"];
      desc.fragmentFunction = empty;
    } else {
      sm50_bitcode_t vs_bitcode = nullptr;
      if (DXILCompilePassThroughVertex(shader, &vs_bitcode, &error)) {
        result.reason = FirstLine(ErrorText(error));
        SM50Destroy(shader);
        return result;
      }
      id<MTLLibrary> vs_lib = library(vs_bitcode);
      desc.vertexFunction = [vs_lib newFunctionWithName:@"vs_passthrough"];
      desc.fragmentFunction = function;
      for (uint32_t i = 0; i < 8; i++)
        if (refl.PixelShader.ValidRenderTargets & (1 << i))
          desc.colorAttachments[i].pixelFormat = MTLPixelFormatRGBA8Unorm;
      for (auto &e : entry.outputs)
        if (e.kind == SemanticKind::Depth || e.kind == SemanticKind::DepthLessEqual ||
            e.kind == SemanticKind::DepthGreaterEqual || e.kind == SemanticKind::StencilRef) {
          desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
          desc.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
        }
    }
    pipeline = [device newRenderPipelineStateWithDescriptor:desc error:&err];
  }
  SM50Destroy(shader);
  if (!pipeline) {
    result.reason = FirstLine(err ? err.localizedDescription.UTF8String : "no pipeline");
    return result;
  }
  result.ok = true;
  return result;
}

} // namespace

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: dxil-translate <folder>\n");
    return 2;
  }
  std::vector<std::filesystem::path> files;
  std::error_code ec;
  for (auto &f : std::filesystem::directory_iterator(argv[1], ec))
    if (f.path().extension() == ".dxil")
      files.push_back(f.path());
  if (ec) {
    fprintf(stderr, "dxil-translate: can't read %s: %s\n", argv[1], ec.message().c_str());
    return 2;
  }
  std::sort(files.begin(), files.end());
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  uint32_t ok = 0;
  double total_ms = 0, slowest_ms = 0;
  std::string slowest = "-";
  for (auto &path : files) {
    std::ifstream in(path, std::ios::binary);
    std::vector<char> bytes((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    auto name = path.filename().string();
    auto start = std::chrono::steady_clock::now();
    Result r;
    @autoreleasepool {
      r = Translate(device, bytes);
    }
    double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    if (r.ok) {
      ok++;
      total_ms += ms;
      if (ms > slowest_ms)
        slowest_ms = ms, slowest = name;
      printf("ok %s %s %.1f\n", name.c_str(), r.stage, ms);
    } else {
      printf("fail %s %s\n", name.c_str(), r.reason.c_str());
    }
    fflush(stdout);
  }
  printf("summary %u/%zu ok, mean %.1f ms, slowest %.1f ms %s\n", ok, files.size(), ok ? total_ms / ok : 0.0, slowest_ms,
         slowest.c_str());
  return ok == files.size() && !files.empty() ? 0 : 1;
}
