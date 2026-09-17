{
  description = "Pure and reproducible overlay which bundles the latest version of unsloth desktop";

  inputs.nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";

  outputs = {
    self,
    nixpkgs,
    ...
  }: let
    system = "x86_64-linux";
    pkgs = import nixpkgs {inherit system;};
    lib = pkgs.lib;
  in {
    packages.${system} = rec {
      default = unsloth-desktop;
      unsloth-desktop = pkgs.callPackage ./package.nix {};
    };

    apps.${system} = rec {
      default = unsloth-desktop;
      unsloth-desktop = {
        type = "app";
        program = lib.getExe self.packages.${system}.unsloth-desktop;
        meta = self.packages.${system}.unsloth-desktop.meta;
      };
    };

    overlays.default = final: prev: {
      inherit (self.packages.${prev.stdenv.hostPlatform.system}) unsloth-desktop;
    };

    devShells.${system}.default = pkgs.mkShell {
      buildInputs = [self.packages.${system}.unsloth-desktop];
    };
  };
}
