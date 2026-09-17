# The Tauri shell: studio/src-tauri, built straight from source.
#
# Upstream's release pipeline runs `cargo tauri build`, which shells out to npm
# for the frontend and then produces .deb/.AppImage bundles. Neither step helps
# here: the frontend is its own derivation and Nix does the packaging, so this
# builds the crate directly and lets tauri-build embed the prebuilt web assets
# through the `custom-protocol` feature.
#
# This is the unwrapped app. package.nix puts it inside an FHS environment,
# which is what lets the shell bootstrap its Python backend on first run.
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
  gsettings-desktop-schemas,
  gtk3,
  hicolor-icon-theme,
  libayatana-appindicator,
  libsoup_3,
  openssl,
  pango,
  shared-mime-info,
  webkitgtk_4_1,
  unsloth-src,
  unsloth-studio-frontend,
  version,
}:
rustPlatform.buildRustPackage {
  pname = "unsloth-studio-unwrapped";
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
  '';

  nativeBuildInputs = [
    pkg-config
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

  postInstall = ''
    # install.rs resolves the installer through Tauri's Resource directory,
    # which the .deb bundler would have populated. On Linux tauri-utils resolves
    # that to `<dir of the running exe>/../lib/<productName>` and canonicalizes
    # it, and tauri-codegen sets productName from tauri.conf.json -- "Unsloth".
    # Without this the first-run bootstrap fails with "Failed to resolve bundled
    # install.sh". wrapGAppsHook's wrapper keeps the binary in $out/bin, so the
    # relative lookup still lands here.
    install -Dm755 install.sh $out/lib/Unsloth/install.sh

    install -Dm644 studio/src-tauri/icons/128x128.png \
      $out/share/icons/hicolor/128x128/apps/unsloth-studio.png
    install -Dm644 studio/src-tauri/icons/32x32.png \
      $out/share/icons/hicolor/32x32/apps/unsloth-studio.png
  '';

  passthru = {
    inherit unsloth-studio-frontend;
  };

  meta = {
    description = "Tauri shell for Unsloth Studio (unwrapped)";
    homepage = "https://unsloth.ai/";
    license = lib.licenses.agpl3Only;
    platforms = ["x86_64-linux"];
    mainProgram = "unsloth-studio";
    sourceProvenance = with lib.sourceTypes; [fromSource];
  };
}
