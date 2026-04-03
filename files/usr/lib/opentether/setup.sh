#!/bin/sh
# /usr/lib/opentether/setup.sh
# Called by postinst (install), prerm (remove), and the LuCI save handler (apply).
# Usage: setup.sh install | setup.sh remove | setup.sh apply

YAML=/etc/hev-socks5-tunnel/main.yml
YAML_BACKUP=/etc/hev-socks5-tunnel/main.yml.pre-opentether

uget() { uci -q get "opentether.$1" 2>/dev/null; }
bool() { [ "$1" = "1" ] && echo "true" || echo "false"; }
opt()  { [ -n "$2" ] && [ "$2" != "0" ] && printf "  %s: %s\n" "$1" "$2"; }
optq() { [ -n "$2" ] && printf "  %s: '%s'\n" "$1" "$2"; }

exact_forward_active() {
    local dev="$1" port="$2"
    adb -s "$dev" forward --list 2>/dev/null | awk -v p="tcp:${port}" '
        $2 == p && $3 == p { found=1; exit }
        END { exit(found ? 0 : 1) }'
}

active_device() {
    adb devices 2>/dev/null | awk '/\tdevice$/{print $1; exit}'
}

generate_yaml() {
    [ -f "$YAML" ] || return 1

    cat > "$YAML" << YAML
tunnel:
  name: $(uget tunnel.name || echo s5tun0)
  mtu: $(uget tunnel.mtu || echo 1440)
  multi-queue: $(bool "$(uget tunnel.multi_queue)")
  ipv4: $(uget tunnel.ipv4 || echo 198.18.0.1)
  ipv6: '$(uget tunnel.ipv6 || echo fc00::1)'
$(optq "post-up-script"  "$(uget tunnel.post_up_script)")
$(optq "pre-down-script" "$(uget tunnel.pre_down_script)")

socks5:
  port: $(uget socks5.port || echo 1088)
  address: $(uget socks5.address || echo 127.0.0.1)
  udp: '$(uget socks5.udp || echo tcp)'
$(optq "udp-address" "$(uget socks5.udp_address)")
$([ "$(uget socks5.pipeline)" = "1" ] && echo "  pipeline: true" || true)
$(optq "username" "$(uget socks5.username)")
$(optq "password" "$(uget socks5.password)")
$(opt  "mark"     "$(uget socks5.mark)")

mapdns:
  address: $(uget mapdns.address || echo 127.0.0.1)
  port: $(uget mapdns.port || echo 1088)
  network: $(uget mapdns.network || echo 100.64.0.0)
  netmask: $(uget mapdns.netmask || echo 255.192.0.0)
  cache-size: $(uget mapdns.cache_size || echo 10000)

misc:
  task-stack-size: $(uget misc.task_stack_size || echo 86016)
  tcp-buffer-size: $(uget misc.tcp_buffer_size || echo 65536)
  udp-recv-buffer-size: $(uget misc.udp_recv_buffer_size || echo 524288)
$(opt  "udp-copy-buffer-nums"    "$(uget misc.udp_copy_buffer_nums)")
$(opt  "max-session-count"       "$(uget misc.max_session_count)")
$(opt  "connect-timeout"         "$(uget misc.connect_timeout)")
$(opt  "tcp-read-write-timeout"  "$(uget misc.tcp_rw_timeout)")
$(opt  "udp-read-write-timeout"  "$(uget misc.udp_rw_timeout)")
$(optq "log-file"                "$(uget misc.log_file)")
$(optq "log-level"               "$(uget misc.log_level)")
$(optq "pid-file"                "$(uget misc.pid_file)")
$(opt  "limit-nofile"            "$(uget misc.limit_nofile)")
YAML
}

_yget_sec() {
    local yaml="$1" section="$2" key="$3"
    sed -n "/^${section}:/,/^[^ ]/{ /^  ${key}:/{ s/^  ${key}:[[:space:]]*//; s/['\"]//g; s/#.*//; s/[[:space:]]*$//; p; q } }" "$yaml"
}

import_yaml() {
    local yaml="/etc/hev-socks5-tunnel/main.yml"
    [ -f "$yaml" ] || { echo "ERROR: no YAML at $yaml" >&2; exit 1; }
    local v
    v=$(_yget_sec "$yaml" "tunnel" "name");          [ -n "$v" ] && uci set "opentether.tunnel.name=$v"
    v=$(_yget_sec "$yaml" "tunnel" "mtu");           [ -n "$v" ] && uci set "opentether.tunnel.mtu=$v"
    v=$(_yget_sec "$yaml" "tunnel" "multi-queue");   [ -n "$v" ] && uci set "opentether.tunnel.multi_queue=$([ "$v" = "true" ] && echo 1 || echo 0)"
    v=$(_yget_sec "$yaml" "tunnel" "ipv4");          [ -n "$v" ] && uci set "opentether.tunnel.ipv4=$v"
    v=$(_yget_sec "$yaml" "tunnel" "ipv6");          [ -n "$v" ] && uci set "opentether.tunnel.ipv6=$v"
    v=$(_yget_sec "$yaml" "tunnel" "post-up-script");   uci set "opentether.tunnel.post_up_script=$v"
    v=$(_yget_sec "$yaml" "tunnel" "pre-down-script");  uci set "opentether.tunnel.pre_down_script=$v"
    v=$(_yget_sec "$yaml" "socks5" "port");          [ -n "$v" ] && uci set "opentether.socks5.port=$v"
    v=$(_yget_sec "$yaml" "socks5" "address");       [ -n "$v" ] && uci set "opentether.socks5.address=$v"
    v=$(_yget_sec "$yaml" "socks5" "udp");           [ -n "$v" ] && uci set "opentether.socks5.udp=$v"
    v=$(_yget_sec "$yaml" "socks5" "udp-address");   uci set "opentether.socks5.udp_address=$v"
    v=$(_yget_sec "$yaml" "socks5" "pipeline");      [ "$v" = "true" ] && uci set "opentether.socks5.pipeline=1" || uci set "opentether.socks5.pipeline=0"
    v=$(_yget_sec "$yaml" "socks5" "username");      uci set "opentether.socks5.username=$v"
    v=$(_yget_sec "$yaml" "socks5" "password");      uci set "opentether.socks5.password=$v"
    v=$(_yget_sec "$yaml" "socks5" "mark");          uci set "opentether.socks5.mark=${v:-0}"
    v=$(_yget_sec "$yaml" "mapdns" "address");       [ -n "$v" ] && uci set "opentether.mapdns.address=$v"
    v=$(_yget_sec "$yaml" "mapdns" "port");          [ -n "$v" ] && uci set "opentether.mapdns.port=$v"
    v=$(_yget_sec "$yaml" "mapdns" "network");       [ -n "$v" ] && uci set "opentether.mapdns.network=$v"
    v=$(_yget_sec "$yaml" "mapdns" "netmask");       [ -n "$v" ] && uci set "opentether.mapdns.netmask=$v"
    v=$(_yget_sec "$yaml" "mapdns" "cache-size");    [ -n "$v" ] && uci set "opentether.mapdns.cache_size=$v"
    v=$(_yget_sec "$yaml" "misc" "task-stack-size");        [ -n "$v" ] && uci set "opentether.misc.task_stack_size=$v"
    v=$(_yget_sec "$yaml" "misc" "tcp-buffer-size");        [ -n "$v" ] && uci set "opentether.misc.tcp_buffer_size=$v"
    v=$(_yget_sec "$yaml" "misc" "udp-recv-buffer-size");   [ -n "$v" ] && uci set "opentether.misc.udp_recv_buffer_size=$v"
    v=$(_yget_sec "$yaml" "misc" "udp-copy-buffer-nums");   uci set "opentether.misc.udp_copy_buffer_nums=$v"
    v=$(_yget_sec "$yaml" "misc" "max-session-count");      uci set "opentether.misc.max_session_count=$v"
    v=$(_yget_sec "$yaml" "misc" "connect-timeout");        uci set "opentether.misc.connect_timeout=$v"
    v=$(_yget_sec "$yaml" "misc" "tcp-read-write-timeout"); uci set "opentether.misc.tcp_rw_timeout=$v"
    v=$(_yget_sec "$yaml" "misc" "udp-read-write-timeout"); uci set "opentether.misc.udp_rw_timeout=$v"
    v=$(_yget_sec "$yaml" "misc" "log-file");               uci set "opentether.misc.log_file=$v"
    v=$(_yget_sec "$yaml" "misc" "log-level");              uci set "opentether.misc.log_level=${v:-warn}"
    v=$(_yget_sec "$yaml" "misc" "pid-file");               uci set "opentether.misc.pid_file=$v"
    v=$(_yget_sec "$yaml" "misc" "limit-nofile");           uci set "opentether.misc.limit_nofile=$v"
    uci commit opentether
    logger -t opentether "YAML imported to UCI"
    echo "Done."
}

case "$1" in
install)
    FRESH=1
    uci -q get opentether.tunnel >/dev/null 2>&1 && FRESH=0

    [ -f "$YAML_BACKUP" ] || cp "$YAML" "$YAML_BACKUP" 2>/dev/null || true

    generate_yaml

    if [ "$FRESH" = "1" ]; then
        uci -q delete network.opentether || true
        uci set network.opentether=interface
        uci set network.opentether.proto='static'
        uci set network.opentether.device="$(uget tunnel.name || echo s5tun0)"
        uci set network.opentether.ipaddr="$(uget tunnel.ipv4 || echo 198.18.0.1)"
        uci set network.opentether.netmask='255.255.255.255'
        uci set network.opentether.ip6addr='fc00::1/128'
        uci set network.opentether.metric='10'
        uci add_list network.opentether.dns='1.1.1.1'
        uci add_list network.opentether.dns='2606:4700:4700::1111'
        uci commit network

        uci -q delete firewall.opentether_zone || true
        uci set firewall.opentether_zone=zone
        uci set firewall.opentether_zone.name='opentether'
        uci set firewall.opentether_zone.network='opentether'
        uci set firewall.opentether_zone.input='REJECT'
        uci set firewall.opentether_zone.output='ACCEPT'
        uci set firewall.opentether_zone.forward='REJECT'
        uci set firewall.opentether_zone.masq='1'
        uci set firewall.opentether_zone.ip6masq='1'
        uci set firewall.opentether_zone.mtu_fix='1'

        uci -q delete firewall.opentether_forward || true
        uci set firewall.opentether_forward=forwarding
        uci set firewall.opentether_forward.src='lan'
        uci set firewall.opentether_forward.dest='opentether'
        uci commit firewall

        uci -q delete dhcp.@dnsmasq[0].server || true
        uci add_list dhcp.@dnsmasq[0].server='1.1.1.1'
        uci add_list dhcp.@dnsmasq[0].server='2606:4700:4700::1111'
        uci set dhcp.@dnsmasq[0].noresolv='1'
        uci set dhcp.@dnsmasq[0].localservice='0'
        uci commit dhcp

        /etc/init.d/opentether enable
        /etc/init.d/network restart
        /etc/init.d/firewall restart
        /etc/init.d/dnsmasq restart

        echo "OpenTether installed. Plug in your phone and approve USB debugging."
    else
        logger -t opentether "Upgrade detected — YAML regenerated without forcing tunnel restart"
        echo "OpenTether upgraded."
    fi
    ;;

import-yaml)
    import_yaml
    ;;

apply)
    generate_yaml
    uci set network.opentether.device="$(uget tunnel.name || echo s5tun0)"
    uci set network.opentether.ipaddr="$(uget tunnel.ipv4 || echo 198.18.0.1)"
    uci commit network

    ifdown opentether 2>/dev/null || true
    ifup opentether 2>/dev/null || true

    DEVICE="$(active_device || true)"
    PORT="$(uget socks5.port || echo 1088)"

    if [ -n "$DEVICE" ] && exact_forward_active "$DEVICE" "$PORT"; then
        /etc/init.d/opentether restart >/dev/null 2>&1 || true
        logger -t opentether "Applied config and restarted tunnel on active forwarded device $DEVICE"
    else
        /etc/init.d/opentether stop >/dev/null 2>&1 || true
        logger -t opentether "Applied config — tunnel left stopped until an authorized forwarded device is present"
    fi
    ;;

remove)
    if [ -f /tmp/opentether-hotplug.pid ]; then
        kill "$(cat /tmp/opentether-hotplug.pid)" 2>/dev/null || true
        rm -f /tmp/opentether-hotplug.pid
    fi
    rm -f /tmp/opentether-device
    rm -rf /tmp/opentether.lock

    /etc/init.d/opentether stop    2>/dev/null || true
    /etc/init.d/opentether disable 2>/dev/null || true

    adb forward --remove-all 2>/dev/null || true

    [ -f "$YAML_BACKUP" ] && mv "$YAML_BACKUP" "$YAML"

    uci -q delete network.opentether || true
    uci commit network
    uci -q delete firewall.opentether_zone || true
    uci -q delete firewall.opentether_forward || true
    uci commit firewall
    uci -q delete dhcp.@dnsmasq[0].server || true
    uci set dhcp.@dnsmasq[0].noresolv='0'
    uci set dhcp.@dnsmasq[0].localservice='1'
    uci commit dhcp

    rm -f /etc/resolv.conf

    /etc/init.d/network restart
    /etc/init.d/firewall restart
    /etc/init.d/dnsmasq restart
    ;;

*)
    echo "Usage: $0 install|apply|import-yaml|remove" >&2
    exit 1
    ;;
esac

exit 0
