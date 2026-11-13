#!/bin/bash
# Keeps the Deck's wifi locked to the best nearby access point (BSSID lock) while awake. See README.md.
LOG=/tmp/wifi-lock.log
STATE=/home/deck/.wifi-lock.profiles  # UUIDs of profiles this script has locked, so a clear after a reboot knows what to undo
NETWORKS=/home/deck/.wifi-lock.networks  # SSIDs to manage, one per line (exact match); any other network is left completely alone
MIN6=55                               # weakest 6 GHz signal (nmcli 0-100 scale, about -72 dBm) still preferred over 5 GHz
NM=org.freedesktop.NetworkManager

log(){ echo "$(date '+%F %T') $*" >> "$LOG"; }

# Profiles are addressed by UUID: SteamOS can create a second profile with the same name when you re-enter a password.
get_uuid(){ nmcli -t -f UUID,TYPE con show --active | awk -F: '$2=="802-11-wireless"{print $1; exit}'; }
# These take a profile UUID and print nothing for an empty one (no active wifi connection yet, e.g. right after boot).
ssid_of(){ [ -n "$1" ] && nmcli -g 802-11-wireless.ssid con show uuid "$1"; }
name_of(){ [ -n "$1" ] && nmcli -g connection.id con show uuid "$1"; }
lock_of(){ [ -n "$1" ] && nmcli -g 802-11-wireless.bssid con show uuid "$1" | tr -d '\\'; }
find_wifi(){ nmcli -t -f DEVICE,TYPE dev | awk -F: '$2=="wifi"{print $1; exit}'; }
dev_state(){ nmcli -t -f DEVICE,STATE dev | awk -F: -v d="$WIFI" '$1==d{print $2}'; }
connected(){ [ "$(dev_state)" = connected ]; }
track_uuid(){ [ -n "$1" ] && { grep -qx "$1" "$STATE" 2>/dev/null || echo "$1" >> "$STATE"; }; }
# Is profile $1 on a network listed in $NETWORKS? Matching is by SSID: UUIDs change when SteamOS recreates a profile, and a mesh has many BSSIDs.
allowed(){ local s; s=$(ssid_of "$1"); [ -n "$s" ] && grep -Fxq -- "$s" "$NETWORKS" 2>/dev/null; }
# The profiles this script manages: every one it has locked before, plus the active one if it is allowed.
profiles(){ { cat "$STATE" 2>/dev/null; local a; a=$(get_uuid); allowed "$a" && echo "$a"; } | sort -u; }

# Poll every 0.2 s for up to $1 seconds until wifi is connected.
wait_connected(){ local i; for i in $(seq $(( $1 * 5 ))); do connected && return 0; sleep 0.2; done; return 1; }
# Poll for up to $1 seconds until NetworkManager has finished waking the radio (disconnected, or connected by itself).
wait_ready(){ local i s; for i in $(seq $(( $1 * 5 ))); do s=$(dev_state); [ "$s" = disconnected ] || [ "$s" = connected ] && return 0; sleep 0.2; done; return 1; }

# NetworkManager's LastScan (ms on the boot clock) only changes when a scan completes, and a full scan including 6 GHz takes ~6 s.
dev_path(){ busctl --system call $NM /org/freedesktop/NetworkManager $NM GetDeviceByIpIface s "$WIFI" 2>/dev/null | awk '{gsub(/"/,"",$2); print $2}'; }
last_scan(){ busctl --system get-property $NM "$1" $NM.Device.Wireless LastScan 2>/dev/null | awk '{print $2}'; }
boot_ms(){ awk '{printf "%d", $1*1000}' /proc/uptime; }
# Did the last scan finish at or after boot-clock time $1 (ms)?
scan_since(){ local t; t=$(last_scan "$(dev_path)"); [ -n "$t" ] && [ "$t" -ge "$1" ]; }
# Force a scan and wait up to $1 seconds for it to finish.
rescan_wait(){
  local p before i
  p=$(dev_path); before=$(last_scan "$p")
  nmcli dev wifi rescan >/dev/null 2>&1
  [ -z "$before" ] && { sleep 6; return; }   # LastScan unreadable: fixed wait
  for i in $(seq $(( $1 * 5 ))); do [ "$(last_scan "$p")" != "$before" ] && return 0; sleep 0.2; done
  return 1
}

# Best BSSID for an SSID: strongest 6 GHz AP if its signal is at least MIN6, otherwise strongest 5 GHz AP.
pick_bssid(){
  nmcli -t -f BSSID,SSID,FREQ,SIGNAL dev wifi list | sed 's/\\:/-/g' |
  awk -F: -v ssid="$1" -v min6="$MIN6" '
    $2==ssid { f=$3+0; s=$4+0; b=$1; gsub(/-/,":",b)
      if (f>=5925) { if (s>s6) {s6=s; b6=b} }
      else if (f>=5000) { if (s>s5) {s5=s; b5=b} } }
    END { if (b6!="" && (b5=="" || s6>=min6)) print b6; else if (b5!="") print b5 }'
}

clear_lock(){ local u; for u in $(profiles); do nmcli con mod uuid "$u" 802-11-wireless.bssid '' 2>/dev/null; done; }
autoconnect_on(){ local u; for u in $(profiles) $SLEEP_UUID; do nmcli con mod uuid "$u" connection.autoconnect yes 2>/dev/null; done; }

# Lock profile $1 to BSSID $2 and bring it up. The lock is only read when a connection is activated (nmcli dev reapply refuses
# to change it), and `nmcli con up` re-activates even an already-connected profile. On failure the lock is cleared again.
lock_and_connect(){
  # Autoconnect is switched on only after the connect: setting it first makes NetworkManager start its own activation in parallel.
  nmcli con mod uuid "$1" 802-11-wireless.bssid "$2"
  nmcli -w 15 con up uuid "$1" ifname "$WIFI" >/dev/null 2>&1 && connected && { nmcli con mod uuid "$1" connection.autoconnect yes; return 0; }
  nmcli con mod uuid "$1" 802-11-wireless.bssid ''
  return 1
}

# Log what the pick was chosen from (BSSID freq signal), so a bad pick can be diagnosed afterwards.
log_cands(){
  log "picked $2 from: $(nmcli -t -f BSSID,SSID,FREQ,SIGNAL dev wifi list | sed 's/\\:/-/g' | awk -F: -v s="$1" '$2==s{printf "%s%s/%s", sep, $1, $3+0 "/" $4; sep=" "}' | sed 's/-/:/g')"
}

# Best BSSID for SSID $1: from recent scan results if they contain it, otherwise from a new scan. Right after resume the radio is
# not ready and a scan can "finish" at once with an empty list, so an empty list means wait for the next scan (up to ~10 s),
# while a list of other networks means ours is not here and we stop after that one scan.
pick_fresh(){
  local best end=$(( SECONDS + 10 ))
  # Results are only trusted if the scan finished after SCAN_SINCE (the wake event after a sleep, otherwise the last 15 s): after
  # resume the list can still hold the previous room's access points.
  if scan_since "${SCAN_SINCE:-$(( $(boot_ms) - 15000 ))}"; then best=$(pick_bssid "$1"); [ -n "$best" ] && { log_cands "$1" "$best"; echo "$best"; return 0; }; fi
  while :; do
    rescan_wait 8
    best=$(pick_bssid "$1"); [ -n "$best" ] && { log_cands "$1" "$best"; echo "$best"; return 0; }
    [ -n "$(nmcli -t -f BSSID dev wifi list)" ] && return 1
    [ $SECONDS -ge $end ] && return 1
  done
}

# Lock the active connection to the best AP, reconnecting once. Used when NetworkManager has already connected by itself.
relock(){
  local u cur best
  u=$(get_uuid)
  allowed "$u" || { log "'$(name_of "$u")' is not an allowed network, leaving it alone"; return; }
  cur=$(iw dev "$WIFI" link | awk '/Connected to/{print toupper($3)}')
  best=$(pick_fresh "$(ssid_of "$u")")
  if [ -z "$best" ]; then log "could not pick a BSSID (uuid=$u), not locking"; return; fi
  track_uuid "$u"
  if lock_and_connect "$u" "$best"; then log "locked '$(name_of "$u")' ($u) to $best (was $cur, reconnected)"
  else log "could not connect to $best, cleared lock"; nmcli -w 15 con up uuid "$u" ifname "$WIFI" >/dev/null 2>&1; fi
}

# Relock once wifi is up, but only when a sleep, wifi toggle or startup left the lock cleared.
PENDING=1
SLEEP_UUID=""
maybe_relock(){
  [ "$PENDING" = 1 ] || return
  clear_lock
  # Nudge NetworkManager with an explicit known profile; `dev connect` can try to create a new connection when no AP is visible.
  local u=${SLEEP_UUID:-$(profiles | head -1)}
  connected || { [ -n "$u" ] && nmcli -w 15 con up uuid "$u" ifname "$WIFI" >/dev/null 2>&1; }
  if ! wait_connected 45; then log "no wifi after 60s, will retry when it connects"; return; fi
  PENDING=0
  relock
}

# At wake autoconnect is off, so NetworkManager has not connected yet: pick the AP first, then connect once with the lock set.
# If NetworkManager connected on its own anyway, or anything fails, fall back to maybe_relock (lock, then reconnect).
wake_connect(){
  [ "$PENDING" = 1 ] || return
  local t0=$EPOCHREALTIME u=$SLEEP_UUID best
  SCAN_SINCE=$(( $(boot_ms) - 1500 ))   # a scan that finished since the wake event counts; allow for the event arriving late
  wait_ready 10
  if [ -z "$u" ] || connected; then autoconnect_on; maybe_relock; return; fi
  best=$(pick_fresh "$(ssid_of "$u")")
  if [ -n "$best" ] && lock_and_connect "$u" "$best"; then
    PENDING=0
    log "locked '$(name_of "$u")' ($u) to $best (connected once after wake, $(( (${EPOCHREALTIME/[.,]/} - ${t0/[.,]/}) / 1000 )) ms)"
    return
  fi
  log "wake connect failed (best=${best:-none}), falling back"
  autoconnect_on
  maybe_relock
}

case "$1" in
  --pick)  pick_bssid "$(ssid_of "$(get_uuid)")"; exit ;;
  --clear) clear_lock; autoconnect_on; exit ;;
esac

for i in $(seq 30); do WIFI=$(find_wifi); [ -n "$WIFI" ] && break; sleep 1; done
[ -n "$WIFI" ] || { log "no wifi device found, exiting"; sleep 30; exit 1; }
log "started (wifi device $WIFI, $(grep -c . "$NETWORKS" 2>/dev/null || echo 0) allowed network(s), profile lock at start: [$(lock_of "$(get_uuid)")])"
autoconnect_on
maybe_relock

SIG=""
while read -r src line; do
  case "$src:$line" in
    DBUS:*member=PrepareForSleep*)    SIG=sleep ;;
    DBUS:*member=PrepareForShutdown*) SIG=shutdown ;;
    DBUS:*"boolean true"*)
      case $SIG in
        sleep)    SLEEP_UUID=$(get_uuid)
                  if allowed "$SLEEP_UUID"; then
                    track_uuid "$SLEEP_UUID"   # One call, so it lands before the machine suspends.
                    nmcli con mod uuid "$SLEEP_UUID" 802-11-wireless.bssid '' connection.autoconnect no
                    log "going to sleep, lock cleared and autoconnect paused"
                  else
                    SLEEP_UUID=""; log "going to sleep (network not allowed, leaving it alone)"
                  fi
                  PENDING=1 ;;
        shutdown) # Clear while NetworkManager and polkit still exist, so the next boot cannot start on a stale lock.
                  clear_lock; log "shutting down, lock cleared" ;;
      esac ;;
    DBUS:*"boolean false"*)
      case $SIG in
        sleep)    log "woke up"; wake_connect; SCAN_SINCE="" ;;
        shutdown) PENDING=1; log "shutdown cancelled"; maybe_relock ;;
      esac ;;
    "NM:$WIFI: unavailable"*)
      # Events queue while a handler runs, so check the device really is unavailable now (not a stale event from suspend).
      if [ "$(dev_state)" = unavailable ]; then log "wifi turned off, lock cleared"; clear_lock; PENDING=1
      else log "ignored stale unavailable event (device is $(dev_state))"; fi ;;
    "NM:$WIFI: connected"*) maybe_relock ;;
  esac
done < <(
  { dbus-monitor --system "type='signal',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'" \
                          "type='signal',interface='org.freedesktop.login1.Manager',member='PrepareForShutdown'" | sed -u 's/^/DBUS /' &
    stdbuf -oL nmcli monitor | sed -u 's/^/NM /' &
    wait; }
)
