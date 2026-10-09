{
  description = "Unsloth CLI and Unsloth Desktop, built from source";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";

    unsloth-src.url = "github:unslothai/unsloth";
    unsloth-src.flake = false;
  };

  outputs = {
    self,
    nixpkgs,
    unsloth-src,
    ...
  }: let
    systems = [
      "x86_64-linux"
      "aarch64-linux"
    ];

    forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

    # pyproject.toml reads the version from this attribute too.
    version = builtins.head (
      builtins.match ".*__version__ = \"([^\"]+)\".*" (builtins.readFile "${unsloth-src}/unsloth/_version.py")
    );
  in {
    formatter = forAllSystems (pkgs: pkgs.alejandra);

    packages = forAllSystems (
      pkgs: let
        inherit (pkgs) lib;

        # Runtime dependencies which unsloth or unsloth studio will not fetch
        # automatically themselves.
        targetPkgs = _:
          with pkgs; [
            getent
            procps
            util-linux
            curl
            git
            pciutils
            iproute2
            uv
            python3
            xdg-utils
            desktop-file-utils
            zlib
            vulkan-loader
            rocmPackages.rocminfo

            # Needed by unsloth desktop for sandboxing
            bubblewrap
          ];

        # Statically linked `true`. Unsloth's sandbox preflight (sandbox_linux.py,
        # _preflight) executes realpath(/usr/bin/true) inside a minimal bwrap sandbox that
        # only binds the FHS system roots. Nix's /usr/bin/true is a symlink to the coreutils
        # multicall: its applet dispatch keys off argv[0] (which becomes "coreutils" after
        # realpath), and its glibc lives under /nix/store, which the preflight does not bind.
        # A static copy stored under its own name runs in that sandbox.
        staticTrue =
          pkgs.runCommandCC "fhs-static-true" {
            buildInputs = [pkgs.stdenv.cc.libc.static or null];
          } ''
            printf 'int main(void){return 0;}\n' > true.c
            $CC -static -O2 -s -o $out true.c
          '';

        # Unsloth's OS-sandbox trust check (studio/backend/core/inference/sandbox_linux.py,
        # _trusted_bwrap_path) requires bwrap and every ancestor directory up to / to be
        # root-owned and not group/other-writable. The FHS rootfs normally holds a symlink
        # into /nix/store, which is 1775 root:nixbld (group-writable), so the check rejects
        # it and Studio reports "OS sandbox is not available". Replace the symlink with a
        # real copy of the binary: realpath then stays at /usr/bin/bwrap, whose ancestors
        # (the read-only rootfs dirs plus the runtime tmpfs root) all pass the check.
        trustedBwrapRootfs = ''
          if [ -e $out/usr/bin/bwrap ]; then
            rm $out/usr/bin/bwrap
            cp ${pkgs.bubblewrap}/bin/bwrap $out/usr/bin/bwrap
            chmod 0555 $out/usr/bin/bwrap
          fi
          if [ -e $out/usr/bin/true ]; then
            rm $out/usr/bin/true
            cp ${staticTrue} $out/usr/bin/true
            chmod 0555 $out/usr/bin/true
          fi
        '';

        # Studio builds its own uv venv under $HOME/.unsloth/studio at first run. Point it
        # at the store's CPython (3.13, upstream's default for x86_64 Linux) so the venv's
        # bin/python is a symlink into /nix/store: sandbox_linux.prepare() only binds
        # /nix/store into the OS tool sandbox when realpath(sys.executable) lives there,
        # and without that bind every FHS command (store binaries with store-path ELF
        # interpreters) fails to exec inside the sandbox.
        studioVenvPython = ''
          export UNSLOTH_PYTHON=${pkgs.python313}/bin/python3
        '';

        # Bundles the resulting executables in a FHS sandbox to accomodate for
        # Unsloth's runtime dependency fetching
        wrapPackage = package: attrs:
          pkgs.buildFHSEnv ({
              inherit targetPkgs;

              runScript = lib.getExe package;
              meta = package.meta;

              extraBuildCommands = trustedBwrapRootfs;
            }
            // attrs);
      in rec {
        unsloth-frontend = pkgs.callPackage ./nix/frontend.nix {
          inherit version unsloth-src;
        };

        unsloth-unwrapped = pkgs.callPackage ./nix/unsloth-unwrapped.nix {
          inherit version unsloth-src;
        };

        unsloth-desktop-unwrapped = pkgs.callPackage ./nix/unsloth-desktop-unwrapped.nix {
          inherit version unsloth-src unsloth-frontend;
        };

        unsloth = wrapPackage unsloth-unwrapped {
          name = "unsloth";

          profile = studioVenvPython;
        };

        unsloth-desktop = wrapPackage unsloth-desktop-unwrapped {
          name = "unsloth-desktop";

          executableName = ".unsloth-desktop-fhs";

          extraBwrapArgs = [
            ''''${UNSLOTH_DESKTOP_EXE:+--ro-bind ${unsloth-desktop-unwrapped}/bin/.unsloth-desktop-real "$UNSLOTH_DESKTOP_EXE"}''
          ];

          extraInstallCommands = ''
            cat > $out/bin/unsloth-desktop <<EOF
            #!${pkgs.runtimeShell}
            export UNSLOTH_DESKTOP_EXE=$out/bin/unsloth-desktop
            exec $out/bin/.unsloth-desktop-fhs "\$@"
            EOF
            chmod +x $out/bin/unsloth-desktop
            ln -s ${unsloth-desktop-unwrapped}/lib $out/lib
            ln -s ${unsloth-desktop-unwrapped}/share $out/share
          '';

          profile =
            studioVenvPython
            + ''
              export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
              export GIO_EXTRA_MODULES="${pkgs.glib-networking}/lib/gio/modules:$GIO_EXTRA_MODULES"
              export CC="${pkgs.gcc}/bin/cc"
              export PATH="$UV_INSTALL_DIR''${PATH:+:$PATH}"
            '';
        };

        default = unsloth-desktop;
      }
    );

    apps = forAllSystems (
      pkgs: let
        inherit (pkgs) lib;
        packages = self.packages.${pkgs.stdenv.hostPlatform.system};
      in rec {
        unsloth-desktop = {
          type = "app";
          program = lib.getExe packages.unsloth-desktop;
          meta = packages.unsloth-desktop.meta;
        };

        default = unsloth-desktop;
      }
    );
  };
}
