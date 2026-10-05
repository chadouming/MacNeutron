# LLVM 15 and the host tools linked against it, by architecture, for wine-arm64/build.sh (arm64) (sourced).
# The caller defines die, ROOT and LLVM_TAG (dxmt/pins); this file sets no variables. Messages go to stderr.

# LLVM 15: static, with DXMT's CI flags but no assertions (they slowed every pipeline's translation, which Unreal does
# thousands of times a launch). Built once per install folder.
build_llvm() {  # build_llvm <arch> <install> <llvm-project>
  if [ -f "$2/.complete" ]; then return 0; fi
  if [ ! -d "$3/llvm" ]; then  # cloned aside and moved into place, so an interrupted clone isn't taken for a source tree
    rm -rf "$3.tmp"
    git clone -q --depth 1 --branch "$LLVM_TAG" https://github.com/llvm/llvm-project.git "$3.tmp" \
      || die "can't clone llvm-project $LLVM_TAG"
    rm -rf "$3"; mv "$3.tmp" "$3"
  fi
  echo "dxmt: building LLVM $LLVM_TAG (a few minutes, once); log: $2.log" >&2
  { cmake -B "$2-build" -S "$3/llvm" -G Ninja \
      -DCMAKE_INSTALL_PREFIX="$2" -DCMAKE_OSX_ARCHITECTURES="$1" -DLLVM_HOST_TRIPLE="$1-apple-darwin" \
      -DLLVM_ENABLE_ASSERTIONS=Off -DLLVM_ENABLE_ZSTD=Off -DCMAKE_BUILD_TYPE=Release -DLLVM_TARGETS_TO_BUILD="" \
      -DLLVM_BUILD_TOOLS=Off -DLLVM_VERSION_PRINTER_SHOW_HOST_TARGET_INFO=Off -DCMAKE_POLICY_VERSION_MINIMUM=3.5 &&
    cmake --build "$2-build" && cmake --install "$2-build"; } > "$2.log" 2>&1 \
    || die "LLVM build failed; see $2.log"
  touch "$2/.complete"  # written last: an interrupted install is redone
}

# The DXIL probe (spec §6), against the same LLVM. -fno-rtti matches LLVM's own build.
build_probe() {  # build_probe <arch> <llvm> <out-dir> <log-dir>
  /usr/bin/clang++ -arch "$1" -std=c++17 -O1 -fno-rtti -I"$2/include" "$ROOT/dxmt/tools/dxil-probe.cpp" -o "$3/dxil-probe" \
    -L"$2/lib" -lLLVMBitReader -lLLVMCore -lLLVMRemarks -lLLVMBitstreamReader -lLLVMBinaryFormat -lLLVMSupport \
    -lLLVMDemangle -lz -lcurses > "$4/dxil-probe.log" 2>&1 || die "dxil-probe failed to build; see $4/dxil-probe.log"
}

# The offline corpus tool (DXIL translator plan, Task 5), against the fork's native airconv. The -lLLVM list is
# src/airconv/meson.build's llvm_deps, in order.
build_translate() {  # build_translate <arch> <llvm> <dxmt-src> <dxmt-build> <out-dir> <log-dir>
  /usr/bin/clang++ -arch "$1" -std=c++20 -O1 -fno-rtti -fno-exceptions -fobjc-arc -I"$2/include" -I"$3/src/airconv" \
    -I"$3/include" -I"$3/libs" -I"$3/include/native/windows" -I"$3/include/native/directx" \
    "$ROOT/dxmt/tools/dxil-translate.mm" -o "$5/dxil-translate" \
    "$4/src/airconv/darwin/libairconv.a" "$4/libs/DXBCParser/libDXBCParserNative.a" \
    -L"$2/lib" -lLLVMPasses -lLLVMTarget -lLLVMObjCARCOpts -lLLVMCoroutines -lLLVMipo -lLLVMInstrumentation \
    -lLLVMVectorize -lLLVMLinker -lLLVMIRReader -lLLVMAsmParser -lLLVMFrontendOpenMP -lLLVMScalarOpts \
    -lLLVMInstCombine -lLLVMAggressiveInstCombine -lLLVMTransformUtils -lLLVMBitWriter -lLLVMAnalysis \
    -lLLVMProfileData -lLLVMSymbolize -lLLVMDebugInfoPDB -lLLVMDebugInfoMSF -lLLVMDebugInfoDWARF -lLLVMObject \
    -lLLVMTextAPI -lLLVMMCParser -lLLVMMC -lLLVMDebugInfoCodeView -lLLVMBitReader -lLLVMCore -lLLVMRemarks \
    -lLLVMBitstreamReader -lLLVMBinaryFormat -lLLVMSupport -lLLVMDemangle -lm -lz -lcurses -lxml2 \
    -framework Metal -framework Foundation > "$6/dxil-translate.log" 2>&1 \
    || die "dxil-translate failed to build; see $6/dxil-translate.log"
}
