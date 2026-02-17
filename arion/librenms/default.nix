let
  common = import ../common.nix;
in {
  project.name = "librenms";

  /*
  The following environment variables are required to be set in the various env_files that are included directly below. They are explicitly not checked into this repo and are required to exist for this to work.

  MYSQL_DATABASE = "$${MYSQL_DATABASE}";
  MYSQL_USER = "$${MYSQL_USER}";
  MYSQL_PASSWORD = "$${MYSQL_PASSWORD}";
  DB_NAME = "$${MYSQL_DATABASE}";
  DB_USER = "$${MYSQL_USER}";
  DB_PASSWORD = "$${MYSQL_PASSWORD}";
  TZ = "$${TZ}";
  PUID = "$${PUID}";
  PGID = "$${PGID}";
  */

  services = {
    db = {
      service = {
        image = "mariadb:10.5";
        container_name = "librenms_db";
        restart = "unless-stopped";
        command = [
          "mysqld"
          "--innodb-file-per-table=1"
          "--lower-case-table-names=0"
          "--character-set-server=utf8mb4"
          "--collation-server=utf8mb4_unicode_ci"
        ];
        volumes = [
          "/docker-local/librenms/db:/var/lib/mysql"
        ];
        environment = {
          MYSQL_ALLOW_EMPTY_PASSWORD = "yes";
        };
        env_file = [
          "/home/doot/secret_test/librenms/env"
        ];
      };
      out.service = common.outDefaults // {cpu_shares = 512;};
    };

    redis = {
      service = {
        image = "redis:5.0-alpine";
        container_name = "librenms_redis";
        restart = "unless-stopped";
        env_file = [
          "/home/doot/secret_test/librenms/env"
        ];
      };
      out.service = common.outDefaults // {cpu_shares = 512;};
    };

    msmtpd = {
      service = {
        image = "crazymax/msmtpd:latest";
        container_name = "librenms_msmtpd";
        restart = "unless-stopped";
        env_file = [
          "/home/doot/secret_test/librenms/env"
          "/home/doot/secret_test/librenms/msmtpd.env"
        ];
      };
      out.service = common.outDefaults // {cpu_shares = 512;};
    };

    librenms = {
      service = {
        image = "librenms/librenms:latest";
        container_name = "librenms";
        hostname = "librenms";
        restart = "unless-stopped";
        capabilities.NET_ADMIN = true;
        capabilities.NET_RAW = true;
        ports = [
          "7000:8000/tcp"
        ];
        volumes = [
          "/docker-local/librenms/librenms:/data"
        ];
        depends_on = [
          "db"
          "redis"
          "msmtpd"
        ];
        env_file = [
          "/home/doot/secret_test/librenms/env"
          "/home/doot/secret_test/librenms/librenms.env"
        ];
        environment = {
          # PUID = "$${PUID}";
          # PGID = "$${PGID}";
          DB_HOST = "db";
          # DB_NAME = "$${MYSQL_DATABASE}";
          # DB_USER = "$${MYSQL_USER}";
          # DB_PASSWORD = "$${MYSQL_PASSWORD}";
          DB_TIMEOUT = "60";
          REDIS_HOST = "redis";
          REDIS_PORT = "6379";
          REDIS_DB = "0";
        };
      };
      out.service = common.outDefaults // {cpu_shares = 512;};
    };

    dispatcher = {
      service = {
        image = "librenms/librenms:latest";
        container_name = "librenms_dispatcher";
        hostname = "librenms-dispatcher";
        restart = "unless-stopped";
        capabilities.NET_ADMIN = true;
        capabilities.NET_RAW = true;
        volumes = [
          "/docker-local/librenms/librenms:/data"
        ];
        depends_on = [
          "librenms"
          "redis"
        ];
        env_file = [
          "/home/doot/secret_test/librenms/env"
          "/home/doot/secret_test/librenms/librenms.env"
        ];
        environment = {
          DB_HOST = "db";
          DB_TIMEOUT = "60";
          DISPATCHER_NODE_ID = "dispatcher1";
          REDIS_HOST = "redis";
          REDIS_PORT = "6379";
          REDIS_DB = "0";
          SIDECAR_DISPATCHER = "1";
        };
      };
      out.service = common.outDefaults;
    };

    syslogng = {
      service = {
        image = "librenms/librenms:latest";
        container_name = "librenms_syslogng";
        hostname = "librenms-syslogng";
        restart = "unless-stopped";
        capabilities.NET_ADMIN = true;
        capabilities.NET_RAW = true;
        volumes = [
          "/docker-local/librenms/librenms:/data"
        ];
        depends_on = [
          "librenms"
          "redis"
        ];
        ports = [
          "514:514/tcp"
          "514:514/udp"
        ];
        env_file = [
          "/home/doot/secret_test/librenms/env"
        ];
        environment = {
          DB_HOST = "db";
          DB_TIMEOUT = "60";
          REDIS_HOST = "redis";
          REDIS_PORT = "6379";
          REDIS_DB = "0";
          SIDECAR_SYSLOGNG = "1";
        };
      };
      out.service = common.outDefaults // {cpu_shares = 512;};
    };

    snmptrapd = {
      service = {
        image = "librenms/librenms:latest";
        container_name = "librenms_snmptrapd";
        hostname = "librenms-snmptrapd";
        restart = "unless-stopped";
        capabilities.NET_ADMIN = true;
        capabilities.NET_RAW = true;
        volumes = [
          "/docker-local/librenms/librenms:/data"
        ];
        depends_on = [
          "librenms"
          "redis"
        ];
        ports = [
          "162:162/tcp"
          "162:162/udp"
        ];
        env_file = [
          "/home/doot/secret_test/librenms/env"
        ];
        environment = {
          DB_HOST = "db";
          DB_TIMEOUT = "60";
          REDIS_HOST = "redis";
          REDIS_PORT = "6379";
          REDIS_DB = "0";
          SIDECAR_SNMPTRAPD = "1";
        };
      };
      out.service = common.outDefaults // {cpu_shares = 512;};
    };
  };
}
