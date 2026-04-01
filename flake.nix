{
  description = "OpenClaw NixOS module and package";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    {
      nixosModules.default = import ./modules/openclaw.nix;

      overlays.default = final: _: {
        openclaw = import ./packages/openclaw.nix { pkgs = final; };
      };

      packages = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          openclaw = pkgs.callPackage ./packages/openclaw.nix { };
        in
        {
          inherit openclaw;
          default = openclaw;
        }
      );
    };
}
