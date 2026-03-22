# clone-tests

Continuous `git clone` speed and network diagnostics tool for measuring GitHub.com connectivity. Designed to build evidence for network transit issues — particularly degraded clone speeds caused by packet loss on transit provider backbone links (e.g. Zayo) between your location and GitHub's datacenters.

Runs on **macOS**, **Linux**, and **Docker** (amd64 + arm64). No API tokens or authentication required — uses only public endpoints.

## Quick Start

### Docker (recommended — zero install)

```bash
docker run --rm -v ./logs:/app/logs ghcr.io/maxwellpower/clone-tests --env "your-location"
```

All dependencies (mtr, dig, traceroute, etc.) are pre-installed in the image. Logs are persisted to the `./logs` directory on your host via the volume mount.

### Native

```bash
git clone https://github.com/maxwellpower/clone-tests.git
cd clone-tests
chmod +x clone-tests.sh
./clone-tests.sh --env "your-location"
```

Stop anytime with **Ctrl+C**. All data collected so far is preserved. Results go to `logs/<run-id>/`. Zip the folder and send it for analysis.

## How It Works

1. **System fingerprint** — captures OS, public IP, ISP geolocation, git/curl versions, network interfaces, DNS config, routing table, and TCP tuning parameters
2. **MTR report** — sends 100+ probes to GitHub's datacenter IPs, recording per-hop packet loss and latency. This is the single most valuable diagnostic for identifying which transit router is dropping packets
3. **GitHub debug diagnostics** — mirrors the [github-debug.com](https://github-debug.com/) CLI tests: CDN download speeds, verbose `GIT_TRACE`/`GIT_CURL_VERBOSE` clone, SSH connectivity test
4. **Background ping** — continuous timestamped ping to github.com for correlating latency spikes with speed drops
5. **Continuous clone loop** — repeatedly clones `torvalds/linux` (~4.5 GB), cancelling after 5 minutes each time. Before each clone it captures DNS routing, per-AZ TCP latency, HTTPS timing, ping, traceroute, and TCP retransmit stats. During the clone it samples git's reported transfer speed in real-time

The tool runs until you stop it. More clones = more data points = stronger evidence. A typical 30-minute session produces 5-6 clone iterations with full diagnostics.

## Usage

### Native

```bash
# Run with defaults (clones torvalds/linux, ~4.5 GB)
./clone-tests.sh

# Tag the environment for multi-site comparison
./clone-tests.sh --env "MacBook-YYC"
./clone-tests.sh --env "Jenkins-us-west-2"

# Use a different repository
./clone-tests.sh --repo https://github.com/chromium/chromium

# Combine both
./clone-tests.sh --env "AWS-us-east-1" --repo https://github.com/torvalds/linux
```

### Docker

```bash
# Basic — logs persist to ./logs on the host
docker run --rm -v ./logs:/app/logs ghcr.io/maxwellpower/clone-tests

# Tag the environment
docker run --rm -v ./logs:/app/logs ghcr.io/maxwellpower/clone-tests --env "Docker-us-west-2"

# Use a different repository
docker run --rm -v ./logs:/app/logs ghcr.io/maxwellpower/clone-tests --repo https://github.com/chromium/chromium

# Pin to a specific version
docker run --rm -v ./logs:/app/logs ghcr.io/maxwellpower/clone-tests:1.0.0 --env "production"

# Run analysis on collected logs
docker run --rm -v ./logs:/app/logs --entrypoint ./analyze.sh ghcr.io/maxwellpower/clone-tests
```

### CI / Automation

```yaml
# GitHub Actions example
- name: Run clone diagnostics
  timeout-minutes: 10
  run: |
    docker run --rm -v "$GITHUB_WORKSPACE/clone-logs:/app/logs" \
      ghcr.io/maxwellpower/clone-tests:latest \
      --env "gha-runner"

- name: Upload diagnostics
  uses: actions/upload-artifact@v4
  if: always()
  with:
    name: clone-diagnostics
    path: clone-logs/
```

The container exits cleanly on SIGTERM (which is what Docker sends on `docker stop` and what CI sends on timeout), so all data collected up to that point is preserved and the JSON summary is finalized.

## Options

| Flag | Description |
|------|-------------|
| `--env <name>` | Label for this test environment. Appears in all logs and JSON output for multi-site comparison. Use something descriptive like `MacBook-YYC`, `Jenkins-us-west-2`, or `customer-prod-01`. |
| `--repo <url>` | Override the default clone target. Must be a public HTTPS URL. Default: `torvalds/linux` (~4.5 GB). Larger repos produce longer transfers and more speed samples per clone. |

## Output Files

Each run creates a unique directory `logs/<run-id>/` containing:

| File | Description |
|------|-------------|
| `clone_summary.log` | One line per clone: result (TIMEOUT/SUCCESS/FAILURE), speed min/max/avg, POP, IP, HTTPS timing, ping |
| `clone_speeds.csv` | Real-time speed samples during each clone — shows the sawtooth pattern caused by packet loss |
| `network_diag.log` | DNS resolver analysis, NS1 vs Route53 comparison, per-AZ TCP latency, traceroutes |
| `clone_test.log` | Full verbose log with all git output, diagnostics, and timestamps |
| `clone_live.log` | Live-updating log — use `tail -f` to watch in real-time |
| `system_info.log` | Public IP, ISP geolocation, OS, git/curl versions, TCP tuning, routing table, DNS config |
| `mtr.log` | Per-hop packet loss analysis — the key evidence for transit issues |
| `github_debug.log` | CDN endpoint speeds, verbose git trace (mirrors github-debug.com), SSH test |
| `tcp_stats.log` | TCP retransmit counters before/after each clone — quantifies packet loss impact |
| `ping_continuous.log` | Timestamped continuous ping for correlating latency spikes with speed drops |
| `run_summary.json` | Machine-readable summary: system info, MTR worst hop, per-clone metrics for automated aggregation |

### Analyzing Multiple Runs

Use `analyze.sh` to aggregate results across multiple runs — locally or from customer-submitted zip files:

```bash
# Analyze all runs in logs/
./analyze.sh

# Analyze specific runs
./analyze.sh logs/20260320-113015-8neg/ logs/20260321-090422-x7kf/

# Compare customer submissions (unzip each into a directory)
./analyze.sh customer1/ customer2/
```

Output includes:
- **Summary table** — one row per run: ISP, location, POP, speed stats, MTR worst hop
- **Detailed breakdown** — per-clone results with individual speeds, worst MTR hops, transit providers
- **Transit analysis** — surfaces common problem routers seen across all runs (e.g. Zayo's `cr1.iad21.us`)
- **CSV fingerprints** — copy-paste into a spreadsheet for the upstream support ticket

### Monitoring in Real-Time

```bash
# Watch speed samples as they come in
tail -f logs/*/clone_speeds.csv

# Watch all git output live
tail -f logs/*/clone_live.log

# Watch one-line summaries after each clone completes
tail -f logs/*/clone_summary.log
```

### Packaging for a Support Ticket

```bash
# Zip a single run
cd logs && zip -r ../diagnostic-$(date +%Y%m%d).zip <run-id>/

# Zip all runs
zip -r diagnostic-all-$(date +%Y%m%d).zip logs/
```

## What to Look For

### MTR (Most Important)

The MTR report in `mtr.log` shows packet loss at each network hop. Look for:

- **Loss at intermediate hops** (not the first or last) — indicates a congested transit link
- **Same router showing loss from multiple test locations** — confirms the issue is the transit provider, not your local network
- **Loss that climbs progressively** through consecutive hops — a clear sign of a saturated link

Example of a bad path (Zayo backbone to GitHub IAD):

```
 9  zayo.ae20.mpr1.yyc2.ca     0.0%   11ms   <- Entry point (clean)
10  et-0-4-2.ter2.atl10.us     0.0%   53ms   <- Cross-country jump
11  ae0.cr2.msp1.us            26.0%  53ms   <- Loss starts here
12  ae4.cr2.ord9.us            79.0%  53ms   <- Getting worse
14  ae5.cr1.iad21.us           81.0%  53ms   <- Core router, 81% loss
20  lb-140-82-113-4-iad        0.0%   51ms   <- GitHub endpoint is clean
```

In this example, packets are fine until they hit Zayo's backbone (hop 11+), where 81% are dropped. GitHub's own infrastructure (hop 20) shows 0% loss — the problem is entirely in the transit path.

### Speed Patterns

```bash
# Compare speeds by POP (datacenter)
grep "| SEA |" logs/*/clone_speeds.csv   # samples routed to Seattle
grep "| IAD |" logs/*/clone_speeds.csv   # samples routed to Virginia (US East)
```

- **Sawtooth pattern** (e.g. min=15 max=60 MiB/s) — TCP congestion window repeatedly collapsing from packet loss. Classic sign of a lossy transit link.
- **Steady speed** (e.g. min=50 max=60 MiB/s) — healthy path, no significant loss.

### TCP Retransmits

Check `tcp_stats.log` — compare "before" and "after" counters for each clone. A high delta in retransmit segments during a 5-minute clone (hundreds or thousands) confirms the speed swings are caused by packet loss at the network level, not server-side throttling or rate limiting.

### DNS Routing

Check `network_diag.log` for the NS1 vs Route53 comparison. If these two DNS providers return different GitHub IPs (different POPs), it may indicate a DNS-based routing issue where your resolver's geographic location is causing traffic to be sent to a suboptimal datacenter.

## Requirements

### Docker (recommended)

- Docker 20.10+ (or any OCI-compatible runtime: Podman, nerdctl, etc.)
- Internet access to github.com
- ~10 GB free disk space (for the clone target)

All tools are pre-installed in the image. Nothing else to install or configure.

### Native

- **bash** (4.0+), **git**, **curl** — present on macOS and most Linux by default
- **mtr** — **strongly recommended** for per-hop loss analysis
  - macOS: `brew install mtr`
  - Ubuntu/Debian: `sudo apt install mtr`
  - RHEL/Fedora: `sudo dnf install mtr`
- **dig** — for DNS resolver analysis (part of `dnsutils` or `bind-utils`)
- **perl** — pre-installed on macOS; used for unbuffered pipe handling on systems without `stdbuf`
- **traceroute** — fallback path analysis when MTR is not available
- Internet access to github.com
- ~10 GB free disk space

## Docker Image

Pre-built multi-platform images (linux/amd64, linux/arm64) are published to [GitHub Container Registry](https://ghcr.io/maxwellpower/clone-tests) on every push to `main`.

| Tag | Description |
|-----|-------------|
| `latest` | Most recent commit on `main` — always up to date |
| `1.0.0` (etc.) | Pinned version matching the `.version` file — use for reproducibility |
| `sha-abc1234` | Exact commit SHA — full traceability for specific builds |

```bash
# Pull the latest
docker pull ghcr.io/maxwellpower/clone-tests:latest

# Pull a specific version
docker pull ghcr.io/maxwellpower/clone-tests:1.0.0
```

### What's in the Image

The Docker image is based on `debian:bookworm-slim` and includes all required tools:

`git` `curl` `bash` `perl` `mtr-tiny` `dnsutils` (dig) `bind9-host` (host) `traceroute` `iputils-ping` `iproute2` `net-tools` `procps`

### Volume Mount

Logs are written to `/app/logs` inside the container. Mount a host directory to persist them:

```bash
docker run --rm -v /path/to/your/logs:/app/logs ghcr.io/maxwellpower/clone-tests
```

Each run creates a unique subdirectory (`logs/<run-id>/`), so multiple runs share the same mount safely without overwriting each other.

### Network & Permissions

The container uses Docker's default bridge networking, which is sufficient for all diagnostics. The network path from inside the container closely mirrors the host — this is what you want for CI runners, VMs, and cloud instances.

MTR requires the `NET_RAW` capability to send raw ICMP packets. This capability is **included in Docker's default set**, so no extra flags are needed for standard Docker or Podman setups.

If running in a restricted environment that drops all capabilities (e.g. `--cap-drop ALL` or locked-down Kubernetes):

```bash
docker run --rm --cap-add NET_RAW -v ./logs:/app/logs ghcr.io/maxwellpower/clone-tests
```

For Kubernetes pods:

```yaml
securityContext:
  capabilities:
    add: ["NET_RAW"]
```

If raw sockets are fully blocked by the runtime, MTR will fail gracefully and the tool falls back to repeated `traceroute` — you'll still get path data, just without per-hop loss percentages.

## Versioning

The current version is tracked in `.version` at the repo root. It is:

- Printed in the startup banner (`Clone Speed Test v1.0.0`)
- Recorded in `system_info.log` and `run_summary.json` for every run
- Used as a Docker image tag on each build

This means you can always tell exactly which version of the tool produced a given set of diagnostics, even months later.

### Releasing a New Version

1. Update `.version` (e.g. `1.1.0`)
2. Commit and push to `main`
3. The Docker workflow automatically builds and pushes `ghcr.io/maxwellpower/clone-tests:1.1.0` and `:latest`
4. Optionally, create a git tag for an immutable release reference:
   ```bash
   git tag v1.1.0 && git push --tags
   ```

## Troubleshooting

### "MTR not installed" (native only)

Install MTR for the best diagnostics. Without it, the tool falls back to repeated `traceroute`, which shows the path but not per-hop loss percentages. The Docker image always has MTR pre-installed.

```bash
# macOS
brew install mtr

# Ubuntu/Debian
sudo apt install mtr

# RHEL/Fedora
sudo dnf install mtr
```

### Clone fails with HTTP 400

The tool sets `http.postBuffer=524288000` (500 MB) to handle large ref negotiations with repos like `torvalds/linux`. If you still see HTTP 400 errors, try a smaller repo:

```bash
./clone-tests.sh --repo https://github.com/git/git
```

### "Already running" message

The tool uses a lock file (`clone_test.lock`) to prevent multiple simultaneous instances. If a previous run crashed without cleaning up:

```bash
rm -f clone_test.lock
```

### Low disk space warnings

Each clone of `torvalds/linux` is ~4.5 GB. The tool requires at least 10 GB free and checks before each clone. The clone directory is automatically deleted after each iteration — only the small log files (~1-5 MB total) persist.

### Docker: logs directory is empty after run

Make sure the volume mount is correct. The path before the colon must be a host path:

```bash
# Using relative path (current directory)
docker run --rm -v ./logs:/app/logs ghcr.io/maxwellpower/clone-tests

# Using absolute path
docker run --rm -v "$(pwd)/logs:/app/logs" ghcr.io/maxwellpower/clone-tests
```

### Docker: MTR shows "not installed" or permission errors

Some hardened container runtimes drop the `NET_RAW` capability. Add it back:

```bash
docker run --rm --cap-add NET_RAW -v ./logs:/app/logs ghcr.io/maxwellpower/clone-tests
```

### Ctrl+C doesn't stop cleanly

The tool traps SIGINT and SIGTERM for graceful shutdown — it finalizes the JSON summary, kills all child processes, and removes the lock file. If processes linger (rare), they're automatically killed via SIGKILL after 1 second. To force cleanup:

```bash
pkill -f "git clone.*git_clone"
rm -f clone_test.lock
```

## License

MIT
