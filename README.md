# Pi exit node tuner

A small Docker setup that squeezes more speed and less latency out of a
Raspberry Pi running as a **Tailscale** exit node. It tunes the Pi's network
stack, keeps those settings applied, and can optionally run Tailscale itself
and log latency and speed so you can see what changed.

Works on any Pi that runs Docker, on 32-bit or 64-bit Raspberry Pi OS (or any
other Linux). A Pi 4 or 5 on a recent kernel gets the most out of it.

## Quick start

```sh
git clone https://github.com/s-rakim/D.en.git pi-exit && cd pi-exit
cp .env.example .env          # optional, the defaults are fine

# Tailscale already installed on the Pi (the usual case):
docker compose up -d --build

# Want latency/speed logging too:
docker compose --profile monitor up -d --build

# Check what got applied:
docker compose run --rm tuner check
```

If you'd rather have Tailscale in Docker as well, put an auth key in `.env`
(`TS_AUTHKEY=tskey-...`), stop the host's Tailscale (`sudo systemctl disable --now tailscaled`)
and run:

```sh
docker compose --profile tailscale --profile monitor up -d --build
```

Then approve the exit node in the Tailscale admin console (Machines, the `...`
menu on the Pi, Edit route settings, tick "Use as exit node").

## What it changes, and why

All of this lives in [`tuner/tune.sh`](tuner/tune.sh). Every step is optional,
idempotent, and skips itself with a warning if your kernel doesn't support it.
It re-checks every 5 minutes, so if Tailscale restarts or a cable gets
replugged, the settings come back on their own.

| Change | What it does for you |
| --- | --- |
| IP forwarding (v4 + v6) | Required for an exit node to work at all. |
| UDP GRO forwarding on the WAN interface | Tailscale's own recommendation for Linux exit nodes. The kernel batches forwarded UDP packets instead of handling them one by one. This is one of the biggest throughput wins on a Pi. Needs kernel 6.2+ (Raspberry Pi OS Bookworm has it). |
| RPS across all CPU cores | The Pi's Ethernet has one receive queue, so by default one core does all the packet work while the other three idle. RPS spreads it out. |
| CPU governor to `performance` | Stops the CPU from napping between bursts. The clock ramp-up delay shows up as jitter. Costs a bit of power and heat; set `CPU_GOVERNOR=ondemand` if you care. |
| Wi-Fi power save off | If the Pi is on Wi-Fi, power save is the main cause of random 50-200 ms spikes. Only touches Wi-Fi interfaces. |
| TCP MSS clamping on `tailscale0` | Tailscale's tunnel MTU is 1280. Without clamping, some sites stall or load half a page because path MTU discovery gets blocked. |
| `fq` qdisc + BBR | `fq` paces each flow so one big download doesn't wreck everyone's ping. BBR helps the TCP connections the Pi itself makes, which matters most when traffic falls back to a DERP relay. |
| Bigger socket buffers, backlog, budget | Fewer dropped packets when a burst arrives faster than the Pi can drain it. |
| Bigger conntrack table, loose `rp_filter` | Lots of clients and flows don't overflow the table, and return traffic through `tailscale0` isn't dropped as spoofed. |

Nothing is written to disk on the host. A reboot puts everything back to stock
until the container starts again (it does on boot, thanks to `restart: unless-stopped`).
To undo it: `docker compose down && sudo reboot`.

## Why it needs host networking and privileged mode

This is a host tuning tool, so the access is the point, but here's exactly
what needs what:

| Service | Access | Why |
| --- | --- | --- |
| `tuner` | `network_mode: host` | sysctls, qdiscs, ethtool and iptables only affect the network namespace they run in. Without this it would tune the container, not the Pi. |
| `tuner` | `privileged: true` | Write access to `/proc/sys`, `/sys` (RPS, CPU governor) and netfilter. `NET_ADMIN` alone can't write `/sys`. |
| `tuner` | `/lib/modules` read-only | So `modprobe tcp_bbr` works if BBR isn't loaded yet. |
| `tailscale` | `network_mode: host`, `/dev/net/tun`, `NET_ADMIN`, `NET_RAW` | Creates a real `tailscale0` interface the kernel can forward through, and listens on UDP 41641 for direct connections. Runs in kernel TUN mode, never userspace mode (much slower). |
| `monitor` | `network_mode: host` only | Measures the Pi's real uplink rather than Docker's NAT. No extra privileges. |

## The stuff Docker can't fix (but matters more)

Honestly, the tuner gets you maybe 10-40% depending on the Pi. These get you
far more, so check them first:

1. **Make sure connections are direct, not relayed.** On a client using the
   exit node, run `tailscale status`. If the Pi shows `relay "xyz"` instead of
   `direct 1.2.3.4:41641`, traffic is going through a DERP server and you're
   capped at a fraction of your bandwidth with extra latency. Fix it by
   forwarding **UDP 41641** on your router to the Pi (the compose file pins
   that port). `tailscale netcheck` on the Pi tells you if your NAT is hard.
2. **Use Ethernet.** Wi-Fi on a Pi adds latency and jitter no sysctl can remove.
3. **Use a 64-bit OS and a recent kernel.** Bookworm 64-bit gets the UDP GRO
   path and better WireGuard performance.
4. **Keep Tailscale current.** Recent releases have made big throughput jumps
   on Linux. `docker compose pull` if you run the container version.
5. **Watch temperature.** A throttling Pi is a slow Pi. `vcgencmd measure_temp`;
   add a heatsink or fan if it sits above about 75°C under load.

## Monitoring

With `--profile monitor`, the monitor pings `1.1.1.1` and `8.8.8.8` every
minute and runs a speed test every 6 hours. Results land in `./data/`
as CSV.

```sh
docker compose exec monitor monitor.sh summary   # averages so far
docker compose exec monitor monitor.sh speed     # one speed test now
docker compose logs -f monitor
```

Each speed test uses a few hundred MB. Set `SPEEDTEST_INTERVAL=0` in `.env`
if you're on a metered connection.

A good way to measure the tuner's effect: run the monitor for a day with
the tuner stopped, then a day with it running, and compare the summaries.

## Settings

Everything is in [`.env.example`](.env.example). The ones you're most likely
to touch:

- `WAN_IFACE`: auto-detected from the default route. Set it (`eth0`, `wlan0`)
  if detection picks the wrong one.
- `CPU_GOVERNOR`: `performance` (default), `ondemand`, `schedutil`, or `none`.
- `IPTABLES`: auto-picks whichever backend already has rules. Force
  `iptables-legacy` or `iptables-nft` if MSS clamp rules don't show up.
- `ENABLE_*`: turn individual tweaks off.

## Troubleshooting

- **`rx-udp-gro-forwarding` not available**: your kernel is older than 6.2.
  `sudo apt update && sudo apt full-upgrade` on Raspberry Pi OS, then reboot.
- **BBR isn't available**: some custom kernels don't ship `tcp_bbr`. The rest
  of the tuning still applies.
- **Exit node works but some sites hang**: check MSS clamping with
  `docker compose run --rm tuner check`. If the rule count is 0, try
  `IPTABLES=iptables-legacy`.
- **Using another VPN instead of Tailscale?** The tuner works for WireGuard
  and most others too. Set `TS_IFACE` to your tunnel interface (`wg0`, `tun0`).
