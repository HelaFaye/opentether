# OpenTether

Uses your Android phone's internet connection as a router WAN via USB tethering over ADB and SOCKS5.

Plug in your phone → approve USB debugging → internet works. No app required beyond any SOCKS5 proxy app on the phone.

## How it works

1. Phone is plugged into router USB
2. USB hotplug fires, `adb start-server` runs
3. Phone shows "Allow USB debugging?" — user approves
4. `adb forward tcp:1088 tcp:1088` tunnels the proxy to localhost
5. `hev-socks5-tunnel` creates `s5tun0` virtual interface
6. Default route and DNS are pinned through the tunnel
7. All LAN clients use the phone's internet connection

## Packages

| Package | Repo | Contents |
|---|---|---|
| `opentether` | this repo | init service, hotplug scripts, UCI config, `opentether-check` |
| `luci-app-opentether` | [luci-app-opentether](https://github.com/HelaFaye/luci-app-opentether) | LuCI web interface |

## Dependencies

- `hev-socks5-tunnel`
- `adb`
- `curl`

## Building

```sh
cp -r opentether /path/to/openwrt/package/
cd /path/to/openwrt
make menuconfig   # select Network → opentether
make package/opentether/compile V=s
```

## Installing

The output path varies by target architecture. Replace `aarch64_cortex-a53` with your router's architecture.

**apk (OpenWrt 24+ snapshot builds):**
```sh
scp bin/packages/<arch>/base/opentether-*.apk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 "apk add --allow-untrusted /tmp/opentether-*.apk"
```

**opkg (OpenWrt stable releases):**
```sh
scp bin/packages/<arch>/base/opentether-*.ipk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 "opkg install /tmp/opentether-*.ipk"
```


## Phone setup

Install [Socks5](https://github.com/heiher/socks5) on your Android phone and configure it to listen on port 1088 (or whatever port you configure in OpenTether). It's a lightweight SOCKS5 server by the same author as hev-socks5-tunnel. Enable USB debugging in Developer Options, plug into the router, and approve the debug prompt.


## Headless configuration (UCI)

All settings are stored in `/etc/config/opentether` and can be configured without the web UI:

```sh
# SOCKS5 proxy
uci set opentether.socks5.port='1088'
uci set opentether.socks5.address='127.0.0.1'
uci set opentether.socks5.udp='tcp'

# Tunnel interface
uci set opentether.tunnel.name='s5tun0'
uci set opentether.tunnel.mtu='1440'
uci set opentether.tunnel.ipv4='198.18.0.1'
uci set opentether.tunnel.ipv6='fc00::1'

# Apply — regenerates YAML and restarts tunnel
uci commit opentether
/usr/lib/opentether/setup.sh apply
```

Full UCI schema: `opentether.tunnel`, `opentether.socks5`, `opentether.mapdns`, `opentether.misc`.

## Package signing

To avoid `--allow-untrusted` / unsigned package warnings, you can host these in your own signed feed. See the [OpenWrt package signing documentation](https://openwrt.org/docs/guide-developer/package-signing).

## Diagnostics

```sh
opentether-check   # full status: ADB, process, interface, routes, connectivity, DNS, log
logread | grep opentether
```
