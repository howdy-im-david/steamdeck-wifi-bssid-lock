#!/bin/bash
get_card(){ nmcli -t -f DEVICE,TYPE,STATE dev | awk -F: '$2=="wifi" && $3=="connected"{print $1; exit}'; }
get_con(){ nmcli -t -f NAME,TYPE con show --active | awk -F: '$2=="802-11-wireless"{print $1; exit}'; }
LOG=/tmp/wifi-lock.log
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

if [ "$1" = "--pick" ]; then
  pick_bssid "$(nmcli -g 802-11-wireless.ssid con show "$(get_con)")"
  exit
fi

dbus-monitor --system "type='signal',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'" |
while read -r line; do
  if echo "$line" | grep -q "boolean true"; then
    log "going to sleep, clearing lock"
    CON=$(get_con)
    [ -n "$CON" ] && nmcli con mod "$CON" 802-11-wireless.bssid ''
  elif echo "$line" | grep -q "boolean false"; then
    log "woke up"
    for i in $(seq 60); do [ -n "$(get_card)" ] && break; sleep 1; done
    CON=$(get_con)
    [ -n "$CON" ] && nmcli con mod "$CON" 802-11-wireless.bssid ''
    nmcli dev wifi rescan; sleep 5
    CARD=$(get_card); CON=$(get_con)
    CUR=$(iw dev "$CARD" link | awk '/Connected to/{print toupper($3)}')
    BEST=$(pick_bssid "$(nmcli -g 802-11-wireless.ssid con show "$CON")")
    if [ -n "$CARD" ] && [ -n "$CON" ] && [ -n "$BEST" ]; then
      # The lock only reaches the supplicant on a (re)connect, so always reconnect, even if already on $BEST.
      nmcli con mod "$CON" 802-11-wireless.bssid "$BEST"
      nmcli dev disconnect "$CARD"; sleep 1; nmcli dev connect "$CARD"
      for i in $(seq 15); do [ -n "$(get_card)" ] && break; sleep 1; done
      if [ -z "$(get_card)" ]; then
        nmcli con mod "$CON" 802-11-wireless.bssid ''; nmcli dev connect "$CARD"
        log "could not connect to $BEST, cleared lock"
      else
        log "locked '$CON' to $BEST (was $CUR, reconnected)"
      fi
    else
      log "could not pick BSSID (cur=$CUR best=$BEST), not locking"
    fi
  fi
done
