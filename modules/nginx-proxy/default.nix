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
  config = lib.mkIf cfg.enable {
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
  };
}
