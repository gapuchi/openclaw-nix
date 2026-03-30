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

      # Standalone packages
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          nodejs = pkgs.nodejs_24;

          version = "2026.3.28";

          # Combine tarball + lockfile into a proper source
          src = pkgs.stdenv.mkDerivation {
            name = "openclaw-src-${version}";
            src = pkgs.fetchurl {
              url = "https://registry.npmjs.org/openclaw/-/openclaw-${version}.tgz";
              hash = "sha256-/XCaOfXRTAL3c/N+GKq8D1GAw3N7Jvce+pCwba/D7cI=";
            };
            phases = [
              "unpackPhase"
              "installPhase"
            ];
            installPhase = ''
              cp -r . $out
              cp ${./package-lock.json} $out/package-lock.json
            '';
            sourceRoot = "package";
          };
        in
        {
          openclaw = pkgs.buildNpmPackage {
            pname = "openclaw";
            inherit src;
            inherit version;
            inherit nodejs;

            # Generated with: prefetch-npm-deps package-lock.json
            npmDepsHash = "sha256-v2UB5lpEJDHneLn7Uz5utsbn85CxJOTdwJkphXjJbBY=";

            # Skip native compilation of optional deps (node-llama-cpp, etc)
            # Sharp will use prebuilt binaries
            npmFlags = [
              "--ignore-scripts"
              "--legacy-peer-deps"
            ];
            makeCacheWritable = true;

            nativeBuildInputs = with pkgs; [
              python3
              pkg-config
              makeWrapper
            ];

            buildInputs = with pkgs; [
              vips # for sharp prebuilt binaries
            ];

            # The package is pre-built (dist/ included in npm tarball)
            # so we just need to install deps and create wrappers
            dontNpmBuild = true;

            postInstall = ''
              # sharp needs its platform-specific prebuilt binary
              # Run install/check to download it (network allowed in this phase
              # only if using --impure; otherwise sharp falls back gracefully)
              cd $out/lib/node_modules/openclaw
              ${nodejs}/bin/node node_modules/sharp/install/check.js 2>/dev/null || true

              # Ensure the openclaw binary wrapper exists
              mkdir -p $out/bin
              rm -f $out/bin/openclaw 2>/dev/null || true
              makeWrapper "${nodejs}/bin/node" "$out/bin/openclaw" \
                --add-flags "$out/lib/node_modules/openclaw/openclaw.mjs" \
                --set NODE_PATH "$out/lib/node_modules"
            '';

            meta = with pkgs.lib; {
              description = "OpenClaw — AI agent infrastructure platform";
              homepage = "https://github.com/openclaw/openclaw";
              license = licenses.mit;
              platforms = platforms.linux;
              mainProgram = "openclaw";
            };
          };

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
