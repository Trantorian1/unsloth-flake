# Unsloth Studio, built from source and bundled with its runtime.
#
# The app is four pieces that upstream assembles at runtime and this package
# assembles at build time:
#
#   nix/frontend.nix    the Vite/React web UI            (npm, from package-lock.json)
#   nix/backend.nix     the `unsloth` CLI + API server   (Python, incl. ROCm torch)
#   nix/llama-cpp.nix   GGUF inference                   (HIP + Vulkan backends)
#   nix/desktop.nix     the Tauri shell                  (Rust; wraps the above)
#
# Upstream's desktop build ships only the shell and bootstraps the rest into
# ~/.unsloth/studio on first launch: a uv venv, PyTorch wheels chosen from the
# detected GPU, and a llama.cpp release download. None of that can happen in a
# read-only store path, and none of it is reproducible, so each piece is a
# derivation and the shell is pointed at them by environment variable.
{
  callPackage,
  lib,
  python3,
  unsloth-src,
  # Turning this off gives a CPU-only backend; it does not switch to CUDA.
  # For NVIDIA, import nixpkgs with config.cudaSupport instead.
  rocmSupport ? true,
  # Restrict the HIP compile to the GFX arch you have, e.g. [ "gfx1100" ].
  # Left null, nixpkgs builds every target it knows, which is very slow.
  rocmGpuTargets ? null,
}: let
  # The upstream tree carries no release version of its own that survives into a
  # source build: studio/src-tauri/Cargo.toml says so in as many words (its
  # `version` field is a placeholder that the release workflow rewrites), and
  # unsloth/_version.py is stamped by scripts/stamp_studio_release.py at publish
  # time. So date the package from the commit nix locked instead, which is both
  # accurate for a main-branch build and monotonic across `nix flake update`.
  #
  # lastModifiedDate is YYYYMMDDHHMMSS; nixpkgs spells an unreleased snapshot
  # 0-unstable-YYYY-MM-DD.
  stamp = unsloth-src.lastModifiedDate or "";

  date =
    if stamp == ""
    then "unknown"
    else "${lib.substring 0 4 stamp}-${lib.substring 4 2 stamp}-${lib.substring 6 2 stamp}";

  version = "0-unstable-${date}";

  unsloth-studio-frontend = callPackage ./nix/frontend.nix {
    inherit unsloth-src version;
  };

  unsloth-studio-backend = callPackage ./nix/backend.nix {
    inherit
      python3
      rocmSupport
      unsloth-src
      unsloth-studio-frontend
      version
      ;
  };

  unsloth-studio-llama-cpp = callPackage ./nix/llama-cpp.nix {
    inherit rocmSupport rocmGpuTargets;
  };
in
  callPackage ./nix/desktop.nix {
    inherit
      unsloth-src
      unsloth-studio-backend
      unsloth-studio-frontend
      unsloth-studio-llama-cpp
      version
      ;
  }
