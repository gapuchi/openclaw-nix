{ pkgs }:

let
  pin = {
    version = "2026.4.2";
    npmTarballHash = "sha256-tbXIalz/wOlNcM/3dceVENkF/vDMqrJk/Cse2+1en3A=";
    # Generated with: nix build .#openclaw (set to fakeHash first, then use the correct hash from the error)
    pnpmDepsHash = "sha256-aHepSWiQ4+UyjPHBF+4+M9/nFrgfCw422q671saJM+U=";
  };

  nodejs = pkgs.nodejs_24;
  lockfile = ../pnpm-lock.yaml;

  # Combine tarball + lockfile + .npmrc into a proper source.
  # The published npm tarball excludes pnpm-lock.yaml and .npmrc, so we inject
  # them here. node-linker=hoisted is required so workspace sub-package deps
  # (e.g. @buape/carbon from extensions/discord) are hoisted to the top-level
  # node_modules, matching the upstream repo's configuration.
  src = pkgs.stdenv.mkDerivation {
    name = "openclaw-src-${pin.version}";
    src = pkgs.fetchurl {
      url = "https://registry.npmjs.org/openclaw/-/openclaw-${pin.version}.tgz";
      hash = pin.npmTarballHash;
    };
    phases = [
      "unpackPhase"
      "installPhase"
    ];
    installPhase = ''
      cp -r . $out
      cp ${lockfile} $out/pnpm-lock.yaml
      echo 'node-linker=hoisted' > $out/.npmrc
    '';
    sourceRoot = "package";
  };
in
pkgs.stdenv.mkDerivation (finalAttrs: {
  pname = "openclaw";
  inherit src;
  version = pin.version;

  pnpmDeps = pkgs.fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    hash = pin.pnpmDepsHash;
    fetcherVersion = 3;
  };

  nativeBuildInputs = with pkgs; [
    nodejs
    pnpm
    pnpmConfigHook
    python3
    pkg-config
    makeWrapper
  ];

  buildInputs = with pkgs; [
    vips # for sharp prebuilt binaries
  ];

  # The package is pre-built (dist/ included in npm tarball)
  # so we just need to install deps and create wrappers
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/node_modules/openclaw
    cp -r . $out/lib/node_modules/openclaw

    # sharp needs its platform-specific prebuilt binary
    cd $out/lib/node_modules/openclaw
    ${nodejs}/bin/node node_modules/sharp/install/check.js 2>/dev/null || true

    # Ensure the openclaw binary wrapper exists
    mkdir -p $out/bin
    makeWrapper "${nodejs}/bin/node" "$out/bin/openclaw" \
      --add-flags "$out/lib/node_modules/openclaw/openclaw.mjs" \
      --set NODE_PATH "$out/lib/node_modules"

    runHook postInstall
  '';

  meta = with pkgs.lib; {
    description = "OpenClaw — AI agent infrastructure platform";
    homepage = "https://github.com/openclaw/openclaw";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "openclaw";
  };
})
