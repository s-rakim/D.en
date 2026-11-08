#!/usr/bin/env bash
# Tunes the host network stack of a Raspberry Pi running as a Tailscale exit node.
#
# Runs inside a privileged container with network_mode: host, so every sysctl,
# ethtool and iptables change here lands on the Pi itself.
#
#   tune.sh          apply once, then re-apply every REAPPLY_INTERVAL seconds
#   tune.sh once     apply once and exit
#   tune.sh check    print the current state without changing anything
#
# Every step is idempotent and fails soft: if one knob isn't supported by your
# kernel or hardware, it logs a warning and moves on.

set -uo pipefail

: "${WAN_IFACE:=auto}"
: "${TS_IFACE:=tailscale0}"
: "${REAPPLY_INTERVAL:=300}"
: "${ENABLE_BBR:=true}"
: "${ENABLE_UDP_GRO_FORWARDING:=true}"
: "${ENABLE_MSS_CLAMP:=true}"
: "${ENABLE_RPS:=true}"
: "${CPU_GOVERNOR:=performance}"
: "${DISABLE_WIFI_POWERSAVE:=true}"
: "${TXQUEUELEN:=}"
: "${IPTABLES:=auto}"

log()  { printf '%s [tuner] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '%s [tuner] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
on()   { [[ "${1,,}" == "true" || "$1" == "1" || "${1,,}" == "yes" ]]; }

detect_wan() {
  if [[ "$WAN_IFACE" != "auto" ]]; then
    echo "$WAN_IFACE"; return
  fi
  ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

# Pick whichever iptables backend the host is already using, so our rules sit
# next to Tailscale's instead of in a table nobody reads.
pick_iptables() {
  if [[ "$IPTABLES" != "auto" ]]; then
    IPT="$IPTABLES"; IPT6="${IPTABLES/iptables/ip6tables}"; return
  fi
  local legacy_rules nft_rules
  legacy_rules=$(iptables-legacy-save 2>/dev/null | grep -c '^-A' || true)
  nft_rules=$(iptables-nft-save 2>/dev/null | grep -c '^-A' || true)
  if (( legacy_rules > nft_rules )); then
    IPT=iptables-legacy; IPT6=ip6tables-legacy
  else
    IPT=iptables-nft; IPT6=ip6tables-nft
  fi
}

set_sysctl() {
  local key="$1" val="$2" path="/proc/sys/${1//./\/}"
  if [[ ! -e "$path" ]]; then
    warn "sysctl $key not available on this kernel, skipping"; return
  fi
  if sysctl -qw "$key=$val" 2>/dev/null; then
    :
  else
    warn "could not set $key=$val"
  fi
}

apply_sysctls() {
  # Forwarding is the one thing an exit node can't live without.
  set_sysctl net.ipv4.ip_forward 1
  set_sysctl net.ipv6.conf.all.forwarding 1

  # Bigger socket buffers. tailscaled moves WireGuard over UDP sockets, and on a
  # busy link the defaults (~200 KB) drop packets before userspace drains them.
  set_sysctl net.core.rmem_max 7500000
  set_sysctl net.core.wmem_max 7500000
  set_sysctl net.core.rmem_default 1048576
  set_sysctl net.core.wmem_default 1048576
  set_sysctl net.ipv4.tcp_rmem "4096 131072 7500000"
  set_sysctl net.ipv4.tcp_wmem "4096 65536 7500000"
  set_sysctl net.ipv4.udp_rmem_min 16384
  set_sysctl net.ipv4.udp_wmem_min 16384

  # Let the kernel queue more packets per softirq round. A Pi's CPU is the
  # bottleneck long before the NIC is, so smoothing bursts helps.
  set_sysctl net.core.netdev_max_backlog 16384
  set_sysctl net.core.netdev_budget 600
  set_sysctl net.core.netdev_budget_usecs 8000
  set_sysctl net.core.somaxconn 8192

  # TCP behaviour for connections the Pi itself terminates (DERP relay traffic,
  # control plane, anything else you run on it).
  set_sysctl net.ipv4.tcp_fastopen 3
  set_sysctl net.ipv4.tcp_mtu_probing 1
  set_sysctl net.ipv4.tcp_slow_start_after_idle 0
  set_sysctl net.ipv4.tcp_notsent_lowat 131072
  set_sysctl net.ipv4.tcp_tw_reuse 1
  set_sysctl net.ipv4.tcp_fin_timeout 15

  # Exit nodes track a connection for every flow from every client.
  set_sysctl net.netfilter.nf_conntrack_max 262144
  set_sysctl net.netfilter.nf_conntrack_tcp_timeout_established 7200

  # Loose reverse-path filtering, otherwise replies routed back through
  # tailscale0 can get dropped as "martians".
  set_sysctl net.ipv4.conf.all.rp_filter 2
  set_sysctl net.ipv4.conf.default.rp_filter 2
}

apply_bbr() {
  on "$ENABLE_BBR" || return 0
  # fq does per-flow pacing and keeps one fat download from starving everyone
  # else's ping. BBR rides on top of it.
  set_sysctl net.core.default_qdisc fq
  modprobe tcp_bbr 2>/dev/null || true
  if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null \
     || sysctl -qw net.ipv4.tcp_congestion_control=bbr 2>/dev/null; then
    set_sysctl net.ipv4.tcp_congestion_control bbr
  else
    warn "BBR isn't available in this kernel, leaving congestion control as is"
  fi
}

apply_qdisc() {
  local dev="$1"
  [[ -n "$dev" && -e "/sys/class/net/$dev" ]] || return 0
  on "$ENABLE_BBR" || return 0
  # default_qdisc only affects interfaces created after it's set, so swap the
  # root qdisc on the existing ones too.
  if ! tc qdisc show dev "$dev" 2>/dev/null | grep -q '^qdisc fq '; then
    tc qdisc replace dev "$dev" root fq 2>/dev/null \
      && log "set fq qdisc on $dev" \
      || warn "could not set fq qdisc on $dev"
  fi
}

apply_udp_gro() {
  local dev="$1"
  on "$ENABLE_UDP_GRO_FORWARDING" || return 0
  [[ -n "$dev" && -e "/sys/class/net/$dev" ]] || return 0
  # Tailscale's own recommendation for Linux exit nodes (kernel 6.2+). Lets the
  # kernel batch UDP packets that are being forwarded, which is a big chunk of
  # the throughput gain on small CPUs.
  local feats
  feats=$(ethtool -k "$dev" 2>/dev/null)
  if ! grep -q 'rx-udp-gro-forwarding' <<<"$feats"; then
    warn "$dev doesn't expose rx-udp-gro-forwarding (kernel too old?), skipping"; return
  fi
  if grep -q 'rx-udp-gro-forwarding: on' <<<"$feats" && grep -q 'rx-gro-list: off' <<<"$feats"; then
    return
  fi
  ethtool -K "$dev" rx-udp-gro-forwarding on rx-gro-list off 2>/dev/null \
    && log "enabled UDP GRO forwarding on $dev" \
    || warn "ethtool refused rx-udp-gro-forwarding on $dev"
}

apply_rps() {
  local dev="$1"
  on "$ENABLE_RPS" || return 0
  [[ -n "$dev" && -d "/sys/class/net/$dev/queues" ]] || return 0
  # The Pi's built-in Ethernet has a single RX queue, so every packet lands on
  # CPU0 unless we spread the work. RPS hashes flows across all cores.
  local ncpu mask
  ncpu=$(nproc)
  (( ncpu > 1 )) || return 0
  mask=$(printf '%x' $(( (1 << ncpu) - 1 )))
  local q
  for q in /sys/class/net/"$dev"/queues/rx-*; do
    [[ -w "$q/rps_cpus" ]] || continue
    if [[ "$(tr -d ',' < "$q/rps_cpus" | sed 's/^0*//')" != "$mask" ]]; then
      echo "$mask" > "$q/rps_cpus" 2>/dev/null && log "RPS mask $mask on $q"
    fi
    [[ -w "$q/rps_flow_cnt" ]] && echo 4096 > "$q/rps_flow_cnt" 2>/dev/null
  done
  [[ -w /proc/sys/net/core/rps_sock_flow_entries ]] && \
    echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null
}

apply_txqueuelen() {
  local dev="$1"
  [[ -n "$TXQUEUELEN" && -n "$dev" && -e "/sys/class/net/$dev" ]] || return 0
  ip link set dev "$dev" txqueuelen "$TXQUEUELEN" 2>/dev/null \
    || warn "could not set txqueuelen on $dev"
}

ipt_ensure() {
  # ipt_ensure <binary> <table> <chain> <rule...>
  local bin="$1" table="$2" chain="$3"; shift 3
  command -v "$bin" >/dev/null || return 0
  "$bin" -t "$table" -C "$chain" "$@" 2>/dev/null && return 0
  "$bin" -t "$table" -A "$chain" "$@" 2>/dev/null
}

apply_mss_clamp() {
  on "$ENABLE_MSS_CLAMP" || return 0
  # tailscale0 runs at MTU 1280. Without clamping, TCP flows through the exit
  # node rely on PMTU discovery, and plenty of sites block the ICMP that needs.
  # Result: stalls and retransmits. Clamping the SYN fixes it up front.
  local dir ok=0
  for dir in -o -i; do
    ipt_ensure "$IPT"  mangle FORWARD "$dir" "$TS_IFACE" -p tcp --tcp-flags SYN,RST SYN \
      -j TCPMSS --clamp-mss-to-pmtu && ok=1
    ipt_ensure "$IPT6" mangle FORWARD "$dir" "$TS_IFACE" -p tcp --tcp-flags SYN,RST SYN \
      -j TCPMSS --clamp-mss-to-pmtu
  done
  (( ok )) || warn "could not add MSS clamp rules with $IPT"
}

apply_cpu_governor() {
  [[ -n "$CPU_GOVERNOR" && "$CPU_GOVERNOR" != "none" ]] || return 0
  # ondemand/schedutil take a few ms to ramp the clock up when a packet burst
  # arrives. On a Pi that shows up directly as latency and jitter.
  local g changed=0
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -w "$g" ]] || continue
    if [[ "$(cat "$g")" != "$CPU_GOVERNOR" ]]; then
      echo "$CPU_GOVERNOR" > "$g" 2>/dev/null && changed=1
    fi
  done
  (( changed )) && log "CPU governor set to $CPU_GOVERNOR"
  return 0
}

apply_wifi_powersave() {
  on "$DISABLE_WIFI_POWERSAVE" || return 0
  command -v iw >/dev/null || return 0
  # Pi Wi-Fi power saving parks the radio between beacons. It's the single
  # biggest source of random 50-200 ms spikes on a Wi-Fi-connected Pi.
  local dev
  for dev in $(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}'); do
    if iw dev "$dev" get power_save 2>/dev/null | grep -q 'on'; then
      iw dev "$dev" set power_save off 2>/dev/null && log "Wi-Fi power save off on $dev"
    fi
  done
}

apply_all() {
  local wan
  wan=$(detect_wan)
  [[ -n "$wan" ]] || warn "couldn't find a default route, interface tweaks skipped this round"
  apply_sysctls
  apply_bbr
  apply_qdisc "$wan"
  apply_udp_gro "$wan"
  apply_rps "$wan"
  apply_txqueuelen "$wan"
  apply_mss_clamp
  apply_cpu_governor
  apply_wifi_powersave
}

show() { printf '  %-42s %s\n' "$1" "$2"; }

check() {
  local wan; wan=$(detect_wan)
  echo "Exit node tuning status"
  echo
  show "WAN interface" "${wan:-<none found>}"
  show "Tailscale interface" "$TS_IFACE $( [[ -e /sys/class/net/$TS_IFACE ]] && echo "(mtu $(cat /sys/class/net/$TS_IFACE/mtu))" || echo '(not up)')"
  show "Kernel" "$(uname -r)"
  echo
  local k
  for k in net.ipv4.ip_forward net.ipv6.conf.all.forwarding net.core.default_qdisc \
           net.ipv4.tcp_congestion_control net.core.rmem_max net.core.wmem_max \
           net.core.netdev_max_backlog net.ipv4.tcp_mtu_probing net.netfilter.nf_conntrack_max; do
    show "$k" "$(sysctl -n "$k" 2>/dev/null || echo n/a)"
  done
  echo
  if [[ -n "$wan" ]]; then
    show "qdisc on $wan" "$(tc qdisc show dev "$wan" 2>/dev/null | awk 'NR==1{print $2}')"
    show "UDP GRO forwarding on $wan" "$(ethtool -k "$wan" 2>/dev/null | awk -F': ' '/rx-udp-gro-forwarding/{print $2}')"
    show "rx-gro-list on $wan" "$(ethtool -k "$wan" 2>/dev/null | awk -F': ' '/rx-gro-list/{print $2}')"
    show "RPS mask on $wan rx-0" "$(cat /sys/class/net/"$wan"/queues/rx-0/rps_cpus 2>/dev/null || echo n/a)"
  fi
  show "CPU governor" "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
  show "iptables backend" "$IPT"
  show "MSS clamp rules (v4)" "$("$IPT" -t mangle -S FORWARD 2>/dev/null | grep -c TCPMSS)"
}

main() {
  pick_iptables
  case "${1:-loop}" in
    check) check ;;
    once)  apply_all; log "done" ;;
    loop)
      log "applying tuning (re-checking every ${REAPPLY_INTERVAL}s)"
      apply_all
      check
      trap 'log "stopping; host settings stay as they are until reboot"; exit 0' TERM INT
      while true; do
        sleep "$REAPPLY_INTERVAL" &
        wait $!
        apply_all
      done
      ;;
    *) echo "usage: $0 [loop|once|check]" >&2; exit 2 ;;
  esac
}

main "$@"
