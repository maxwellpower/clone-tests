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
# Version (read from .version file next to this script)
VERSION="unknown"
[ -f "$SCRIPT_DIR/.version" ] && VERSION=$(tr -d '[:space:]' < "$SCRIPT_DIR/.version")
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
GITHUB_DEBUG_LOG="$TEST_DIR/github_debug.log"
SYSTEM_INFO_LOG="$TEST_DIR/system_info.log"
MTR_LOG="$TEST_DIR/mtr.log"
PING_LOG="$TEST_DIR/ping_continuous.log"
TCP_STATS_LOG="$TEST_DIR/tcp_stats.log"
RUN_SUMMARY_JSON="$TEST_DIR/run_summary.json"
CLONE_DIR="$SCRIPT_DIR/git_clone"
CLONE_TIMEOUT=300  # 5 minutes - linux kernel needs ~2-5 min depending on connection speed
SLEEP_BETWEEN_RUNS=0   # No delay - start next clone immediately after cancel
LOCK_FILE="$SCRIPT_DIR/clone_test.lock"
MAX_LOG_SIZE_KB=51200  # 50 MB - rotate clone_test.log when it exceeds this
MIN_DISK_FREE_KB=10485760  # 10 GB - skip clone if disk is below this (need ~5 GB for linux kernel)
mkdir -p "$TEST_DIR"
echo "============================================"
echo "Clone Speed Test v${VERSION}"
echo "Run ID: $RUN_ID"
echo "Logs:   logs/$RUN_ID/"
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
pkill -f "git.*clone.*git_clone" 2>/dev/null
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
PING_BG_PID=""

SHUTTING_DOWN=0

cleanup() {
    kill_tree $HEARTBEAT_PID 2>/dev/null
    kill_tree $SPEEDS_HEARTBEAT_PID 2>/dev/null
    kill_tree $CLONE_PID 2>/dev/null
    kill_tree $KILLER_PID 2>/dev/null
    kill_tree $PING_BG_PID 2>/dev/null
    # Escalate to SIGKILL for anything that survived
    sleep 1
    kill_tree $HEARTBEAT_PID KILL 2>/dev/null
    kill_tree $SPEEDS_HEARTBEAT_PID KILL 2>/dev/null
    kill_tree $CLONE_PID KILL 2>/dev/null
    kill_tree $KILLER_PID KILL 2>/dev/null
    kill_tree $PING_BG_PID KILL 2>/dev/null
    wait 2>/dev/null
    rm -f "$LOCK_FILE"
}

handle_signal() {
    echo ""
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Caught signal, shutting down..."
    SHUTTING_DOWN=1
    type finalize_run_summary &>/dev/null && finalize_run_summary 2>/dev/null
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

# Capture system/environment fingerprint - runs once per invocation
# Provides context for support tickets: what machine, OS, network stack, git version
capture_system_info() {
    local info_log="$SYSTEM_INFO_LOG"
    echo "# System Information - $(date '+%Y-%m-%d %H:%M:%S')" > "$info_log"
    echo "# Run ID: $RUN_ID" >> "$info_log"
    echo "# Version: $VERSION" >> "$info_log"
    echo "" >> "$info_log"

    log_message "--- Capturing System Info ---"

    # OS and kernel
    echo "=== OS ===" >> "$info_log"
    uname -a >> "$info_log" 2>&1
    if [[ "$(uname)" == "Darwin" ]]; then
        sw_vers >> "$info_log" 2>&1
    elif [ -f /etc/os-release ]; then
        cat /etc/os-release >> "$info_log" 2>&1
    fi
    echo "" >> "$info_log"

    # Network interfaces and IPs
    echo "=== Network Interfaces ===" >> "$info_log"
    if [[ "$(uname)" == "Darwin" ]]; then
        ifconfig 2>/dev/null | grep -E 'flags|inet ' >> "$info_log"
    else
        ip -4 addr show 2>/dev/null >> "$info_log" || ifconfig 2>/dev/null | grep -E 'flags|inet ' >> "$info_log"
    fi
    echo "" >> "$info_log"

    # Public IP and geolocation (critical for proving where traffic originates)
    echo "=== Public IP ===" >> "$info_log"
    PUB_IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null)
    PUB_CITY="" PUB_REGION="" PUB_ORG="" PUB_COUNTRY=""
    if [ -n "$PUB_IP" ]; then
        echo "Public IP: $PUB_IP" >> "$info_log"
        log_message "Public IP: $PUB_IP"
        # ipinfo.io returns city/region/org - shows ISP and geographic location
        local pub_geo
        pub_geo=$(curl -s --max-time 5 "https://ipinfo.io/${PUB_IP}/json" 2>/dev/null)
        if [ -n "$pub_geo" ]; then
            echo "$pub_geo" >> "$info_log"
            PUB_CITY=$(echo "$pub_geo" | grep -oE '"city":\s*"[^"]*"' | cut -d'"' -f4)
            PUB_REGION=$(echo "$pub_geo" | grep -oE '"region":\s*"[^"]*"' | cut -d'"' -f4)
            PUB_ORG=$(echo "$pub_geo" | grep -oE '"org":\s*"[^"]*"' | cut -d'"' -f4)
            PUB_COUNTRY=$(echo "$pub_geo" | grep -oE '"country":\s*"[^"]*"' | cut -d'"' -f4)
            log_message "Location: $PUB_CITY, $PUB_REGION | ISP: $PUB_ORG"
        fi
    else
        echo "Public IP: unavailable" >> "$info_log"
    fi
    echo "" >> "$info_log"

    # Git version
    echo "=== Git ===" >> "$info_log"
    git --version >> "$info_log" 2>&1
    echo "" >> "$info_log"

    # curl version (TLS backend matters for performance)
    echo "=== curl ===" >> "$info_log"
    curl --version | head -2 >> "$info_log" 2>&1
    echo "" >> "$info_log"

    # DNS configuration
    echo "=== DNS Configuration ===" >> "$info_log"
    if [[ "$(uname)" == "Darwin" ]]; then
        scutil --dns >> "$info_log" 2>&1
    elif [ -f /etc/resolv.conf ]; then
        cat /etc/resolv.conf >> "$info_log" 2>&1
    fi
    echo "" >> "$info_log"

    # Routing table (shows default gateway and any static routes)
    echo "=== Routing Table ===" >> "$info_log"
    if [[ "$(uname)" == "Darwin" ]]; then
        netstat -rn -f inet 2>/dev/null >> "$info_log"
    else
        ip route show 2>/dev/null >> "$info_log" || netstat -rn 2>/dev/null >> "$info_log"
    fi
    echo "" >> "$info_log"

    # TCP tuning parameters (buffer sizes affect throughput on long-haul paths)
    echo "=== TCP Tuning ===" >> "$info_log"
    if [[ "$(uname)" == "Darwin" ]]; then
        sysctl net.inet.tcp.sendspace net.inet.tcp.recvspace \
               net.inet.tcp.autorcvbufmax net.inet.tcp.autosndbufmax \
               net.inet.tcp.rfc1323 net.inet.tcp.mssdflt \
               net.inet.tcp.win_scale_factor 2>/dev/null >> "$info_log"
    else
        sysctl net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
               net.ipv4.tcp_congestion_control net.ipv4.tcp_window_scaling \
               net.core.rmem_max net.core.wmem_max 2>/dev/null >> "$info_log"
    fi
    echo "" >> "$info_log"

    log_message "System info saved to: system_info.log"
    log_message "--- End System Info ---"
}

# MTR (My Traceroute) - the single most valuable tool for finding where packet loss occurs
# Combines traceroute + ping: shows per-hop loss %, jitter, and latency over many probes
# Run once at startup with enough cycles to catch intermittent loss
run_mtr() {
    local mtr_log="$MTR_LOG"
    log_message "--- Running MTR (per-hop packet loss analysis) ---"

    if command -v mtr &>/dev/null; then
        echo "# MTR Report - $(date '+%Y-%m-%d %H:%M:%S')" > "$mtr_log"
        echo "# 100 probes to github.com - look for packet loss at intermediate hops" >> "$mtr_log"
        echo "# Run ID: $RUN_ID" >> "$mtr_log"
        echo "" >> "$mtr_log"

        # --report mode: send 100 probes, print summary table with loss % per hop
        # --report-wide: don't truncate hostnames
        log_message "Running MTR with 100 probes (this takes ~100 seconds)..."
        echo "=== MTR to github.com (100 cycles) ===" >> "$mtr_log"
        mtr --report --report-wide --report-cycles 100 github.com >> "$mtr_log" 2>&1
        echo "" >> "$mtr_log"

        # Also run MTR to the specific IAD IPs to compare paths
        for az_ip in 140.82.112.3 140.82.113.3; do
            local az_rdns
            az_rdns=$(host "$az_ip" 2>/dev/null | awk '/domain name pointer/ {print $NF}' | head -1)
            echo "=== MTR to $az_ip (${az_rdns:-IAD}) - 50 cycles ===" >> "$mtr_log"
            mtr --report --report-wide --report-cycles 50 "$az_ip" >> "$mtr_log" 2>&1
            echo "" >> "$mtr_log"
        done

        log_message "MTR complete - saved to mtr.log"
    else
        echo "# MTR not installed" > "$mtr_log"
        echo "# Install with: brew install mtr (macOS) or apt install mtr (Linux)" >> "$mtr_log"
        log_message "MTR: not installed (brew install mtr) - falling back to extended traceroute"

        # Fallback: multiple traceroutes to detect path instability
        echo "" >> "$mtr_log"
        echo "=== Extended Traceroute (3 runs, 30s each) ===" >> "$mtr_log"
        local trace_cmd=""
        command -v traceroute &>/dev/null && trace_cmd="traceroute"
        command -v tracepath &>/dev/null && [ -z "$trace_cmd" ] && trace_cmd="tracepath"
        if [ -n "$trace_cmd" ]; then
            local timeout_cmd=""
            command -v timeout &>/dev/null && timeout_cmd="timeout 30"
            command -v gtimeout &>/dev/null && [ -z "$timeout_cmd" ] && timeout_cmd="gtimeout 30"
            [ -z "$timeout_cmd" ] && timeout_cmd="perl -e 'alarm 30; exec @ARGV'"
            for run in 1 2 3; do
                echo "--- Traceroute run $run - $(date '+%Y-%m-%d %H:%M:%S') ---" >> "$mtr_log"
                $timeout_cmd $trace_cmd -m 25 github.com >> "$mtr_log" 2>&1 || true
                echo "" >> "$mtr_log"
                sleep 2
            done
        fi
    fi
}

# Capture TCP connection stats (retransmits, window sizes)
# High retransmits = packet loss causing TCP to throttle back = speed swings
capture_tcp_stats() {
    local label="$1"  # "before" or "after"
    echo "=== TCP Stats ($label clone #$CLONE_NUM) - $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$TCP_STATS_LOG"
    if [[ "$(uname)" == "Darwin" ]]; then
        netstat -s -p tcp 2>/dev/null | grep -iE 'retransmit|timeout|reset|segment|connection|out of order|duplicate' >> "$TCP_STATS_LOG"
    else
        netstat -s -t 2>/dev/null | grep -iE 'retransmit|timeout|reset|segment|out of order|loss' >> "$TCP_STATS_LOG"
        # ss -ti shows per-connection stats but only for active connections
        ss -ti dst 140.82.112.0/22 2>/dev/null >> "$TCP_STATS_LOG"
    fi
    echo "" >> "$TCP_STATS_LOG"
}

# Start background continuous ping - timestamps every ping for correlation with speed drops
start_ping_log() {
    log_message "Starting background ping logger..."
    (
        echo "# Continuous Ping - $(date '+%Y-%m-%d %H:%M:%S')" > "$PING_LOG"
        echo "# Correlate timestamps with speed drops in clone_speeds.csv" >> "$PING_LOG"
        echo "" >> "$PING_LOG"
        if [[ "$(uname)" == "Darwin" ]]; then
            ping -i 1 github.com 2>&1 | while IFS= read -r line; do
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] $line" >> "$PING_LOG"
            done
        else
            ping -i 1 github.com 2>&1 | while IFS= read -r line; do
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] $line" >> "$PING_LOG"
            done
        fi
    ) &
    PING_BG_PID=$!
    log_message "Ping logger running (PID $PING_BG_PID)"
}

# GitHub Debug diagnostics (mirrors https://github-debug.com/)
# Runs once per script invocation to capture CDN speeds and verbose git trace
run_github_debug() {
    local debug_log="$GITHUB_DEBUG_LOG"
    local debug_clone_dir="$SCRIPT_DIR/debug-repo"

    echo "# GitHub Debug Diagnostics - $(date '+%Y-%m-%d %H:%M:%S')" > "$debug_log"
    echo "# Equivalent to https://github-debug.com/ CLI tests" >> "$debug_log"
    echo "# Run ID: $RUN_ID" >> "$debug_log"
    echo "" >> "$debug_log"

    log_message "--- GitHub Debug Diagnostics (one-time) ---"

    # 1. CDN endpoint download speed tests
    log_message "Testing download speed from GitHub CDN endpoints..."
    echo "=== CDN Download Speed Tests ===" >> "$debug_log"
    local cdn_endpoints="github.com cloud.githubusercontent.com avatars.githubusercontent.com github.githubassets.com"
    for endpoint in $cdn_endpoints; do
        local dl_speed dl_size dl_time
        dl_out=$(curl -w 'speed:%{speed_download} size:%{size_download} time:%{time_total} dns:%{time_namelookup} tcp:%{time_connect} tls:%{time_appconnect} ttfb:%{time_starttransfer}' \
            -o /dev/null -s --max-time 15 "https://$endpoint" 2>/dev/null) || dl_out=""
        if [ -n "$dl_out" ]; then
            dl_speed=$(echo "$dl_out" | grep -oE 'speed:[0-9.]+' | cut -d: -f2)
            dl_size=$(echo "$dl_out" | grep -oE 'size:[0-9.]+' | cut -d: -f2)
            dl_time=$(echo "$dl_out" | grep -oE 'time:[0-9.]+' | cut -d: -f2)
            dl_dns=$(echo "$dl_out" | grep -oE 'dns:[0-9.]+' | cut -d: -f2)
            dl_tcp=$(echo "$dl_out" | grep -oE 'tcp:[0-9.]+' | cut -d: -f2)
            dl_tls=$(echo "$dl_out" | grep -oE 'tls:[0-9.]+' | cut -d: -f2)
            dl_ttfb=$(echo "$dl_out" | grep -oE 'ttfb:[0-9.]+' | cut -d: -f2)
            local dl_mbps
            dl_mbps=$(awk "BEGIN {printf \"%.2f\", ${dl_speed:-0} * 8 / 1024 / 1024}")
            log_message "  $endpoint: ${dl_mbps} Mbps (${dl_size:-0} bytes in ${dl_time:-?}s)"
            echo "$endpoint | ${dl_mbps} Mbps | ${dl_size:-0} bytes | time=${dl_time:-?}s dns=${dl_dns:-?}s tcp=${dl_tcp:-?}s tls=${dl_tls:-?}s ttfb=${dl_ttfb:-?}s" >> "$debug_log"
        else
            log_message "  $endpoint: failed"
            echo "$endpoint | FAILED" >> "$debug_log"
        fi
    done
    echo "" >> "$debug_log"

    # 2. Verbose git clone of github/debug-repo (small test repo - protocol-level diagnostics)
    log_message "Running verbose debug-repo clone (HTTP)..."
    echo "=== Verbose Debug Repo Clone (HTTPS) ===" >> "$debug_log"
    rm -rf "$debug_clone_dir"
    local debug_start debug_end
    debug_start=$(date +%s)
    GIT_TRACE=1 GIT_TRANSFER_TRACE=1 GIT_CURL_VERBOSE=1 \
        git -c http.postBuffer=524288000 clone https://github.com/github/debug-repo "$debug_clone_dir" >> "$debug_log" 2>&1
    local debug_exit=$?
    debug_end=$(date +%s)
    local debug_duration=$((debug_end - debug_start))
    if [ $debug_exit -eq 0 ]; then
        log_message "  debug-repo HTTPS clone: OK (${debug_duration}s)"
    else
        log_message "  debug-repo HTTPS clone: FAILED (exit $debug_exit, ${debug_duration}s)"
    fi
    echo "" >> "$debug_log"
    echo "Debug repo HTTPS clone: exit=$debug_exit duration=${debug_duration}s" >> "$debug_log"
    echo "" >> "$debug_log"
    rm -rf "$debug_clone_dir"

    # 3. SSH clone test (if SSH key is available)
    echo "=== Verbose Debug Repo Clone (SSH) ===" >> "$debug_log"
    if ssh -T git@github.com 2>&1 | grep -qi "successfully authenticated\|Hi "; then
        log_message "Running verbose debug-repo clone (SSH)..."
        debug_start=$(date +%s)
        GIT_TRACE=1 GIT_TRANSFER_TRACE=1 GIT_SSH_COMMAND="ssh -v" \
            git clone git@github.com:github/debug-repo "$debug_clone_dir" >> "$debug_log" 2>&1
        debug_exit=$?
        debug_end=$(date +%s)
        debug_duration=$((debug_end - debug_start))
        if [ $debug_exit -eq 0 ]; then
            log_message "  debug-repo SSH clone: OK (${debug_duration}s)"
        else
            log_message "  debug-repo SSH clone: FAILED (exit $debug_exit, ${debug_duration}s)"
        fi
        echo "" >> "$debug_log"
        echo "Debug repo SSH clone: exit=$debug_exit duration=${debug_duration}s" >> "$debug_log"
        rm -rf "$debug_clone_dir"
    else
        log_message "  debug-repo SSH clone: skipped (no SSH auth to github.com)"
        echo "SSH clone: skipped (no SSH auth)" >> "$debug_log"
    fi
    echo "" >> "$debug_log"

    # 4. Full curl diagnostic (matches github-debug.com format)
    echo "=== Full curl diagnostic ===" >> "$debug_log"
    curl -s -o/dev/null -w "downloadspeed: %{speed_download} | dnslookup: %{time_namelookup} | connect: %{time_connect} | appconnect: %{time_appconnect} | pretransfer: %{time_pretransfer} | starttransfer: %{time_starttransfer} | total: %{time_total} | size: %{size_download}\n" \
        https://github.com >> "$debug_log" 2>&1
    echo "" >> "$debug_log"

    log_message "GitHub debug diagnostics saved to: github_debug.log"
    log_message "--- End GitHub Debug Diagnostics ---"
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

    # DNS resolver chain analysis - trace the full path that queries take
    # GitHub uses Route53/NS1 which geo-route based on the resolver's IP, not the client's
    DNS_RESOLVER=""
    DNS_AUTH_NS=""
    DNS_RESOLVER_RDNS=""
    DNS_CHAIN=""
    if command -v dig &>/dev/null; then
        # 1. What local/system resolver did our query actually go to?
        local dns_server_used
        dns_server_used=$(dig github.com 2>/dev/null | awk '/^;; SERVER:/ {split($3, a, "#"); print a[1]}' | head -1)
        if [ -n "$dns_server_used" ]; then
            local dns_server_rdns
            dns_server_rdns=$(host "$dns_server_used" 2>/dev/null | awk '/domain name pointer/ {print $NF}' | head -1)
            log_message "System DNS server: $dns_server_used${dns_server_rdns:+ ($dns_server_rdns)}"
            DNS_CHAIN="client->$dns_server_used"
        fi

        # 2. What upstream forwarders does the system resolver use?
        #    Query through the system resolver to see what IP auth NS receives from
        local resolver_via_system resolver_via_system_rdns
        resolver_via_system=$(dig +short whoami.akamai.net @ns1-1.akamaitech.net 2>/dev/null | head -1)
        if [ -n "$resolver_via_system" ]; then
            resolver_via_system_rdns=$(host "$resolver_via_system" 2>/dev/null | awk '/domain name pointer/ {print $NF}' | head -1)
            log_message "Direct auth query source (WAN IP): $resolver_via_system${resolver_via_system_rdns:+ ($resolver_via_system_rdns)}"
        fi

        # 3. What IP does the system resolver present to authoritative NS?
        #    Query akamai whoami THROUGH the system resolver (not direct to auth NS)
        local resolver_seen_by_auth resolver_seen_rdns
        if [ -n "$dns_server_used" ]; then
            resolver_seen_by_auth=$(dig +short whoami.akamai.net @"$dns_server_used" 2>/dev/null | head -1)
        fi
        if [ -z "$resolver_seen_by_auth" ]; then
            # Fallback: use default resolver
            resolver_seen_by_auth=$(dig +short whoami.akamai.net 2>/dev/null | head -1)
        fi
        if [ -n "$resolver_seen_by_auth" ]; then
            resolver_seen_rdns=$(host "$resolver_seen_by_auth" 2>/dev/null | awk '/domain name pointer/ {print $NF}' | head -1)
            DNS_RESOLVER="$resolver_seen_by_auth"
            DNS_RESOLVER_RDNS="$resolver_seen_rdns"
            log_message "Auth NS sees resolver as: $resolver_seen_by_auth${resolver_seen_rdns:+ ($resolver_seen_rdns)}"
            DNS_CHAIN="${DNS_CHAIN:+$DNS_CHAIN->}$resolver_seen_by_auth->authNS"
        fi

        # 4. Check EDNS Client Subnet: does Google DNS forward our subnet to auth NS?
        #    This overrides geo-routing — auth NS uses ECS subnet instead of resolver IP
        local ecs_info
        ecs_info=$(dig +short o-o.myaddr.l.google.com TXT @8.8.8.8 2>/dev/null | grep "edns0-client-subnet" | tr -d '"')
        [ -n "$ecs_info" ] && log_message "Google DNS ECS: $ecs_info"

        # 5. Cloudflare resolver identity — what IP does CF use to query auth NS?
        local cf_resolver_ip
        cf_resolver_ip=$(dig +short whoami.cloudflare CH TXT @1.1.1.1 2>/dev/null | tr -d '"')
        [ -n "$cf_resolver_ip" ] && log_message "Cloudflare resolver IP: $cf_resolver_ip"

        # 6. Which authoritative NS providers serve github.com?
        DNS_AUTH_NS=$(dig NS github.com +short 2>/dev/null | sort | tr '\n' ' ')
        [ -n "$DNS_AUTH_NS" ] && log_message "Auth nameservers: $DNS_AUTH_NS"

        # 7. What do Route53 vs NS1 each return for github.com?
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
        if [ -n "$ns1_pop" ] && [ -n "$r53_pop" ] && [ "$ns1_pop" != "$r53_pop" ]; then
            log_message "WARNING: NS1 ($ns1_pop) and Route53 ($r53_pop) disagree on POP!"
        fi

        # 8. Compare: what does the system resolver return vs direct public DNS?
        local system_github_ip google_github_ip cf_github_ip sys_pop google_pop cf_pop
        system_github_ip=$(dig +short github.com 2>/dev/null | head -1)
        google_github_ip=$(dig +short github.com @8.8.8.8 2>/dev/null | head -1)
        cf_github_ip=$(dig +short github.com @1.1.1.1 2>/dev/null | head -1)
        if [ -n "$system_github_ip" ]; then
            sys_pop=$(host "$system_github_ip" 2>/dev/null | awk '/domain name pointer/ {print $NF}' | head -1 | sed 's/.*-\([a-z][a-z][a-z]\)\..*/\1/' | tr '[:lower:]' '[:upper:]')
        fi
        if [ -n "$google_github_ip" ]; then
            google_pop=$(host "$google_github_ip" 2>/dev/null | awk '/domain name pointer/ {print $NF}' | head -1 | sed 's/.*-\([a-z][a-z][a-z]\)\..*/\1/' | tr '[:lower:]' '[:upper:]')
        fi
        if [ -n "$cf_github_ip" ]; then
            cf_pop=$(host "$cf_github_ip" 2>/dev/null | awk '/domain name pointer/ {print $NF}' | head -1 | sed 's/.*-\([a-z][a-z][a-z]\)\..*/\1/' | tr '[:lower:]' '[:upper:]')
        fi
        log_message "POP by resolver: System=${sys_pop:-?}($system_github_ip) Google=${google_pop:-?}($google_github_ip) CF=${cf_pop:-?}($cf_github_ip)"

        [ -n "$DNS_CHAIN" ] && log_message "DNS chain: $DNS_CHAIN"
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
    echo "Clone #$CLONE_NUM | $(date '+%Y-%m-%d %H:%M:%S') | IP=$GITHUB_IP | POP=$GITHUB_POP | Resolver=${DNS_RESOLVER:-N/A} | AuthNS=${DNS_AUTH_NS:-N/A} | DNSChain=${DNS_CHAIN:-N/A} | AZ_Latency: ${AZ_LATENCY_SUMMARY:-N/A}| $DIAG_SUMMARY | Ping=${PING_AVG:-N/A}ms Loss=${PING_LOSS:-N/A} | rDNS=${GITHUB_RDNS:-N/A}" >> "$NETWORK_LOG"

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

# Run one-time diagnostics at start of run
capture_system_info
run_github_debug
run_mtr
start_ping_log

# Extract worst MTR hop for summary (highest loss at an intermediate hop)
MTR_WORST_HOP="" MTR_WORST_LOSS="" MTR_WORST_HOST=""
if [ -f "$MTR_LOG" ] && grep -q "Loss%" "$MTR_LOG"; then
    # Parse MTR report: find intermediate hop with highest loss (skip first/last hop and ???)
    read -r MTR_WORST_HOST MTR_WORST_LOSS <<< $(awk '
        /^\s*[0-9]+\.\|--/ && !/\?\?\?/ {
            gsub(/\|--/, "")
            hop=$1+0; host=$2; loss=$3
            gsub(/%/, "", loss)
            if (loss+0 > max_loss+0 && loss+0 < 100) { max_loss=loss; max_host=host; max_hop=hop }
        }
        END { if (max_hop) printf "%s %s", max_host, max_loss }
    ' "$MTR_LOG")
fi

# Write initial run_summary.json with system info
# Escape strings for safe JSON embedding (handles quotes, backslashes, newlines)
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}
RUN_SUMMARY_FINALIZED=0
write_run_summary() {
    cat > "$RUN_SUMMARY_JSON" << SUMMARY_EOF
{
  "run_id": "$RUN_ID",
  "version": "$VERSION",
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "env": "$(json_escape "${CLONE_ENV:-}")",
  "repo": "$(json_escape "$REPO_URL")",
  "system": {
    "os": "$(json_escape "$(uname -s) $(uname -r)")",
    "hostname": "$(json_escape "$(hostname -s 2>/dev/null || echo unknown)")",
    "public_ip": "$(json_escape "${PUB_IP:-unknown}")",
    "city": "$(json_escape "${PUB_CITY:-unknown}")",
    "region": "$(json_escape "${PUB_REGION:-unknown}")",
    "country": "$(json_escape "${PUB_COUNTRY:-unknown}")",
    "isp": "$(json_escape "${PUB_ORG:-unknown}")",
    "git_version": "$(git --version 2>/dev/null | awk '{print $3}')",
    "curl_version": "$(curl --version 2>/dev/null | head -1 | awk '{print $2}')"
  },
  "mtr": {
    "worst_hop_host": "$(json_escape "${MTR_WORST_HOST:-none}")",
    "worst_hop_loss_pct": ${MTR_WORST_LOSS:-0},
    "has_mtr": $(command -v mtr &>/dev/null && echo "true" || echo "false")
  },
  "clones": [
SUMMARY_EOF
}

# Append a clone result to run_summary.json
append_clone_summary() {
    local result="$1" comma=""
    # Add comma before all entries except the first
    [ "$CLONE_NUM" -gt 1 ] && comma=","
    cat >> "$RUN_SUMMARY_JSON" << CLONE_EOF
    ${comma}{
      "clone_num": $CLONE_NUM,
      "timestamp": "$(json_escape "$START_TIMESTAMP")",
      "result": "$result",
      "duration_s": $DURATION,
      "speed_min_mib": ${SPEED_MIN:-0},
      "speed_max_mib": ${SPEED_MAX:-0},
      "speed_avg_mib": ${SPEED_AVG:-0},
      "speed_samples": ${SPEED_SAMPLES:-0},
      "pop": "$(json_escape "${GITHUB_POP:-unknown}")",
      "github_ip": "$GITHUB_IP",
      "dns_resolver_ip": "$(json_escape "${DNS_RESOLVER:-unknown}")",
      "ping_avg_ms": "${PING_AVG:-0}",
      "ping_loss": "${PING_LOSS:-0%}",
      "https_dns_ms": "${DIAG_DNS_MS:-0}",
      "https_tcp_ms": "${DIAG_TCP_MS:-0}",
      "https_tls_ms": "${DIAG_TLS_MS:-0}",
      "https_ttfb_ms": "${DIAG_TTFB_MS:-0}"
    }
CLONE_EOF
}

# Close the JSON array (called on shutdown, idempotent)
finalize_run_summary() {
    if [ "$RUN_SUMMARY_FINALIZED" -eq 0 ] && [ -f "$RUN_SUMMARY_JSON" ]; then
        RUN_SUMMARY_FINALIZED=1
        echo "  ]" >> "$RUN_SUMMARY_JSON"
        echo "}" >> "$RUN_SUMMARY_JSON"
    fi
}
write_run_summary

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
DIAG_DNS_MS=""
DIAG_TCP_MS=""
DIAG_TLS_MS=""
DIAG_TTFB_MS=""
DNS_RESOLVER=""
DNS_CHAIN=""
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

# Capture TCP stats before clone (delta shows retransmits during clone)
capture_tcp_stats "before"

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
# Use PTY so git outputs progress (git buffers when piped). script writes typescript to /dev/stdout
run_git() {
    if command -v stdbuf &>/dev/null; then
        stdbuf -oL git -c http.postBuffer=524288000 clone --bare --progress "$REPO_URL" "$CLONE_DIR" 2>&1
    elif command -v script &>/dev/null; then
        if [[ "$(uname)" == "Darwin" ]]; then
            script -q /dev/stdout git -c http.postBuffer=524288000 clone --bare --progress "$REPO_URL" "$CLONE_DIR" 2>&1
        else
            script -q -F -t 0 /dev/stdout git -c http.postBuffer=524288000 clone --bare --progress "$REPO_URL" "$CLONE_DIR" 2>&1
        fi
    else
        git -c http.postBuffer=524288000 clone --bare --progress "$REPO_URL" "$CLONE_DIR" 2>&1
    fi
}
unbuf_tr() {
    if command -v stdbuf &>/dev/null; then
        stdbuf -oL tr '\r' '\n'
    else
        perl -e '$|=1; while(sysread(STDIN,$b,4096)){$b=~s/\r/\n/g;print $b}'
    fi
}

( run_git | unbuf_tr | while IFS= read -r line; do
    [ -z "$line" ] && continue
    kill $HEARTBEAT_PID 2>/dev/null
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] GIT: $line"
    echo "$msg" >> "$LOG_FILE"
    echo "$msg"
    echo "$msg" >> "$CLONE_LIVE_LOG"
    if [[ "$line" =~ ([0-9]+\.[0-9]+)\ (MiB|GiB)\ \|\ ([0-9]+\.[0-9]+)\ (MiB|KiB)/s ]]; then
        received_val="${BASH_REMATCH[1]}"
        received_unit="${BASH_REMATCH[2]}"
        speed_val="${BASH_REMATCH[3]}"
        speed_unit="${BASH_REMATCH[4]}"
        if [[ "$received_unit" == "GiB" ]]; then
            received_mib=$(awk "BEGIN {printf \"%.2f\", $received_val * 1024}")
        else
            received_mib="$received_val"
        fi
        if [[ -n "$LAST_RECEIVED_MIB" ]]; then
            is_backward=$(awk "BEGIN {print ($received_mib < $LAST_RECEIVED_MIB) ? 1 : 0}")
            [[ "$is_backward" == "1" ]] && continue
        fi
        current="${received_val}|${speed_val}|${speed_unit}"
        [[ "$current" == "${LAST_SPEED:-}" ]] && continue
        LAST_SPEED="$current"
        LAST_RECEIVED_MIB="$received_mib"
        ts=$(date '+%Y-%m-%d %H:%M:%S')
        if [[ "$speed_unit" == "KiB" ]]; then
            speed_mib=$(awk "BEGIN {printf \"%.2f\", $speed_val / 1024}")
        else
            speed_mib="$speed_val"
        fi
        speed_display="${speed_mib} MiB/s"
        line_out="Clone #$CLONE_NUM | ${CLONE_ENV:--} | $ts | ${received_val} ${received_unit} received | $speed_display | ${GITHUB_POP:-?} | $GITHUB_IP"
        echo "$line_out" >> "$SPEEDS_LOG"
        echo "$line_out"
        echo "$speed_mib" >> "$SPEED_STATS_FILE"
    fi
done ) &
CLONE_PID=$!
# Kill the entire process tree after timeout
( sleep $CLONE_TIMEOUT && kill_tree $CLONE_PID && sleep 2 && kill_tree $CLONE_PID KILL ) 2>/dev/null &
KILLER_PID=$!
wait $CLONE_PID 2>/dev/null
EXIT_CODE=$?
kill_tree $HEARTBEAT_PID 2>/dev/null
kill_tree $SPEEDS_HEARTBEAT_PID 2>/dev/null
kill_tree $KILLER_PID 2>/dev/null
# Only wait for specific PIDs - bare 'wait' would block on PING_BG_PID (runs forever)
wait $CLONE_PID $KILLER_PID 2>/dev/null
END_TIME=$(date +%s)
END_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
DURATION=$((END_TIME - START_TIME))
log_message "Clone ended at: $END_TIMESTAMP"
log_message "Duration: ${DURATION} seconds"

# Capture TCP stats after clone (compare with before to find retransmits)
capture_tcp_stats "after"

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
    append_clone_summary "TIMEOUT"
elif [ $EXIT_CODE -eq 0 ]; then
    log_message "RESULT: SUCCESS (full clone completed before timeout)"
    log_summary "Clone #$CLONE_NUM | ${CLONE_ENV:--} | $START_TIMESTAMP | SUCCESS | Duration: ${DURATION}s | Size: ${SIZE:-N/A} | $SPEED_STATS | POP: ${GITHUB_POP:-?} | IP: $GITHUB_IP | Net: ${DIAG_SUMMARY:-N/A} | Ping: ${PING_AVG:-N/A}ms Loss: ${PING_LOSS:-N/A}"
    append_clone_summary "SUCCESS"
else
    log_message "RESULT: FAILURE"
    log_message "Exit code: $EXIT_CODE"
    ERROR_MSG=$(grep -i "fatal\|error\|timeout" "$LOG_FILE" | tail -1 | sed 's/\[.*\] GIT: //')
    log_message "Error summary from git output:"
    grep -i "error\|fatal\|timeout\|connection\|denied" "$LOG_FILE" | tail -10 | tee -a "$LOG_FILE"
    log_summary "Clone #$CLONE_NUM | ${CLONE_ENV:--} | $START_TIMESTAMP | FAILURE | Duration: ${DURATION}s | Exit Code: $EXIT_CODE | POP: ${GITHUB_POP:-?} | IP: $GITHUB_IP | Net: ${DIAG_SUMMARY:-N/A} | Ping: ${PING_AVG:-N/A}ms Loss: ${PING_LOSS:-N/A} | Error: $ERROR_MSG"
    append_clone_summary "FAILURE"
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
