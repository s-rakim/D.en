#!/usr/bin/env bash
# Keeps an eye on the exit node's uplink: latency, jitter and packet loss every
# few minutes, plus an occasional speed test. Results go to CSV files in /data
# so you can see whether a tweak actually helped.
#
#   monitor.sh           run forever
#   monitor.sh summary   print averages from what's been logged so far
#   monitor.sh speed     run one speed test right now

set -uo pipefail

: "${PING_TARGETS:=1.1.1.1 8.8.8.8}"
: "${PING_INTERVAL:=60}"
: "${PING_COUNT:=20}"
: "${SPEEDTEST_INTERVAL:=21600}"   # 6 hours. 0 turns it off.
: "${DATA_DIR:=/data}"

PING_CSV="$DATA_DIR/latency.csv"
SPEED_CSV="$DATA_DIR/speed.csv"

log() { printf '%s [monitor] %s\n' "$(date '+%H:%M:%S')" "$*"; }

init_files() {
  mkdir -p "$DATA_DIR"
  [[ -s "$PING_CSV" ]]  || echo "time,target,loss_pct,min_ms,avg_ms,max_ms,jitter_ms" > "$PING_CSV"
  [[ -s "$SPEED_CSV" ]] || echo "time,server,ping_ms,down_mbps,up_mbps" > "$SPEED_CSV"
}

ping_one() {
  local target="$1" out loss rtt
  out=$(ping -n -q -c "$PING_COUNT" -i 0.2 -W 2 "$target" 2>/dev/null)
  loss=$(grep -oE '[0-9.]+% packet loss' <<<"$out" | grep -oE '^[0-9.]+')
  # iputils prints: rtt min/avg/max/mdev = 9.1/10.2/14.8/1.3 ms
  rtt=$(grep -oE '= [0-9./]+ ms' <<<"$out" | tr -d '= ms')
  local min avg max mdev
  IFS=/ read -r min avg max mdev <<<"${rtt:-///}"
  echo "$(date -Iseconds),$target,${loss:-100},${min},${avg},${max},${mdev}" >> "$PING_CSV"
  log "$target  avg ${avg:-?} ms  jitter ${mdev:-?} ms  loss ${loss:-100}%"
}

speed() {
  log "running speed test (this uses real bandwidth for ~20s)"
  local out
  if ! out=$(/opt/speedtest/bin/speedtest-cli --secure --csv 2>/dev/null); then
    log "speed test failed"; return
  fi
  # speedtest-cli CSV: id,sponsor,name,timestamp,distance,ping,download(bps),upload(bps),...
  python3 - "$out" "$SPEED_CSV" <<'PY'
import csv, io, sys
row = next(csv.reader(io.StringIO(sys.argv[1])))
sponsor, name, ts, ping = row[1], row[2], row[3], float(row[5])
down, up = float(row[6]) / 1e6, float(row[7]) / 1e6
with open(sys.argv[2], "a") as f:
    f.write(f"{ts},{(sponsor + ' ' + name).replace(',', ' ')},{ping:.1f},{down:.1f},{up:.1f}\n")
print(f"down {down:.1f} Mbps  up {up:.1f} Mbps  ping {ping:.1f} ms  ({sponsor}, {name})")
PY
}

summary() {
  init_files
  echo "Latency (all samples logged so far)"
  awk -F, 'NR>1 && $5!="" {n[$2]++; a[$2]+=$5; j[$2]+=$7; l[$2]+=$3}
           END {for (t in n) printf "  %-16s avg %6.1f ms   jitter %5.1f ms   loss %4.1f%%   (%d runs)\n",
                t, a[t]/n[t], j[t]/n[t], l[t]/n[t], n[t]}' "$PING_CSV"
  echo
  echo "Last 5 speed tests"
  tail -n +2 "$SPEED_CSV" | tail -n 5 | awk -F, '{printf "  %s  down %6s Mbps  up %6s Mbps  ping %5s ms\n", $1, $4, $5, $3}'
}

loop() {
  init_files
  log "pinging [$PING_TARGETS] every ${PING_INTERVAL}s, speed test every ${SPEEDTEST_INTERVAL}s (0 = off)"
  local last_speed=0 now t
  trap 'exit 0' TERM INT
  while true; do
    for t in $PING_TARGETS; do ping_one "$t"; done
    now=$(date +%s)
    if (( SPEEDTEST_INTERVAL > 0 && now - last_speed >= SPEEDTEST_INTERVAL )); then
      speed
      last_speed=$now
    fi
    sleep "$PING_INTERVAL" &
    wait $!
  done
}

case "${1:-loop}" in
  loop)    loop ;;
  summary) summary ;;
  speed)   init_files; speed ;;
  *) echo "usage: $0 [loop|summary|speed]" >&2; exit 2 ;;
esac
