{
  description = "One flake. Fully hardened. Your agents, secured.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      # NixOS module — import this in your configuration.nix
      nixosModules = {
        default = import ./modules/openclaw.nix;
        openclaw = import ./modules/openclaw.nix;
      };

      # Overlay that provides pkgs.openclaw
      overlays.default = final: prev: {
        openclaw = self.packages.${final.system}.openclaw;
      };

      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          openclaw = import ./packages/openclaw.nix { inherit pkgs; };
          default = pkgs.writeShellScriptBin "openclaw-nix" "";
        }
      );

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/openclaw-nix";
        };
      });
    };
}
