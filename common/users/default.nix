{pkgs, ...}: {
  users = {
    users = {
      doot = {
        isNormalUser = true;
        extraGroups = [
          "wheel"
          "docker"
        ]; # Enable ‘sudo’, 'docker' for the user.
        openssh.authorizedKeys.keys = [
          "ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAgEA4osVf7DLuEOs4g5zIFEGwW4RDFZ2UY+ueCXqvZrT7HGFxv9O6yNAGYm5+r+9Q0lH3eXN1klr9WXoPSzztILwIo41LVIsx9AfdXti3HF/FHfh89sCylUQSeOHYWLDAFdyy+tYduMhyGnqWCCcxyDcCQeCKSNIjbQy+i26c3dV8fsi9VsKleIEuCh+buf5vuOJNzHGEcO7DwvanwvS8M/6ujz0DWvgb+yYcDwFX3wN/2qOylu99atky/fLTF9tbbIcEm7/7WLqFz5uqIzO9hI8ZjWpshQBwLFLiU6ojgtnjp7EGwT1+bieBXAJO0ayDDpM4DevSZ/m0XQJyWQf1LMe1f2ZzhZjvkVrtVYjbJUaK1aABK2LrD/JxASkF5s50+Dtewl3IzvWUjMXE88wle8oLhzBviSXCdn2A4mF3rL+IKFf+sRT4xfdfIXH7B6oHwwskvlsqNh9ua14TDjBfutAyyuj6XiZn2mopKV/18OtqAgLlKCyYrr4PVm0o6FO5aWSqv/IAVZTVUIdLq3rqwWC31HIEdphUtp5HUg6v9QKt8FRfFdCtysHtdE4E2W56ps+Bl1htLMEY+YN2Nm3u6ybPOPdB3nKORsQ6jm4Gb1NzveziEwpBE5H26zYiLg3xNJVUmtuDemASi8kvecKCRBcXLn8NaDImN4QaBLavee9VSc= jhauschi@linkedin.com"
        ];
        packages = with pkgs; [];
      };

      docker-media = {
        isNormalUser = true;
        uid = 1029;
        createHome = false;
      };
    };

    groups = {
      docker-media = {
        gid = 1029;
      };
    };
  };
}
