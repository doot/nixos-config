# Module enable Forgejo
{
  config,
  lib,
  outputs,
  pkgs,
  ...
}: let
  cfg = config.roles.forgejo;
in {
  options.roles.forgejo = {
    enable =
      lib.mkEnableOption "forgejo role"
      // {
        default = false;
      };
  };
  config = lib.mkIf cfg.enable {
    environment = {
      systemPackages = with pkgs; [
        forgejo-cli
      ];
    };
    services = {
      forgejo = {
        enable = true;
        package = pkgs.unstable.forgejo;
        database.type = "sqlite3";
        # # Enable support for Git Large File Storage
        # lfs.enable = false;
        settings = {
          server = {
            DOMAIN = "git.${outputs.nixosConfigurations.nix-media-docker._module.specialArgs.fqdn}";
            ROOT_URL = "https://${config.services.forgejo.settings.server.DOMAIN}/";
            HTTP_PORT = 3333;
          };
          # # You can temporarily allow registration to create an admin user.
          service.DISABLE_REGISTRATION = true;
          # Add support for actions, based on act: https://github.com/nektos/act
          actions = {
            ENABLED = true;
            DEFAULT_ACTIONS_URL = "github";
          };
          # Sending emails is completely optional
          # You can send a test email from the web UI at:
          # Profile Picture > Site Administration > Configuration >  Mailer Configuration
          # mailer = {
          #   ENABLED = true;
          #   SMTP_ADDR = "mail.example.com";
          #   FROM = "noreply@${srv.DOMAIN}";
          #   USER = "noreply@${srv.DOMAIN}";
          # };
        };
        # mailerPasswordFile = config.age.secrets.forgejo-mailer-password.path;
      };
    };
  };
}
