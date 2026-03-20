# clone-tests

Continuous `git clone` speed and network diagnostics tool for measuring GitHub.com connectivity. Designed to build evidence for network performance issues — particularly degraded clone speeds and reliability from the US West Coast.

Runs on **macOS** and **Linux**.

## What It Does

Repeatedly clones a large public repository over HTTPS, capturing:

- **Git transfer speeds** (MiB/s) sampled in real-time from git progress output
- **HTTPS connection timing** — DNS lookup, TCP handshake, TLS handshake, time-to-first-byte (via `curl`)
- **Ping latency & packet loss** to github.com
- **Reverse DNS** on the resolved GitHub IP to identify which datacenter/POP is being hit
- **Clone result** — success, timeout (cancelled after limit), or failure with error details

Each clone iteration runs network diagnostics first, then clones for up to 5 minutes before cancelling, cleaning up, and starting the next run. All data is logged to structured files for analysis.

## Usage

```bash
# Make executable (first time only)
chmod +x clone-tests.sh

# Run with defaults (clones torvalds/linux, the largest practical GitHub repo at ~4.5 GB)
./clone-tests.sh

# Tag the environment for multi-site comparison
./clone-tests.sh --env "MacBook-SFO"

# Use a different repository
./clone-tests.sh --repo https://github.com/BabylonJS/Babylon.js

# Combine both
./clone-tests.sh --env "AWS-us-west-2" --repo https://github.com/BabylonJS/Babylon.js
```

**Stop anytime** with `Ctrl+C` — all child processes are cleaned up automatically.

## Options

| Flag | Description |
|------|-------------|
| `--env <name>` | Label for this test environment (e.g. `MacBook-SFO`, `AWS-us-west-2`). Appears in all log output. |
| `--repo <url>` | Override the default repository URL. Must be HTTPS. Default: `https://github.com/torvalds/linux` |

## Output Files

All files are created in the script's directory and are gitignored.

| File | Description |
|------|-------------|
| `clone_summary.log` | One-line-per-clone results with speed, timing, ping, and IP data |
| `clone_speeds.csv` | Real-time speed samples extracted from git progress output |
| `network_diag.log` | Per-clone HTTPS timing, ping stats, and reverse DNS |
| `clone_test.log` | Full verbose log with all git output and diagnostics |
| `clone_live.log` | Live-updating log for `tail -f` monitoring |

### Monitoring in Real-Time

```bash
# Watch speed samples as they come in
tail -f clone_speeds.csv

# Watch all git output live
tail -f clone_live.log

# Watch one-line summaries after each clone completes
tail -f clone_summary.log
```

## What to Look For

When building a case for network issues, compare across environments and look for:

- **High TCP handshake times** (>50ms from West Coast suggests suboptimal routing)
- **Reverse DNS showing East Coast POPs** (e.g. `iad` for Virginia instead of `sea`/`sjc` for West Coast)
- **Inconsistent speeds** between runs at the same location
- **Packet loss** on ping (any non-zero loss is notable)
- **Speed differences** between West Coast and other regions running the same test
- **Timeouts or failures** that correlate with specific times of day or GitHub IPs

## How It Works

1. Resolves `github.com` IP and performs reverse DNS to identify the serving POP
2. Measures HTTPS connection timing (DNS, TCP, TLS, TTFB) via `curl`
3. Pings `github.com` for baseline latency and packet loss
4. Starts a `git clone --progress` of the target repo over HTTPS
5. Parses git's progress output in real-time to extract transfer speeds
6. After the timeout (default 5 min), kills the clone and logs results
7. Cleans up the cloned data and immediately starts the next iteration

## Requirements

- `bash`, `git`, `curl` (present on macOS and most Linux distros by default)
- `perl` (used on macOS for unbuffered pipe handling; pre-installed on macOS)
- Internet access to github.com
