# steamdeck-wifi-bssid-lock

A small background service for the Steam Deck (SteamOS) that locks wifi to the best nearby access point of the networks you choose, and unlocks it whenever a lock would do harm.

## Why

On a mesh network, the Deck periodically scans for better access points while connected (NetworkManager does it about every five minutes). During Steam Remote Play, where the Deck is the streaming client, that scan shows up as a lag spike. Pinning the connection to one access point (a BSSID lock) stops the scanning.

A lock that is simply left on has downsides:

- If you carry the Deck to another room, it stays glued to the old node.
- A lock saved in the wifi profile survives a reboot, so a Deck that starts up out of range of that node cannot connect at all, and SteamOS then asks for the wifi password again (creating a second profile with the same name).
- On a hotel or airport network you move around while awake, and a lock would strand you on a distant access point.

So this service keeps a lock only on networks you list, only while it is useful: it clears the lock when the Deck sleeps, shuts down or has wifi switched off, and locks to the best node again when wifi is back.

## What it does

**Only networks listed in `/home/deck/.wifi-lock.networks` are touched** (one SSID per line, exact match). On any other network the script does nothing at all: no lock, no reconnect, no autoconnect change. With no file, it does nothing anywhere. Matching is by SSID because profile UUIDs change when SteamOS recreates a profile, and a mesh has many BSSIDs for one SSID.

| Event | What happens |
|---|---|
| **Sleep** | Clears the lock and turns autoconnect off on the active profile (one `nmcli` call, so it lands before suspend), so NetworkManager does not connect by itself at wake. |
| **Wake** | Waits for the radio, uses recent scan results if they contain the network (otherwise it does a new scan, about 6 seconds for a full scan including 6 GHz; if the scan list is completely empty, the radio is not ready yet right after resume, so it waits for the next scan, for up to about 10 seconds), picks the best node, sets the lock, turns autoconnect back on and connects once with the lock already applied. If NetworkManager connected by itself anyway, or the scan or connect fails, it falls back to the lock-then-reconnect path used at startup. |
| **Service start** (boot or login) | Clears locks, waits for wifi, scans, locks to the best node and reconnects once. |
| **Wifi switched off, then on** | Clears the lock when it goes off. When wifi connects again, it locks and reconnects once. Switching wifi off and on is also your manual escape hatch if a lock ever misbehaves; NetworkManager reconnects by itself, without waiting for this script. |
| **Shutdown or reboot** | Clears the lock while NetworkManager and polkit still exist, so the next boot cannot start on a stale lock. |

### Choosing a node

For the profile's SSID, among 5 and 6 GHz access points (2.4 GHz is never chosen):

- the strongest 6 GHz access point, if its signal is at least `MIN6` (default 55 on NetworkManager's 0-100 scale, roughly -72 dBm);
- otherwise the strongest 5 GHz access point.

### Why a fresh connection

The BSSID lock is a NetworkManager profile setting that is only read when a connection is activated. `nmcli dev reapply` refuses to change it ("Can't reapply changes to '802-11-wireless.bssid' setting"), so a lock set on an already-connected Deck does not stop its background scans. The lock has to be in place when the connection comes up. After wake the script gets that for free by connecting once itself. In the other paths it uses one `nmcli con up`, which re-activates the profile even if the Deck is already on the chosen node. If the connect fails within 15 seconds, the lock is cleared so you are not left offline.

### How it listens

Sleep, wake and shutdown come from the `PrepareForSleep` and `PrepareForShutdown` signals of `systemd-logind` on D-Bus. Wifi being switched off or on comes from `nmcli monitor` (it watches for `<device>: unavailable` and `<device>: connected`). Events that queue up during suspend are checked against the device's real state before the script acts on them. Scan completion is detected from NetworkManager's `LastScan` property, which only changes when a scan finishes. Profiles are addressed by UUID, and the ones the script has locked are remembered in `/home/deck/.wifi-lock.profiles` so a clear after a reboot knows what to undo. Events are logged to `/tmp/wifi-lock.log`.

## Requirements

- SteamOS (or any Linux with NetworkManager, `iw`, `busctl`, `dbus-monitor` and `stdbuf`)
- A wifi profile managed by NetworkManager
- No root access needed. Everything lives under `/home/deck`.

## Install

Copy the script and the unit file to the Deck, then on the Deck run:

```bash
chmod +x /home/deck/wifi-lock-on-wake.sh
printf '%s\n' "<your wifi network name>" > /home/deck/.wifi-lock.networks
mkdir -p ~/.config/systemd/user
cp wifi-lock-on-wake.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now wifi-lock-on-wake.service
```

Add more networks by appending lines to `/home/deck/.wifi-lock.networks`. Avoid common default names (such as `xfinitywifi` or `NETGEAR`): the script cannot tell two networks with the same SSID apart.

Check it is running:

```bash
systemctl --user status wifi-lock-on-wake.service
```

Put the Deck to sleep and wake it, then look at the log:

```bash
cat /tmp/wifi-lock.log
```

You should see lines like:

```
started (wifi device wlan0, 1 allowed network(s), profile lock at start: [])
locked '<profile>' (<uuid>) to <BSSID> (was <previous BSSID>, reconnected)
going to sleep, lock cleared and autoconnect paused
woke up
locked '<profile>' (<uuid>) to <BSSID> (connected once after wake, 1480 ms)
ignored stale unavailable event (device is connected)
```

The "ignored stale unavailable event" line is normal after a wake: NetworkManager reports the device as unavailable during suspend, and the event is processed late. Other lines you may see: `shutting down, lock cleared`, `wifi turned off, lock cleared`, `'<profile>' is not an allowed network, leaving it alone`, and `wake connect failed (...), falling back`.

## Try the ranking without sleeping

```bash
/home/deck/wifi-lock-on-wake.sh --pick
```

This prints the BSSID the script would choose right now and exits. It changes nothing.

## Tuning

Edit the top of the script:

- `MIN6`: the weakest 6 GHz signal still preferred over 5 GHz. Raise it to fall back to 5 GHz sooner; lower it to stay on 6 GHz even when it is weak.

## Notes and caveats

- **Permissions.** NetworkManager (via polkit) may refuse `nmcli con mod` and `nmcli dev wifi rescan` when run from an SSH session, with "Insufficient privileges" or "not authorized". The same commands work from the systemd user service. To test one by hand over SSH, wrap it in `systemd-run --user --wait nmcli ...`.
- **Linger.** The service runs as a systemd user service. On a default SteamOS setup it starts with the `deck` user's session, including in Game Mode, after a reboot. If yours does not, you may need `loginctl enable-linger deck`.
- **Log location.** `/tmp/wifi-lock.log` is cleared on reboot.
- **The lock stays while awake.** If you move rooms without sleeping the Deck, it keeps the old node until the next sleep, wake or wifi toggle.
- **Hard resets.** A forced power-off sends no shutdown signal, so the lock is not cleared then. The service clears it at the next start, but if the old node is out of range, the Deck may fail to connect in the gap before the service runs, and SteamOS may ask for the wifi password.
- **Away from home.** If you sleep the Deck on a listed network and wake it somewhere else, the script does one scan (about 6 seconds) looking for the listed network before letting NetworkManager connect normally. Networks that are not listed are left alone.
- **Autoconnect is briefly off.** Between sleep and the post-wake connect, the active profile has `connection.autoconnect` set to `no`. The script switches it back on at wake, on every service start, and when the service stops. If the Deck ever loses power during sleep and boots with it off, the service turns it back on as soon as it starts; if the service cannot start, choose the network in Game Mode or run `nmcli con mod uuid <uuid> connection.autoconnect yes`.
- **Duplicate profiles.** If SteamOS already created a second profile with the same name, the script only touches the active one and the ones it locked itself. You can delete a stale duplicate with `nmcli con delete uuid <uuid>` (find it with `nmcli -f NAME,UUID,TYPE con show`).
- **SteamOS updates** can reset user changes, so re-check the service after a big update.

## Uninstall

Stopping the service already clears the locks it set, so run the clear first to be sure, then remove everything:

```bash
/home/deck/wifi-lock-on-wake.sh --clear
systemctl --user disable --now wifi-lock-on-wake.service
rm ~/.config/systemd/user/wifi-lock-on-wake.service /home/deck/wifi-lock-on-wake.sh /home/deck/.wifi-lock.profiles /home/deck/.wifi-lock.networks
```

Run these on the Deck itself (over SSH, NetworkManager may refuse the clear; see the permissions note above).

## License

MIT. See [LICENSE](LICENSE).
