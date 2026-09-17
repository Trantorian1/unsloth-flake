# llama.cpp, laid out the way Unsloth Studio expects to find it.
#
# Left alone, studio/backend downloads a prebuilt llama.cpp release into
# ~/.unsloth/studio/llama.cpp on first run (studio/install_llama_prebuilt.py)
# and picks a backend from the detected GPU. UNSLOTH_LLAMA_CPP_PATH overrides
# that, and studio/backend/main.py honours it, so this derivation builds
# llama.cpp from nixpkgs with the AMD backends enabled and arranges it into the
# layout the override expects.
#
# Two details of that layout are load-bearing, both in
# studio/backend/utils/llama_cpp_path_settings.py:
#
#   * llama_server_candidates() looks for `<root>/llama-server` first, then
#     `<root>/build/bin/llama-server`. nixpkgs installs to `bin/`, which is
#     neither, so the tree is re-rooted here.
#   * binary_gpu_backends() lists the directory of the *resolved* binary and
#     reads the GPU backends off the `libggml-<backend>.so` names it finds. It
#     calls Path.resolve(), so a symlink farm would resolve back into the
#     llama-cpp store path, where only the CPU variants sit beside the
#     executables and the GPU backends are one directory up in lib/. The app
#     would then conclude the build is CPU-only and route inference to the CPU.
#     Hence real copies, with the GPU backends alongside.
{
  lib,
  stdenvNoCC,
  llama-cpp,
  # Both backends in one build so the runtime can pick. Unsloth prefers Vulkan
  # on AMD parts whose ROCm support is untuned (studio/ROCM_RDNA2_APU.md
  # measures Vulkan at ~6x ROCm on RDNA2 APUs) and ROCm where it is good, and
  # llama.cpp's GGML_BACKEND_DL loads whichever backends are present.
  rocmSupport ? true,
  vulkanSupport ? true,
  # Narrow this to the GFX arch you actually have (for example [ "gfx1100" ] for
  # RDNA3 or [ "gfx1030" ] for RDNA2) to cut the HIP compile down from every
  # target nixpkgs knows about to one.
  rocmGpuTargets ? null,
}: let
  llama = llama-cpp.override (
    {
      inherit rocmSupport vulkanSupport;
    }
    // lib.optionalAttrs (rocmGpuTargets != null) {
      inherit rocmGpuTargets;
    }
  );
in
  stdenvNoCC.mkDerivation {
    pname = "unsloth-studio-llama-cpp";
    inherit (llama) version;

    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall

      mkdir -p $out

      # Executables plus the per-microarchitecture libggml-cpu-*.so that
      # GGML_CPU_ALL_VARIANTS emits beside them.
      cp -a ${llama}/bin/. $out/

      # The GPU backends and the core libraries, which nixpkgs installs to lib/.
      # They have to sit next to the executables for binary_gpu_backends() to
      # see them, and for GGML_BACKEND_DL to load them.
      cp -a ${llama}/lib/*.so* $out/

      chmod -R u+w $out

      runHook postInstall
    '';

    # Copying the executables leaves their RUNPATHs pointing back into the
    # llama-cpp store path, which is what should happen: the copies are there to
    # be *listed*, and they keep resolving their libraries from the original
    # closure. Check that the two names the app looks for actually arrived,
    # since a silent miss here degrades to CPU inference rather than an error.
    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck

      test -x $out/llama-server \
        || { echo "ERROR: llama-server missing from $out" >&2; exit 1; }

      ${lib.optionalString rocmSupport ''
        test -e $out/libggml-hip.so \
          || { echo "ERROR: ROCm requested but libggml-hip.so is absent; Unsloth would read this build as CPU-only" >&2; exit 1; }
      ''}
      ${lib.optionalString vulkanSupport ''
        test -e $out/libggml-vulkan.so \
          || { echo "ERROR: Vulkan requested but libggml-vulkan.so is absent; Unsloth would read this build as CPU-only" >&2; exit 1; }
      ''}

      runHook postInstallCheck
    '';

    passthru.llama-cpp = llama;

    meta = {
      description = "llama.cpp arranged for UNSLOTH_LLAMA_CPP_PATH, with AMD backends";
      inherit (llama.meta) homepage license;
      platforms = ["x86_64-linux"];
      # Deliberately no mainProgram: the binaries sit at the top of $out rather
      # than in $out/bin, because that is the layout llama_server_candidates()
      # searches, so lib.getExe would point at a path that does not exist.
    };
  }
