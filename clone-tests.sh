#!/bin/bash
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
# Parse --env parameter (e.g. ./clone-tests.sh --env AWS)
CLONE_ENV=""
CLONE_REPO=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --env)
            CLONE_ENV="$2"
            shift 2
            ;;
        --repo)
            CLONE_REPO="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
# Configuration - use script's directory for portability across environments
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Default repo: torvalds/linux (~4.5 GB full clone) - large enough for sustained speed measurement
# Override with --repo <url> for other repos (e.g. --repo https://github.com/chromium/chromium)
REPO_URL="${CLONE_REPO:-https://github.com/torvalds/linux}"
# Generate a unique run ID: timestamp + 4-char random suffix
RUN_ID="$(date '+%Y%m%d-%H%M%S')-$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'a-z0-9' | head -c 4)"
TEST_DIR="$SCRIPT_DIR/logs/$RUN_ID"
LOG_FILE="$TEST_DIR/clone_test.log"
SUMMARY_LOG="$TEST_DIR/clone_summary.log"
SPEEDS_LOG="$TEST_DIR/clone_speeds.csv"
CLONE_LIVE_LOG="$TEST_DIR/clone_live.log"
NETWORK_LOG="$TEST_DIR/network_diag.log"
SPEED_STATS_FILE="$TEST_DIR/.clone_speed_stats"
CLONE_DIR="$SCRIPT_DIR/git_clone"
CLONE_TIMEOUT=300  # 5 minutes - linux kernel needs ~2-5 min depending on connection speed
SLEEP_BETWEEN_RUNS=0   # No delay - start next clone immediately after cancel
LOCK_FILE="$SCRIPT_DIR/clone_test.lock"
MAX_LOG_SIZE_KB=51200  # 50 MB - rotate clone_test.log when it exceeds this
MIN_DISK_FREE_KB=10485760  # 10 GB - skip clone if disk is below this (need ~5 GB for linux kernel)
mkdir -p "$TEST_DIR"
echo "============================================"
echo "Clone Speed Test - Run ID: $RUN_ID"
echo "Logs: logs/$RUN_ID/"
echo "============================================"
# Prevent multiple instances; clean up orphans from a previous crashed run
if [ -f "$LOCK_FILE" ]; then
    OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null)
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Already running (PID $OLD_PID), exiting"
        exit 0
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Stale lock file found (PID $OLD_PID dead), cleaning up"
        rm -f "$LOCK_FILE"
    fi
fi
# Kill any orphaned git clone processes left over from a previous interrupted run
pkill -f "git clone.*git_clone" 2>/dev/null
echo $$ > "$LOCK_FILE"

# Function to kill a process tree (process + all descendants)
kill_tree() {
    local pid=$1 sig=${2:-TERM}
    [ -z "$pid" ] && return
    local children
    children=$(pgrep -P "$pid" 2>/dev/null)
    for child in $children; do
        kill_tree "$child" "$sig"
    done
    kill -"$sig" "$pid" 2>/dev/null
}

# Track all background PIDs for cleanup
HEARTBEAT_PID=""
SPEEDS_HEARTBEAT_PID=""
CLONE_PID=""
KILLER_PID=""

SHUTTING_DOWN=0

cleanup() {
    kill_tree $HEARTBEAT_PID 2>/dev/null
    kill_tree $SPEEDS_HEARTBEAT_PID 2>/dev/null
    kill_tree $CLONE_PID 2>/dev/null
    kill_tree $KILLER_PID 2>/dev/null
    # Escalate to SIGKILL for anything that survived
    sleep 1
    kill_tree $HEARTBEAT_PID KILL 2>/dev/null
    kill_tree $SPEEDS_HEARTBEAT_PID KILL 2>/dev/null
    kill_tree $CLONE_PID KILL 2>/dev/null
    kill_tree $KILLER_PID KILL 2>/dev/null
    wait 2>/dev/null
    rm -f "$LOCK_FILE"
}

handle_signal() {
    echo ""
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Caught signal, shutting down..."
    SHUTTING_DOWN=1
    cleanup
    exit 0
}
trap handle_signal INT TERM
trap cleanup EXIT

# Function to log with timestamp (writes to file and stdout for live tailing)
log_message() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >> "$LOG_FILE"
    echo "$msg"
}
# Function to write summary log (writes to file and stdout)
log_summary() {
    echo "$1" >> "$SUMMARY_LOG"
    echo "$1"
}

# Network diagnostics - measure connection quality to GitHub before each clone
run_network_diag() {
    log_message "--- Network Diagnostics ---"

    # Reverse DNS on GitHub IP to identify datacenter/POP
    GITHUB_RDNS=""
    GITHUB_POP=""
    if [[ "$GITHUB_IP" != "unresolved" ]]; then
        GITHUB_RDNS=$(host "$GITHUB_IP" 2>/dev/null | awk '/domain name pointer/ {print $NF}' | head -1)
        if [ -n "$GITHUB_RDNS" ]; then
            log_message "Reverse DNS: $GITHUB_IP -> $GITHUB_RDNS"
            # Extract POP code from rDNS (e.g. lb-140-82-112-4-sea.github.com -> SEA)
            GITHUB_POP=$(echo "$GITHUB_RDNS" | sed 's/.*-\([a-z][a-z][a-z]\)\..*/\1/' | tr '[:lower:]' '[:upper:]')
            [ -n "$GITHUB_POP" ] && log_message "GitHub POP: $GITHUB_POP"
        fi
    fi
    [ -z "$GITHUB_POP" ] && GITHUB_POP="unknown"

    # DNS resolver analysis - critical for GeoIP routing investigation
    # GitHub uses Route53/NS1 which route based on the *resolver's* IP, not the client's
    # If the resolver is in the wrong region, traffic gets sent to the wrong POP
    DNS_RESOLVER=""
    DNS_AUTH_NS=""
    DNS_RESOLVER_RDNS=""
    if command -v dig &>/dev/null; then
        # What DNS resolver is this machine using? (the IP that Route53/NS1 sees)
        DNS_RESOLVER=$(dig +short whoami.akamai.net @ns1-1.akamaitech.net 2>/dev/null | head -1)
        [ -z "$DNS_RESOLVER" ] && DNS_RESOLVER=$(dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null | head -1)
        if [ -n "$DNS_RESOLVER" ]; then
            DNS_RESOLVER_RDNS=$(host "$DNS_RESOLVER" 2>/dev/null | awk '/domain name pointer/ {print $NF}' | head -1)
            log_message "DNS resolver outbound IP: $DNS_RESOLVER${DNS_RESOLVER_RDNS:+ ($DNS_RESOLVER_RDNS)}"
        fi

        # Which DNS server actually answered our query? (local resolver, not auth NS)
        DNS_SERVER=$(dig github.com 2>/dev/null | awk '/^;; SERVER:/ {gsub(/[^0-9.]/, "", $3); print $3}' | head -1)
        [ -n "$DNS_SERVER" ] && log_message "DNS server used: $DNS_SERVER"
        # Which authoritative NS providers serve github.com? (should be Route53 + NS1)
        DNS_AUTH_NS=$(dig NS github.com +short 2>/dev/null | sort | tr '\n' ' ')
        [ -n "$DNS_AUTH_NS" ] && log_message "Auth nameservers: $DNS_AUTH_NS"

        # What do Route53 vs NS1 each return? (they may disagree on POP)
        local ns1_ip r53_ip ns1_pop r53_pop
        ns1_ip=$(dig +short github.com @dns1.p08.nsone.net 2>/dev/null | head -1)
        r53_ip=$(dig +short github.com @ns-1707.awsdns-21.co.uk 2>/dev/null | head -1)
        if [ -n "$ns1_ip" ]; then
            ns1_pop=$(host "$ns1_ip" 2>/dev/null | awk '/domain name pointer/ {print $NF}' | head -1 | sed 's/.*-\([a-z][a-z][a-z]\)\..*/\1/' | tr '[:lower:]' '[:upper:]')
            log_message "NS1 returns: $ns1_ip (POP: ${ns1_pop:-?})"
        fi
        if [ -n "$r53_ip" ]; then
            r53_pop=$(host "$r53_ip" 2>/dev/null | awk '/domain name pointer/ {print $NF}' | head -1 | sed 's/.*-\([a-z][a-z][a-z]\)\..*/\1/' | tr '[:lower:]' '[:upper:]')
            log_message "Route53 returns: $r53_ip (POP: ${r53_pop:-?})"
        fi
        # Flag if NS1 and Route53 disagree on POP routing
        if [ -n "$ns1_pop" ] && [ -n "$r53_pop" ] && [ "$ns1_pop" != "$r53_pop" ]; then
            log_message "WARNING: NS1 ($ns1_pop) and Route53 ($r53_pop) disagree on POP!"
        fi
    else
        log_message "DNS resolver analysis: dig not available"
    fi

    # Configured nameservers on this system
    local sys_resolvers
    if [ -f /etc/resolv.conf ]; then
        sys_resolvers=$(awk '/^nameserver/ {printf "%s ", $2}' /etc/resolv.conf)
    fi
    if [[ "$(uname)" == "Darwin" ]]; then
        sys_resolvers="${sys_resolvers}$(scutil --dns 2>/dev/null | awk '/nameserver\[/ {printf "%s ", $3}' | tr ' ' '\n' | sort -u | tr '\n' ' ')"
    fi
    [ -n "$sys_resolvers" ] && log_message "System resolvers: $sys_resolvers"

    # Per-AZ latency comparison - raw TCP handshake to each known github.com subnet
    # Uses curl in TCP-only mode (no TLS) for pure network latency measurement
    log_message "AZ latency comparison (TCP connect to port 80):"
    local az_ips="140.82.112.3 140.82.113.3 140.82.114.3"
    # Also test the IP we actually resolved to, in case it's a different subnet
    if [[ "$GITHUB_IP" != "unresolved" ]] && ! echo "$az_ips" | grep -q "$GITHUB_IP"; then
        az_ips="$az_ips $GITHUB_IP"
    fi
    AZ_LATENCY_SUMMARY=""
    for az_ip in $az_ips; do
        local az_tcp_time az_pop_name
        # Use TCP-only connect (http:// not https://) to measure pure network latency without TLS
        az_tcp_time=$(curl -w '%{time_connect}' -o /dev/null -s --max-time 5 \
            --resolve "github.com:80:$az_ip" http://github.com 2>/dev/null) || az_tcp_time=""
        if [ -n "$az_tcp_time" ]; then
            local az_tcp_ms
            az_tcp_ms=$(awk "BEGIN {printf \"%.0f\", $az_tcp_time * 1000}")
            az_pop_name=$(host "$az_ip" 2>/dev/null | awk '/domain name pointer/ {print $NF}' | head -1 | sed 's/.*-\([a-z][a-z][a-z]\)\..*/\1/' | tr '[:lower:]' '[:upper:]')
            log_message "  $az_ip (${az_pop_name:-?}): TCP=${az_tcp_ms}ms"
            AZ_LATENCY_SUMMARY="${AZ_LATENCY_SUMMARY}${az_pop_name:-?}@${az_ip}=${az_tcp_ms}ms "
        else
            log_message "  $az_ip: unreachable"
            AZ_LATENCY_SUMMARY="${AZ_LATENCY_SUMMARY}?@${az_ip}=timeout "
        fi
    done

    # HTTPS connection timing via curl (DNS, TCP handshake, TLS handshake, time-to-first-byte)
    local curl_out
    curl_out=$(curl -w 'dns:%{time_namelookup} tcp:%{time_connect} tls:%{time_appconnect} ttfb:%{time_starttransfer}' \
        -o /dev/null -s --max-time 10 https://github.com 2>/dev/null) || curl_out=""

    if [[ -n "$curl_out" ]]; then
        local dns_s tcp_s tls_s ttfb_s
        dns_s=$(echo "$curl_out" | grep -oE 'dns:[0-9.]+' | cut -d: -f2)
        tcp_s=$(echo "$curl_out" | grep -oE 'tcp:[0-9.]+' | cut -d: -f2)
        tls_s=$(echo "$curl_out" | grep -oE 'tls:[0-9.]+' | cut -d: -f2)
        ttfb_s=$(echo "$curl_out" | grep -oE 'ttfb:[0-9.]+' | cut -d: -f2)

        DIAG_DNS_MS=$(awk "BEGIN {printf \"%.0f\", ${dns_s:-0} * 1000}")
        DIAG_TCP_MS=$(awk "BEGIN {printf \"%.0f\", (${tcp_s:-0} - ${dns_s:-0}) * 1000}")
        DIAG_TLS_MS=$(awk "BEGIN {printf \"%.0f\", (${tls_s:-0} - ${tcp_s:-0}) * 1000}")
        DIAG_TTFB_MS=$(awk "BEGIN {printf \"%.0f\", ${ttfb_s:-0} * 1000}")

        DIAG_SUMMARY="DNS=${DIAG_DNS_MS}ms TCP=${DIAG_TCP_MS}ms TLS=${DIAG_TLS_MS}ms TTFB=${DIAG_TTFB_MS}ms"
        log_message "HTTPS timing: $DIAG_SUMMARY"
    else
        DIAG_SUMMARY="curl-failed"
        log_message "HTTPS timing: curl request failed"
    fi

    # Ping test for latency and packet loss (-W is ms on macOS, seconds on Linux)
    local ping_out
    if [[ "$(uname)" == "Darwin" ]]; then
        ping_out=$(ping -c 5 -W 5000 github.com 2>&1) || true
    else
        ping_out=$(ping -c 5 -W 5 github.com 2>&1) || true
    fi
    PING_LOSS=$(echo "$ping_out" | grep -oE '[0-9.]+% packet loss' | head -1)
    PING_AVG=$(echo "$ping_out" | grep -E 'min/avg/max' | cut -d'=' -f2 | cut -d'/' -f2 | tr -d ' ')

    if [[ -n "$PING_AVG" ]]; then
        log_message "Ping: avg=${PING_AVG}ms loss=${PING_LOSS:-0%}"
    else
        log_message "Ping: failed (ICMP may be blocked)"
    fi

    # Append to network diagnostics log
    echo "Clone #$CLONE_NUM | $(date '+%Y-%m-%d %H:%M:%S') | IP=$GITHUB_IP | POP=$GITHUB_POP | Resolver=${DNS_RESOLVER:-N/A} | AuthNS=${DNS_AUTH_NS:-N/A} | AZ_Latency: ${AZ_LATENCY_SUMMARY:-N/A}| $DIAG_SUMMARY | Ping=${PING_AVG:-N/A}ms Loss=${PING_LOSS:-N/A} | rDNS=${GITHUB_RDNS:-N/A}" >> "$NETWORK_LOG"

    # Traceroute - capture the path to github.com (key evidence for routing issues)
    log_message "Running traceroute to github.com (15s max)..."
    local traceroute_cmd
    if command -v traceroute &>/dev/null; then
        traceroute_cmd="traceroute"
    elif command -v tracepath &>/dev/null; then
        traceroute_cmd="tracepath"
    fi
    if [[ -n "$traceroute_cmd" ]]; then
        local trace_out
        # Hard 15s timeout - traceroute can hang for minutes on unresponsive hops
        if command -v timeout &>/dev/null; then
            trace_out=$(timeout 15 $traceroute_cmd -m 20 github.com 2>&1) || true
        elif command -v gtimeout &>/dev/null; then
            trace_out=$(gtimeout 15 $traceroute_cmd -m 20 github.com 2>&1) || true
        else
            # macOS fallback: use perl alarm as timeout
            trace_out=$(perl -e 'alarm 15; exec @ARGV' $traceroute_cmd -m 20 github.com 2>&1) || true
        fi
        local hop_count
        hop_count=$(echo "$trace_out" | grep -cE '^\s*[0-9]+' || echo "0")
        log_message "Traceroute: $hop_count hops to github.com"
        echo "" >> "$NETWORK_LOG"
        echo "--- Traceroute Clone #$CLONE_NUM $(date '+%Y-%m-%d %H:%M:%S') ---" >> "$NETWORK_LOG"
        echo "$trace_out" >> "$NETWORK_LOG"
    else
        log_message "Traceroute: not available (install traceroute for path analysis)"
    fi

    log_message "--- End Network Diagnostics ---"
}

# Self-scheduling loop - runs continuously, no cron needed
while true; do
# Check if we received a shutdown signal
[ $SHUTTING_DOWN -eq 1 ] && exit 0

# Rotate verbose log if it exceeds MAX_LOG_SIZE_KB
if [ -f "$LOG_FILE" ]; then
    log_size_kb=$(du -sk "$LOG_FILE" 2>/dev/null | cut -f1)
    if [ "${log_size_kb:-0}" -ge "$MAX_LOG_SIZE_KB" ]; then
        mv "$LOG_FILE" "${LOG_FILE}.old"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Log rotated (previous log exceeded ${MAX_LOG_SIZE_KB}KB)" > "$LOG_FILE"
    fi
fi

# Disk space pre-check - skip clone if < MIN_DISK_FREE_KB available
DISK_FREE_KB=$(df -k "$TEST_DIR" | awk 'NR==2 {print $4}')
if [ "${DISK_FREE_KB:-0}" -lt "$MIN_DISK_FREE_KB" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: Low disk space (${DISK_FREE_KB}KB free, need ${MIN_DISK_FREE_KB}KB). Waiting 60s..." | tee -a "$LOG_FILE"
    sleep 60
    continue
fi

# Reset PIDs for this iteration (previous iteration's processes are already dead)
HEARTBEAT_PID=""
SPEEDS_HEARTBEAT_PID=""
CLONE_PID=""
KILLER_PID=""
DIAG_SUMMARY=""
PING_AVG=""
PING_LOSS=""
GITHUB_RDNS=""
GITHUB_POP=""
rm -rf "$CLONE_DIR"
rm -f "$SPEED_STATS_FILE"
log_message "==========================================="
log_message "Clone Test Started (READ-ONLY)"
[ -n "$CLONE_ENV" ] && log_message "Environment: $CLONE_ENV"
log_message "Repository: $REPO_URL"
# Get clone number (count of previous runs + 1)
if [ -f "$SUMMARY_LOG" ]; then
    CLONE_NUM=$(grep -c "^Clone #" "$SUMMARY_LOG" 2>/dev/null) || CLONE_NUM=0
    CLONE_NUM=$((CLONE_NUM + 1))
else
    CLONE_NUM=1
    # Create summary log with header
    echo "# Clone Test Summary Log - Repository: $REPO_URL" > "$SUMMARY_LOG"
    [ -n "$CLONE_ENV" ] && echo "# Environment: $CLONE_ENV" >> "$SUMMARY_LOG"
    echo "# Format: Clone #N | Env | Timestamp | Result | Duration | Size | Speed | IP | Network | Ping" >> "$SUMMARY_LOG"
    echo "" >> "$SUMMARY_LOG"
fi
# Resolve github.com IP (respects /etc/hosts overrides and dnsmasq)
if [[ "$(uname)" == "Darwin" ]]; then
    GITHUB_IP=$(host github.com 2>/dev/null | awk '/has address/ {print $4}' | head -1)
else
    GITHUB_IP=$(getent hosts github.com 2>/dev/null | awk '{print $1}' | head -1)
fi
[ -z "$GITHUB_IP" ] && GITHUB_IP=$(dig +short github.com 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
[ -z "$GITHUB_IP" ] && GITHUB_IP="unresolved"

# Run network diagnostics before clone
run_network_diag

# Record start time
START_TIME=$(date +%s)
START_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
log_message "Clone started at: $START_TIMESTAMP"
log_message "github.com resolves to: $GITHUB_IP"
log_message "Clone directory: $CLONE_DIR"
# Attempt to clone over HTTPS - run for CLONE_TIMEOUT seconds, then cancel
# Captures download speed for network performance monitoring
log_message "Running clone for ${CLONE_TIMEOUT}s - will cancel and restart for continuous speed tracking"
# Create speeds log with header if new file (human-readable for tailing)
[ ! -f "$SPEEDS_LOG" ] && echo "# Clone # | Env  | Timestamp           | Received  | Speed      | POP  | IP" > "$SPEEDS_LOG"
[ ! -f "$NETWORK_LOG" ] && echo "# Clone # | Timestamp | IP | POP | HTTPS Timing | Ping | rDNS" > "$NETWORK_LOG"
# Live log: every line from git, updated in real-time (tail -f clone_live.log)
echo "[$(date '+%Y-%m-%d %H:%M:%S')] --- Clone #$CLONE_NUM started${CLONE_ENV:+ (env: $CLONE_ENV)} ---" > "$CLONE_LIVE_LOG"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] (connecting - git may take 1-2 min before first output)..." >> "$CLONE_LIVE_LOG"
# Heartbeat: keep file updating during initial git connect delay (git produces nothing for ~1 min)
( while true; do sleep 5; echo "[$(date '+%Y-%m-%d %H:%M:%S')] (waiting for git output...)" >> "$CLONE_LIVE_LOG"; done ) &
HEARTBEAT_PID=$!
# Speeds heartbeat: when git stalls (no output for 60s), append to speeds CSV so tail -f shows activity
( while true; do
    sleep 60
    [ ! -f "$SPEEDS_LOG" ] && continue
    case $(uname) in Darwin) mtime=$(stat -f %m "$SPEEDS_LOG" 2>/dev/null) ;; *) mtime=$(stat -c %Y "$SPEEDS_LOG" 2>/dev/null) ;; esac
    [ -z "$mtime" ] && continue
    [ $(date +%s) -le $((mtime + 55)) ] && continue  # file updated recently, not stalled
    echo "Clone #$CLONE_NUM | ${CLONE_ENV:--} | $(date '+%Y-%m-%d %H:%M:%S') | (stalled - no update 60s) | -- | ${GITHUB_POP:-?} | $GITHUB_IP" >> "$SPEEDS_LOG"
  done ) &
SPEEDS_HEARTBEAT_PID=$!
# Use PTY so git outputs progress (git buffers when piped). script writes typescript to file - use /dev/stdout to capture
run_git() {
    # Large repos need bigger POST buffer to avoid HTTP 400 on ref negotiation
    if command -v stdbuf &>/dev/null; then
        stdbuf -oL git -c http.postBuffer=524288000 clone --progress "$REPO_URL" "$CLONE_DIR" 2>&1
    elif command -v script &>/dev/null; then
        if [[ "$(uname)" == "Darwin" ]]; then
            script -q /dev/stdout git -c http.postBuffer=524288000 clone --progress "$REPO_URL" "$CLONE_DIR" 2>&1
        else
            script -q -F -t 0 /dev/stdout git -c http.postBuffer=524288000 clone --progress "$REPO_URL" "$CLONE_DIR" 2>&1
        fi
    else
        git -c http.postBuffer=524288000 clone --progress "$REPO_URL" "$CLONE_DIR" 2>&1
    fi
}
# tr '\r' '\n' - git uses \r for progress overwrites; without this, read blocks until clone finishes
# Unbuffered \r-to-\n conversion (stdbuf on Linux, perl sysread on macOS)
unbuf_tr() {
    if command -v stdbuf &>/dev/null; then
        stdbuf -oL tr '\r' '\n'
    else
        perl -e '$|=1; while(sysread(STDIN,$b,4096)){$b=~s/\r/\n/g;print $b}'
    fi
}

( run_git | unbuf_tr | while IFS= read -r line; do
    [ -z "$line" ] && continue
    # Stop heartbeat once git starts producing output
    kill $HEARTBEAT_PID 2>/dev/null
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] GIT: $line"
    echo "$msg" >> "$LOG_FILE"
    echo "$msg"
    # Live log: append every line immediately for tail -f (updates as git outputs, not just speed samples)
    echo "$msg" >> "$CLONE_LIVE_LOG"
    # Extract speed samples - git uses MiB/s when fast, KiB/s when slow (e.g. "157.21 MiB | 4.58 MiB/s" or "13.30 MiB | 774.00 KiB/s")
    if [[ "$line" =~ ([0-9]+\.[0-9]+)\ (MiB|GiB)\ \|\ ([0-9]+\.[0-9]+)\ (MiB|KiB)/s ]]; then
        received_val="${BASH_REMATCH[1]}"
        received_unit="${BASH_REMATCH[2]}"
        speed_val="${BASH_REMATCH[3]}"
        speed_unit="${BASH_REMATCH[4]}"
        # Normalize received to MiB for monotonic check (detect macOS script buffer replays)
        if [[ "$received_unit" == "GiB" ]]; then
            received_mib=$(awk "BEGIN {printf \"%.2f\", $received_val * 1024}")
        else
            received_mib="$received_val"
        fi
        # Skip if received went backward (macOS script replays entire buffer at end)
        if [[ -n "$LAST_RECEIVED_MIB" ]]; then
            is_backward=$(awk "BEGIN {print ($received_mib < $LAST_RECEIVED_MIB) ? 1 : 0}")
            [[ "$is_backward" == "1" ]] && continue
        fi
        # Skip consecutive identical values
        current="${received_val}|${speed_val}|${speed_unit}"
        [[ "$current" == "${LAST_SPEED:-}" ]] && continue
        LAST_SPEED="$current"
        LAST_RECEIVED_MIB="$received_mib"
        ts=$(date '+%Y-%m-%d %H:%M:%S')
        # Normalize to MiB/s for consistent CSV (KiB/s / 1024 = MiB/s)
        if [[ "$speed_unit" == "KiB" ]]; then
            speed_mib=$(awk "BEGIN {printf \"%.2f\", $speed_val / 1024}")
        else
            speed_mib="$speed_val"
        fi
        speed_display="${speed_mib} MiB/s"
        line_out="Clone #$CLONE_NUM | ${CLONE_ENV:--} | $ts | ${received_val} ${received_unit} received | $speed_display | ${GITHUB_POP:-?} | $GITHUB_IP"
        echo "$line_out" >> "$SPEEDS_LOG"
        echo "$line_out"
        # Track min/max/sum/count for per-clone speed stats
        echo "$speed_mib" >> "$SPEED_STATS_FILE"
    fi
done ) &
CLONE_PID=$!
# Kill the entire process tree (git + pipe + while loop) after timeout
( sleep $CLONE_TIMEOUT
  kill_tree $CLONE_PID
  sleep 2
  kill_tree $CLONE_PID KILL
) &
KILLER_PID=$!
wait $CLONE_PID 2>/dev/null
EXIT_CODE=$?
kill_tree $HEARTBEAT_PID 2>/dev/null
kill_tree $SPEEDS_HEARTBEAT_PID 2>/dev/null
kill_tree $KILLER_PID 2>/dev/null
wait 2>/dev/null
END_TIME=$(date +%s)
END_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
DURATION=$((END_TIME - START_TIME))
log_message "Clone ended at: $END_TIMESTAMP"
log_message "Duration: ${DURATION} seconds"

# Calculate per-clone speed stats from samples (min/max/avg)
SPEED_MIN="" SPEED_MAX="" SPEED_AVG="" SPEED_SAMPLES=0
if [ -f "$SPEED_STATS_FILE" ] && [ -s "$SPEED_STATS_FILE" ]; then
    read -r SPEED_MIN SPEED_MAX SPEED_AVG SPEED_SAMPLES <<< $(awk '
        BEGIN { min=999999; max=0; sum=0; n=0 }
        { val=$1+0; if(val>0){ if(val<min)min=val; if(val>max)max=val; sum+=val; n++ } }
        END { if(n>0) printf "%.1f %.1f %.1f %d", min, max, sum/n, n; else print "0 0 0 0" }
    ' "$SPEED_STATS_FILE")
    log_message "Speed stats: min=${SPEED_MIN} MiB/s | max=${SPEED_MAX} MiB/s | avg=${SPEED_AVG} MiB/s | samples=${SPEED_SAMPLES}"
fi
rm -f "$SPEED_STATS_FILE"
SPEED_STATS="Min=${SPEED_MIN:-N/A} Max=${SPEED_MAX:-N/A} Avg=${SPEED_AVG:-N/A} MiB/s (${SPEED_SAMPLES:-0} samples)"
# Timed out if we ran for (nearly) the full timeout duration
TIMED_OUT=0
[ $DURATION -ge $((CLONE_TIMEOUT - 2)) ] && TIMED_OUT=1
if [ -d "$CLONE_DIR" ]; then
    SIZE=$(du -sh "$CLONE_DIR" 2>/dev/null | cut -f1)
    SIZE_KB=$(du -sk "$CLONE_DIR" 2>/dev/null | cut -f1)
    SIZE_BYTES=$((SIZE_KB * 1024))
    if [ $DURATION -gt 0 ] && [ $SIZE_BYTES -gt 0 ]; then
        SPEED_MBPS=$(awk "BEGIN {printf \"%.2f\", $SIZE_BYTES / $DURATION / 1024 / 1024}")
        log_message "Download speed: ${SPEED_MBPS} MiB/s"
    fi
    # Get last reported speed from git output (instantaneous rate)
    GIT_SPEED=$(grep -oE '[0-9]+\.[0-9]+ MiB/s' "$LOG_FILE" | tail -1)
    [ -n "$GIT_SPEED" ] && log_message "Git reported speed: $GIT_SPEED"
    FILE_COUNT=$(find "$CLONE_DIR" -type f 2>/dev/null | wc -l)
    log_message "Clone size: $SIZE | Files: $FILE_COUNT"
    if [ $TIMED_OUT -eq 1 ]; then
        log_message "RESULT: TIMEOUT (cancelled after ${CLONE_TIMEOUT}s for network monitoring)"
    fi
fi
if [ $TIMED_OUT -eq 1 ]; then
    log_summary "Clone #$CLONE_NUM | ${CLONE_ENV:--} | $START_TIMESTAMP | TIMEOUT | Duration: ${DURATION}s | Size: ${SIZE:-N/A} | $SPEED_STATS | POP: ${GITHUB_POP:-?} | IP: $GITHUB_IP | Net: ${DIAG_SUMMARY:-N/A} | Ping: ${PING_AVG:-N/A}ms Loss: ${PING_LOSS:-N/A}"
elif [ $EXIT_CODE -eq 0 ]; then
    log_message "RESULT: SUCCESS (full clone completed before timeout)"
    log_summary "Clone #$CLONE_NUM | ${CLONE_ENV:--} | $START_TIMESTAMP | SUCCESS | Duration: ${DURATION}s | Size: ${SIZE:-N/A} | $SPEED_STATS | POP: ${GITHUB_POP:-?} | IP: $GITHUB_IP | Net: ${DIAG_SUMMARY:-N/A} | Ping: ${PING_AVG:-N/A}ms Loss: ${PING_LOSS:-N/A}"
else
    log_message "RESULT: FAILURE"
    log_message "Exit code: $EXIT_CODE"
    ERROR_MSG=$(grep -i "fatal\|error\|timeout" "$LOG_FILE" | tail -1 | sed 's/\[.*\] GIT: //')
    log_message "Error summary from git output:"
    grep -i "error\|fatal\|timeout\|connection\|denied" "$LOG_FILE" | tail -10 | tee -a "$LOG_FILE"
    log_summary "Clone #$CLONE_NUM | ${CLONE_ENV:--} | $START_TIMESTAMP | FAILURE | Duration: ${DURATION}s | Exit Code: $EXIT_CODE | POP: ${GITHUB_POP:-?} | IP: $GITHUB_IP | Net: ${DIAG_SUMMARY:-N/A} | Ping: ${PING_AVG:-N/A}ms Loss: ${PING_LOSS:-N/A} | Error: $ERROR_MSG"
fi
# ALWAYS cleanup clone directory to save space
if [ -d "$CLONE_DIR" ]; then
    log_message "Removing clone directory to free space"
    rm -rf "$CLONE_DIR"
    if [ $? -eq 0 ]; then
        log_message "Successfully removed clone directory"
    else
        log_message "WARNING: Failed to remove clone directory"
    fi
fi
# Check disk space after test
log_message "Disk space after clone:"
df -h "$TEST_DIR" | tee -a "$LOG_FILE"
log_message "Clone test completed"
log_message "Logs: logs/$RUN_ID/ | Speeds: clone_speeds.csv | Network: network_diag.log | Live: clone_live.log (tail -f)"
log_message "==========================================="
if [ $SLEEP_BETWEEN_RUNS -gt 0 ]; then
    log_message "Next run in ${SLEEP_BETWEEN_RUNS}s..."
    sleep $SLEEP_BETWEEN_RUNS
else
    log_message "Starting next clone immediately..."
fi
done
