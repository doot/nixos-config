{
  name = "jf";
  port = 8096;
  extraConfig = ''
    client_max_body_size 30M;
    proxy_read_timeout   600s;
    proxy_buffering off;
  '';
}
