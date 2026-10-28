#!/bin/sh
set -eu
umask 077

mode=apply
case "$#:$*" in
    0:|1:--apply) ;;
    *)
        [ "$#" -eq 4 ] || exit 1
        case "$1" in --allow-gateway|--revoke-gateway) mode=$1 ;; *) exit 1 ;; esac
        run=$2; ip=$3; port=$4
        ;;
esac
[ "$(id -u)" -eq 0 ] && [ "${REMOTECODE_CONTEXT_NETWORK_POLICY:-}" = private-egress-v1 ] || exit 1
state_dir=/run/remotecode-context-gateways
ready=/run/remotecode-context-network-ready
lock=/run/remotecode-context-network.lock
[ ! -L "$lock" ] && [ ! -L "$state_dir" ] || exit 1
exec 9>"$lock"
chmod 0600 "$lock"
flock -x -w 5 9
mkdir -p "$state_dir"
[ -d "$state_dir" ] && [ "$(stat -c %u "$state_dir")" -eq 0 ] || exit 1
chmod 0700 "$state_dir"

validate_endpoint() {
    /usr/bin/python3 -I -S - "$1" "$2" "$3" <<'PY'
import ipaddress, sys, uuid
try:
    run, address, port = sys.argv[1:]
    assert str(uuid.UUID(run)) == run
    parsed = ipaddress.IPv4Address(address)
    assert str(parsed) == address
    assert not parsed.is_global
    assert not (parsed.is_loopback or parsed.is_multicast or parsed.is_unspecified)
    assert 1 <= len(port) <= 5 and port.isascii() and port.isdigit()
    assert 1 <= int(port) <= 65535 and str(int(port)) == port
except Exception:
    raise SystemExit(1)
PY
}

# One file per run lease (ip, port, state): concurrent runs on one VM each
# hold their own gateway endpoint.
read_lease() {
    f=$state_dir/$1
    lease_ip= lease_port= lease_state=
    [ -e "$f" ] || return 0
    [ ! -L "$f" ] && [ -f "$f" ] && [ "$(stat -c %u "$f")" -eq 0 ] || exit 1
    [ "$(wc -l < "$f")" -eq 3 ] || exit 1
    lease_ip=$(sed -n '1p' "$f")
    lease_port=$(sed -n '2p' "$f")
    lease_state=$(sed -n '3p' "$f")
    validate_endpoint "$1" "$lease_ip" "$lease_port"
    case "$lease_state" in active|revoking|revoked) ;; *) exit 1 ;; esac
}

write_lease() {
    [ ! -L "$state_dir/$1.tmp" ] || exit 1
    printf '%s\n%s\n%s\n' "$2" "$3" "$4" > "$state_dir/$1.tmp"
    chmod 0600 "$state_dir/$1.tmp"
    mv -f "$state_dir/$1.tmp" "$state_dir/$1"
}

lease_runs() {
    for f in "$state_dir"/*; do
        [ -e "$f" ] || continue
        name=${f##*/}
        case "$name" in *.tmp) rm -f "$f"; continue ;; esac
        printf '%s\n' "$name"
    done
}

apply_ipv4() {
    # Rejects first: iptables stops at the first matching rule.
    gateway_rules=
    for lease_run in $(lease_runs); do
        read_lease "$lease_run"
        case "$lease_state" in revoking|revoked)
            gateway_rules="$gateway_rules
-A RC_CONTEXT_GATEWAY -d $lease_ip/32 -p tcp --dport $lease_port -j REJECT" ;;
        esac
    done
    for lease_run in $(lease_runs); do
        read_lease "$lease_run"
        if [ "$lease_state" = active ]; then
            gateway_rules="$gateway_rules
-A RC_CONTEXT_GATEWAY -d $lease_ip/32 -p tcp --dport $lease_port -j ACCEPT"
        fi
    done
    iptables-restore --noflush <<RULES4
*filter
:RC_CONTEXT_NETWORK - [0:0]
:RC_CONTEXT_GATEWAY - [0:0]
-F RC_CONTEXT_NETWORK
-F RC_CONTEXT_GATEWAY
$gateway_rules
-A RC_CONTEXT_NETWORK -j RC_CONTEXT_GATEWAY
-A RC_CONTEXT_NETWORK -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A RC_CONTEXT_NETWORK -o lo -j ACCEPT
-A RC_CONTEXT_NETWORK -d 0.0.0.0/8 -m conntrack --ctstate NEW -j REJECT
-A RC_CONTEXT_NETWORK -d 10.0.0.0/8 -m conntrack --ctstate NEW -j REJECT
-A RC_CONTEXT_NETWORK -d 100.64.0.0/10 -m conntrack --ctstate NEW -j REJECT
-A RC_CONTEXT_NETWORK -d 169.254.0.0/16 -m conntrack --ctstate NEW -j REJECT
-A RC_CONTEXT_NETWORK -d 172.16.0.0/12 -m conntrack --ctstate NEW -j REJECT
-A RC_CONTEXT_NETWORK -d 192.0.0.0/24 -m conntrack --ctstate NEW -j REJECT
-A RC_CONTEXT_NETWORK -d 192.0.2.0/24 -m conntrack --ctstate NEW -j REJECT
-A RC_CONTEXT_NETWORK -d 192.168.0.0/16 -m conntrack --ctstate NEW -j REJECT
-A RC_CONTEXT_NETWORK -d 198.18.0.0/15 -m conntrack --ctstate NEW -j REJECT
-A RC_CONTEXT_NETWORK -d 198.51.100.0/24 -m conntrack --ctstate NEW -j REJECT
-A RC_CONTEXT_NETWORK -d 203.0.113.0/24 -m conntrack --ctstate NEW -j REJECT
-A RC_CONTEXT_NETWORK -d 224.0.0.0/4 -m conntrack --ctstate NEW -j REJECT
-A RC_CONTEXT_NETWORK -d 240.0.0.0/4 -m conntrack --ctstate NEW -j REJECT
COMMIT
RULES4
    if ! iptables -C OUTPUT -j RC_CONTEXT_NETWORK 2>/dev/null; then
        iptables -I OUTPUT 1 -j RC_CONTEXT_NETWORK
    fi
    iptables -C OUTPUT -j RC_CONTEXT_NETWORK
    iptables -C RC_CONTEXT_NETWORK -j RC_CONTEXT_GATEWAY
    for lease_run in $(lease_runs); do
        read_lease "$lease_run"
        case "$lease_state" in
            active) iptables -C RC_CONTEXT_GATEWAY -d "$lease_ip/32" -p tcp --dport "$lease_port" -j ACCEPT ;;
            revoking|revoked) iptables -C RC_CONTEXT_GATEWAY -d "$lease_ip/32" -p tcp --dport "$lease_port" -j REJECT ;;
        esac
    done
}

if [ "$mode" != apply ]; then
    validate_endpoint "$run" "$ip" "$port"
    if [ "$mode" = --allow-gateway ]; then
        [ -f "$ready" ] || exit 1
        # Another run's live endpoint cannot be shared: revoking one would cut both.
        for other in $(lease_runs); do
            [ "$other" = "$run" ] && continue
            read_lease "$other"
            [ "$lease_ip:$lease_port" != "$ip:$port" ] || [ "$lease_state" = revoked ] || exit 1
        done
        read_lease "$run"
        [ "$lease_state" != revoking ] || exit 1
        if [ "$lease_state" = active ]; then
            [ "$lease_ip:$lease_port" = "$ip:$port" ] || exit 1
        fi
        write_lease "$run" "$ip" "$port" revoking
        allow_pending=1
        trap 'if [ "$allow_pending" -eq 1 ]; then write_lease "$run" "$ip" "$port" revoking || :; apply_ipv4 || :; fi' EXIT
        write_lease "$run" "$ip" "$port" active
        apply_ipv4
        allow_pending=0
        printf '%s\n' context-gateway-lease-v1
        exit 0
    fi
    read_lease "$run"
    [ "$lease_ip:$lease_port" = "$ip:$port" ] && [ -n "$lease_state" ] || exit 1
    write_lease "$run" "$ip" "$port" revoking
    apply_ipv4
    delete_status=0
    conntrack -D -f ipv4 -p tcp -d "$ip" --dport "$port" >/dev/null 2>&1 || delete_status=$?
    [ "$delete_status" -le 1 ] || exit 1
    flows=$(conntrack -L -f ipv4 -p tcp -d "$ip" --dport "$port" 2>/dev/null) || exit 1
    [ -z "$flows" ] || exit 1
    write_lease "$run" "$ip" "$port" revoked
    printf '%s\n' context-gateway-revoked-v1
    exit 0
fi

rm -f "$ready"
apply_ipv4
for lease_run in $(lease_runs); do
    read_lease "$lease_run"
    [ "$lease_state" != revoking ] || exit 1
done
iptables -C RC_CONTEXT_NETWORK -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -C RC_CONTEXT_NETWORK -o lo -j ACCEPT
for subnet in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4; do
    iptables -C RC_CONTEXT_NETWORK -d "$subnet" -m conntrack --ctstate NEW -j REJECT
done
ip6tables-restore --noflush <<'RULES6'
*filter
:RC_CONTEXT_NETWORK - [0:0]
-F RC_CONTEXT_NETWORK
-A RC_CONTEXT_NETWORK -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A RC_CONTEXT_NETWORK -o lo -j ACCEPT
-A RC_CONTEXT_NETWORK -d fc00::/7 -m conntrack --ctstate NEW -j REJECT
-A RC_CONTEXT_NETWORK -d fe80::/10 -m conntrack --ctstate NEW -j REJECT
-A RC_CONTEXT_NETWORK -d ff00::/8 -m conntrack --ctstate NEW -j REJECT
-A RC_CONTEXT_NETWORK -d ::/128 -m conntrack --ctstate NEW -j REJECT
COMMIT
RULES6
if ! ip6tables -C OUTPUT -j RC_CONTEXT_NETWORK 2>/dev/null; then
    ip6tables -I OUTPUT 1 -j RC_CONTEXT_NETWORK
fi
ip6tables -C OUTPUT -j RC_CONTEXT_NETWORK
ip6tables -C RC_CONTEXT_NETWORK -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ip6tables -C RC_CONTEXT_NETWORK -o lo -j ACCEPT
for subnet in fc00::/7 fe80::/10 ff00::/8 ::/128; do
    ip6tables -C RC_CONTEXT_NETWORK -d "$subnet" -m conntrack --ctstate NEW -j REJECT
done
: > "$ready"
chmod 0600 "$ready"
printf '%s\n' context-network-policy-v1
