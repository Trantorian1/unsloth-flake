# The Python half of Unsloth Studio: the `unsloth` CLI, which the Tauri shell
# spawns as `unsloth studio --api-only -H 127.0.0.1 -p <port>`.
#
# Upstream never ships this as a normal Python install. The desktop app expects
# to find a uv-managed venv under ~/.unsloth/studio and, when it is missing,
# bootstraps one at runtime: studio/install_python_stack.py resolves a PyTorch
# index from the detected GPU and pip-installs the whole training stack.
# That is precisely what a Nix package must not do, so the environment is built
# here instead and the shell is pointed at it (see nix/desktop.nix).
{
  lib,
  python3,
  unsloth-src,
  unsloth-studio-frontend,
  version,
  gcc,
  nodejs_22,
  pciutils,
  rocmPackages,
  rocmSupport ? true,
}: let
  python = python3.override {
    self = python;
    packageOverrides = final: prev: {
      # nixpkgs currently carries 2026.4.7, but unsloth's pyproject.toml floors
      # unsloth_zoo at 2026.9.4 for the FSDP2 mixed-precision fix its compiled
      # trainers depend on. Relaxing the pin instead would install a zoo that
      # generates trainer code the rest of the stack cannot run.
      unsloth-zoo = prev.unsloth-zoo.overridePythonAttrs (old: rec {
        version = "2026.9.4";
        src = final.fetchPypi {
          pname = "unsloth_zoo";
          inherit version;
          hash = "sha256-fS2qKijEQTyG7g3r5JH0CTdOH4ziLc/r2AQRU7fOQgc=";
        };
      });
    };
  };

  ps = python.pkgs;
in
  ps.buildPythonApplication {
    pname = "unsloth-studio-backend";
    inherit version;
    pyproject = true;

    src = unsloth-src;

    postPatch = ''
      # Exact build-tool pins that nixpkgs does not carry and that add nothing
      # here; the same relaxation nixpkgs' own `unsloth` package applies.
      substituteInPlace pyproject.toml \
        --replace-fail 'requires = ["setuptools==82.0.1", "setuptools-scm==9.2.2"]' \
                       'requires = ["setuptools", "setuptools-scm"]'

      # studio/backend/run.py serves studio/frontend/dist, and pyproject.toml
      # ships it as package data. Upstream's build.sh produces it with
      # `npm run build` just before `python -m build`; here it is its own
      # derivation, so drop it in place before setuptools collects package data.
      rm -rf studio/frontend/dist
      cp -r ${unsloth-studio-frontend} studio/frontend/dist
      chmod -R u+w studio/frontend/dist
    '';

    build-system = with ps; [
      setuptools
      setuptools-scm
    ];

    # Upstream pins nearly every runtime dependency to an exact version to match
    # the wheels its own installer downloads. nixpkgs tracks its own versions, so
    # the pins are relaxed and the nixpkgs set is used as-is.
    pythonRelaxDeps = true;

    dependencies = with ps;
      [
        # [project].dependencies: needed by every CLI invocation.
        typer
        rich
        pydantic
        pyyaml
        nest-asyncio
        huggingface-hub
        structlog
        click
      ]
      ++ [
        # [project.optional-dependencies].studio - the API server stack,
        # mirroring studio/backend/requirements/studio.txt.
        fastapi
        uvicorn
        packaging
        matplotlib
        pandas
        datasets
        pyjwt
        urllib3
        jinja2
        diceware
        ddgs
        cryptography
        boto3
        httpx
        fastmcp
        gguf
        av
        sqlite-vec
        pymupdf
        pymupdf4llm
        python-docx
        markdown-it-py
      ]
      ++ [
        # The training and inference stack. torch here is the ROCm build,
        # because the flake sets config.rocmSupport.
        torch
        torchvision
        transformers
        trl
        peft
        accelerate
        sentence-transformers
        diffusers
        unsloth-zoo
        cut-cross-entropy
        bitsandbytes
        sentencepiece
        protobuf
        tyro
        psutil
        numpy
        tqdm
        safetensors
        tokenizers
        hf-transfer
        pillow
        lxml
        regex
      ]
      ++ [
        # Audio: datasets>=4 decodes through torchcodec, with soundfile and
        # PyAV as the fallback when it cannot load.
        torchcodec
        soundfile
      ]
      ++ [
        # unsloth's kernels import triton directly. This is the same derivation
        # torch already depends on (torch takes `triton` from this set), so it
        # adds no second, mismatched copy to the environment.
        triton
      ];

    # `import unsloth` initialises the GPU stack and raises without a device, so
    # neither the test suite nor an import check can run in the sandbox.
    doCheck = false;
    pythonImportsCheck = [];

    # One argument per list element: without __structuredAttrs these are joined
    # and word-split by the wrapper hook, so "--set CC /path" only works by
    # accident of store paths having no spaces in them.
    makeWrapperArgs = [
      # Triton compiles kernels at runtime and shells out to a C compiler;
      # without this the first kernel launch fails on a missing `cc`.
      "--set"
      "CC"
      (lib.getExe' gcc "cc")
      "--set"
      "CXX"
      (lib.getExe' gcc "c++")

      # studio/backend reaches for node to run the bundled oxc validator and
      # stdio MCP servers, and for lspci when probing GPUs. Upstream downloads
      # its own node (studio/install_node_prebuilt.py); this supplies it.
      "--prefix"
      "PATH"
      ":"
      (lib.makeBinPath (
        [nodejs_22 pciutils gcc]
        ++ lib.optionals rocmSupport [
          rocmPackages.rocminfo
          rocmPackages.rocm-smi
        ]
      ))
    ];

    meta = {
      description = "Unsloth Studio backend and `unsloth` CLI";
      homepage = "https://unsloth.ai/";
      # studio/ and unsloth_cli/ are AGPL-3.0-only (studio/LICENSE.AGPL-3.0);
      # the unsloth training library itself is Apache-2.0. The combined install
      # is governed by the stricter of the two.
      license = lib.licenses.agpl3Only;
      platforms = ["x86_64-linux"];
      mainProgram = "unsloth";
      sourceProvenance = with lib.sourceTypes; [fromSource];
    };
  }
