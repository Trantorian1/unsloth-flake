{
  description = "Unsloth CLI and Unsloth Desktop, built from source";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    nixlib.url = "github:nix-util/nixlib";

    opencode-sandbox.url = "github:OpencodeSandbox/opencode-sandbox";

    unsloth-src.url = "github:unslothai/unsloth";
    unsloth-src.flake = false;
  };

  outputs = {
    nixlib,
    unsloth-src,
    ...
  } @ inputs: let
    systems = [
      "x86_64-linux"
      "aarch64-linux"
    ];

    util = nixlib.util {inherit systems inputs;};

    # pyproject.toml reads the version from this attribute too.
    version = builtins.head (
      builtins.match ".*__version__ = \"([^\"]+)\".*" (builtins.readFile "${unsloth-src}/unsloth/_version.py")
    );
  in {
    formatter = util.forEachSystem ({pkgs, ...}: pkgs.alejandra);

    packages = util.forEachSystem (
      {
        pkgs,
        opencode-sandbox,
        ...
      }: let
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
            # Studio's tool sandbox. On PATH so Studio does not report it
            # missing; the bwrap it runs is pinned in ./nix/sandbox.nix.
            bubblewrap
          ];

        sandboxCompat = pkgs.callPackage ./nix/sandbox.nix {};

        # Bundles the resulting executables in a FHS sandbox to accomodate for
        # Unsloth's runtime dependency fetching
        wrapPackage = package: attrs:
          pkgs.buildFHSEnv ({
              inherit targetPkgs;

              runScript = lib.getExe package;
              meta = package.meta;
            }
            // attrs
            // {
              profile = sandboxCompat.profile + (attrs.profile or "");
            });
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

          profile = ''
            export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            export GIO_EXTRA_MODULES="${pkgs.glib-networking}/lib/gio/modules:$GIO_EXTRA_MODULES"
            export CC="${pkgs.gcc}/bin/cc"
            export PATH="$UV_INSTALL_DIR''${PATH:+:$PATH}"
          '';
        };

        sandbox = opencode-sandbox.packages.sandbox.override {
          opencode-sandbox = {
            git.remote.url = "https://github.com/Trantorian1/unsloth-flake.git";
            git.shutdown.pushOnExit = false;
            git.withLocalChanges = true;

            forwardPorts = [8888];

            env.extend = with pkgs; [
              unsloth
              unsloth-desktop

              nil
              alejandra
            ];
          };
        };

        default = unsloth-desktop;
      }
    );

    apps = util.forEachSystem (
      {
        self,
        libpkgs,
        ...
      }: rec {
        unsloth-desktop = libpkgs.mkApp self.packages.unsloth-desktop;

        default = unsloth-desktop;
      }
    );
  };
}
