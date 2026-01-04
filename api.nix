{ name, nodes, pkgs, modulesPath, lib, ... }:
let
  theServer = pkgs.callPackage ../application/default.nix { };

  # strip trailing newline so keys work cleanly in URLs/vars
  readKey = path: lib.strings.removeSuffix "\n" (builtins.readFile path);

  # ---- secrets (create these files next to hive.nix) ----
  dbPass           = readKey ./postgres-password.key;      # password for Postgres role "gradedescent"
  jwtSecret        = readKey ./jwt-secret.key;
  serviceTokenSalt = readKey ./service-token-salt.key;
  openaiKey = readKey ./openai.key;

  # ---- app settings ----
  appPort = "3000";

  # IMPORTANT: use 127.0.0.1 (avoid localhost -> ::1 issues)
  dbHost = "127.0.0.1";
  dbPort = "5432";

  dbName = "gradedescent";
  shadowDbName = "gradedescentshadow";

  databaseUrl =
    "postgresql://gradedescent:${dbPass}@${dbHost}:${dbPort}/${dbName}?schema=public";
  shadowDatabaseUrl =
    "postgresql://gradedescent:${dbPass}@${dbHost}:${dbPort}/${shadowDbName}?schema=public";
in
{
  imports = [ "${modulesPath}/virtualisation/amazon-image.nix" ];

  deployment.targetHost = "api.gradedescent.com";
  networking.hostName = "api"; # must not contain dots

  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = [
    theServer
  ];

  # --- Postgres on-box ---
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_16;

    ensureDatabases = [ dbName shadowDbName ];
    ensureUsers = [
      { name = "gradedescent"; }
    ];

    # Password auth over TCP localhost; peer for local socket access.
    authentication = lib.mkOverride 10 ''
      # TYPE  DATABASE          USER          ADDRESS         METHOD
      local   all               all                           peer
      host    all               gradedescent   127.0.0.1/32    scram-sha-256
      host    all               gradedescent   ::1/128         scram-sha-256
    '';
  };

  # --- DB init (separate oneshot so Postgres service doesn't fail) ---
  systemd.services.gradedescent-db-init = {
    description = "Initialize GradeDescent Postgres role/password/ownership";
    after = [ "postgresql.service" ];
    wants = [ "postgresql.service" ];
    wantedBy = [ "multi-user.target" ];

    # give us psql + pg_isready
    path = [ pkgs.postgresql_16 ];

    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
    };

    script = ''
      set -euo pipefail

      # Wait until Postgres is responding
      for i in $(seq 1 30); do
        pg_isready -h 127.0.0.1 -p 5432 && break
        sleep 1
      done
      pg_isready -h 127.0.0.1 -p 5432

      # Ensure role exists, set password safely
      psql -v ON_ERROR_STOP=1 --set=pass="${dbPass}" <<'SQL'
      DO $$
      BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'gradedescent') THEN
          CREATE ROLE gradedescent LOGIN;
        END IF;
      END $$;

      ALTER ROLE gradedescent WITH LOGIN PASSWORD :'pass';
SQL

      # Ensure DB ownership
      psql -v ON_ERROR_STOP=1 -c "ALTER DATABASE ${dbName} OWNER TO gradedescent;" || true
      psql -v ON_ERROR_STOP=1 -c "ALTER DATABASE ${shadowDbName} OWNER TO gradedescent;" || true

      # Ensure schema privileges for Prisma (writes into schema "public")
      psql -v ON_ERROR_STOP=1 -d ${dbName} -c "GRANT USAGE, CREATE ON SCHEMA public TO gradedescent;"
      psql -v ON_ERROR_STOP=1 -d ${dbName} -c "ALTER SCHEMA public OWNER TO gradedescent;" || true

      psql -v ON_ERROR_STOP=1 -d ${shadowDbName} -c "GRANT USAGE, CREATE ON SCHEMA public TO gradedescent;"
      psql -v ON_ERROR_STOP=1 -d ${shadowDbName} -c "ALTER SCHEMA public OWNER TO gradedescent;" || true
    '';
  };

  # --- nginx + TLS ---
  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
  };

  services.nginx.virtualHosts."api.gradedescent.com" = {
    forceSSL = true;
    enableACME = true;
    default = true;

    locations."/" = {
      proxyPass = "http://127.0.0.1:${appPort}/";
    };
  };

  security.acme.acceptTerms = true;
  security.acme.certs."api.gradedescent.com".email = "dev@gradedescent.com";

  # --- Prisma migrations (run before node starts) ---
  systemd.services.prisma-migrate = {
    description = "Prisma migrate deploy (GradeDescent)";

    after = [ "network-online.target" "postgresql.service" "gradedescent-db-init.service" ];
    wants = [ "network-online.target" "postgresql.service" ];
    requires = [ "gradedescent-db-init.service" ];

    wantedBy = [ "multi-user.target" ];

    # Put openssl + pg_isready on PATH for this unit
    path = [ pkgs.openssl pkgs.postgresql_16 ];

    environment = {
      NODE_ENV = "production";
      DATABASE_URL = databaseUrl;
      SHADOW_DATABASE_URL = shadowDatabaseUrl;
    };

    serviceConfig = {
      Type = "oneshot";
      User = "gradedesc";

      ExecStartPre = "${pkgs.bash}/bin/bash -lc 'for i in {1..30}; do ${pkgs.postgresql_16}/bin/pg_isready -h 127.0.0.1 -p 5432 && exit 0; sleep 1; done; exit 1'";
      ExecStart = "${theServer}/bin/gradedescent-migrate deploy";
    };
  };

  # --- node service ---
  systemd.services.node = {
    description = "GradeDescent API (node service)";

    after = [ "network-online.target" "postgresql.service" "prisma-migrate.service" ];
    wants = [ "network-online.target" "postgresql.service" ];
    requires = [ "prisma-migrate.service" ];

    wantedBy = [ "multi-user.target" ];

    # helps runtime Prisma/OpenSSL too (harmless if not needed)
    path = [ pkgs.openssl ];

    environment = {
      DATABASE_URL = databaseUrl;
      SHADOW_DATABASE_URL = shadowDatabaseUrl;

      JWT_SECRET = jwtSecret;
      SERVICE_TOKEN_SALT = serviceTokenSalt;

      PORT = appPort;
      NODE_ENV = "production";

      APP_URL = "http://localhost:${appPort}";
      API_BASE_URL = "http://localhost:${appPort}/v1";

      EMAIL_FROM = "GradeDescent <no-reply@gradedescent.com>";
      EMAIL_PROVIDER = "console"; # console | ses | sendgrid | smtp

      RATE_LIMIT_PER_MINUTE = "100";
      MAGIC_LINK_TTL_MINUTES = "15";

      AWS_REGION="us-east-2";
      ARTIFACTS_BUCKET="artifacts.gradedescent.com";

      OPENAI_KEY= openaiKey;
    };

    serviceConfig = {
      ExecStart = "${theServer}/bin/gradedescent-api";
      User = "gradedesc";
      Restart = "always";
      RestartSec = "3";

      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
    };
  };

  # runtime user for node/prisma
  users.users.gradedesc = {
    isNormalUser = true;
    group = "gradedesc";
  };
  users.groups.gradedesc = {};

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
