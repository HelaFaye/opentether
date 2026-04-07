#!/bin/sh
# /usr/lib/opentether/setup.sh
# Subcommands:
#   install              — fresh install / upgrade
#   add-device <serial>  — register a new device, create UCI + YAML + network + firewall
#   remove-device <serial> — tear down a device's config
#   apply <serial>       — regenerate YAML, bounce interface, restart tunnel instance
#   remove               — full uninstall

YAML_DIR=/etc/hev-socks5-tunnel/devices
YAML_BACKUP_DIR=/etc/hev-socks5-tunnel/backup

# ── Helpers ────────────────────────────────────────────────────────────────────
uget()  { uci -q get "opentether.$1" 2>/dev/null; }
dget()  { uci -q get "opentether.$1.$2" 2>/dev/null; }  # device section getter
bool()  { [ "$1" = "1" ] && echo "true" || echo "false"; }
opt()   { [ -n "$2" ] && [ "$2" != "0" ] && printf "  %s: %s\n" "$1" "$2"; }
optq()  { [ -n "$2" ] && printf "  %s: '%s'\n" "$1" "$2"; }

# YAML section parser — top-level to avoid POSIX sh nested function limitation
_yget_sec() {
    local yaml="$1" section="$2" key="$3"
    sed -n "/^${section}:/,/^[^ ]/{  /^  ${key}:/{ s/^  ${key}:[[:space:]]*//; s/'//g; s/#.*//; s/[[:space:]]*$//; p; q } }" "$yaml"
}

# Find the UCI section name for a given serial
_cfg_for_serial() {
    local serial="$1"
    uci show opentether 2>/dev/null | \
    awk -F= '/\.serial=/{gsub(/'\''/, "", $2); if ($2 == "'"$serial"'") {split($1,a,"."); print a[2]}}' | head -1
}

# Get next available port starting from 1088 (only checks device sections)
_next_port() {
    local port=1088
    while uci show opentether 2>/dev/null | awk -F= '/=device$/{sec=$1} /\.port=/{if(sec) print}' | grep -q "'${port}'"; do
        port=$((port + 1))
    done
    echo $port
}

# Get next available interface index
_next_iface_idx() {
    local idx=0
    while uci show opentether 2>/dev/null | grep -q "\.iface='s5tun${idx}'"; do
        idx=$((idx + 1))
    done
    echo $idx
}

# ── YAML generation ────────────────────────────────────────────────────────────
# IMPORTANT: This function must stay in sync with buildYaml() in the LuCI
# main.js view. If you add or change a field here, update main.js too.
generate_yaml() {
    local serial="$1"
    local cfg
    cfg=$(_cfg_for_serial "$serial")
    [ -n "$cfg" ] || { echo "ERROR: no config for $serial" >&2; return 1; }

    local port   iface  ipv4   ipv6   mtu    mq
    local s5addr s5udp  pipeline
    local md_addr md_port md_network md_netmask md_cache
    local stack  buf    udp_buf

    port="$(dget $cfg port         || echo 1088)"
    iface="$(dget $cfg iface       || echo s5tun0)"
    ipv4="$(dget $cfg ipv4         || echo 198.18.0.1)"
    ipv6="$(dget $cfg ipv6         || echo fc00::1)"
    mtu="$(dget $cfg mtu           || echo 1440)"
    mq="$(dget $cfg multi_queue    || echo 0)"
    s5addr="$(dget $cfg s5_address || echo 127.0.0.1)"
    s5udp="$(dget $cfg s5_udp      || echo tcp)"
    pipeline="$(dget $cfg s5_pipeline || echo 0)"
    md_addr="$(dget $cfg md_address   || echo 127.0.0.1)"
    md_port="$(dget $cfg md_port      || echo $port)"
    md_network="$(dget $cfg md_network  || echo 100.64.0.0)"
    md_netmask="$(dget $cfg md_netmask  || echo 255.192.0.0)"
    md_cache="$(dget $cfg md_cache_size || echo 10000)"
    stack="$(dget $cfg task_stack_size  || echo 86016)"
    buf="$(dget $cfg tcp_buffer_size    || echo 65536)"
    udp_buf="$(dget $cfg udp_recv_buffer_size || echo 524288)"

    mkdir -p "$YAML_DIR"
    # Build YAML via printf to avoid blank lines from empty opt/optq calls
    {
        printf 'tunnel:\n'
        printf '  name: %s\n' "${iface}"
        printf '  mtu: %s\n' "${mtu}"
        printf '  multi-queue: %s\n' "$(bool "$mq")"
        printf '  ipv4: %s\n' "${ipv4}"
        printf "  ipv6: '%s'\n" "${ipv6}"
        [ -n "$(dget $cfg post_up_script)" ]  && printf "  post-up-script: '%s'\n"  "$(dget $cfg post_up_script)"
        [ -n "$(dget $cfg pre_down_script)" ] && printf "  pre-down-script: '%s'\n" "$(dget $cfg pre_down_script)"
        printf '\n'
        printf 'socks5:\n'
        printf '  port: %s\n' "${port}"
        printf '  address: %s\n' "${s5addr}"
        printf "  udp: '%s'\n" "${s5udp}"
        [ -n "$(dget $cfg s5_udp_address)" ] && printf "  udp-address: '%s'\n" "$(dget $cfg s5_udp_address)"
        [ "$pipeline" = "1" ] && printf '  pipeline: true\n'
        [ -n "$(dget $cfg s5_username)" ] && printf "  username: '%s'\n" "$(dget $cfg s5_username)"
        [ -n "$(dget $cfg s5_password)" ] && printf "  password: '%s'\n" "$(dget $cfg s5_password)"
        local mark; mark="$(dget $cfg s5_mark)"
        [ -n "$mark" ] && [ "$mark" != "0" ] && printf '  mark: %s\n' "$mark"
        printf '\n'
        printf 'mapdns:\n'
        printf '  address: %s\n' "${md_addr}"
        printf '  port: %s\n' "${md_port}"
        printf '  network: %s\n' "${md_network}"
        printf '  netmask: %s\n' "${md_netmask}"
        printf '  cache-size: %s\n' "${md_cache}"
        printf '\n'
        printf 'misc:\n'
        printf '  task-stack-size: %s\n' "${stack}"
        printf '  tcp-buffer-size: %s\n' "${buf}"
        printf '  udp-recv-buffer-size: %s\n' "${udp_buf}"
        local v
        v="$(dget $cfg udp_copy_buffer_nums)"; [ -n "$v" ] && [ "$v" != "0" ] && printf '  udp-copy-buffer-nums: %s\n' "$v"
        v="$(dget $cfg max_session_count)";    [ -n "$v" ] && [ "$v" != "0" ] && printf '  max-session-count: %s\n' "$v"
        v="$(dget $cfg connect_timeout)";      [ -n "$v" ] && printf '  connect-timeout: %s\n' "$v"
        v="$(dget $cfg tcp_rw_timeout)";       [ -n "$v" ] && printf '  tcp-read-write-timeout: %s\n' "$v"
        v="$(dget $cfg udp_rw_timeout)";       [ -n "$v" ] && printf '  udp-read-write-timeout: %s\n' "$v"
        v="$(dget $cfg log_file)";             [ -n "$v" ] && printf "  log-file: '%s'\n" "$v"
        v="$(dget $cfg log_level)";            [ -n "$v" ] && [ "$v" != "warn" ] && printf "  log-level: '%s'\n" "$v"
        v="$(dget $cfg pid_file)";             [ -n "$v" ] && printf "  pid-file: '%s'\n" "$v"
        v="$(dget $cfg limit_nofile)";         [ -n "$v" ] && [ "$v" != "0" ] && printf '  limit-nofile: %s\n' "$v"
    } > "${YAML_DIR}/${serial}.yml" 
    logger -t opentether "[$serial] YAML generated: ${YAML_DIR}/${serial}.yml"
}

# ── Add device ─────────────────────────────────────────────────────────────────
add_device() {
    local serial="$1"
    local name="$2"   # optional friendly name (e.g. from ro.product.model)
    [ -n "$serial" ] || { echo "Usage: $0 add-device <serial> [name]" >&2; exit 1; }

    # Idempotent — don't duplicate
    if [ -n "$(_cfg_for_serial "$serial")" ]; then
        echo "Device $serial already configured" >&2
        return 0
    fi

    local port idx iface ipv4 ipv6
    port=$(_next_port)
    idx=$(_next_iface_idx)
    iface="s5tun${idx}"
    ipv4="198.18.${idx}.1"
    ipv6="fc$(printf '%02x' $((idx + 0)))::1"
    # Keep IPs in valid ranges
    [ "$idx" -gt 0 ] && ipv4="198.18.${idx}.1"

    # Create UCI device section
    local section="device_${serial}"
    uci set "opentether.${section}=device"
    uci set "opentether.${section}.serial=${serial}"
    [ -n "$name" ] && uci set "opentether.${section}.name=${name}"
    uci set "opentether.${section}.enabled=0"   # disabled until user configures and saves
    uci set "opentether.${section}.port=${port}"
    uci set "opentether.${section}.iface=${iface}"
    uci set "opentether.${section}.mtu=1440"
    uci set "opentether.${section}.ipv4=${ipv4}"
    uci set "opentether.${section}.ipv6=${ipv6}"
    uci set "opentether.${section}.metric=10"
    uci set "opentether.${section}.ttl_mangle=0"
    uci set "opentether.${section}.s5_address=127.0.0.1"
    uci set "opentether.${section}.s5_udp=tcp"
    uci set "opentether.${section}.md_address=127.0.0.1"
    uci set "opentether.${section}.md_port=${port}"
    uci set "opentether.${section}.md_network=100.64.0.0"
    uci set "opentether.${section}.md_netmask=255.192.0.0"
    uci set "opentether.${section}.md_cache_size=10000"
    uci set "opentether.${section}.task_stack_size=86016"
    uci set "opentether.${section}.tcp_buffer_size=65536"
    uci set "opentether.${section}.udp_recv_buffer_size=524288"
    uci commit opentether

    logger -t opentether "[$serial] device registered (port=$port iface=$iface) — not yet enabled"
    echo "Device $serial registered. Configure and save in LuCI to enable."
}

# ── Apply (save and activate) ──────────────────────────────────────────────────
apply_device() {
    local serial="$1"
    [ -n "$serial" ] || { echo "Usage: $0 apply <serial>" >&2; exit 1; }

    local cfg iface ipv4 metric
    cfg=$(_cfg_for_serial "$serial")
    [ -n "$cfg" ] || { echo "ERROR: no config for $serial" >&2; exit 1; }

    iface="$(dget $cfg iface  || echo s5tun0)"
    ipv4="$(dget $cfg ipv4   || echo 198.18.0.1)"
    metric="$(dget $cfg metric || echo 10)"

    generate_yaml "$serial"

    # Sync network interface UCI
    uci set "network.ot_${serial}=interface"
    uci set "network.ot_${serial}.proto=static"
    uci set "network.ot_${serial}.device=${iface}"
    uci set "network.ot_${serial}.ipaddr=${ipv4}"
    uci set "network.ot_${serial}.netmask=255.255.255.255"
    uci set "network.ot_${serial}.metric=${metric}"
    uci commit network

    # Ensure firewall zone and forwarding exist and are up to date
    local zone="ot_zone_${serial}"
    local fwd="ot_fwd_${serial}"
    local fw_changed=0
    if ! uci -q get "firewall.${zone}" >/dev/null 2>&1; then
        uci set "firewall.${zone}=zone"
        uci set "firewall.${zone}.input=REJECT"
        uci set "firewall.${zone}.output=ACCEPT"
        uci set "firewall.${zone}.forward=REJECT"
        uci set "firewall.${zone}.masq=1"
        uci set "firewall.${zone}.ip6masq=1"
        uci set "firewall.${zone}.mtu_fix=1"
        uci set "firewall.${fwd}=forwarding"
        uci set "firewall.${fwd}.src=lan"
        uci set "firewall.${fwd}.dest=ot_${serial}"
        fw_changed=1
    fi
    # Always update name and network in case iface was renamed
    uci set "firewall.${zone}.name=ot_${serial}"
    uci set "firewall.${zone}.network=ot_${serial}"
    uci commit firewall
    [ "$fw_changed" = "1" ] && /etc/init.d/firewall restart || /etc/init.d/firewall reload

    echo f > /proc/net/nf_conntrack 2>/dev/null || true

    # Full restart so procd re-registers all instances with correct commands
    ifdown "ot_${serial}" 2>/dev/null
    ifup   "ot_${serial}" 2>/dev/null
    /etc/init.d/opentether restart
    logger -t opentether "[$serial] applied"
}

# ── Remove device ──────────────────────────────────────────────────────────────
remove_device() {
    local serial="$1"
    [ -n "$serial" ] || { echo "Usage: $0 remove-device <serial>" >&2; exit 1; }

    local cfg
    cfg=$(_cfg_for_serial "$serial")

    # Kill watchdog
    local pidfile="/tmp/opentether-watchdog-${serial}.pid"
    [ -f "$pidfile" ] && kill "$(cat $pidfile)" 2>/dev/null && rm -f "$pidfile"
    rm -rf "/tmp/opentether-${serial}.lock"

    # Stop tunnel instance and clean up PID files
    ubus call service set '{"name":"opentether","instances":{"'"${serial}"'":{"action":"stop"}}}' 2>/dev/null || true
    rm -f "/tmp/opentether-tunnel-${serial}.pid"

    # Remove forward
    adb -s "$serial" forward --remove-all 2>/dev/null || true

    # Tear down network interface
    ifdown "ot_${serial}" 2>/dev/null || true
    uci -q delete "network.ot_${serial}" || true
    uci commit network 2>/dev/null || true

    # Remove firewall zone/forward
    uci -q delete "firewall.ot_zone_${serial}" || true
    uci -q delete "firewall.ot_fwd_${serial}"  || true
    uci commit firewall 2>/dev/null || true

    # Remove YAML
    rm -f "${YAML_DIR}/${serial}.yml"

    # Remove UCI device section
    [ -n "$cfg" ] && { uci -q delete "opentether.${cfg}" || true; uci commit opentether || true; }

    /etc/init.d/opentether restart
    /etc/init.d/firewall restart

    logger -t opentether "[$serial] removed"
}

# ── Install / upgrade ──────────────────────────────────────────────────────────
install() {
    mkdir -p "$YAML_DIR" "$YAML_BACKUP_DIR"

    # Detect state:
    #   - has device sections = 1.2.x config already present, just ensure service is enabled
    #   - has legacy tunnel/socks5 sections = upgrading from 1.1.x
    #   - neither = genuine fresh install

    local has_devices has_legacy
    uci show opentether 2>/dev/null | grep -q "=device$"  && has_devices=1 || has_devices=0
    uci show opentether 2>/dev/null | grep -q "^opentether\.tunnel=" && has_legacy=1 || has_legacy=0

    if [ "$has_devices" = "1" ]; then
        # Already configured — just make sure the service is enabled and running
        /etc/init.d/opentether enable
        /etc/init.d/opentether restart
        echo "OpenTether upgraded — existing device config preserved."
        return 0
    fi

    if [ "$has_legacy" = "1" ]; then
        # Upgrading from 1.1.x — migrate old single-device config into a device section
        # Use a placeholder serial; user can rename in LuCI after identifying their device
        local port iface ipv4 ipv6 mtu metric
        port="$(uci -q get opentether.socks5.port    || echo 1088)"
        iface="$(uci -q get opentether.tunnel.name   || echo s5tun0)"
        ipv4="$(uci -q get opentether.tunnel.ipv4    || echo 198.18.0.1)"
        ipv6="$(uci -q get opentether.tunnel.ipv6    || echo fc00::1)"
        mtu="$(uci -q get opentether.tunnel.mtu      || echo 1440)"
        metric="10"

        local section="device_migrated"
        uci set "opentether.${section}=device"
        uci set "opentether.${section}.serial=migrated"
        uci set "opentether.${section}.name=Migrated from 1.1.x"
        uci set "opentether.${section}.enabled=1"
        uci set "opentether.${section}.port=${port}"
        uci set "opentether.${section}.iface=${iface}"
        uci set "opentether.${section}.mtu=${mtu}"
        uci set "opentether.${section}.ipv4=${ipv4}"
        uci set "opentether.${section}.ipv6=${ipv6}"
        uci set "opentether.${section}.metric=${metric}"
        uci set "opentether.${section}.s5_address=$(uci -q get opentether.socks5.address || echo 127.0.0.1)"
        uci set "opentether.${section}.s5_udp=$(uci -q get opentether.socks5.udp || echo tcp)"
        uci set "opentether.${section}.s5_pipeline=$(uci -q get opentether.socks5.pipeline || echo 0)"
        uci set "opentether.${section}.s5_mark=$(uci -q get opentether.socks5.mark || echo 0)"
        uci set "opentether.${section}.md_address=$(uci -q get opentether.mapdns.address || echo 127.0.0.1)"
        uci set "opentether.${section}.md_port=$(uci -q get opentether.mapdns.port || echo $port)"
        uci set "opentether.${section}.md_network=$(uci -q get opentether.mapdns.network || echo 100.64.0.0)"
        uci set "opentether.${section}.md_netmask=$(uci -q get opentether.mapdns.netmask || echo 255.192.0.0)"
        uci set "opentether.${section}.md_cache_size=$(uci -q get opentether.mapdns.cache_size || echo 10000)"
        uci set "opentether.${section}.task_stack_size=$(uci -q get opentether.misc.task_stack_size || echo 86016)"
        uci set "opentether.${section}.tcp_buffer_size=$(uci -q get opentether.misc.tcp_buffer_size || echo 65536)"
        uci set "opentether.${section}.udp_recv_buffer_size=$(uci -q get opentether.misc.udp_recv_buffer_size || echo 524288)"
        uci set "opentether.${section}.log_level=$(uci -q get opentether.misc.log_level || echo warn)"

        # Remove legacy sections
        for sec in tunnel socks5 mapdns misc; do
            uci -q delete "opentether.${sec}" || true
        done
        uci commit opentether 2>/dev/null || true

        /etc/init.d/opentether enable
        /etc/init.d/opentether restart

        # Ensure dnsmasq is configured — 1.1.x install sets this, but re-apply to be safe
        uci -q delete dhcp.@dnsmasq[0].server || true
        uci add_list dhcp.@dnsmasq[0].server='1.1.1.1'
        uci add_list dhcp.@dnsmasq[0].server='2606:4700:4700::1111'
        uci set dhcp.@dnsmasq[0].noresolv='1'
        uci set dhcp.@dnsmasq[0].localservice='0'
        uci commit dhcp
        /etc/init.d/dnsmasq restart

        echo "OpenTether upgraded from 1.1.x — config migrated. Update the device serial in LuCI."
        return 0
    fi

    # Genuine fresh install

    # ── DNS ───────────────────────────────────────────────────────────────────
    uci -q delete dhcp.@dnsmasq[0].server || true
    uci add_list dhcp.@dnsmasq[0].server='1.1.1.1'
    uci add_list dhcp.@dnsmasq[0].server='2606:4700:4700::1111'
    uci set dhcp.@dnsmasq[0].noresolv='1'
    uci set dhcp.@dnsmasq[0].localservice='0'
    uci commit dhcp
    /etc/init.d/dnsmasq restart

    /etc/init.d/opentether enable
    echo "OpenTether installed. Plug in an Android device and add it in LuCI to get started."
}

# ── Remove (full uninstall) ────────────────────────────────────────────────────
remove() {
    /etc/init.d/opentether stop    2>/dev/null
    /etc/init.d/opentether disable 2>/dev/null

    # Kill all watchdogs
    for pidfile in /tmp/opentether-watchdog-*.pid; do
        [ -f "$pidfile" ] || continue
        kill "$(cat $pidfile)" 2>/dev/null
        rm -f "$pidfile"
    done
    rm -rf /tmp/opentether-*.lock

    # Remove all device configs — avoid pipe subshell by collecting first
    local cfg serial
    for cfg in $(uci show opentether 2>/dev/null | grep "=device$" | \
                 awk -F= '{split($1,a,"."); print a[2]}'); do
        serial="$(uci -q get opentether.${cfg}.serial 2>/dev/null || true)"
        [ -n "$serial" ] && remove_device "$serial"
    done

    uci -q delete opentether.defaults
    uci commit opentether

    uci -q delete dhcp.@dnsmasq[0].server || true
    uci set dhcp.@dnsmasq[0].noresolv='0'
    uci set dhcp.@dnsmasq[0].localservice='1'
    uci commit dhcp

    rm -f /etc/resolv.conf  # dnsmasq will regenerate

    /etc/init.d/network restart
    /etc/init.d/firewall restart
    /etc/init.d/dnsmasq restart
}

# ── Import YAML → UCI ─────────────────────────────────────────────────────────
# Reads the device's YAML file and writes recognized values back to UCI.
# Useful when the YAML has been manually edited.
import_yaml() {
    local serial="$1"
    [ -n "$serial" ] || { echo "Usage: $0 import-yaml <serial>" >&2; exit 1; }

    local cfg yaml
    cfg=$(_cfg_for_serial "$serial")
    [ -n "$cfg" ] || { echo "ERROR: no config for $serial" >&2; exit 1; }

    yaml="${YAML_DIR}/${serial}.yml"
    [ -f "$yaml" ] || { echo "ERROR: no YAML at $yaml" >&2; exit 1; }

    # Parse a key from a specific section block
    # _yget_sec is defined at top level below import_yaml()

    local v
    # tunnel:
    v=$(_yget_sec "$yaml" "tunnel" "name");         [ -n "$v" ] && uci set "opentether.${cfg}.iface=$v"
    v=$(_yget_sec "$yaml" "tunnel" "mtu");          [ -n "$v" ] && uci set "opentether.${cfg}.mtu=$v"
    v=$(_yget_sec "$yaml" "tunnel" "multi-queue");  [ -n "$v" ] && uci set "opentether.${cfg}.multi_queue=$([ "$v" = "true" ] && echo 1 || echo 0)"
    v=$(_yget_sec "$yaml" "tunnel" "ipv4");         [ -n "$v" ] && uci set "opentether.${cfg}.ipv4=$v"
    v=$(_yget_sec "$yaml" "tunnel" "ipv6");         [ -n "$v" ] && uci set "opentether.${cfg}.ipv6=$v"
    v=$(_yget_sec "$yaml" "tunnel" "post-up-script");  uci set "opentether.${cfg}.post_up_script=$v"
    v=$(_yget_sec "$yaml" "tunnel" "pre-down-script"); uci set "opentether.${cfg}.pre_down_script=$v"

    # socks5:
    v=$(_yget_sec "$yaml" "socks5" "port");         [ -n "$v" ] && uci set "opentether.${cfg}.port=$v"
    v=$(_yget_sec "$yaml" "socks5" "address");      [ -n "$v" ] && uci set "opentether.${cfg}.s5_address=$v"
    v=$(_yget_sec "$yaml" "socks5" "udp");          [ -n "$v" ] && uci set "opentether.${cfg}.s5_udp=$v"
    v=$(_yget_sec "$yaml" "socks5" "udp-address");  uci set "opentether.${cfg}.s5_udp_address=$v"
    v=$(_yget_sec "$yaml" "socks5" "pipeline");     [ "$v" = "true" ] && uci set "opentether.${cfg}.s5_pipeline=1" || uci set "opentether.${cfg}.s5_pipeline=0"
    v=$(_yget_sec "$yaml" "socks5" "username");     uci set "opentether.${cfg}.s5_username=$v"
    v=$(_yget_sec "$yaml" "socks5" "password");     uci set "opentether.${cfg}.s5_password=$v"
    v=$(_yget_sec "$yaml" "socks5" "mark");         uci set "opentether.${cfg}.s5_mark=${v:-0}"

    # mapdns:
    v=$(_yget_sec "$yaml" "mapdns" "address");      [ -n "$v" ] && uci set "opentether.${cfg}.md_address=$v"
    v=$(_yget_sec "$yaml" "mapdns" "port");         [ -n "$v" ] && uci set "opentether.${cfg}.md_port=$v"
    v=$(_yget_sec "$yaml" "mapdns" "network");      [ -n "$v" ] && uci set "opentether.${cfg}.md_network=$v"
    v=$(_yget_sec "$yaml" "mapdns" "netmask");      [ -n "$v" ] && uci set "opentether.${cfg}.md_netmask=$v"
    v=$(_yget_sec "$yaml" "mapdns" "cache-size");   [ -n "$v" ] && uci set "opentether.${cfg}.md_cache_size=$v"

    # misc:
    v=$(_yget_sec "$yaml" "misc" "task-stack-size");       [ -n "$v" ] && uci set "opentether.${cfg}.task_stack_size=$v"
    v=$(_yget_sec "$yaml" "misc" "tcp-buffer-size");       [ -n "$v" ] && uci set "opentether.${cfg}.tcp_buffer_size=$v"
    v=$(_yget_sec "$yaml" "misc" "udp-recv-buffer-size");  [ -n "$v" ] && uci set "opentether.${cfg}.udp_recv_buffer_size=$v"
    v=$(_yget_sec "$yaml" "misc" "udp-copy-buffer-nums");  uci set "opentether.${cfg}.udp_copy_buffer_nums=$v"
    v=$(_yget_sec "$yaml" "misc" "max-session-count");     uci set "opentether.${cfg}.max_session_count=$v"
    v=$(_yget_sec "$yaml" "misc" "connect-timeout");       uci set "opentether.${cfg}.connect_timeout=$v"
    v=$(_yget_sec "$yaml" "misc" "tcp-read-write-timeout"); uci set "opentether.${cfg}.tcp_rw_timeout=$v"
    v=$(_yget_sec "$yaml" "misc" "udp-read-write-timeout"); uci set "opentether.${cfg}.udp_rw_timeout=$v"
    v=$(_yget_sec "$yaml" "misc" "log-file");              uci set "opentether.${cfg}.log_file=$v"
    v=$(_yget_sec "$yaml" "misc" "log-level");             uci set "opentether.${cfg}.log_level=${v:-warn}"
    v=$(_yget_sec "$yaml" "misc" "pid-file");              uci set "opentether.${cfg}.pid_file=$v"
    v=$(_yget_sec "$yaml" "misc" "limit-nofile");          uci set "opentether.${cfg}.limit_nofile=$v"

    uci commit opentether
    logger -t opentether "[$serial] YAML imported to UCI"
    echo "Done — run 'apply $serial' to activate."
}

case "$1" in
    install)      install ;;
    add-device)   add_device "$2" "$3" ;;
    apply)        apply_device "$2" ;;
    import-yaml)  import_yaml "$2" ;;
    remove-device) remove_device "$2" ;;
    remove)       remove ;;
    *)
        echo "Usage: $0 install|add-device <serial> [name]|apply <serial>|import-yaml <serial>|remove-device <serial>|remove" >&2
        exit 1
        ;;
esac

exit 0