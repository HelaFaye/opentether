# OpenTether

OpenTether bridges any Android device running a SOCKS5 proxy to any OpenWrt router's WAN connection via ADB port forwarding and [hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel). Once installed, simply plug in your device, approve the USB debugging prompt, and all LAN clients will route their traffic through the device's internet connection automatically — no manual configuration required after initial setup.

Version 1.2.0 adds support for multiple devices simultaneously. Each device gets its own isolated tunnel interface, firewall zone, ADB forward, and procd service instance. Devices can be added, removed, enabled, and disabled independently through the LuCI web interface or via UCI on the command line.

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

1.2.0 supports any number of Android devices connected simultaneously. Each device is registered independently and gets its own:

- **UCI section** — `opentether.device_<serial>` storing all per-device configuration
- **TUN interface** — a dedicated virtual network interface (e.g. `s5tun0`, `s5tun1`)
- **ADB port forward** — a unique local port mapped to the device's SOCKS5 proxy
- **hev-socks5-tunnel instance** — a separate procd-managed tunnel process with its own YAML config at `/etc/hev-socks5-tunnel/devices/<serial>.yml`
- **Firewall zone and forwarding rule** — isolated from other devices and from WAN
- **Watchdog** — an independent background process monitoring the device's connection

Devices are registered through the LuCI Configuration tab using the **Add Device** section, which scans for connected ADB devices and lets you register each one individually. Registered devices can be enabled or disabled without removing them — disabling a device stops its tunnel and prevents the hotplug script from starting it on reconnect, while preserving all configuration for later use.

Route metrics control which device is preferred when multiple are active. Lower metric = higher priority. The default metric for the first device is 10; subsequent devices are assigned incrementally higher metrics. This can be changed per-device in the Configuration tab.

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

**apk (OpenWrt 24+ snapshot builds):**
```sh
scp bin/packages/aarch64_cortex-a53/base/opentether-*.apk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 "apk add --allow-untrusted /tmp/opentether-*.apk"
```

**opkg (OpenWrt stable releases):**
```sh
scp bin/packages/aarch64_cortex-a53/base/opentether-*.ipk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 "opkg install /tmp/opentether-*.ipk"
```

## Device setup

Install a SOCKS5 proxy app on your Android device like [Socks5](https://github.com/heiher/socks5), a lightweight, fast proxy from the same author as hev-socks5-tunnel. Configure it to listen on port 1088 (or whatever port you set in OpenTether).

Enable USB debugging in Developer Options, plug into the router, and approve the debug prompt.

## Headless configuration (UCI)

All settings are stored in `/etc/config/opentether` in per-device sections and can be configured without the web UI. Each device has its own section named after its ADB serial number.

To register a new device from the command line:

```sh
# Replace ZY22KQ8RM2 with your device serial (run: adb devices)
/usr/lib/opentether/setup.sh add-device ZY22KQ8RM2 "My Device"
```

To configure an existing device section directly:

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

# Apply — regenerates YAML and restarts tunnel instance
uci commit opentether
/usr/lib/opentether/setup.sh apply ${SERIAL}
```

To remove a device:

```sh
/usr/lib/opentether/setup.sh remove-device ZY22KQ8RM2
```

## Diagnostics

```sh
opentether-check          # full per-device status: ADB, forward, tunnel, interface, routes, connectivity, DNS, log
logread | grep opentether # raw log output
```
