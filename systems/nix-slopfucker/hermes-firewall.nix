# Host-side confinement for the agent veth, independent of global service grants.
# Separate base chains prevent native established/DNAT accepts from bypassing it;
# unrelated traffic remains subject to the normal host firewall.
{
  lib,
  vethHost,
  hostAddress,
  allowedInternalHosts,
  allowedInternalServices,
  lanDenyCidrs,
}: {
  family = "inet";
  content = ''
    chain input {
      type filter hook input priority filter - 10; policy accept;
      iifname "${vethHost}" jump from-container
    }
    chain from-container {
      meta nfproto ipv6 drop
      ct state { established, related } ct direction reply accept
      ip daddr ${hostAddress} udp dport 53 accept
      ip daddr ${hostAddress} tcp dport 53 accept
      drop
    }
    chain forward {
      type filter hook forward priority filter - 10; policy accept;
      iifname "${vethHost}" jump egress
      oifname "${vethHost}" meta nfproto ipv6 drop
      oifname "${vethHost}" ct state { established, related } ct direction reply accept
      oifname "${vethHost}" drop
    }
    chain egress {
      meta nfproto ipv6 drop
      ${lib.concatMapStringsSep "\n" (host: "ip daddr ${host} accept") allowedInternalHosts}
      ${lib.concatMapStringsSep "\n" (svc: "ip daddr ${svc.host} tcp dport { ${lib.concatMapStringsSep ", " toString svc.ports} } accept") allowedInternalServices}
      ip daddr { ${lib.concatStringsSep ", " lanDenyCidrs} } drop
      accept
    }
  '';
}
