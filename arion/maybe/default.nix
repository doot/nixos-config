{
  project.name = "maybe";

  # env_file provides the following env variables that are required:
  #   - SECRET_KEY_BASE
  #   - POSTGRES_PASSWORD

  services = {
    maybe = {
      service = {
        image = "ghcr.io/maybe-finance/maybe:latest";
        container_name = "maybe";
        hostname = "maybe";
        restart = "unless-stopped";
        volumes = [
          "/docker-local/maybe/app:/rails/storage"
        ];
        ports = [
          "3060:3000/tcp"
        ];
        environment = {
          SELF_HOSTED = "true";
          RAILS_FORCE_SSL = "false";
          RAILS_ASSUME_SSL = "false";
          GOOD_JOB_EXECUTION_MODE = "async";
          DB_HOST = "postgres";
          POSTGRES_DB = "maybe_production";
          POSTGRES_USER = "maybe_user";
        };
        depends_on = {
          postgress.condition = "service_healthy";
        };
        env_file = [
          "/home/doot/secret_test/maybe/env"
        ];
      };
      out.service.pull_policy = "always";
    };

    postgress = {
      service = {
        image = "postgres:16";
        container_name = "postgres";
        hostname = "postgres";
        restart = "unless-stopped";
        volumes = [
          "/docker-local/maybe/postgres:/var/lib/postgresql/data"
        ];
        environment = {
          POSTGRES_USER = "maybe_user";
          POSTGRES_DB = "maybe_production";
        };
        healthcheck = {
          test = ["CMD-SHELL" "pg_isready -U $$POSTGRES_USER -d $$POSTGRES_DB"];
          interval = "5s";
          timeout = "5s";
          retries = 5;
          start_period = "1m";
        };
        env_file = [
          "/home/doot/secret_test/maybe/env"
        ];
      };
      out.service.pull_policy = "always";
    };
  };
}
