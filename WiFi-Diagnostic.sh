#!/bin/bash
###############################################################################
# Miniloong Pocket 1 (stock OS) Wi-Fi / Bluetooth diagnostic
#
# HOW IT RUNS: drop this file into  <SD>/Roms/PORTS/  and launch it from the
# stock launcher's PORTS system like a game. loong_service remounts the SD
# exec, chmods it, and runs it directly as root. It collects diagnostics and
# writes a report next to itself on the SD card, then exits back to the menu.
#
# It makes NO permanent changes: it only reads state and forces a one-shot
# Wi-Fi re-association to capture WHY a connection fails, then restores the
# saved config. Nothing is written to internal storage that survives reboot
# except an optional copy of the report under /userdata for convenience.
#
# OPTIONAL connect test: put a file named  wifi-test.txt  next to this script
# (see template) with SSID and PSK to force a fresh connection attempt against
# a specific network. If absent, the script re-associates using whatever
# network was already saved through the stock Wi-Fi menu.
###############################################################################

set +e

# --- resolve where we live (removable SD) so the report is retrievable -------
HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
[ -z "$HERE" ] && HERE="$(pwd)"
STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo unknown)"
OUTDIR="$HERE/wifi-diag-$STAMP"
mkdir -p "$OUTDIR" 2>/dev/null || OUTDIR="$HERE"
REPORT="$OUTDIR/report.txt"
TTY=/dev/tty0

say() {            # progress to screen (best effort) and report
  echo "$*"
  [ -w "$TTY" ] && echo "$*" > "$TTY" 2>/dev/null
}
sec() { echo "" >>"$REPORT"; echo "===== $* =====" >>"$REPORT"; }
run() { echo "" >>"$REPORT"; echo "\$ $*" >>"$REPORT"; eval "$@" >>"$REPORT" 2>&1; }

: > "$REPORT"
echo "Miniloong Pocket 1 Wi-Fi/BT diagnostic" >>"$REPORT"
echo "generated: $(date 2>/dev/null)  uptime: $(cat /proc/uptime 2>/dev/null)" >>"$REPORT"
echo "output dir: $OUTDIR" >>"$REPORT"

say ""
say "Wi-Fi/BT diagnostic running... do not power off."
say "Report -> $OUTDIR"

# --- 1. firmware / kernel / build identity -----------------------------------
sec "SYSTEM IDENTITY"
run "uname -a"
run "cat /etc/os-release"
run "cat /etc/version 2>/dev/null; cat /usr/lib/libloong_version.so >/dev/null 2>&1; strings /usr/lib/libloong_version.so 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' | head"
run "cat /proc/cmdline"

# --- 2. Wi-Fi/BT hardware + driver -------------------------------------------
sec "WIFI/BT HARDWARE + DRIVER"
run "lsmod"
run "cat /var/run/wifibt-info.txt 2>/dev/null"          # detected chip
run "ls -l /sys/bus/sdio/devices/"
for d in /sys/bus/sdio/devices/*; do
  run "echo $d; cat $d/vendor $d/device 2>/dev/null"    # e.g. 024c d723 = RTL8723DS
done
# driver version + BT-COEX snapshot baked into the .ko (KEY for the connect bug)
for ko in /lib/modules/RTL8723DS.ko /lib/modules/RTL8733BS.ko /usr/lib/modules/RTL8723DS.ko; do
  [ -f "$ko" ] && run "echo $ko; strings '$ko' | grep -E '^version=|COEX|vermagic' | head"
done
run "ls -l /lib/firmware/ /lib/firmware/rtlbt/ 2>/dev/null"
run "wpa_supplicant -v 2>&1 | head -2"

# --- 3. RF-kill / interface state --------------------------------------------
sec "RFKILL + INTERFACE STATE"
for r in /sys/class/rfkill/*; do
  run "echo $r; cat $r/type $r/state $r/soft $r/hard 2>/dev/null"
done
run "ifconfig -a"
run "ip addr"
run "iw dev"
run "iw phy 2>/dev/null | head -60"

# --- 4. Wi-Fi scan -----------------------------------------------------------
sec "WIFI SCAN"
ifconfig wlan0 up 2>>"$REPORT"
run "iw dev wlan0 scan 2>&1 | grep -E 'SSID|signal|freq|BSS ' | head -80"
run "wpa_cli -i wlan0 scan_results 2>&1 | head -60"

# --- 5. Wi-Fi CONNECT ATTEMPT (the discriminating test) ----------------------
sec "WIFI CONNECT ATTEMPT"
DMESG_BEFORE=$(dmesg 2>/dev/null | wc -l)
CREDS="$HERE/wifi-test.txt"
TEST_SSID=""; TEST_PSK=""
if [ -f "$CREDS" ]; then
  TEST_SSID=$(grep -iE '^SSID=' "$CREDS" | head -1 | cut -d= -f2- | tr -d '\r')
  TEST_PSK=$(grep -iE '^PSK='  "$CREDS" | head -1 | cut -d= -f2- | tr -d '\r')
fi

run "wpa_cli -i wlan0 status"          # state before
run "wpa_cli -i wlan0 log_level DEBUG"

TMPID=""
if [ -n "$TEST_SSID" ]; then
  echo "using SSID from wifi-test.txt: $TEST_SSID" >>"$REPORT"
  TMPID=$(wpa_cli -i wlan0 add_network 2>/dev/null | tail -1)
  wpa_cli -i wlan0 set_network "$TMPID" ssid "\"$TEST_SSID\"" >>"$REPORT" 2>&1
  if [ -n "$TEST_PSK" ]; then
    wpa_cli -i wlan0 set_network "$TMPID" psk "\"$TEST_PSK\"" >>"$REPORT" 2>&1
  else
    wpa_cli -i wlan0 set_network "$TMPID" key_mgmt NONE >>"$REPORT" 2>&1
  fi
  wpa_cli -i wlan0 enable_network "$TMPID" >>"$REPORT" 2>&1
  wpa_cli -i wlan0 select_network "$TMPID" >>"$REPORT" 2>&1
else
  echo "no wifi-test.txt: re-associating using saved network(s)" >>"$REPORT"
  wpa_cli -i wlan0 reassociate >>"$REPORT" 2>&1
fi

# poll association / 4-way-handshake / DHCP for 40s
say "Testing connection (about 40s)..."
i=0
while [ $i -lt 20 ]; do
  echo "--- t+$((i*2))s ---" >>"$REPORT"
  wpa_cli -i wlan0 status 2>&1 | grep -E 'wpa_state|ssid|bssid|ip_address|EAP|key_mgmt|reason' >>"$REPORT"
  ST=$(wpa_cli -i wlan0 status 2>/dev/null | grep -E '^wpa_state=' | cut -d= -f2)
  if [ "$ST" = "COMPLETED" ]; then
    echo "L2 associated; requesting DHCP" >>"$REPORT"
    udhcpc -i wlan0 -n -q -t 4 >>"$REPORT" 2>&1
    break
  fi
  sleep 2
  i=$((i+1))
done
run "wpa_cli -i wlan0 status"          # final
run "iw dev wlan0 link"
run "iw dev wlan0 station dump"
run "ping -c 3 -W 2 192.168.0.1 2>&1; ping -c 3 -W 2 8.8.8.8 2>&1"

# dmesg produced DURING the attempt = coex/firmware/handshake evidence
sec "DMESG DURING CONNECT ATTEMPT"
DMESG_AFTER=$(dmesg 2>/dev/null | wc -l)
run "dmesg 2>/dev/null | tail -n $((DMESG_AFTER - DMESG_BEFORE + 5))"

# restore: drop temp network so we leave the saved config as it was
if [ -n "$TMPID" ]; then
  wpa_cli -i wlan0 remove_network "$TMPID" >/dev/null 2>&1
  wpa_cli -i wlan0 reconfigure >/dev/null 2>&1
fi
wpa_cli -i wlan0 log_level INFO >/dev/null 2>&1

# --- 6. Bluetooth ------------------------------------------------------------
sec "BLUETOOTH"
run "ps -ef 2>/dev/null | grep -iE 'hciattach|bluealsa|bluetooth' | grep -v grep"
run "hciconfig -a 2>&1"
run "hcitool dev 2>&1"
run "cat /proc/bluetooth/sleep/proto 2>/dev/null"

# --- 7. full logs ------------------------------------------------------------
sec "FILTERED KERNEL LOG (wifi/bt/coex/sdio)"
run "dmesg 2>/dev/null | grep -iE 'rtl|wlan|8723|8733|coex|sdio|mmc2|rfkill|firmware|btcoex|hci' | tail -120"
dmesg > "$OUTDIR/dmesg-full.txt" 2>/dev/null
cp /var/run/wpa_supplicant/wpa_supplicant.conf "$OUTDIR/wpa_supplicant.conf.txt" 2>/dev/null
cp /var/log/messages "$OUTDIR/messages.txt" 2>/dev/null

# --- 8. finish ---------------------------------------------------------------
# best-effort internal backup copy (not required to survive reboot)
cp -r "$OUTDIR" /userdata/wifi-diag-$STAMP 2>/dev/null
sync

say ""
say "DONE. Power the console off and remove the SD card."
say "Send us the folder:  Roms/PORTS/wifi-diag-$STAMP/"
say "(report.txt + dmesg-full.txt)"
sleep 6
exit 0
