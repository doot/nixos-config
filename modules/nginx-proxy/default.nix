# Module to generate nginx reverse proxy vhosts from a list of proxy entries
{
  config,
  lib,
  fqdn,
  ...
}: let
  cfg = config.roles.nginx-proxy;
in {
  options.roles.nginx-proxy = {
    enable =
      lib.mkEnableOption "nginx reverse proxy role"
      // {
        default = false;
      };
    acme = {
      enable =
        lib.mkEnableOption "ACME wildcard certificate"
        // {
          default = false;
        };
      email = lib.mkOption {
        type = lib.types.str;
        description = "Email for ACME account";
      };
      dnsProvider = lib.mkOption {
        type = lib.types.str;
        description = "DNS provider for ACME DNS-01 challenge";
      };
      dnsResolver = lib.mkOption {
        type = lib.types.str;
        default = "8.8.8.8";
        description = "DNS resolver for propagation checks. Needed due to using a wildcard and the fact that we hijack these DNS entries locally.";
      };
      environmentFile = lib.mkOption {
        type = lib.types.str;
        description = "Path to environment file with DNS provider credentials";
      };
    };
    proxies = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "Subdomain name for the vhost";
          };
          port = lib.mkOption {
            type = lib.types.either lib.types.int lib.types.str;
            description = "Port to proxy to (int or string)";
          };
          proxyPassHost = lib.mkOption {
            type = lib.types.str;
            default = "http://127.0.0.1";
            description = "Host to proxy to";
          };
          extraConfig = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Extra nginx config for the location block";
          };
          default = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether this is the default vhost";
          };
        };
      });
      default = [];
      description = "List of reverse proxy entries";
    };
  };
  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      networking.firewall.allowedTCPPorts = [80 443];
      services.nginx.virtualHosts = builtins.listToAttrs (
        builtins.map (proxy: {
          name = "${proxy.name}.${fqdn}";
          value = {
            inherit (proxy) default;
            useACMEHost = fqdn;
            forceSSL = true;
            locations."/" = {
              proxyPass = "${proxy.proxyPassHost}:${toString proxy.port}";
              proxyWebsockets = true;
              extraConfig = proxy.extraConfig;
            };
          };
        })
        cfg.proxies
      );
    })
    (lib.mkIf (cfg.enable && cfg.acme.enable) {
      security.acme = {
        acceptTerms = true;
        defaults.email = cfg.acme.email;
        defaults.dnsResolver = cfg.acme.dnsResolver;
        certs.${fqdn} = {
          domain = "*.${fqdn}";
          dnsProvider = cfg.acme.dnsProvider;
          dnsPropagationCheck = true;
          environmentFile = cfg.acme.environmentFile;
        };
      };
      users.users.nginx.extraGroups = ["acme"];
    })
  ];
}
