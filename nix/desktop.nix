# The Tauri shell: studio/src-tauri, built straight from source.
#
# Upstream's release pipeline runs `cargo tauri build`, which shells out to npm
# for the frontend and then produces .deb/.AppImage bundles. Neither step helps
# here: the frontend is its own derivation and Nix does the packaging, so this
# builds the crate directly and lets tauri-build embed the prebuilt web assets
# through the `custom-protocol` feature.
#
# This is also where the app is wrapped, because the GTK/GSettings wrapper and
# the variables that point the shell at its bundled runtime have to end up in a
# single wrapper rather than two nested ones.
{
  lib,
  rustPlatform,
  pkg-config,
  wrapGAppsHook3,
  atk,
  cairo,
  gdk-pixbuf,
  glib,
  glib-networking,
  gtk3,
  gsettings-desktop-schemas,
  hicolor-icon-theme,
  libayatana-appindicator,
  libsoup_3,
  openssl,
  pango,
  shared-mime-info,
  webkitgtk_4_1,
  unsloth-src,
  unsloth-studio-frontend,
  unsloth-studio-backend,
  unsloth-studio-llama-cpp,
  version,
}:
rustPlatform.buildRustPackage {
  pname = "unsloth-studio";
  inherit version;

  src = unsloth-src;

  cargoRoot = "studio/src-tauri";
  buildAndTestSubdir = "studio/src-tauri";

  cargoLock = {
    lockFile = "${unsloth-src}/studio/src-tauri/Cargo.lock";
    # Cargo.toml takes `fix-path-env` straight from git. `allowBuiltinFetchGit`
    # resolves it with builtins.fetchGit at the revision Cargo.lock pins, which
    # keeps evaluation pure and avoids an `outputHashes` entry that would need
    # regenerating whenever upstream moves the pin.
    allowBuiltinFetchGit = true;
  };

  postPatch = ''
    # tauri-build reads tauri.conf.json at compile time and embeds whatever
    # frontendDist names. `beforeBuildCommand` is left alone deliberately: it is
    # the Tauri CLI's hook, and building the crate with cargo never runs it.
    substituteInPlace studio/src-tauri/tauri.conf.json \
      --replace-fail '"frontendDist": "../frontend/dist"' \
                     '"frontendDist": "${unsloth-studio-frontend}"'

    # The desktop shell resolves the Python backend at a fixed location under
    # $HOME, which it then offers to bootstrap with uv over the network. Nix
    # supplies a complete backend instead, so teach the lookup to accept one by
    # environment variable and keep the $HOME path as the fallback for a
    # user-managed install.
    substituteInPlace studio/src-tauri/src/process.rs \
      --replace-fail 'pub fn find_unsloth_binary() -> Option<std::path::PathBuf> {
    let home = dirs::home_dir()?;' 'pub fn find_unsloth_binary() -> Option<std::path::PathBuf> {
    // Set by the Nix wrapper to the backend built alongside this binary.
    if let Some(bin) = std::env::var_os("UNSLOTH_STUDIO_BACKEND_BIN") {
        let bin = std::path::PathBuf::from(bin);
        if bin.is_file() {
            return Some(bin);
        }
    }

    let home = dirs::home_dir()?;'
  '';

  nativeBuildInputs = [
    pkg-config
    # Brings makeWrapper with it, and creates the single wrapper that
    # preFixup below contributes to.
    wrapGAppsHook3
  ];

  buildInputs = [
    atk
    cairo
    gdk-pixbuf
    glib
    glib-networking
    gsettings-desktop-schemas
    gtk3
    hicolor-icon-theme
    libayatana-appindicator
    libsoup_3
    openssl
    pango
    shared-mime-info
    webkitgtk_4_1
  ];

  # reqwest's default-tls feature links native-tls; build that against nixpkgs'
  # openssl rather than letting openssl-sys vendor and compile its own copy.
  env.OPENSSL_NO_VENDOR = "1";

  # The crate's tests cover $HOME path handling and the managed-venv layout,
  # neither of which exists in the sandbox.
  doCheck = false;

  # wrapGAppsHook3 picks these up and folds them into the single wrapper it
  # creates, so the app gets its GTK environment and its runtime pointers at
  # once instead of through nested wrappers.
  preFixup = ''
    gappsWrapperArgs+=(
      # Skip the $HOME bootstrap: the backend is already built and complete.
      --set UNSLOTH_STUDIO_BACKEND_BIN "${unsloth-studio-backend}/bin/unsloth"

      # Likewise for inference. Without this the backend downloads a llama.cpp
      # release into ~/.unsloth/studio on first run; this one is built from
      # nixpkgs with the AMD backends enabled.
      --set UNSLOTH_LLAMA_CPP_PATH "${unsloth-studio-llama-cpp}"

      # The store binary is read-only, so an in-app update can only fail
      # partway through. This package is the update mechanism.
      --set UNSLOTH_DISABLE_UPDATE_CHECK "1"

      # WebKitGTK's DMA-BUF renderer renders black under many drivers, which for
      # this app means an empty window with no error.
      --set WEBKIT_DISABLE_DMABUF_RENDERER "1"
    )
  '';

  postInstall = ''
    install -Dm644 studio/src-tauri/icons/128x128.png \
      $out/share/icons/hicolor/128x128/apps/unsloth-studio.png
    install -Dm644 studio/src-tauri/icons/32x32.png \
      $out/share/icons/hicolor/32x32/apps/unsloth-studio.png

    # studio/src-tauri/linux/unsloth.desktop is a Handlebars template the Tauri
    # bundler fills in; write the resolved entry directly instead.
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
      unsloth-studio-frontend
      unsloth-studio-backend
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
