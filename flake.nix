{
  description = "Pure and reproducible flake which builds Unsloth Studio from source, with an AMD/ROCm runtime bundled";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";

    # Unsloth Studio's source. `flake = false` because upstream ships no flake:
    # nix locks it by narHash in flake.lock, so `nix flake update unsloth-src`
    # moves the package to the latest `main` with no hash to maintain by hand.
    unsloth-src = {
      url = "github:unslothai/unsloth";
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    unsloth-src,
    ...
  }: let
    system = "x86_64-linux";

    # rocmSupport is read by torch, bitsandbytes, llama-cpp and friends through
    # `config`, so setting it once here gives the whole closure an AMD backend
    # instead of overriding each package separately.
    pkgs = import nixpkgs {
      inherit system;
      config = {
        rocmSupport = true;
        allowUnfree = true;
      };
    };

    lib = pkgs.lib;

    unsloth-studio = pkgs.callPackage ./package.nix {
      inherit unsloth-src;
    };
  in {
    packages.${system} =
      {
        default = unsloth-studio;
        inherit unsloth-studio;
      }
      # The individual stages, so a failure can be bisected and so each can be
      # built (and cached) on its own.
      // {
        inherit
          (unsloth-studio.passthru)
          unsloth-studio-frontend
          unsloth-studio-backend
          unsloth-studio-llama-cpp
          ;
      };

    apps.${system} = rec {
      default = unsloth-studio;
      unsloth-studio = {
        type = "app";
        program = lib.getExe self.packages.${system}.unsloth-studio;
        meta = self.packages.${system}.unsloth-studio.meta;
      };
    };

    overlays.default = final: prev: {
      inherit (self.packages.${prev.stdenv.hostPlatform.system}) unsloth-studio;
    };

    devShells.${system}.default = pkgs.mkShell {
      packages = [self.packages.${system}.unsloth-studio];
    };

    formatter.${system} = pkgs.alejandra;
  };
}
