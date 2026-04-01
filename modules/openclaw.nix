{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.openclaw;
  settingsFormat = pkgs.formats.json { };
in
{
  options.services.openclaw = {
    enable = lib.mkEnableOption "OpenClaw hardened agent infrastructure";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openclaw;
      description = "The OpenClaw package to use. Auto-fetched from npm if not provided.";
    };

    gatewayPort = lib.mkOption {
      type = lib.types.port;
      default = 3002;
      description = "Gateway listen port (`gateway.port` in openclaw.json). Binds via `gateway.bind` (loopback).";
    };

    gatewayAuthTokenFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to a **raw** gateway auth token (single line, no `KEY=value` wrapper).
        The store-built `openclaw.json` does not contain the secret; `preStart`
        injects it with `jq` after copying the template into the service directory.
        Use agenix/sops (`config.age.secrets.….path`) or another path readable by
        the `openclaw` user.
      '';
    };

    anthropicApiKeyFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to a **raw** Anthropic API key (single line, no `KEY=value` wrapper).
        OpenClaw reads it via `secrets.providers` + a file `SecretRef` (e.g. agenix
        `config.age.secrets.….path`). Ensure the decrypted file is readable by `openclaw`
        (e.g. `age.secrets.*.mode`, `owner`, `group`).
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/openclaw";
      description = ''
        Home directory for the `openclaw` user. OpenClaw loads config from
        `''${dataDir}/.openclaw/openclaw.json` (installed from the Nix-generated file on each start).
        Agent workspace is `''${dataDir}/workspace`.
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
      default = "debug";
      description = ''
        If set, sets `OPENCLAW_LOG_LEVEL` for the service (overrides `logging.*` in config).
        Prefer this for temporary debug without editing generated JSON.
      '';
    };

    controlUiAllowedOrigins = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "https://openclaw.example.com" ];
      description = ''
        Full origins for the Control UI (`gateway.controlUi.allowedOrigins`), e.g. when
        serving the UI through HTTPS on a hostname (reverse proxy). When the list is
        empty, `controlUi` is omitted from generated JSON (typical loopback-only use).
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    let
      openclawHome = "${cfg.dataDir}";
      openclawStateDir = "${cfg.dataDir}/.openclaw";
      openclawConfigPath = "${openclawStateDir}/openclaw.json";

      # Store path; copied into ~/.openclaw/openclaw.json (see preStart).
      # Gateway token: empty here — injected from `gatewayAuthTokenFile` in preStart (not in store).
      # Anthropic: file SecretRef + `secrets.providers` (raw one-line key, e.g. agenix path).
      #
      # When `controlUiAllowedOrigins` is non-empty, sets `gateway.controlUi` for HTTPS / hostname UI.
      openclawConfigFile = settingsFormat.generate "openclaw.json" {
        gateway = {
          mode = "local";
          port = cfg.gatewayPort;
          bind = "loopback";
          auth = {
            mode = "token";
            token = "";
          };
        }
        // lib.optionalAttrs (cfg.controlUiAllowedOrigins != [ ]) {
          controlUi = {
            enabled = true;
            allowedOrigins = cfg.controlUiAllowedOrigins;
          };
        };
        # models = {
        #   providers = {
        #     anthropic = {
        #       apiKey = {
        #         source = "file";
        #         provider = "anthropicApiKey";
        #         id = "value";
        #       };
        #     };
        #   };
        # };
        agents = {
          defaults = {
            model = "anthropic/claude-sonnet-4-6";
            workspace = "${openclawHome}/workspace";
          };
        };
        # secrets = {
        #   providers = {
        #     anthropic = {
        #       source = "file";
        #       path = toString cfg.anthropicApiKeyFile;
        #       mode = "singleValue";
        #     };
        #   };
        # };
        # auth = {
        #   profiles = {
        #     "anthropic:default" = {
        #       provider = "anthropic";
        #       mode = "api_key";
        #     };
        #   };
        # };
      };
    in
    {

      # ── Packages ──
      environment.systemPackages = [ cfg.package ];

      systemd.tmpfiles.rules = [
        "d ${openclawHome} 0750 openclaw openclaw -"
        "d ${openclawStateDir} 0750 openclaw openclaw -"
        "d ${openclawHome}/workspace 0750 openclaw openclaw -"
      ];

      # ── Main gateway service ──
      systemd.services.openclaw-gateway = {
        description = "OpenClaw Gateway";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];

        preStart = ''
          # Default config path: ~/.openclaw/openclaw.json (HOME = dataDir for this user)
          install -m640 ${openclawConfigFile} ${openclawConfigPath}
          ${pkgs.jq}/bin/jq --rawfile tok ${toString cfg.gatewayAuthTokenFile} \
            '.gateway.auth.token = ($tok | rtrimstr("\n"))' \
            ${openclawConfigPath} > ${openclawConfigPath}.new
          mv ${openclawConfigPath}.new ${openclawConfigPath}
          chmod 640 ${openclawConfigPath}
        '';

        serviceConfig = {
          Type = "simple";
          # `gateway run` starts the WebSocket server in the foreground. Do not use
          # `gateway start` here — that subcommand only talks to the *user* systemd
          # unit (systemctl --user) and fails without a session bus (e.g. system services).
          ExecStart = "${cfg.package}/bin/openclaw gateway run";
          EnvironmentFile = cfg.anthropicApiKeyFile;
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

        environment = {
          HOME = openclawHome;
          OPENCLAW_HOME = openclawHome;
          OPENCLAW_STATE_DIR = openclawStateDir;
          OPENCLAW_CONFIG_PATH = openclawConfigPath;
          OPENCLAW_LOG_LEVEL = cfg.logLevel;
          NODE_ENV = "production";
          # Tells OpenClaw the gateway is managed by Nix/NixOS (disables built-in
          # `gateway install` / uninstall flows that assume user systemd).
          OPENCLAW_NIX_MODE = "1";
        };
      };

      users.groups.openclaw = { };
      users.users.openclaw = {
        isSystemUser = true;
        group = "openclaw";
        home = cfg.dataDir;
        description = "OpenClaw service user";
      };
    }
  );
}
