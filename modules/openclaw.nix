{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.openclaw;
  settingsFormat = pkgs.formats.json { };

  gatewayBase = {
    mode = "local";
    port = cfg.gatewayPort;
    bind = "loopback";
    auth = {
      mode = "token";
      token = {
        source = "file";
        provider = "gatewayToken";
        id = "value";
      };
    };
  };

  toolsFromModule =
    lib.optionalAttrs (cfg.toolSecurity == "allowlist") { allow = cfg.toolAllowlist; }
    // lib.optionalAttrs (cfg.toolSecurity == "deny") { deny = [ "*" ]; };

  secretProviders = {
    gatewayToken = {
      source = "file";
      path = toString cfg.authTokenFile;
      mode = "singleValue";
    };
  }
  // lib.optionalAttrs (cfg.modelApiKeyFile != null) {
    modelApiKey = {
      source = "file";
      path = toString cfg.modelApiKeyFile;
      mode = "singleValue";
    };
  }
  // lib.optionalAttrs (cfg.discord.enable && cfg.discord.tokenFile != null) {
    discordToken = {
      source = "file";
      path = toString cfg.discord.tokenFile;
      mode = "singleValue";
    };
  };

  modelsBlock = lib.optionalAttrs (cfg.modelApiKeyFile != null) {
    models = {
      mode = "merge";
      providers = {
        "${cfg.modelProvider}" = {
          apiKey = {
            source = "file";
            provider = "modelApiKey";
            id = "value";
          };
        };
      };
    };
  };

  channelsInner =
    lib.optionalAttrs (cfg.telegram.enable && cfg.telegram.tokenFile != null) {
      telegram = {
        enabled = true;
        tokenFile = toString cfg.telegram.tokenFile;
      };
    }
    // lib.optionalAttrs (cfg.discord.enable && cfg.discord.tokenFile != null) {
      discord = {
        enabled = true;
        token = {
          source = "file";
          provider = "discordToken";
          id = "value";
        };
      };
    };

  channelsBlock = lib.optionalAttrs (channelsInner != { }) { channels = channelsInner; };

  openclawConfig = lib.foldl' lib.recursiveUpdate { } [
    { secrets.providers = secretProviders; }
    { gateway = lib.recursiveUpdate gatewayBase cfg.extraGatewayConfig; }
    (lib.optionalAttrs (toolsFromModule != { }) { tools = toolsFromModule; })
    modelsBlock
    channelsBlock
  ];

  # Store path; copied into ~/.openclaw/openclaw.json for the service (see preStart).
  openclawConfigFile = settingsFormat.generate "openclaw.json" openclawConfig;
in
{
  options.services.openclaw = {
    enable = lib.mkEnableOption "OpenClaw hardened agent infrastructure";

    package = lib.mkOption {
      type = lib.types.package;
      default =
        pkgs.openclaw or (pkgs.stdenv.mkDerivation rec {
          pname = "openclaw";
          version = cfg.version;
          nativeBuildInputs = with pkgs; [
            nodejs_22
            cacert
          ];
          buildInputs = with pkgs; [ nodejs_22 ];
          dontUnpack = true;
          buildPhase = ''
            export HOME=$TMPDIR
            export npm_config_cache=$TMPDIR/npm-cache
            mkdir -p $npm_config_cache
            npm install --global --prefix=$out openclaw@${version}
          '';
          installPhase = ''
            mkdir -p $out/bin
            for f in $out/lib/node_modules/.bin/*; do
              name=$(basename $f)
              [ ! -e "$out/bin/$name" ] && ln -sf "$f" "$out/bin/$name"
            done
          '';
          meta.description = "OpenClaw agent infrastructure";
        });
      defaultText = lib.literalExpression "pkgs.openclaw (auto-built from npm if not in nixpkgs)";
      description = "The OpenClaw package to use. Auto-fetched from npm if not provided.";
    };

    version = lib.mkOption {
      type = lib.types.str;
      default = "2026.2.6-3";
      description = "OpenClaw version (used for npm/docker install fallback).";
    };

    domain = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "agents.example.com";
      description = "Public domain for Caddy TLS. Leave empty to disable Caddy.";
    };

    gatewayPort = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = "Gateway listen port (`gateway.port` in openclaw.json). Binds via `gateway.bind` (loopback).";
    };

    authTokenFile = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/openclaw/auth-token";
      description = "Path to file containing the gateway auth token. Auto-generated if missing.";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/openclaw";
      description = ''
        Home directory for the `openclaw` user. OpenClaw loads config from
        `''${dataDir}/.openclaw/openclaw.json` (installed from the Nix-generated file on each start).
      '';
    };

    # --- Tool Security ---
    toolSecurity = lib.mkOption {
      type = lib.types.enum [
        "deny"
        "allowlist"
      ];
      default = "allowlist";
      description = ''
        Tool execution security mode.
        "deny" blocks all tool execution. "allowlist" permits only listed tools.
        Note: "full" mode is intentionally excluded — it grants unrestricted access.
      '';
    };

    toolAllowlist = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "read"
        "write"
        "edit"
        "web_search"
        "web_fetch"
        "message"
        "tts"
      ];
      description = ''
        Tools permitted when toolSecurity = "allowlist".
        Defaults are safe read/write/search tools. exec, browser, nodes excluded by default.
        Add "exec" only if you understand the implications.
      '';
    };

    # --- Plugins ---
    telegram = {
      enable = lib.mkEnableOption "Telegram channel";
      tokenFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Bot token file (`channels.telegram.tokenFile` in openclaw.json).";
      };
    };

    discord = {
      enable = lib.mkEnableOption "Discord channel";
      tokenFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Bot token file (`channels.discord.token` via SecretRef in openclaw.json).";
      };
    };

    # --- Model ---
    modelProvider = lib.mkOption {
      type = lib.types.str;
      default = "anthropic";
      description = ''
        Provider id for `models.providers.<id>.apiKey` when `modelApiKeyFile` is set
        (must match OpenClaw catalog ids, e.g. `anthropic`, `openai`).
      '';
    };

    modelApiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        If set, registers a SecretRef-backed API key at
        `models.providers.<modelProvider>.apiKey` in openclaw.json.
      '';
    };

    # --- Updates ---
    autoUpdate = {
      enable = lib.mkEnableOption "automatic OpenClaw updates via systemd timer";
      schedule = lib.mkOption {
        type = lib.types.str;
        default = "weekly";
        description = "systemd calendar expression for update checks.";
      };
    };

    # --- Advanced ---
    extraGatewayConfig = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = ''
        Extra attributes deep-merged into the `gateway` object in openclaw.json.
        See OpenClaw gateway configuration reference for valid keys.
      '';
    };

    logLevel = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.enum [
          "debug"
          "info"
          "warn"
          "error"
          "trace"
        ]
      );
      default = null;
      description = ''
        If set, sets `OPENCLAW_LOG_LEVEL` for the service (overrides `logging.*` in config).
        Prefer this for temporary debug without editing generated JSON.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open firewall ports (443 for HTTPS, 22 for SSH).";
    };
  };

  config = lib.mkIf cfg.enable {

    # ── Packages ──
    environment.systemPackages = [ cfg.package ];

    # ── Auth token generation ──
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 openclaw openclaw -"
      "d ${cfg.dataDir}/.openclaw 0750 openclaw openclaw -"
    ];

    # ── Main gateway service ──
    systemd.services.openclaw-gateway = {
      description = "OpenClaw Gateway (hardened)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      preStart = ''
        # Auto-generate auth token if missing
        if [ ! -f "${cfg.authTokenFile}" ]; then
          ${pkgs.openssl}/bin/openssl rand -hex 32 > "${cfg.authTokenFile}"
          chmod 600 "${cfg.authTokenFile}"
          echo "Generated new gateway auth token at ${cfg.authTokenFile}"
        fi
        # Default config path: ~/.openclaw/openclaw.json (HOME = dataDir for this user)
        install -m640 ${openclawConfigFile} ${cfg.dataDir}/.openclaw/openclaw.json
      '';

      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/openclaw gateway start";
        Restart = "on-failure";
        RestartSec = 5;
        WorkingDirectory = cfg.dataDir;
        StateDirectory = "openclaw";

        # ── Hardening ──
        DynamicUser = false; # We use a dedicated user below
        User = "openclaw";
        Group = "openclaw";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
          "AF_NETLINK"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = false; # Node.js needs JIT
        ReadWritePaths = [ cfg.dataDir ];
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
          "~@resources"
        ];
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        UMask = "0077";
      };

      environment = lib.mkMerge [
        {
          HOME = toString cfg.dataDir;
          OPENCLAW_HOME = toString cfg.dataDir;
          NODE_ENV = "production";
        }
        (lib.mkIf (cfg.logLevel != null) {
          OPENCLAW_LOG_LEVEL = cfg.logLevel;
        })
      ];
    };

    # ── Dedicated user ──
    users.users.openclaw = {
      isSystemUser = true;
      group = "openclaw";
      home = cfg.dataDir;
      description = "OpenClaw service user";
    };
    users.groups.openclaw = { };

    # ── Caddy reverse proxy ──
    services.caddy = lib.mkIf (cfg.domain != "") {
      enable = true;
      virtualHosts."${cfg.domain}" = {
        extraConfig = ''
          reverse_proxy 127.0.0.1:${toString cfg.gatewayPort}

          header {
            Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
            X-Content-Type-Options "nosniff"
            X-Frame-Options "DENY"
            Referrer-Policy "strict-origin-when-cross-origin"
            -Server
          }
        '';
      };
    };

    # ── Firewall ──
    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedTCPPorts = [
        443
        80
      ]; # 80 for ACME redirect
    };

    # ── Fail2ban ──
    services.fail2ban = {
      enable = true;
      maxretry = 5;
      bantime = "1h";
      bantime-increment.enable = true;
    };

    # ── Auto-update timer ──
    systemd.services.openclaw-update = lib.mkIf cfg.autoUpdate.enable {
      description = "OpenClaw auto-update";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.writeShellScript "openclaw-update" ''
          echo "Checking for OpenClaw updates..."
          ${
            pkgs.nixos-rebuild or pkgs.writeShellScript "noop" "echo 'nixos-rebuild not available'"
          }/bin/nixos-rebuild switch --flake /etc/nixos#$(hostname) --upgrade 2>&1 || true
        ''}";
      };
    };

    systemd.timers.openclaw-update = lib.mkIf cfg.autoUpdate.enable {
      description = "OpenClaw update timer";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.autoUpdate.schedule;
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };
  };
}
