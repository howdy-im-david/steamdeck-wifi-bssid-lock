#!/bin/bash
get_card(){ nmcli -t -f DEVICE,TYPE,STATE dev | awk -F: '$2=="wifi" && $3=="connected"{print $1; exit}'; }
# Profiles are addressed by UUID: SteamOS can create a second profile with the same name when you re-enter a password.
get_uuid(){ nmcli -t -f UUID,TYPE con show --active | awk -F: '$2=="802-11-wireless"{print $1; exit}'; }
LOG=/tmp/wifi-lock.log
STATE=/home/deck/.wifi-lock.profiles
log(){ echo "$(date '+%F %T') $*" >> "$LOG"; }

# Best BSSID for an SSID: strongest 6 GHz AP if its signal is at least MIN6 (nmcli 0-100 scale), otherwise strongest 5 GHz AP.
MIN6=55
pick_bssid(){
  nmcli -t -f BSSID,SSID,FREQ,SIGNAL dev wifi list | sed 's/\\:/-/g' |
  awk -F: -v ssid="$1" -v min6="$MIN6" '
    $2==ssid { f=$3+0; s=$4+0; b=$1; gsub(/-/,":",b)
      if (f>=5925) { if (s>s6) {s6=s; b6=b} }
      else if (f>=5000) { if (s>s5) {s5=s; b5=b} } }
    END { if (b6!="" && (b5=="" || s6>=min6)) print b6; else if (b5!="") print b5 }'
}

# Clear the lock on every profile this script has locked (remembered across reboots) and on the active wifi profile.
clear_lock(){
  local u
  for u in $(cat "$STATE" 2>/dev/null) "$(get_uuid)"; do
    [ -n "$u" ] && nmcli con mod uuid "$u" 802-11-wireless.bssid ''
  done
}

# The lock only reaches the supplicant on a (re)connect, so always reconnect, even if already on the chosen AP.
relock(){
  nmcli dev wifi rescan; sleep 5
  local CARD U NAME CUR BEST
  CARD=$(get_card); U=$(get_uuid)
  CUR=$(iw dev "$CARD" link | awk '/Connected to/{print toupper($3)}')
  BEST=$(pick_bssid "$(nmcli -g 802-11-wireless.ssid con show uuid "$U")")
  NAME=$(nmcli -g connection.id con show uuid "$U")
  if [ -n "$CARD" ] && [ -n "$U" ] && [ -n "$BEST" ]; then
    grep -qx "$U" "$STATE" 2>/dev/null || echo "$U" >> "$STATE"
    nmcli con mod uuid "$U" 802-11-wireless.bssid "$BEST"
    nmcli dev disconnect "$CARD"; sleep 1; nmcli dev connect "$CARD"
    for i in $(seq 15); do [ -n "$(get_card)" ] && break; sleep 1; done
    if [ -z "$(get_card)" ]; then
      nmcli con mod uuid "$U" 802-11-wireless.bssid ''; nmcli dev connect "$CARD"
      log "could not connect to $BEST, cleared lock"
    else
      log "locked '$NAME' ($U) to $BEST (was $CUR, reconnected)"
    fi
  else
    log "could not pick BSSID (cur=$CUR best=$BEST uuid=$U), not locking"
  fi
}

# Relock once wifi is up, but only when a sleep, wifi toggle or startup left the lock cleared.
PENDING=1
maybe_relock(){
  [ "$PENDING" = 1 ] || return
  clear_lock
  if [ -z "$(get_card)" ] && [ -n "$WIFI" ]; then nmcli dev connect "$WIFI" >/dev/null 2>&1; fi
  for i in $(seq 60); do [ -n "$(get_card)" ] && break; sleep 1; done
  if [ -z "$(get_card)" ]; then log "no wifi after 60s, will retry when it connects"; return; fi
  PENDING=0
  relock
}

case "$1" in
  --pick)  pick_bssid "$(nmcli -g 802-11-wireless.ssid con show uuid "$(get_uuid)")"; exit ;;
  --clear) clear_lock; exit ;;
esac

WIFI=$(nmcli -t -f DEVICE,TYPE dev | awk -F: '$2=="wifi"{print $1; exit}')
log "started, relocking (wifi device: ${WIFI:-none})"
maybe_relock

while read -r src line; do
  case "$src:$line" in
    DBUS:*"boolean true"*)  log "going to sleep, clearing lock"; clear_lock; PENDING=1 ;;
    DBUS:*"boolean false"*) log "woke up"; maybe_relock ;;
    "NM:$WIFI: unavailable"*) log "wifi turned off, clearing lock"; clear_lock; PENDING=1 ;;
    "NM:$WIFI: connected"*)   maybe_relock ;;
  esac
done < <(
  { dbus-monitor --system "type='signal',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'" | sed -u 's/^/DBUS /' &
    stdbuf -oL nmcli monitor | sed -u 's/^/NM /' &
    wait; }
)
