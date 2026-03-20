# clone-tests

Continuous `git clone` speed and network diagnostics tool for measuring GitHub.com connectivity. Designed to build evidence for network performance issues — particularly degraded clone speeds and reliability when GitHub's geo-DNS routes traffic to a suboptimal datacenter (POP).

Runs on **macOS** and **Linux**. No API tokens or authentication required — uses only public endpoints.

## What It Does

Repeatedly clones a large public repository over HTTPS, capturing:

- **Git transfer speeds** (MiB/s) sampled in real-time, with per-clone min/max/avg stats
- **GitHub POP identification** — which datacenter is serving (e.g. SEA, IAD) via reverse DNS
- **DNS resolver analysis** — identifies the outbound resolver IP that Route53/NS1 use for geo-routing decisions
- **NS1 vs Route53 comparison** — queries both authoritative nameservers directly to check if they agree on POP routing
- **Per-AZ latency comparison** — TCP handshake time to each known GitHub AZ, showing relative distance
- **HTTPS connection timing** — DNS lookup, TCP handshake, TLS handshake, time-to-first-byte
- **Ping latency & packet loss** to github.com
- **Traceroute** to show the network path (15s timeout, won't hang)
- **Clone result** — success, timeout (cancelled after limit), or failure with error details

Each iteration runs full network diagnostics, clones for up to 5 minutes, logs results, cleans up, and starts the next run.

## Usage

```bash
# Make executable (first time only)
chmod +x clone-tests.sh

# Run with defaults (clones chromium/chromium, ~20 GB for sustained speed measurement)
./clone-tests.sh

# Tag the environment for multi-site comparison
./clone-tests.sh --env "MacBook-SFO"
./clone-tests.sh --env "Jenkins-us-west-2"

# Use a different repository (must be HTTPS)
./clone-tests.sh --repo https://github.com/torvalds/linux

# Combine both
./clone-tests.sh --env "AWS-us-west-2" --repo https://github.com/torvalds/linux
```

**Stop anytime** with `Ctrl+C` — all child processes are cleaned up automatically.

## Options

| Flag | Description |
|------|-------------|
| `--env <name>` | Label for this test environment (e.g. `MacBook-SFO`, `Jenkins-us-west-2`). Appears in all log output for multi-site comparison. |
| `--repo <url>` | Override the default repository URL. Must be HTTPS. Default: `https://github.com/chromium/chromium` |

## Output Files

All files are created in the script's directory and are gitignored.

| File | Description |
|------|-------------|
| `clone_summary.log` | One-line-per-clone: speed (avg/min/max), POP, IP, HTTPS timing, ping |
| `clone_speeds.csv` | Real-time speed samples with POP and IP per line |
| `network_diag.log` | DNS resolver info, NS1 vs Route53 results, per-AZ latency, traceroutes |
| `clone_test.log` | Full verbose log with all git output and diagnostics |
| `clone_live.log` | Live-updating log for `tail -f` monitoring |

### Monitoring in Real-Time

```bash
# Watch speed samples as they come in (shows POP per sample)
tail -f clone_speeds.csv

# Watch all git output live
tail -f clone_live.log

# Watch one-line summaries after each clone completes
tail -f clone_summary.log
```

## What to Look For

When building a case for network issues:

### Speed vs POP Correlation
```bash
# Compare speeds by POP
grep "| SEA |" clone_speeds.csv   # speed samples hitting Seattle
grep "| IAD |" clone_speeds.csv   # speed samples hitting Virginia
```

### Key Indicators
- **POP mismatch** — West Coast client getting routed to IAD instead of SEA/SJC
- **NS1 vs Route53 disagreement** — the two authoritative nameservers returning different POPs
- **DNS resolver GeoIP** — resolver outbound IP mapped to wrong region by Route53/NS1
- **Per-AZ latency gap** — e.g. SEA=20ms vs IAD=70ms TCP handshake from same location
- **Speed variance within a clone** — large min/max spread (e.g. min=14 max=60 MiB/s)
- **High TCP/TLS handshake times** — >50ms from West Coast suggests cross-country routing
- **Packet loss** — any non-zero on ping

### DNS Routing (Most Likely Root Cause)
GitHub.com uses geo-DNS (Route53 + NS1). The POP you reach is determined by **your DNS resolver's IP**, not your client IP. If the resolver's outbound IP is GeoIP'd to the wrong region, you'll be routed cross-country. The script captures:
1. Your resolver's outbound IP (what Route53/NS1 see)
2. What each authoritative NS returns independently
3. The actual POP you reached

If the resolver IP is in the wrong region, the fix is on the client's DNS configuration side.

## How It Works

1. Resolves `github.com` IP and performs reverse DNS to identify the serving POP
2. Identifies the DNS resolver outbound IP and queries NS1 + Route53 directly for comparison
3. Tests TCP latency to each known GitHub AZ for side-by-side comparison
4. Measures HTTPS connection timing (DNS, TCP, TLS, TTFB) via `curl`
5. Pings `github.com` for baseline latency and packet loss
6. Runs traceroute to capture the network path (15s max)
7. Starts a `git clone --progress` of the target repo over HTTPS
8. Parses git's progress output in real-time to extract transfer speeds (min/max/avg)
9. After the timeout (default 5 min), kills the clone and logs results
10. Cleans up the cloned data and immediately starts the next iteration

## Requirements

- `bash`, `git`, `curl` (present on macOS and most Linux distros by default)
- `dig` (for DNS resolver analysis — strongly recommended)
- `perl` (used on macOS for unbuffered pipe handling; pre-installed on macOS)
- Internet access to github.com
- ~25 GB free disk space (for Chromium clone; less for smaller repos)
