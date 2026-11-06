# steamdeck-wifi-bssid-lock

A small background service for the Steam Deck (SteamOS) that locks wifi to the best nearby access point after the Deck wakes from sleep, starts up, or has its wifi switched back on.

## Why

On a mesh network, the Deck periodically scans for better access points while connected. During Steam Remote Play, where the Deck is the streaming client, that scan shows up as a lag spike roughly every five minutes. Pinning the connection to one access point (a BSSID lock) stops the scanning.

A permanent lock has two downsides. If you carry the Deck to another room, it stays glued to the old node. And a lock saved in the wifi profile survives a reboot, so a Deck that starts up out of range of that node cannot connect at all, and SteamOS then asks for the wifi password again (creating a second profile with the same name). So this service only keeps the lock while it is useful: it clears it when the Deck sleeps or has wifi switched off, and re-locks to the best node when wifi is back.

## What it does

1. **On sleep:** clears `802-11-wireless.bssid` on every profile the script has locked, restoring normal roaming, and turns autoconnect off on the active profile so NetworkManager does not connect by itself at wake. When wifi is turned off, it clears the lock too.
2. **On wake:** NetworkManager has not connected yet, so the script rescans, picks the best node (see below), sets the lock, turns autoconnect back on, and connects once with the lock already applied. That avoids connecting unlocked and then reconnecting. If NetworkManager connected by itself anyway, or the scan or connect fails, it falls back to the on-start behaviour below.
3. **On service start (boot or login), or when wifi comes back after being switched off:** clears the lock again, nudges NetworkManager to connect if nothing is connected, waits for wifi, triggers a fresh scan, waits 5 seconds, then locks and reconnects.
4. **Picks a node** for the profile's SSID:
   - the strongest 6 GHz access point, if its signal is at least `MIN6` (default 55 on NetworkManager's 0-100 scale, roughly -72 dBm);
   - otherwise the strongest 5 GHz access point.
   - 2.4 GHz is never chosen.
5. **Locks to it, on a fresh connection.** The lock must be in place when the connection is brought up: the BSSID is a saved NetworkManager setting that is only read at activation (`nmcli dev reapply` refuses to change it), so a lock set on an already-connected Deck does not stop its background scans. After wake the script gets that for free by connecting once itself; in the other paths it disconnects and reconnects once, even if the Deck is already on the chosen node. If the connect fails within 15 seconds, the script clears the lock so you are not left offline.

Sleep and wake are detected through the `PrepareForSleep` signal from `systemd-logind` on D-Bus. Wifi being switched off or on is detected from `nmcli monitor` (it watches for `<device>: unavailable` and `<device>: connected`). Profiles are addressed by UUID, not name, because SteamOS can end up with several profiles that share a name; the UUIDs the script has locked are remembered in `/home/deck/.wifi-lock.profiles` so a boot-time clear knows what to undo. Events are logged to `/tmp/wifi-lock.log`.

## Requirements

- SteamOS (or any Linux with NetworkManager, `iw` and `dbus-monitor`)
- A wifi profile managed by NetworkManager
- No root access needed. Everything lives under `/home/deck`.

## Install

Copy the script and the unit file to the Deck, then on the Deck run:

```bash
chmod +x /home/deck/wifi-lock-on-wake.sh
mkdir -p ~/.config/systemd/user
cp wifi-lock-on-wake.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now wifi-lock-on-wake.service
```

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
started, relocking (wifi device: wlan0)
locked '<profile>' (<uuid>) to <BSSID> (was <previous BSSID>, reconnected)
going to sleep, clearing lock and pausing autoconnect
woke up
locked '<profile>' (<uuid>) to <BSSID> (connected once after wake)
ignored stale unavailable event (device is connected)
wifi turned off, clearing lock
```

The "ignored stale unavailable event" line is normal after a wake: NetworkManager reports the device as unavailable during suspend, the event is processed late, and the script checks the device's real state before acting on it.

## Try the ranking without sleeping

```bash
/home/deck/wifi-lock-on-wake.sh --pick
```

This prints the BSSID the script would choose right now and exits. It changes nothing.

## Tuning

Edit the top of the script:

- `MIN6`: the weakest 6 GHz signal still preferred over 5 GHz. Raise it to fall back to 5 GHz sooner; lower it to stay on 6 GHz even when it is weak.
- The `sleep 5` after `nmcli dev wifi rescan`: how long to wait for scan results after wake.

## Notes and caveats

- **Permissions.** NetworkManager (via polkit) may refuse `nmcli con mod` and `nmcli dev wifi rescan` when run from an SSH session, with "Insufficient privileges" or "not authorized". The same commands work from the systemd user service. To test one by hand over SSH, wrap it in `systemd-run --user --wait nmcli ...`.
- **Linger.** The service runs as a systemd user service. On a default SteamOS setup it starts with the `deck` user's session, including in Game Mode, after a reboot. If yours does not, you may need `loginctl enable-linger deck`.
- **Log location.** `/tmp/wifi-lock.log` is cleared on reboot.
- **The lock persists while awake.** If you move rooms without sleeping the Deck, it keeps the old node until the next sleep, wake or wifi toggle. Switching wifi off and on in Game Mode relocks to the best node.
- **Shutdown is best effort.** The unit runs `wifi-lock-on-wake.sh --clear` when the service stops, so the lock is cleared on shutdown and when you disable the service. That clear may be refused during shutdown, which is why the script also clears and relocks every time it starts.
- **Autoconnect is briefly off.** Between sleep and the post-wake connect, the active profile has `connection.autoconnect` set to `no`. The script switches it back on at wake, on every service start, and when the service stops. If the Deck ever loses power during sleep and boots with it off, the service turns it back on as soon as it starts; if the service cannot start, choose the network in Game Mode or run `nmcli con mod uuid <uuid> connection.autoconnect yes`.
- **Duplicate profiles.** If SteamOS already created a second profile with the same name, the script only touches the active one and the ones it locked itself. You can delete a stale duplicate with `nmcli con delete uuid <uuid>` (find it with `nmcli -f NAME,UUID,TYPE con show`).
- **SteamOS updates** can reset user changes, so re-check the service after a big update.

## Uninstall

Stopping the service already clears the locks it set, so run the clear first to be sure, then remove everything:

```bash
/home/deck/wifi-lock-on-wake.sh --clear
systemctl --user disable --now wifi-lock-on-wake.service
rm ~/.config/systemd/user/wifi-lock-on-wake.service /home/deck/wifi-lock-on-wake.sh /home/deck/.wifi-lock.profiles
```

Run these on the Deck itself (over SSH, NetworkManager may refuse the clear; see the permissions note above).

## License

MIT. See [LICENSE](LICENSE).
