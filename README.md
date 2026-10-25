# steamdeck-wifi-bssid-lock

A small background service for the Steam Deck (SteamOS) that locks wifi to the best nearby access point after the Deck wakes from sleep.

## Why

On a mesh network, the Deck periodically scans for better access points while connected. During Steam Remote Play, where the Deck is the streaming client, that scan shows up as a lag spike roughly every five minutes. Pinning the connection to one access point (a BSSID lock) stops the scanning.

A permanent lock has a downside: if you carry the Deck to another room, it stays glued to the old node. So this service only locks while the Deck is awake. It clears the lock when the Deck goes to sleep and re-locks to the best node after each wake.

## What it does

1. **On sleep:** clears `802-11-wireless.bssid` on the active wifi profile, restoring normal roaming.
2. **On wake:** waits for wifi to reconnect, clears the lock again, triggers a fresh scan, and waits 5 seconds.
3. **Picks a node** for the profile's SSID:
   - the strongest 6 GHz access point, if its signal is at least `MIN6` (default 55 on NetworkManager's 0-100 scale, roughly -72 dBm);
   - otherwise the strongest 5 GHz access point.
   - 2.4 GHz is never chosen.
4. **Locks to it.** If the Deck is already connected to that node, it only sets the lock, with no reconnect and no dropped connection. Otherwise it reconnects once. If that reconnect fails within 15 seconds, it clears the lock so you are not left offline.

Wake and sleep are detected through the `PrepareForSleep` signal from `systemd-logind` on D-Bus. Events are logged to `/tmp/wifi-lock.log`.

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
going to sleep, clearing lock
woke up
locked '<profile>' to <BSSID> (already connected, no reconnect)
```

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
- **The lock persists while awake.** If you move rooms without sleeping the Deck, it keeps the old node until the next sleep and wake.
- **SteamOS updates** can reset user changes, so re-check the service after a big update.

## Uninstall

```bash
systemctl --user disable --now wifi-lock-on-wake.service
rm ~/.config/systemd/user/wifi-lock-on-wake.service /home/deck/wifi-lock-on-wake.sh
nmcli con mod "<your wifi profile name>" 802-11-wireless.bssid ''
```

Run the last command on the Deck itself. It clears any lock that was left in place.
