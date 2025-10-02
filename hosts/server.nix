{ pkgs, lib, self, ... }:

let
  # Put your SSH public key(s) here
  sshKeys = [
    "ssh-ed25519 AAAAC3NzaC1... your-key-here"
  ];

  # Production settings - EDIT THESE
  domain = "n8n154.duckdns.org";        # <- CHANGE to your domain
  acmeEmail = "admin@hyper154.pw";   # <- CHANGE to your email (ACME)
  postgresPassword = "tes154";  # <- CHANGE to a strong password
  n8nBasicUser = "hero154";         # <- CHANGE user
  n8nBasicPassword = "hero154@"; # <- CHANGE to a strong password
  n8nWebhookUrl = "https://webhook.site/6c48c5f5-f093-44e4-812f-8ecd1aaadd14";  # public webhook url (must be https)
  n8nPort = "5678";
in
{
  # Required for Garnix
  garnix.server.enable = true;
  nixpkgs.hostPlatform = "x86_64-linux";

  # Networking / firewall
  networking.firewall.allowedTCPPorts = [ 80 443 ];  # only HTTP/HTTPS
  networking.firewall.allowedUDPPorts = [ ];
  networking.firewall.enable = true;

  # Users & ssh
  services.openssh.enable = true;
  users.users.me = {
    isNormalUser = true;
    description = "deploy user";
    extraGroups = [ "wheel" "docker" "systemd-journal" ];
    openssh.authorizedKeys.keys = sshKeys;
  };
  security.sudo.wheelNeedsPassword = false;

  # Base system packages (useful tooling)
  environment.systemPackages = [
    pkgs.htop
    pkgs.git
    pkgs.jq
    pkgs.curl
  ];

  # Docker & docker-compose
  services.docker.enable = true;
  # Optional: allow the 'me' user to use the docker socket (extraGroups above)
  environment.etc."docker/daemon.json".text = ''
    {
      "log-driver": "json-file",
      "log-opts": { "max-size": "50m", "max-file": "5" }
    }
  '';

  # Provide docker-compose (v1/v2 shim may vary by nixpkgs; this references the compose binary from package)
  environment.systemPackages = lib.unique (environment.systemPackages or []) ([
    pkgs.docker
    pkgs.docker-compose
  ]);

  # Create the directory for the compose stack and the docker-compose.yml (declared files)
  environment.etc."srv/n8n/docker-compose.yml".text = ''
    version: "3.8"

    services:
      postgres:
        image: postgres:15-alpine
        restart: unless-stopped
        environment:
          POSTGRES_USER: n8n
          POSTGRES_PASSWORD: ${postgresPassword}
          POSTGRES_DB: n8n
        volumes:
          - db-data:/var/lib/postgresql/data
        healthcheck:
          test: ["CMD-SHELL", "pg_isready -U n8n"]
          interval: 10s
          timeout: 5s
          retries: 5

      n8n:
        image: n8nio/n8n:latest
        restart: unless-stopped
        ports:
          # bind to localhost only to avoid direct exposure
          - "127.0.0.1:${n8nPort}:5678"
        environment:
          DB_TYPE: postgresdb
          DB_POSTGRESDB_HOST: postgres
          DB_POSTGRESDB_PORT: "5432"
          DB_POSTGRESDB_DATABASE: n8n
          DB_POSTGRESDB_USER: n8n
          DB_POSTGRESDB_PASSWORD: ${postgresPassword}

          # n8n runtime settings
          N8N_HOST: 0.0.0.0
          N8N_PORT: "5678"
          GENERIC_TIMEZONE: "UTC"
          NODE_ENV: production

          # Basic auth for the UI (additionally proxied behind Nginx)
          N8N_BASIC_AUTH_ACTIVE: "true"
          N8N_BASIC_AUTH_USER: "${n8nBasicUser}"
          N8N_BASIC_AUTH_PASSWORD: "${n8nBasicPassword}"

          # Important: public URL used by webhooks & OAuth redirects
          WEBHOOK_URL: "${n8nWebhookUrl}"
        depends_on:
          postgres:
            condition: service_healthy
        volumes:
          - n8n-data:/home/node/.n8n

    volumes:
      db-data:
      n8n-data:
  '';

  # Systemd service to run the docker-compose stack
  systemd.services.n8n-docker-stack = {
    description = "n8n + postgres (docker-compose)";
    wants = [ "network-online.target" "docker.service" ];
    after = [ "network-online.target" "docker.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = "yes";
      # Ensure compose pulls images and brings stack up
      ExecStartPre = "${pkgs.docker}/bin/docker info >/dev/null 2>&1 || true";
      ExecStart = "${pkgs.docker-compose}/bin/docker-compose -f /srv/n8n/docker-compose.yml up -d --always-recreate-deps --remove-orphans";
      ExecStop = "${pkgs.docker-compose}/bin/docker-compose -f /srv/n8n/docker-compose.yml down --volumes";
      TimeoutStartSec = "120s";
      TimeoutStopSec = "120s";
    };
  };

  # Nginx reverse proxy with ACME (Let's Encrypt)
  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;

    # global ACME
    virtualHosts."${domain}" = {
      forceSSL = true;
      enableACME = true;
      locations."/" = {
        # Proxy to the local n8n HTTP port (bound to 127.0.0.1 above)
        proxyPass = "http://127.0.0.1:${n8nPort}";
        proxyWebsockets = true;
        extraConfig = ''
          # optional: increase timeouts for long-running executions
          proxy_read_timeout 300s;
          proxy_connect_timeout 300s;
          proxy_send_timeout 300s;
        '';
      };

      # Deny access to sensitive endpoints unless proxied
      extraConfig = ''
        # HTTP security headers (basic set)
        add_header X-Frame-Options "DENY" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header Referrer-Policy "no-referrer-when-downgrade" always;
      '';
    };
  };

  # ACME (Let's Encrypt) settings
  security.acme = {
    acceptTerms = true;
    defaults.email = acmeEmail;
    # By default will use http-01 challenge; ensure domain DNS points to this machine
  };

  # Ensure /srv/n8n exists and is owned by root (declared directory)
  systemd.tmpfiles.rules = [
    # d means directory, 0755 root root
    "d /srv/n8n 0755 root root - -"
  ];

  # Helpful notes in /etc/motd for quick reminders (optional)
  environment.etc."motd".text = ''
    n8n deployment:
      - domain: ${domain}
      - n8n internal host: 127.0.0.1:${n8nPort}
      - docker-compose at: /srv/n8n/docker-compose.yml
      - To view logs: sudo ${pkgs.dockerCompose}/bin/docker-compose -f /srv/n8n/docker-compose.yml logs -f
  '';

  # minimal logging/rotation changes can be added if desired
}
