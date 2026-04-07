# OpenTether

OpenTether bridges any Android device running a SOCKS5 proxy to any OpenWrt router's WAN connection via ADB port forwarding and [hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel). Once installed, plug in your device, approve the USB debugging prompt, and all LAN clients will route their traffic through the device's internet connection automatically — no manual configuration required after initial setup.

Multiple devices are supported simultaneously. Each device gets its own isolated tunnel interface, firewall zone, ADB forward, and procd service instance. Devices can be added, removed, enabled, and disabled independently through the LuCI web interface or via UCI on the command line.

## How it works

1. An Android device is plugged into the router's USB port
2. The USB hotplug script detects the connection and starts the ADB server
3. The device displays an "Allow USB debugging?" prompt — the user approves it
4. `adb forward` establishes a TCP tunnel from `127.0.0.1:<port>` on the router to the SOCKS5 proxy running on the device
5. `hev-socks5-tunnel` creates a virtual TUN interface (e.g. `s5tun0`) and routes all traffic through it
6. The default route and DNS resolver are pinned through the tunnel interface
7. All LAN clients transparently use the device's internet connection

A watchdog process monitors the ADB connection, port forward, and tunnel process every 5 seconds. If the forward is lost it is re-established automatically. If the device is unplugged the tunnel is stopped and the router falls back to whatever the next available route is.

## Multi-device support

Each registered device gets its own:

- **UCI section** — `opentether.device_<serial>` storing all per-device configuration
- **TUN interface** — a dedicated virtual network interface (e.g. `s5tun0`, `s5tun1`)
- **ADB port forward** — a unique local port mapped to the device's SOCKS5 proxy
- **hev-socks5-tunnel instance** — a separate procd-managed tunnel process with its own YAML config at `/etc/hev-socks5-tunnel/devices/<serial>.yml`
- **Firewall zone and forwarding rule** — isolated from other devices and from WAN
- **Watchdog** — an independent background process monitoring the device's connection

Devices are registered through the LuCI Configuration tab using the **Add Device** section. Registered devices can be enabled or disabled without removing them. Route metrics control which device is preferred when multiple are active — lower metric = higher priority.

## Packages

| Package | Repo | Contents |
|---|---|---|
| `opentether` | this repo | init service, hotplug scripts, UCI config, `opentether-check` |
| `luci-app-opentether` | [luci-app-opentether](https://github.com/HelaFaye/luci-app-opentether) | LuCI web interface |

## Dependencies

- `hev-socks5-tunnel`
- `adb`
- `curl`
- `kmod-ipt-ipopt` *(optional — required for TTL mangling)*

## Building

```sh
ln -s /path/to/opentether /path/to/openwrt/package/opentether
cd /path/to/openwrt
make menuconfig   # select Network → opentether
make package/opentether/compile V=s
```

## Installing

### Verified install (recommended)

Add the OpenTether signing key to your router's trusted keys once, then install without `--allow-untrusted`:

```sh
# On your router — do this once
curl -o /etc/apk/keys/opentether.pub \
  https://raw.githubusercontent.com/HelaFaye/opentether/main/key-build.pub

# Then install normally
apk add /tmp/opentether-*.apk
```

### Unverified install

```sh
apk add --allow-untrusted /tmp/opentether-*.apk
```

### opkg (OpenWrt 23.05 and earlier)

```sh
opkg install /tmp/opentether_*.ipk
```

Check your architecture first: `uname -m`. Replace `<arch>` in build output paths accordingly.

## Device setup

Install a SOCKS5 proxy app on your Android device like [Socks5](https://github.com/heiher/socks5), a lightweight, fast proxy from the same author as hev-socks5-tunnel. Configure it to listen on port 1088 (or whatever port you set in OpenTether).

Enable USB debugging in Developer Options, plug into the router, and approve the debug prompt.

## Headless configuration (UCI)

All settings are stored in `/etc/config/opentether` in per-device sections and can be configured without the web UI.

```sh
# Register a new device (replace ZY22KQ8RM2 with your serial — run: adb devices)
/usr/lib/opentether/setup.sh add-device ZY22KQ8RM2 "My Device"
```

```sh
SERIAL=ZY22KQ8RM2

# Enable the device
uci set opentether.device_${SERIAL}.enabled='1'

# SOCKS5 proxy settings
uci set opentether.device_${SERIAL}.port='1088'
uci set opentether.device_${SERIAL}.s5_address='127.0.0.1'
uci set opentether.device_${SERIAL}.s5_udp='tcp'

# Tunnel interface settings
uci set opentether.device_${SERIAL}.iface='s5tun0'
uci set opentether.device_${SERIAL}.mtu='1440'
uci set opentether.device_${SERIAL}.ipv4='198.18.0.1'
uci set opentether.device_${SERIAL}.ipv6='fc00::1'
uci set opentether.device_${SERIAL}.metric='10'

# TTL mangling (0 = disabled; 65 is a common bypass value)
uci set opentether.device_${SERIAL}.ttl_mangle='0'

# Apply — regenerates YAML and restarts tunnel instance
uci commit opentether
/usr/lib/opentether/setup.sh apply ${SERIAL}
```

```sh
# Remove a device
/usr/lib/opentether/setup.sh remove-device ZY22KQ8RM2
```

## TTL mangling

OpenTether can rewrite the TTL (IPv4) and hop limit (IPv6) of all outbound packets from a device's tunnel interface. This is useful for bypassing carrier tethering detection, which often flags packets with a TTL that differs from the phone's native value.

Set `ttl_mangle` in the device's UCI section or via LuCI. Common values:

| Value | Use case |
|-------|----------|
| `0` | Disabled (default) |
| `64` | Standard Linux/Android TTL |
| `65` | Common bypass — arrives at carrier as 64 after one hop |
| `128` | Mimics Windows |
| `255` | Maximum |

Requires `kmod-ipt-ipopt` on the router:

```sh
apk add kmod-ipt-ipopt
```

## Diagnostics

```sh
opentether-check          # full per-device status: ADB, forward, tunnel, interface, routes, connectivity, DNS, log
logread | grep opentether # raw log output
```

## Legacy single-device support

OpenTether 1.1.x provided a simpler single-device implementation. It is available on the `legacy/1.1.x` branch for users who need it, but is no longer actively developed.
