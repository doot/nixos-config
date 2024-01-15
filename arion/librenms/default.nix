{
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

  services.db = {
    service.image = "mariadb:10.5";
    service.container_name = "librenms_db";
    service.restart = "unless-stopped";
    service.command = [
      "mysqld"
      "--innodb-file-per-table=1"
      "--lower-case-table-names=0"
      "--character-set-server=utf8mb4"
      "--collation-server=utf8mb4_unicode_ci"
    ];
    service.volumes = [
      "/docker-local/librenms/db:/var/lib/mysql"
    ];
    service.environment = {
      MYSQL_ALLOW_EMPTY_PASSWORD = "yes";
    };
    service.env_file = [
      "/home/doot/secret_test/librenms/env"
    ];
  };

  services.redis = {
    service.image = "redis:5.0-alpine";
    service.container_name = "librenms_redis";
    service.restart = "unless-stopped";
    service.env_file = [
      "/home/doot/secret_test/librenms/env"
    ];
  };

  services.msmtpd = {
    service.image = "crazymax/msmtpd:latest";
    service.container_name = "librenms_msmtpd";
    service.restart = "unless-stopped";
    service.env_file = [
      "/home/doot/secret_test/librenms/env"
      "/home/doot/secret_test/librenms/msmtpd.env"
    ];
  };

  services.librenms = {
    service.image = "librenms/librenms:latest";
    service.container_name = "librenms";
    service.hostname = "librenms";
    service.restart = "unless-stopped";
    service.capabilities.NET_ADMIN = true;
    service.capabilities.NET_RAW = true;
    service.ports = [
      "7000:8000/tcp"
    ];
    service.volumes = [
      "/docker-local/librenms/librenms:/data"
    ];
    service.depends_on = [
      "db"
      "redis"
      "msmtpd"
    ];
    service.env_file = [
      "/home/doot/secret_test/librenms/env"
      "/home/doot/secret_test/librenms/librenms.env"
    ];
    service.environment = {
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

  services.dispatcher = {
    service.image = "librenms/librenms:latest";
    service.container_name = "librenms_dispatcher";
    service.hostname = "librenms-dispatcher";
    service.restart = "unless-stopped";
    service.capabilities.NET_ADMIN = true;
    service.capabilities.NET_RAW = true;
    service.volumes = [
      "/docker-local/librenms/librenms:/data"
    ];
    service.depends_on = [
      "librenms"
      "redis"
    ];
    service.env_file = [
      "/home/doot/secret_test/librenms/env"
      "/home/doot/secret_test/librenms/librenms.env"
    ];
    service.environment = {
      DB_HOST = "db";
      DB_TIMEOUT = "60";
      DISPATCHER_NODE_ID = "dispatcher1";
      REDIS_HOST = "redis";
      REDIS_PORT = "6379";
      REDIS_DB = "0";
      SIDECAR_DISPATCHER = "1";
    };
  };

  services.syslogng = {
    service.image = "librenms/librenms:latest";
    service.container_name = "librenms_syslogng";
    service.hostname = "librenms-syslogng";
    service.restart = "unless-stopped";
    service.capabilities.NET_ADMIN = true;
    service.capabilities.NET_RAW = true;
    service.volumes = [
      "/docker-local/librenms/librenms:/data"
    ];
    service.depends_on = [
      "librenms"
      "redis"
    ];
    service.ports = [
      "514:514/tcp"
      "514:514/udp"
    ];
    service.env_file = [
      "/home/doot/secret_test/librenms/env"
    ];
    service.environment = {
      DB_HOST = "db";
      DB_TIMEOUT = "60";
      REDIS_HOST = "redis";
      REDIS_PORT = "6379";
      REDIS_DB = "0";
      SIDECAR_SYSLOGNG = "1";
    };
  };

  services.snmptrapd = {
    service.image = "librenms/librenms:latest";
    service.container_name = "librenms_snmptrapd";
    service.hostname = "librenms-snmptrapd";
    service.restart = "unless-stopped";
    service.capabilities.NET_ADMIN = true;
    service.capabilities.NET_RAW = true;
    service.volumes = [
      "/docker-local/librenms/librenms:/data"
    ];
    service.depends_on = [
      "librenms"
      "redis"
    ];
    service.ports = [
      "162:162/tcp"
      "162:162/udp"
    ];
    service.env_file = [
      "/home/doot/secret_test/librenms/env"
    ];
    service.environment = {
      DB_HOST = "db";
      DB_TIMEOUT = "60";
      REDIS_HOST = "redis";
      REDIS_PORT = "6379";
      REDIS_DB = "0";
      SIDECAR_SNMPTRAPD = "1";
    };
  };
}
