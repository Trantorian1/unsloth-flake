{
  description = "Builds Unsloth Studio from source, with AMD (ROCm + Vulkan) inference bundled";

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

    pkgs = import nixpkgs {
      inherit system;
      config = {
        # Read by llama-cpp and the rest of the ROCm closure through `config`,
        # so one setting here rather than an override per package.
        rocmSupport = true;
        # Parts of the ROCm stack are redistributable-but-unfree. Without this
        # a build that reaches one of them stops with a licence error.
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
          unsloth-studio-desktop
          unsloth-studio-frontend
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
