#!/bin/bash
# Node Refresh Script - validates all nodes, replaces config with top 50
# Called by watchdog on proxy failure, or manually

SKILL_DIR="$HOME/.openclaw/skills/mac-proxy"
CONFIG_DIR="$SKILL_DIR/config"
MIHOMO="$SKILL_DIR/mihomo"
VALIDATOR="$SKILL_DIR/node_validator.py"
LOG="$CONFIG_DIR/refresh.log"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

log "🔄 Starting node refresh..."

# Kill current mihomo so ports are free for temp testing
killall mihomo 2>/dev/null
sleep 1

# Run validator (outputs JSON to stdout, logs to stderr)
RESULT=$(python3 "$VALIDATOR" 2>>"$LOG")
EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ] || [ -z "$RESULT" ] || [ "$RESULT" = "[]" ]; then
    log "❌ Validation failed or no working nodes found"
    # Try to restore old config if it exists
    if [ -f "$CONFIG_DIR/config.yaml" ]; then
        log "♻️  Restoring previous config"
        nohup "$MIHOMO" -d "$CONFIG_DIR" -f "$CONFIG_DIR/config.yaml" > "$CONFIG_DIR/mihomo.log" 2>&1 &
        sleep 2
    fi
    exit 1
fi

# Count results
NODE_COUNT=$(echo "$RESULT" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null)
log "✅ Found $NODE_COUNT working nodes"

# Generate new config from results
python3 << PYEOF
import json
import os

config_dir = "$CONFIG_DIR"
result = json.loads('''$RESULT''')

proxy_port = 7890
socks_port = 7891

nodes = [r["node"] for r in result]
non_hk_tw = [r for r in result if not any(kw in r["node"]["name"].upper() for kw in ['香港','HONG','HK','TAIWAN','台湾','TAIPEI','臺北','TW','HKG','TPE'])]

config = f"""# mihomo config - auto-refreshed from {len(nodes)} validated nodes
mixed-port: {proxy_port}
socks-port: {socks_port}
allow-lan: false
mode: rule
log-level: warning
ipv6: false
external-controller: :9090

dns:
  enable: true
  listen: 0.0.0.0:1053
  nameserver:
    - 223.5.5.5
    - 119.29.29.29
  fallback:
    - 8.8.8.8
    - 1.1.1.1
  default-nameserver:
    - 223.5.5.5

proxies:
"""

for n in nodes:
    config += f"  - name: {n['name']}\n"
    config += f"    type: {n['type']}\n"
    config += f"    server: {n['server']}\n"
    config += f"    port: {n['port']}\n"
    if n.get("uuid"): config += f"    uuid: {n['uuid']}\n"
    if n.get("alterId") is not None: config += f"    alterId: {n['alterId']}\n"
    if n.get("cipher"): config += f"    cipher: {n['cipher']}\n"
    if n.get("password"): config += f"    password: {n['password']}\n"
    if n.get("tls"): config += f"    tls: true\n"
    if n.get("sni"): config += f"    sni: {n['sni']}\n"
    if n.get("network"):
        config += f"    network: {n['network']}\n"
        if n.get("ws-opts"):
            config += f"    ws-opts:\n"
            if n["ws-opts"].get("path"): config += f"      path: {n['ws-opts']['path']}\n"
            if n["ws-opts"].get("headers"):
                config += f"      headers:\n"
                for k,v in n["ws-opts"]["headers"].items():
                    config += f"        {k}: {v}\n"
    if n.get("plugin"):
        config += f"    plugin: {n['plugin']}\n"
        if n.get("plugin-opts"):
            config += f"    plugin-opts:\n"
            for k,v in n["plugin-opts"].items():
                config += f"      {k}: {v}\n"
    config += "\n"

all_names = [n["name"] for n in nodes]

config += """
proxy-groups:
  - name: ⚡ 自动选择
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 120
    tolerance: 50
    lazy: true
    proxies:
"""
for name in all_names:
    config += f"      - {name}\n"

config += """
  - name: 🚀 手动选择
    type: select
    proxies:
      - ⚡ 自动选择
      - DIRECT
"""
for name in all_names:
    config += f"      - {name}\n"

config += """
  - name: 🎯 全球直连
    type: select
    proxies:
      - DIRECT
      - ⚡ 自动选择

rules:
  - DOMAIN-SUFFIX,local,DIRECT
  - IP-CIDR,192.168.0.0/16,DIRECT
  - IP-CIDR,10.0.0.0/8,DIRECT
  - IP-CIDR,172.16.0.0/12,DIRECT
  - IP-CIDR,127.0.0.0/8,DIRECT
  - IP-CIDR,224.0.0.0/4,DIRECT
  - IP-CIDR,100.64.0.0/10,DIRECT
  - IP-CIDR,169.254.0.0/16,DIRECT
"""

# China IP ranges
for prefix in [1,14,27,36,39,42,49,58,59,60,61,101,106,110,111,112,113,114,115,116,117,118,119,120,121,122,123,124,125,171,175,180,182,183,202,203,210,211,218,219,220,221,222,223]:
    config += f"  - IP-CIDR,{prefix}.0.0.0/8,DIRECT,no-resolve\n"

config += """
  - DOMAIN-SUFFIX,baidu.com,DIRECT
  - DOMAIN-SUFFIX,qq.com,DIRECT
  - DOMAIN-SUFFIX,taobao.com,DIRECT
  - DOMAIN-SUFFIX,bilibili.com,DIRECT
  - DOMAIN-SUFFIX,alipay.com,DIRECT
  - DOMAIN-SUFFIX,jd.com,DIRECT
  - DOMAIN-SUFFIX,163.com,DIRECT
  - DOMAIN-SUFFIX,weibo.com,DIRECT
  - DOMAIN-SUFFIX,zhihu.com,DIRECT
  - DOMAIN-SUFFIX,douyin.com,DIRECT
  - DOMAIN-SUFFIX,cn,DIRECT
  - MATCH,🚀 手动选择
"""

with open(os.path.join(config_dir, "config.yaml"), "w") as f:
    f.write(config)

print(f"✅ Config written with {len(nodes)} validated nodes")
PYEOF

# Restart mihomo
log "🚀 Starting mihomo with refreshed config..."
nohup "$MIHOMO" -d "$CONFIG_DIR" -f "$CONFIG_DIR/config.yaml" > "$CONFIG_DIR/mihomo.log" 2>&1 &
sleep 3

if pgrep -x mihomo > /dev/null 2>&1; then
    log "✅ mihomo restarted with $NODE_COUNT nodes"
    exit 0
else
    log "❌ mihomo failed to start"
    exit 1
fi
