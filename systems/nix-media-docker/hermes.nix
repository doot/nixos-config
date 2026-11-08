{
  lib,
  pkgs,
  config,
  outputs,
  ...
}: let
  network = import ../../common/network.nix;
  container = outputs.nixosConfigurations.nix-slopfucker.config.containers.hermes;
  webapp = container.config.services.hermes-agent.settings.webapp;
  port = toString webapp.port;
  hostname = lib.removePrefix "https://" webapp.public_url;
  slop = network.hosts.nix-slopfucker;
  tunnelGroup = "hermes-webapp";
  runtimeDirectory = "hermes-webapp-tunnel";
  socket = "/run/${runtimeDirectory}/backend.sock";
  logConfig = ''
    # Request errors can include query-string WebSocket credentials; keep only
    # fatal errors. PrivateDevices in the nginx unit forbids /dev/null here.
    error_log stderr emerg;
    access_log /var/log/nginx/hermes-webapp.access.log hermes_webapp;
  '';
in {
  users.groups.${tunnelGroup} = {};
  users.users.nginx.extraGroups = [tunnelGroup];

  systemd.services.hermes-webapp-tunnel = {
    description = "Encrypted Hermes webapp upstream";
    wantedBy = ["multi-user.target"];
    wants = ["network-online.target"];
    after = ["network-online.target"];
    restartTriggers = [config.environment.etc."ssh/ssh_known_hosts".source];
    startLimitIntervalSec = 0;
    serviceConfig = {
      DynamicUser = true;
      Group = tunnelGroup;
      RuntimeDirectory = runtimeDirectory;
      RuntimeDirectoryMode = "0750";
      UMask = "0077";
      LoadCredential = ["identity:/run/secrets/hermes-webapp-tunnel-key"];
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.openssh}/bin/ssh -F none -NT"
        "-o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none"
        "-o IdentityFile=%d/identity -o StrictHostKeyChecking=yes"
        "-o UserKnownHostsFile=none -o GlobalKnownHostsFile=/etc/ssh/ssh_known_hosts"
        "-o HostKeyAlgorithms=ssh-ed25519 -o UpdateHostKeys=no -o ForwardAgent=no"
        "-o ExitOnForwardFailure=yes -o ConnectTimeout=10"
        "-o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o GatewayPorts=no"
        "-o StreamLocalBindMask=0117 -o StreamLocalBindUnlink=yes"
        "-L ${socket}:${container.localAddress}:${port}"
        "hermes-webapp-tunnel@${slop.ip}"
      ];
      Restart = "always";
      RestartSec = "5s";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      # No PrivateDevices: inside the nmd LXC it makes /dev/null unopenable,
      # and ssh opens /dev/null for stdin even with -N.
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = ["AF_INET" "AF_UNIX"];
      CapabilityBoundingSet = "";
      LockPersonality = true;
    };
  };

  services.nginx = {
    commonHttpConfig = ''
      log_format hermes_webapp '$remote_addr [$time_local] "$request_method $uri $server_protocol" $status $body_bytes_sent';
      map $http_origin $hermes_webapp_origin_allowed {
        default 0;
        "" 1;
        "${webapp.public_url}" 1;
      }
    '';
    virtualHosts = {
      ${hostname} = {
        # The automatic redirect server cannot inherit this vhost's log policy.
        forceSSL = lib.mkForce false;
        onlySSL = true;
        basicAuthFile = "/run/secrets/hermes-webapp-nginx";
        extraConfig =
          logConfig
          + ''
            satisfy all;
          '';
      };
      hermes-http = {
        serverName = hostname;
        extraConfig = logConfig;
        locations."/".return = "308 https://${hostname}$request_uri";
      };
    };
  };

  roles.nginx-proxy.proxies = [
    {
      name = "hermes";
      unixSocket = socket;
      allowAddresses = network.localClientCidrs;
      replaceForwardedHeaders = true;
      extraConfig = ''
        if ($host != ${hostname}) { return 444; }
        if ($hermes_webapp_origin_allowed = 0) { return 403; }
        proxy_set_header Authorization "";
        proxy_set_header Proxy-Authorization "";
        proxy_set_header Forwarded "";
        proxy_set_header X-Forwarded-Prefix "";
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        client_max_body_size 32M;
        add_header Referrer-Policy "no-referrer" always;
        add_header Strict-Transport-Security "max-age=31536000" always;
      '';
    }
  ];
}
