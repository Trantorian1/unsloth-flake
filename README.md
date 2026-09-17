# unsloth-flake

Builds [Unsloth Studio](https://github.com/unslothai/unsloth) from source on the
latest `main`, with AMD (ROCm + Vulkan) inference bundled.

```console
$ nix run github:trantorian1/unsloth-flake
```

## What this builds

| Piece | Source | Derivation |
| --- | --- | --- |
| Web UI | `studio/frontend` (Vite/React) | `nix/frontend.nix` |
| Desktop shell | `studio/src-tauri` (Rust/Tauri) | `nix/desktop.nix` |
| GGUF inference | nixpkgs `llama-cpp`, HIP + Vulkan | `nix/llama-cpp.nix` |

`package.nix` composes them and wraps the result in an FHS environment.

The previous revision unpacked upstream's prebuilt `Unsloth-Desktop-Ubuntu.deb`.
This one compiles the shell and the web UI from the tracked `main`, and pins
llama.cpp through nixpkgs so AMD inference is decided at build time rather than
by a runtime probe.

## The deliberate split

The **Python training stack is not pinned by Nix.** On first run the app creates
a `uv` venv under `~/.unsloth/studio` and `install.sh` populates it, which is
what the FHS environment exists to support: those are manylinux wheels that
expect a loader at `/lib64/ld-linux-x86-64.so.2`. The Tauri binary itself needs
none of that — Nix linked it with store RPATHs.

This is a trade, made on purpose. Pinning the Python side means carrying ~40
packages against upstream's exact pins — `pyproject.toml` fixes `transformers`,
`fastapi`, `datasets` and the rest to the versions its own installer downloads —
holding them together with `pythonRelaxDeps`, and building a ROCm `torch` from
source for hours. That is where essentially all the maintenance burden of a
fully-pinned flake lives, and it buys reproducibility for the component that
changes most often.

So the split follows the cost:

- **pinned by Nix** — the shell, the web UI, and llama.cpp. Cheap to maintain
  (no hashes at all, see below), and llama.cpp is what actually determines
  whether inference uses your GPU.
- **bootstrapped at first run** — the training stack, by upstream's own
  `install.sh`, which already resolves the right PyTorch index from the
  detected hardware.

If you want the Python stack pinned too, that is a real option — it just needs
a `buildPythonApplication` over the nixpkgs Python set, and the upkeep that
comes with it.

## How the runtime is wired

- **`UNSLOTH_LLAMA_CPP_PATH`** is exported by the FHS profile. `studio/backend/main.py`
  only falls back to downloading a llama.cpp release when this is unset, and
  because the path is not the managed one, `mark_managed_llama_cpp_path()` reads
  it as a user override and the in-app updater leaves it alone.
- **`UNSLOTH_DISABLE_UPDATE_CHECK=1`**, because the store binary is read-only and
  an in-app update of the shell could only fail partway through. Rebuild the
  package instead. The backend under `~/.unsloth/studio` is writable and updates
  normally.
- **`install.sh` is installed to `$out/lib/Unsloth/`.** `install.rs` resolves it
  through Tauri's Resource directory, which the `.deb` bundler would have filled
  in. On Linux `tauri-utils` resolves that to `<dir of the running exe>/../lib/<productName>`
  and canonicalizes it, and `tauri-codegen` takes `productName` from
  `tauri.conf.json` — `Unsloth`. Without it the first-run bootstrap fails with
  *Failed to resolve bundled install.sh*.

### No hashes to maintain

There is not a single hand-maintained hash in this flake:

- the npm tree comes from `importNpmLock`, which reuses the `integrity` hashes
  already in `studio/frontend/package-lock.json`;
- the Rust tree comes from `cargoLock.lockFile`, with `allowBuiltinFetchGit` for
  the one git dependency (`fix-path-env`) that `Cargo.lock` carries;
- the upstream source is a flake input, so `flake.lock` holds its hash and
  `nix flake update unsloth-src` maintains it.

`flake.lock` does not yet carry the `unsloth-src` input; nix adds it on the
first evaluation. If you need the lock populated up front, run `nix flake lock`.

One wrinkle is worth knowing about, because it is not obvious and it bites on
upgrade. `package.json` has an `overrides` block whose entries include packages
that are also direct dependencies. `importNpmLock` rewrites `dependencies` to
`file:` store paths but leaves `overrides` at its version string, so npm sees
them disagree and fails with `EOVERRIDE`. Deleting the block does not work
either — it is load-bearing, since `streamdown` depends on `remend` 1.3.0 and
the override is what lifts the tree to 1.3.1; without it npm goes to the
registry and the sandbox has no network. `nix/fix-npm-overrides.jq` instead
points each override at the same store tarball `importNpmLock` already chose.

## AMD GPUs

`flake.nix` imports nixpkgs with `config.rocmSupport = true`, and with
`allowUnfree` because parts of the ROCm stack are redistributable-but-unfree.

**Inference** is pinned: `llama-cpp` is built with `GGML_HIP` *and*
`GGML_VULKAN`, both backends in one tree, and `GGML_BACKEND_DL` loads whichever
the host can use. Shipping both matters — upstream's own measurements
(`studio/ROCM_RDNA2_APU.md`) put Vulkan ~6x ahead of ROCm on untuned RDNA2
parts, while tuned ROCm hardware is faster the other way — so the runtime
decides rather than the packager.

`nix/llama-cpp.nix` re-roots llama.cpp so `llama-server` sits at the top of
`UNSLOTH_LLAMA_CPP_PATH` with the `libggml-*.so` backends beside it. That is not
cosmetic: `binary_gpu_backends()` calls `Path.resolve()` and reads the GPU
backends off the filenames in the resolved binary's directory. A symlink farm
would resolve back into the nixpkgs `bin/`, where only the CPU variants live,
and Unsloth would quietly route inference to the CPU. The derivation's
`installCheckPhase` fails the build if the GPU backends did not arrive.

**Training** is decided at first run by `install.sh`, which consults `lspci`,
`rocminfo`, `rocm-smi`, `amd-smi`, `hipconfig` and the KFD sysfs nodes and takes
the highest ROCm version any of them reports. The FHS environment puts those
probes on `PATH` so that detection can succeed. Deferring to it is deliberate:
it knows which AMD architectures compute *incorrectly* under ROCm and routes
them to CPU wheels instead. `UNSLOTH_TORCH_INDEX_URL` and
`UNSLOTH_TORCH_INDEX_FAMILY` override it if you disagree.

### Pick your GFX target

Left alone, nixpkgs compiles HIP for every AMD target it knows about, which is
slow. Narrow it to your card:

```nix
# gfx1100 = RDNA3 (7900 XT/XTX), gfx1030 = RDNA2 (6800/6900), gfx90a = CDNA2
unsloth-studio = pkgs.callPackage ./package.nix {
  inherit unsloth-src;
  rocmGpuTargets = [ "gfx1100" ];
};
```

`rocminfo | grep gfx` reports what you have. For a CPU-only llama.cpp, pass
`rocmSupport = false`.

## Caveats

**ROCm training is not uniformly reliable.** This is upstream's finding, not a
packaging problem: `studio/ROCM_RDNA2_APU.md` records PyTorch's backward pass
producing wrong results on RDNA2 APUs across three independent ROCm versions,
while Vulkan inference is fine on the same hardware. Check that document against
your GPU before trusting a fine-tune.

**The first run needs network.** It downloads the Python stack. That is the
consequence of the split above, and it means a first launch is not reproducible
and not offline.

**Patches are anchored to upstream text.** `nix/desktop.nix` matches an exact
string in `tauri.conf.json` with `--replace-fail`. Tracking `main` means this
can break on an upstream refactor — deliberately loudly, at build time.

## Verification status

Developed without Nix available (the egress policy blocked the installer), so
**the Nix expressions have not been evaluated end to end.** What was verified
directly:

- the frontend builds — `npm ci` and `npm run build` against upstream `main`
  succeed, and the CSS (581 KB) clears the size gate `build.sh` uses;
- the `importNpmLock` install was replayed locally against all 986 lockfile
  tarballs: the override rewrite installs 1049 packages offline, keeps every
  overridden version, survives the hook's `npm rebuild`, and builds — while the
  two obvious alternatives reproduce `EOVERRIDE` and `ENOTCACHED` respectively;
- the `--replace-fail` anchor matches exactly once in upstream `main`;
- `studio/src-tauri/Cargo.lock` has exactly one git dependency, whose pinned
  revision is reachable, so `allowBuiltinFetchGit` covers it;
- Tauri's Linux resource-directory rule was read from `tauri-utils` at the
  pinned 2.11.5 tag, and `productName` confirmed as the name it uses.

The Rust and llama.cpp builds have not been run. Expect some iteration.
