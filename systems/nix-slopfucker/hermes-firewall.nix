{
  lib,
  vethHost,
  hostAddress,
  allowedInternalHosts,
  allowedInternalServices,
  lanDenyCidrs,
  enableIPv6,
}: let
  egressRules = lib.concatStringsSep "\n" (
    (map (host: "-A hermes-egress -d ${host} -j ACCEPT") allowedInternalHosts)
    ++ (lib.concatMap (
        svc:
          map (port: "-A hermes-egress -d ${svc.host} -p tcp --dport ${toString port} -j ACCEPT") svc.ports
      )
      allowedInternalServices)
    ++ (map (cidr: "-A hermes-egress -d ${cidr} -j DROP") lanDenyCidrs)
    ++ ["-A hermes-egress -j ACCEPT"]
  );
  families = ["iptables"] ++ lib.optional enableIPv6 "ip6tables";
in ''
  # Query failures other than a missing rule must not become duplicate guards.
  hermes_delete_jump() {
    local tool="$1" chain="$2" target="$3" status
    shift 3
    # -C returns a syntax error for a not-yet-created user chain.
    if [ "$target" != DROP ]; then
      if "$tool" -w -S "$target" >/dev/null 2>&1; then
        :
      else
        status=$?
        [ "$status" -eq 1 ] && return 0
        return "$status"
      fi
    fi
    if "$tool" -w -C "$chain" "$@" -j "$target" 2>/dev/null; then
      printf -- '-D %s %s -j %s\n' "$chain" "$*" "$target"
    else
      status=$?
      [ "$status" -eq 1 ] || return "$status"
    fi
  }
  ${lib.concatMapStrings (tool: ''
      input_delete=$(hermes_delete_jump ${tool} INPUT hermes-input -i ${vethHost}) || exit $?
      egress_delete=$(hermes_delete_jump ${tool} FORWARD hermes-egress -i ${vethHost}) || exit $?
      ingress_delete=$(hermes_delete_jump ${tool} FORWARD DROP -o ${vethHost} -m conntrack ! --ctstate ESTABLISHED,RELATED) || exit $?
      # --noflush replaces only the declared chains; COMMIT publishes all changes.
      ${tool}-restore --wait --noflush <<EOF || exit $?
      *filter
      :hermes-input - [0:0]
      :hermes-egress - [0:0]
      ${
        if tool == "iptables"
        then ''
          -A hermes-input -m conntrack --ctstate ESTABLISHED,RELATED --ctdir REPLY -j ACCEPT
          -A hermes-input -d ${hostAddress} -p udp --dport 53 -j ACCEPT
          -A hermes-input -d ${hostAddress} -p tcp --dport 53 -j ACCEPT
          -A hermes-input -j DROP
          ${egressRules}
        ''
        else ''
          -A hermes-input -j DROP
          -A hermes-egress -j DROP
        ''
      }
      $input_delete
      $egress_delete
      $ingress_delete
      -I INPUT 1 -i ${vethHost} -j hermes-input
      -I FORWARD 1 -i ${vethHost} -j hermes-egress
      -I FORWARD 1 -o ${vethHost} -m conntrack ! --ctstate ESTABLISHED,RELATED -j DROP
      COMMIT
      EOF
    '')
    families}
''
