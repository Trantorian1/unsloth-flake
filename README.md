# unsloth-flake

Builds [Unsloth Studio](https://github.com/unslothai/unsloth) from source on the
latest `main` and bundles its runtime for Nix, with AMD (ROCm + Vulkan) support.

```console
$ nix run github:trantorian1/unsloth-flake
```

## What changed

The previous revision of this flake unpacked upstream's prebuilt
`Unsloth-Desktop-Ubuntu.deb` into a `buildFHSEnv`. That shipped only the Tauri
shell; everything underneath it was fetched at first launch. On first run the
app would create a `uv` venv in `~/.unsloth/studio`, pick a PyTorch wheel index
from the detected GPU, pip-install the training stack, and download a prebuilt
llama.cpp release. None of that is reproducible, none of it is offline, and on
an AMD host the wheel index it picks is whatever upstream's probe decides.

This revision builds all four pieces from source and wires them together at
build time:

| Piece | Source | Derivation |
| --- | --- | --- |
| Web UI | `studio/frontend` (Vite/React) | `nix/frontend.nix` |
| Backend + `unsloth` CLI | `studio/backend`, `unsloth_cli` (Python) | `nix/backend.nix` |
| GGUF inference | nixpkgs `llama-cpp`, HIP + Vulkan | `nix/llama-cpp.nix` |
| Desktop shell | `studio/src-tauri` (Rust/Tauri) | `nix/desktop.nix` |

`package.nix` composes them; `nix/desktop.nix` produces the wrapped binary.

## How the runtime is bundled

Two environment variables carry the whole scheme, both set by the wrapper:

- **`UNSLOTH_LLAMA_CPP_PATH`** — read by `studio/backend/main.py`, which only
  falls back to its managed download path when the variable is unset. Because
  the path is not the managed one, `mark_managed_llama_cpp_path()` classifies it
  as a user override and the in-app llama.cpp updater leaves it alone.

- **`UNSLOTH_STUDIO_BACKEND_BIN`** — does not exist upstream. The desktop shell
  resolves its Python backend through `process.rs::find_unsloth_binary()`, which
  is hardcoded to `~/.unsloth/studio`, and `UNSLOTH_STUDIO_HOME` is deliberately
  scrubbed on that path, so there was no existing way in. `nix/desktop.nix`
  patches a three-line lookup onto the front of that function and leaves the
  `$HOME` search as the fallback.

User data — models, datasets, projects — still lives under `~/.unsloth/studio`,
which is as it should be: that directory needs to be writable.

The wrapper also sets `UNSLOTH_DISABLE_UPDATE_CHECK=1`. The store path is
read-only, so an in-app update could only ever fail partway through; rebuild the
package instead.

### Why no `npmDepsHash` / `cargoHash`

Every hash in a build like this is a hash someone has to regenerate on each
upstream bump, and a stale one is a confusing failure. This flake has none:

- the npm tree comes from `importNpmLock`, which reuses the `integrity` hashes
  already in `studio/frontend/package-lock.json`;
- the Rust tree comes from `cargoLock.lockFile`, with `allowBuiltinFetchGit` for
  the one git dependency (`fix-path-env`) that `Cargo.lock` carries;
- the upstream source is a flake input, so `flake.lock` holds its hash and
  `nix flake update unsloth-src` maintains it.

The single pinned hash is `unsloth_zoo`'s sdist in `nix/backend.nix`, explained
below.

`flake.lock` does not yet carry the `unsloth-src` input; nix adds it on the
first evaluation. If you need the lock populated up front, run `nix flake lock`.

## AMD GPUs

`flake.nix` imports nixpkgs with `config.rocmSupport = true`, which is the knob
`torch`, `bitsandbytes` and `llama-cpp` all read. That gives:

- **Inference** — `llama-cpp` built with `GGML_HIP` *and* `GGML_VULKAN`. Both
  backends ship in one tree and `GGML_BACKEND_DL` loads whichever the host can
  use. This matters because upstream's own measurements
  (`studio/ROCM_RDNA2_APU.md`) put Vulkan ~6x ahead of ROCm on untuned RDNA2
  parts, while tuned ROCm hardware is faster the other way; shipping both lets
  the runtime decide instead of the packager.
- **Training** — `torch` built with `rocmSupport`, and `bitsandbytes` following
  it automatically.
- `rocminfo` and `rocm-smi` on the backend's `PATH` for GPU probing.

`nix/llama-cpp.nix` re-roots llama.cpp so that `llama-server` sits at the top of
`UNSLOTH_LLAMA_CPP_PATH` with the `libggml-*.so` backends beside it. That is not
cosmetic: `binary_gpu_backends()` calls `Path.resolve()` and then reads the GPU
backends off the filenames in the resolved binary's directory. A symlink farm
would resolve back into the nixpkgs `bin/`, where only the CPU variants live, and
Unsloth would quietly route inference to the CPU. The derivation's
`installCheckPhase` fails the build if `libggml-hip.so` or `libggml-vulkan.so`
did not make it.

### Pick your GFX target

Left alone, nixpkgs compiles HIP for every AMD target it knows about, which is
very slow. Narrow it to your card:

```nix
# gfx1100 = RDNA3 (7900 XT/XTX), gfx1030 = RDNA2 (6800/6900), gfx90a = CDNA2
unsloth-studio = pkgs.callPackage ./package.nix {
  inherit unsloth-src;
  rocmGpuTargets = [ "gfx1100" ];
};
```

`rocminfo | grep gfx` reports what you have. For a CPU-only build, pass
`rocmSupport = false`.

## Caveats

**`torch` with ROCm builds from source.** It is not in the public binary cache
in this configuration, so the first build is long — hours, and it wants a lot of
RAM. Narrowing `rocmGpuTargets` is the single biggest saving. A binary cache of
your own is worth setting up before the first build.

**Upstream's Python pins are relaxed.** `pyproject.toml` pins nearly every
runtime dependency to the exact version upstream's own installer downloads
(`transformers==5.5.0`, `fastapi==0.141.1`, `datasets==4.3.0`, …). nixpkgs
carries its own versions, so `nix/backend.nix` sets `pythonRelaxDeps = true`.
That satisfies the metadata check; it cannot guarantee API compatibility. If the
backend fails at import or on an API call, a version skew here is the first
place to look.

`unsloth_zoo` is the one dependency where the skew was too wide to relax:
upstream floors it at `2026.9.4` for an FSDP2 fix its compiled trainers rely on,
and nixpkgs carries `2026.4.7`, so `nix/backend.nix` overrides it to the PyPI
release upstream asks for.

**ROCm training is not uniformly reliable.** This is upstream's finding, not a
packaging problem: `studio/ROCM_RDNA2_APU.md` records PyTorch's backward pass
producing wrong results on RDNA2 APUs across three independent ROCm versions.
Inference via Vulkan is fine there. Check that document against your hardware
before trusting a fine-tune.

**Patches are anchored to upstream text.** `nix/desktop.nix` matches exact
strings in `tauri.conf.json` and `process.rs` with `--replace-fail`. Tracking
`main` means these can break on an upstream refactor — deliberately loudly, at
build time, rather than silently producing an app that re-downloads its runtime.

## Verification status

This was developed in an environment without Nix (the egress policy blocked the
installer), so **the Nix expressions have not been evaluated or built**. What was
verified directly:

- the frontend builds — `npm ci` and `npm run build` against upstream `main` both
  succeed, and the emitted CSS (581 KB) passes the size gate `build.sh` uses;
- the patched `process.rs` parses as valid Rust (`rustfmt`, exit 0);
- all three `--replace-fail` anchors match exactly once in upstream `main`;
- `studio/src-tauri/Cargo.lock` has exactly one git dependency, whose pinned
  revision is reachable, so `allowBuiltinFetchGit` covers it;
- the `unsloth_zoo` sdist hash matches the real `fetchPypi` URL byte for byte.

Expect to iterate on the first `nix build`.
