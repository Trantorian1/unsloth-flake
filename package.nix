# Unsloth Studio, built from source and wrapped for a self-bootstrapping runtime.
#
#   nix/frontend.nix   the Vite/React web UI   (npm, from package-lock.json)
#   nix/desktop.nix    the Tauri shell         (Rust, embeds the frontend)
#   nix/llama-cpp.nix  GGUF inference          (HIP + Vulkan backends)
#
# The shell and the web UI are built from source, and llama.cpp is pinned by
# Nix so AMD inference is deterministic. The Python training stack is not: the
# app installs it into ~/.unsloth/studio on first run, the way upstream intends,
# which is what the FHS environment below exists to support.
#
# That split is deliberate. Pinning the Python side in Nix means carrying ~40
# packages against upstream's exact pins (pyproject.toml pins transformers,
# fastapi, datasets and the rest to the versions its own installer downloads),
# plus a ROCm torch that builds from source for hours. Upstream's install.sh
# already resolves the right PyTorch index from the detected GPU -- including
# routing AMD architectures that compute incorrectly under ROCm to CPU wheels
# instead (studio/ROCM_RDNA2_APU.md) -- so the FHS environment supplies the
# probes it looks for and lets it make that call.
{
  buildFHSEnv,
  cacert,
  callPackage,
  lib,
  unsloth-src,
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

  unsloth-studio-desktop = callPackage ./nix/desktop.nix {
    inherit unsloth-src unsloth-studio-frontend version;
  };

  unsloth-studio-llama-cpp = callPackage ./nix/llama-cpp.nix {
    inherit rocmSupport rocmGpuTargets;
  };
in
  buildFHSEnv {
    pname = "unsloth-studio";
    inherit version;

    # The app's first run creates a uv venv under ~/.unsloth/studio and fills it
    # with manylinux wheels -- torch above all -- which expect a loader at
    # /lib64/ld-linux-x86-64.so.2 and libraries under /usr/lib. That is the
    # whole reason for the FHS environment; the Tauri binary itself needs none
    # of it, since Nix linked it with store RPATHs.
    targetPkgs = pkgs:
      with pkgs;
        [
          # What install.sh reaches for: it fetches uv when absent, but a
          # working one on PATH saves the download and the curl|sh.
          uv
          python3
          curl
          wget
          git
          cacert

          # Building wheels that have no manylinux build, and Triton's runtime
          # JIT, which shells out to a C compiler on first kernel launch.
          gcc
          gnumake
          cmake
          binutils

          # studio/backend runs node for the bundled oxc validator and stdio MCP
          # servers; upstream otherwise downloads its own.
          nodejs_22

          # GPU probing. install.sh consults lspci and the ROCm tools below and
          # takes the highest ROCm version any of them reports, so these are
          # what decide whether the training stack gets ROCm or CPU wheels.
          pciutils
          vulkan-loader

          # The GUI stack. The binary resolves these through its RPATH, but the
          # webview also dlopens some of them, and a tray icon needs
          # libayatana-appindicator present by soname.
          gtk3
          webkitgtk_4_1
          libsoup_3
          glib-networking
          gsettings-desktop-schemas
          hicolor-icon-theme
          shared-mime-info
          libayatana-appindicator
          libnghttp2

          # install.sh probes ports and opens the browser.
          lsof
          iproute2
          xdg-utils
        ]
        ++ lib.optionals rocmSupport [
          rocmPackages.rocminfo
          rocmPackages.rocm-smi
          rocmPackages.amdsmi
          # hipconfig, one of the ROCm versions install.sh cross-checks. Already
          # in the closure as llama.cpp's HIP backend depends on it.
          rocmPackages.clr
        ];

    profile = ''
      # Skip the llama.cpp download: this one is built from nixpkgs with the AMD
      # backends enabled. studio/backend/main.py only falls back to its managed
      # download path when this is unset, and because the path is not the
      # managed one, mark_managed_llama_cpp_path() reads it as a user override
      # and the in-app llama.cpp updater leaves it alone.
      export UNSLOTH_LLAMA_CPP_PATH="${unsloth-studio-llama-cpp}"

      # The store binary is read-only, so an in-app update of the shell could
      # only ever fail partway through. Rebuild this package instead. The
      # backend under ~/.unsloth/studio is writable and updates normally.
      export UNSLOTH_DISABLE_UPDATE_CHECK=1

      # WebKitGTK's DMA-BUF renderer renders black under many drivers, which for
      # this app means an empty window and no error.
      export WEBKIT_DISABLE_DMABUF_RENDERER=1

      export SSL_CERT_FILE="${cacert}/etc/ssl/certs/ca-bundle.crt"
    '';

    runScript = lib.getExe unsloth-studio-desktop;

    extraInstallCommands = ''
      install -Dm644 ${unsloth-studio-desktop}/share/icons/hicolor/128x128/apps/unsloth-studio.png \
        $out/share/icons/hicolor/128x128/apps/unsloth-studio.png
      install -Dm644 ${unsloth-studio-desktop}/share/icons/hicolor/32x32/apps/unsloth-studio.png \
        $out/share/icons/hicolor/32x32/apps/unsloth-studio.png

      # studio/src-tauri/linux/unsloth.desktop is a Handlebars template the
      # Tauri bundler fills in; write the resolved entry directly instead.
      mkdir -p $out/share/applications
      cat > $out/share/applications/unsloth-studio.desktop <<EOF
      [Desktop Entry]
      Type=Application
      Name=Unsloth
      Comment=Run and train LLMs and diffusion models locally
      Exec=$out/bin/unsloth-studio %u
      StartupWMClass=unsloth-studio
      Icon=unsloth-studio
      Terminal=false
      Categories=Development;Science;
      MimeType=x-scheme-handler/unsloth;
      EOF
    '';

    passthru = {
      inherit
        unsloth-studio-desktop
        unsloth-studio-frontend
        unsloth-studio-llama-cpp
        ;
    };

    meta = {
      description = "Desktop application for running and training AI models locally";
      homepage = "https://unsloth.ai/";
      changelog = "https://github.com/unslothai/unsloth/releases";
      license = lib.licenses.agpl3Only;
      platforms = ["x86_64-linux"];
      mainProgram = "unsloth-studio";
      sourceProvenance = with lib.sourceTypes; [fromSource];
    };
  }
