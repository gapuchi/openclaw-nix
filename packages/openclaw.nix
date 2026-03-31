{ pkgs }:

let
  pin = {
    version = "2026.3.28";
    npmTarballHash = "sha256-/XCaOfXRTAL3c/N+GKq8D1GAw3N7Jvce+pCwba/D7cI=";
    # Generated with: prefetch-npm-deps package-lock.json
    npmDepsHash = "sha256-v2UB5lpEJDHneLn7Uz5utsbn85CxJOTdwJkphXjJbBY=";
  };

  nodejs = pkgs.nodejs_24;
  lockfile = ../package-lock.json;

  # Combine tarball + lockfile into a proper source
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
      cp ${lockfile} $out/package-lock.json
    '';
    sourceRoot = "package";
  };
in
pkgs.buildNpmPackage {
  pname = "openclaw";
  inherit src;
  inherit nodejs;
  version = pin.version;
  npmDepsHash = pin.npmDepsHash;

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
}
