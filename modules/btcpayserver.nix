{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services;
  inherit (config) nix-bitcoin-services;
  nbxplorer-configFile = pkgs.writeText "config" ''
    network=mainnet
    btcrpcuser=${cfg.bitcoind.rpc.users.btcpayserver.name}
    btcrpcurl=${cfg.nbxplorer.btcrpcurl}
    btcnodeendpoint=${cfg.nbxplorer.btcnodeendpoint}
    bind=${cfg.nbxplorer.bind}
  '';
  btcpayserver-configFile = pkgs.writeText "config" ''
    network=mainnet
    socksendpoint=${cfg.tor.client.socksListenAddress}
    btcexplorerurl=http://${cfg.nbxplorer.bind}:24444/
    btcexplorercookiefile=${cfg.nbxplorer.dataDir}/Main/.cookie
    bind=${cfg.btcpayserver.bind}
    ${optionalString (cfg.btcpayserver.lightning-node == "clightning") "btclightning=type=clightning;server=unix:///${cfg.clightning.dataDir}/bitcoin/lightning-rpc"}
  '';
in {
  options.services = {
    nbxplorer = {
      enable = mkEnableOption "nbxplorer";
      package = mkOption {
        type = types.package;
        default = pkgs.nix-bitcoin.nbxplorer;
        defaultText = "pkgs.nix-bitcoin.nbxplorer";
        description = "The package providing nbxplorer binaries.";
      };
      dataDir = mkOption {
        type = types.path;
        default = "/var/lib/nbxplorer";
        description = "The data directory for nbxplorer.";
      };
      user = mkOption {
        type = types.str;
        default = "nbxplorer";
        description = "The user as which to run nbxplorer.";
      };
      group = mkOption {
        type = types.str;
        default = cfg.nbxplorer.user;
        description = "The group as which to run nbxplorer.";
      };
      btcrpcurl = mkOption {
        type = types.str;
        default = "http://127.0.0.1:8332";
        description = "The RPC server url.";
      };
      btcnodeendpoint = mkOption {
        type = types.str;
        default = "127.0.0.1:8333";
        description = ''
          The p2p connection to a Bitcoin node, make sure you are whitelisted
        '';
      };
      bind = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "The address on which to bind.";
      };
      enforceTor =  nix-bitcoin-services.enforceTor;
    };
    btcpayserver = {
      enable = mkEnableOption "btcpayserver";
      package = mkOption {
        type = types.package;
        default = pkgs.nix-bitcoin.btcpayserver;
        defaultText = "pkgs.nix-bitcoin.btcpayserver";
        description = "The package providing btcpayserver binaries.";
      };
      dataDir = mkOption {
        type = types.path;
        default = "/var/lib/btcpayserver";
        description = "The data directory for btcpayserver.";
      };
      user = mkOption {
        type = types.str;
        default = "btcpayserver";
        description = "The user as which to run btcpayserver.";
      };
      group = mkOption {
        type = types.str;
        default = cfg.btcpayserver.user;
        description = "The group as which to run btcpayserver.";
      };
      bind = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "The address on which to bind.";
      };
      lightning-node = mkOption {
        type = types.nullOr (types.enum [ "clightning" "lnd" ]);
        default = null;
        description = "The lightning node implementation to use.";
      };
      enforceTor =  nix-bitcoin-services.enforceTor;
    };
  };


  config = mkIf cfg.btcpayserver.enable {
    assertions = [
      { assertion = (cfg.btcpayserver.lightning-node == "clightning") -> cfg.clightning.enable;
        message = "btcpayserver.lightning-node clightning requires clightning.";
      }
      { assertion = (cfg.btcpayserver.lightning-node == "lnd") -> cfg.lnd.enable;
        message = "btcpayserver.lightning-node lnd requires lnd.";
      }
    ];

    environment.systemPackages = with pkgs; [
      nix-bitcoin.nbxplorer
      nix-bitcoin.btcpayserver
    ]
    # OpenSSL needed to generate cert fingerprint
    ++ (optionals (cfg.btcpayserver.lightning-node == "lnd" ) [ openssl xxd ]);
    services.nbxplorer.enable = true;

    services.bitcoind.rpc.users.btcpayserver = {
      passwordHMACFromFile = true;
      rpcwhitelist = cfg.bitcoind.rpc.users.public.rpcwhitelist ++ [
        "setban"
        "generatetoaddress"
        "getpeerinfo"
      ];
    };
    nix-bitcoin.secrets.bitcoin-rpcpassword-btcpayserver = {
      user = "bitcoin";
      group = "nbxplorer";
    };
    nix-bitcoin.secrets.bitcoin-HMAC-btcpayserver.user = "bitcoin";

    services.lnd.macaroon.btcpayserver = {
      name = "btcpayserver";
      permissions = ''{"entity":"info","action":"read"},{"entity":"onchain","action":"read"},{"entity":"offchain","action":"read"},{"entity":"address","action":"read"},{"entity":"message","action":"read"},{"entity":"peers","action":"read"},{"entity":"signer","action":"read"},{"entity":"invoices","action":"read"},{"entity":"invoices","action":"write"},{"entity":"address","action":"write"}'';
    };

    users.users.${cfg.nbxplorer.user} = {
        description = "nbxplorer User";
        group = cfg.nbxplorer.group;
        extraGroups = [ "bitcoinrpc" ];
        home = cfg.nbxplorer.dataDir;
    };
    users.groups.${cfg.nbxplorer.group} = {};
    users.users.${cfg.btcpayserver.user} = {
        description = "btcpayserver User";
        group = cfg.btcpayserver.group;
        extraGroups = [ "nbxplorer" ]
        ++ (optionals (cfg.btcpayserver.lightning-node == "clightning" ) [ "clightning" ])
        ++ (optionals (cfg.btcpayserver.lightning-node == "lnd" ) [ "lnd" ]);
        home = cfg.btcpayserver.dataDir;
    };
    users.groups.${cfg.btcpayserver.group} = {};

    systemd.tmpfiles.rules = [
      "d '${cfg.nbxplorer.dataDir}' 0770 ${cfg.nbxplorer.user} ${cfg.nbxplorer.group} - -"
      "d '${cfg.btcpayserver.dataDir}' 0770 ${cfg.btcpayserver.user} ${cfg.btcpayserver.group} - -"
    ];

    systemd.services.nbxplorer = {
      description = "Run nbxplorer";
      path  = with pkgs; [
        nix-bitcoin.nbxplorer
        which
        dotnet-sdk_3 ];
      wantedBy = [ "multi-user.target" ];
      requires = [ "bitcoind.service" ];
      after = [ "bitcoind.service" ];
      preStart = ''
        cp ${nbxplorer-configFile} ${cfg.nbxplorer.dataDir}/settings.config
        chown -R '${cfg.nbxplorer.user}:${cfg.nbxplorer.group}' '${cfg.nbxplorer.dataDir}'
        chmod 600 ${cfg.nbxplorer.dataDir}/settings.config
        echo "btcrpcpassword=$(cat ${config.nix-bitcoin.secretsDir}/bitcoin-rpcpassword-btcpayserver)" >> '${cfg.nbxplorer.dataDir}/settings.config'
      '';
      postStart = ''
        while [[ ! -e ${cfg.nbxplorer.dataDir}/Main/.cookie ]]; do
          sleep 0.1
        done
        chmod 640 ${cfg.nbxplorer.dataDir}/Main/.cookie
      '';
      serviceConfig = nix-bitcoin-services.defaultHardening // {
        ExecStart = "${cfg.nbxplorer.package}/bin/NBXplorer --conf=${cfg.nbxplorer.dataDir}/settings.config --datadir=${cfg.nbxplorer.dataDir}";
        User = cfg.nbxplorer.user;
        Restart = "on-failure";
        RestartSec = "10s";
        ReadWritePaths = cfg.nbxplorer.dataDir;
        MemoryDenyWriteExecute = "false";
      } // (if cfg.nbxplorer.enforceTor
          then nix-bitcoin-services.allowTor
          else nix-bitcoin-services.allowAnyIP
        );
    };

    systemd.services.btcpayserver = {
      description = "Run btcpayserver";
      path  = with pkgs; [
        nix-bitcoin.btcpayserver
        dotnet-sdk_3 ]
      ++ (optionals (cfg.btcpayserver.lightning-node == "lnd" ) [ openssl xxd ]);
      wantedBy = [ "multi-user.target" ];
      requires = [ "nbxplorer.service" ]
      ++ (optionals (cfg.btcpayserver.lightning-node == "clightning" ) [ "clightning.service" ])
      ++ (optionals (cfg.btcpayserver.lightning-node == "lnd" ) [ "lnd.service" ]);
      after = [ "nbxplorer.service" ]
      ++ (optionals (cfg.btcpayserver.lightning-node == "clightning" ) [ "clightning.service" ])
      ++ (optionals (cfg.btcpayserver.lightning-node == "lnd" ) [ "lnd.service" ]);
      preStart = ''
        cp ${btcpayserver-configFile} ${cfg.btcpayserver.dataDir}/settings.config
        chown -R '${cfg.btcpayserver.user}:${cfg.btcpayserver.group}' '${cfg.btcpayserver.dataDir}'
        chmod 600 ${cfg.btcpayserver.dataDir}/settings.config
        ${optionalString (cfg.btcpayserver.lightning-node == "lnd") ''
          certthumbprint=$(openssl x509 -noout -fingerprint -sha256 -in ${toString config.nix-bitcoin.secretsDir}/lnd-cert | sed -e 's/.*=//;s/://g')
          echo -e "btclightning=type=lnd-rest;server=https://${toString cfg.lnd.listen}:${toString cfg.lnd.restPort}/;macaroonfilepath=/run/lnd/${cfg.lnd.macaroon.btcpayserver.name}.macaroon;certthumbprint=$certthumbprint" >> ${cfg.btcpayserver.dataDir}/settings.config
        ''}
      '';
      serviceConfig = nix-bitcoin-services.defaultHardening // {
        ExecStart = "${cfg.btcpayserver.package}/bin/btcpayserver --conf=${cfg.btcpayserver.dataDir}/settings.config --datadir=${cfg.btcpayserver.dataDir}";
        User = cfg.btcpayserver.user;
        Restart = "on-failure";
        RestartSec = "10s";
        ReadWritePaths = cfg.btcpayserver.dataDir;
        MemoryDenyWriteExecute = "false";
      } // (if cfg.btcpayserver.enforceTor
          then nix-bitcoin-services.allowTor
          else nix-bitcoin-services.allowAnyIP
        );
    };
  };
}
