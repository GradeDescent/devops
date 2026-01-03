{ name, nodes, pkgs, modulesPath, lib, ... }:
let
  theFrontend = pkgs.callPackage ../application/frontend/default.nix {
    API_ORIGIN = "https://api.gradedescent.com";
    API_V1_PATH = "/v1";
  };
  
  frontendPort = "3000";
in
{
  imports = [ "${modulesPath}/virtualisation/amazon-image.nix" ];

  deployment.targetHost = "gradedescent.com";
  networking.hostName = "frontend"; # must not contain dots

  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = [
    theFrontend
  ];

  # --- frontend node service ---
  systemd.services.gradedescent-frontend = {
    description = "GradeDescent Frontend (node)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      NODE_ENV = "production";
      PORT = frontendPort;
      HOST = "127.0.0.1";

      # Optional, if your frontend server needs to know:
      # API_BASE_URL = "https://api.gradedescent.com/v1";
      # APP_URL = "https://gradedescent.com";
    };

    serviceConfig = {
      ExecStart = "${theFrontend}/bin/gradedescent-frontend";
      User = "gradedesc";
      Restart = "always";
      RestartSec = "3";

      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
    };
  };

  # runtime user
  users.users.gradedesc = {
    isNormalUser = true;
    group = "gradedesc";
  };
  users.groups.gradedesc = {};

  # --- nginx + TLS ---
  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
  };

  services.nginx.virtualHosts."gradedescent.com" = {
    forceSSL = true;
    enableACME = true;
    default = true;

    locations."/" = {
      proxyPass = "http://127.0.0.1:${frontendPort}/";

      # If your node frontend uses websockets (harmless otherwise):
      proxyWebsockets = true;

      # For SPAs, *if* you want nginx to do fallback routing instead of node:
      # extraConfig = ''
      #   try_files $uri $uri/ /index.html;
      # '';
    };
  };

  services.nginx.virtualHosts."www.gradedescent.com" = {
    forceSSL = true;
    enableACME = true;
    globalRedirect = "gradedescent.com";
  };

  security.acme = {
    acceptTerms = true;
    defaults.email = "dev@gradedescent.com";
  };

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
