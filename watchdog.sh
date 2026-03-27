#!/bin/bash
# Mac Proxy Watchdog v3 - with node refresh on failure
# Flow: detect failure → refresh nodes → if still dead → disable proxy

CONFIG_DIR="$HOME/.openclaw/skills/mac-proxy/config"
MIHOMO="$HOME/.openclaw/skills/mac-proxy/mihomo"
REFRESH_SCRIPT="$HOME/.openclaw/skills/mac-proxy/refresh_nodes.sh"
MIHOMO_PLIST="$HOME/Library/LaunchAgents/com.mac-proxy.mihomo.plist"
LOG="$CONFIG_DIR/watchdog.log"
PROXY_PORT=7890
FAIL_COUNT=0
MAX_FAIL=2

log() { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG"; }

get_active_interfaces() {
    networksetup -listallnetworkservices | grep -v "^An asterisk" | while read -r s; do
        networksetup -getinfo "$s" 2>/dev/null | grep -q "IP address" && echo "$s"
    done
}

disable_proxy() {
    log "⚠️  DISABLING PROXY"
    while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        networksetup -setwebproxystate "$svc" off 2>/dev/null
        networksetup -setsecurewebproxystate "$svc" off 2>/dev/null
        networksetup -setsocksfirewallproxystate "$svc" off 2>/dev/null
    done < <(get_active_interfaces)
}

enable_proxy() {
    log "🔌 ENABLING PROXY"
    while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        networksetup -setwebproxy "$svc" 127.0.0.1 $PROXY_PORT 2>/dev/null
        networksetup -setsecurewebproxy "$svc" 127.0.0.1 $PROXY_PORT 2>/dev/null
        networksetup -setsocksfirewallproxy "$svc" 127.0.0.1 7891 2>/dev/null
        networksetup -setwebproxystate "$svc" on 2>/dev/null
        networksetup -setsecurewebproxystate "$svc" on 2>/dev/null
        networksetup -setsocksfirewallproxystate "$svc" on 2>/dev/null
    done < <(get_active_interfaces)
}

is_proxy_working() {
    curl -s --connect-timeout 3 --max-time 5 -x http://127.0.0.1:$PROXY_PORT \
        -o /dev/null -w "%{http_code}" \
        http://www.gstatic.com/generate_204 2>/dev/null | grep -q "204"
}

do_refresh() {
    log "🔄 REFRESH: validating all nodes..."
    bash "$REFRESH_SCRIPT" >> "$LOG" 2>&1
    return $?
}

# --- Main loop ---
log "🐕 Watchdog v3 started (PID $$)"

while true; do
    sleep 15

    # Check if system proxy is enabled
    WIFI_ON=$(networksetup -getwebproxy Wi-Fi 2>/dev/null | grep -c "Enabled: Yes")
    ETH_ON=$(networksetup -getwebproxy Ethernet 2>/dev/null | grep -c "Enabled: Yes")

    if [ "$WIFI_ON" = "0" ] && [ "$ETH_ON" = "0" ]; then
        FAIL_COUNT=0
        continue
    fi

    # Test proxy connectivity
    if is_proxy_working; then
        FAIL_COUNT=0
        continue
    fi

    FAIL_COUNT=$((FAIL_COUNT + 1))
    log "⚠️  Proxy failed ($FAIL_COUNT/$MAX_FAIL)"

    if [ "$FAIL_COUNT" -ge "$MAX_FAIL" ]; then
        log "💀 $MAX_FAIL consecutive failures — starting refresh flow"

        # Step 1: Disable proxy temporarily
        disable_proxy

        # Step 2: Refresh nodes (validate all, replace config)
        if do_refresh; then
            log "✅ Refresh succeeded — re-enabling proxy"
            sleep 5  # Let mihomo stabilize
            enable_proxy
            sleep 5
            if is_proxy_working; then
                log "✅ Proxy restored after refresh!"
            else
                log "❌ Proxy still dead after refresh, disabling"
                disable_proxy
                killall mihomo 2>/dev/null
            fi
        else
            log "❌ Refresh failed — keeping proxy off"
            killall mihomo 2>/dev/null
        fi
        FAIL_COUNT=0
    fi
done
