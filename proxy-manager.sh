#!/bin/bash
# Mac Proxy Manager - mihomo + free nodes (multi-source)
# Usage: proxy-manager.sh [start|stop|restart|status|update|proxy-on|proxy-off|proxy-status|auto-test]

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
MIHOMO="$SKILL_DIR/mihomo"
CONFIG_DIR="$SKILL_DIR/config"
CONFIG="$CONFIG_DIR/config.yaml"
LOG_FILE="$CONFIG_DIR/mihomo.log"
PID_FILE="$CONFIG_DIR/mihomo.pid"
PROXY_PORT=7890
SOCKS_PORT=7891
MIHOMO_API="http://127.0.0.1:9090"

mkdir -p "$CONFIG_DIR"

# ---- Multi-source subscription ----
# Source 1: Pawdroid/Free-servers (base64 subscription, 6h update)
SUB1_URL="https://proxy.v2gh.com/https://raw.githubusercontent.com/Pawdroid/Free-servers/main/sub"
# Source 2: xiaoji235 v2ray.txt (raw nodes, 3h update, ~600 nodes)
SUB2_URL="https://cdn.jsdelivr.net/gh/xiaoji235/airport-free/v2ray.txt"
# Source 3: xiaoji235 v2rayshare (raw nodes)
SUB3_URL="https://cdn.jsdelivr.net/gh/xiaoji235/airport-free/v2ray/v2rayshare.txt"

fetch_sources() {
    local all_nodes="$CONFIG_DIR/all_nodes.txt"
    > "$all_nodes"
    
    # Source 1: base64 subscription
    echo "📥 [1/3] Pawdroid/Free-servers..."
    local tmp="$CONFIG_DIR/tmp_sub.txt"
    if curl -sL --connect-timeout 15 --max-time 60 "$SUB1_URL" -o "$tmp" 2>/dev/null; then
        if [[ "$(uname)" == "Darwin" ]]; then
            base64 -D < "$tmp" >> "$all_nodes" 2>/dev/null
        else
            base64 -d < "$tmp" >> "$all_nodes" 2>/dev/null
        fi
    fi
    
    # Source 2: raw nodes
    echo "📥 [2/3] xiaoji235/v2ray.txt..."
    curl -sL --connect-timeout 15 --max-time 60 "$SUB2_URL" 2>/dev/null \
        | grep -E '^(vmess|trojan|ss|ssr|vless|hysteria2?)://' >> "$all_nodes" 2>/dev/null || true
    
    # Source 3: raw nodes
    echo "📥 [3/3] xiaoji235/v2rayshare..."
    curl -sL --connect-timeout 15 --max-time 60 "$SUB3_URL" 2>/dev/null \
        | grep -E '^(vmess|trojan|ss|ssr|vless|hysteria2?)://' >> "$all_nodes" 2>/dev/null || true
    
    local count
    count=$(wc -l < "$all_nodes" | tr -d ' ')
    echo "✅ Collected $count raw nodes from all sources"
    
    [ "$count" -gt 0 ]
}

generate_config() {
    # Download GeoIP MMDB if not present
    if [ ! -f "$CONFIG_DIR/Country.mmdb" ]; then
        echo "📥 Downloading GeoIP database..."
        curl -sL --connect-timeout 15 --max-time 120 \
            "https://ghfast.top/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/Country.mmdb" \
            -o "$CONFIG_DIR/Country.mmdb" 2>/dev/null || true
    fi
    
    fetch_sources || { echo "❌ No nodes fetched"; return 1; }
    
    CONFIG_DIR="$CONFIG_DIR" PROXY_PORT="$PROXY_PORT" SOCKS_PORT="$SOCKS_PORT" \
    python3 << 'PYEOF'
import base64
import json
import re
import sys
import os
import urllib.parse

config_dir = os.environ.get("CONFIG_DIR", os.path.expanduser("~/.openclaw/skills/mac-proxy/config"))
nodes_file = os.path.join(config_dir, "all_nodes.txt")
config_file = os.path.join(config_dir, "config.yaml")
proxy_port = int(os.environ.get("PROXY_PORT", "7890"))
socks_port = int(os.environ.get("SOCKS_PORT", "7891"))

# Region detection for filtering
TW_KW = ['香港', 'Hong Kong', 'HK', 'Taiwan', '台湾', 'Taipei', '臺北']

def decode_vmess(link):
    try:
        encoded = link.replace("vmess://", "").strip()
        padding = 4 - len(encoded) % 4
        if padding != 4:
            encoded += "=" * padding
        data = json.loads(base64.b64decode(encoded).decode())
        node = {
            "name": data.get("ps", data.get("add", "unknown")),
            "type": "vmess",
            "server": data.get("add", ""),
            "port": int(data.get("port", 443)),
            "uuid": data.get("id", ""),
            "alterId": int(data.get("aid", 0)),
            "cipher": data.get("scy", "auto"),
            "tls": data.get("tls") == "tls",
        }
        if data.get("net") == "ws":
            node["network"] = "ws"
            node["ws-opts"] = {
                "path": data.get("path", "/"),
                "headers": {"Host": data.get("host", data.get("add", ""))}
            }
        if data.get("host"):
            node["servername"] = data.get("host")
        return node
    except:
        return None

def decode_trojan(link):
    try:
        parsed = urllib.parse.urlparse(link)
        params = urllib.parse.parse_qs(parsed.query)
        name = urllib.parse.unquote(parsed.fragment) if parsed.fragment else parsed.hostname
        return {
            "name": name,
            "type": "trojan",
            "server": parsed.hostname,
            "port": parsed.port,
            "password": parsed.username or "",
            "sni": params.get("sni", [parsed.hostname])[0],
        }
    except:
        return None

def decode_ss(link):
    try:
        parsed = urllib.parse.urlparse(link)
        name = urllib.parse.unquote(parsed.fragment) if parsed.fragment else parsed.hostname
        if parsed.hostname and parsed.username:
            import base64 as b64
            try:
                userinfo = b64.b64decode(parsed.username + "==").decode()
            except:
                userinfo = parsed.username
            if "@" in userinfo:
                parts = userinfo.split("@", 1)
                method, password = parts[0], parts[1] if len(parts) > 1 else ""
                if ":" in method:
                    method, password = method.split(":", 1)
            else:
                if ":" in userinfo:
                    method, password = userinfo.split(":", 1)
                else:
                    method, password = userinfo, ""
            return {
                "name": name,
                "type": "ss",
                "server": parsed.hostname,
                "port": parsed.port,
                "cipher": method,
                "password": password,
            }
        return None
    except:
        return None

def decode_ss_plugin(link):
    """Handle ss:// with v2ray-plugin (complex format)"""
    try:
        parsed = urllib.parse.urlparse(link)
        name = urllib.parse.unquote(parsed.fragment) if parsed.fragment else parsed.hostname
        if not parsed.hostname or not parsed.username:
            return None
        import base64 as b64
        try:
            userinfo = b64.b64decode(parsed.username + "==").decode()
        except:
            userinfo = parsed.username
        method = "none"
        password = userinfo.split(":")[1] if ":" in userinfo else userinfo
        
        params = urllib.parse.parse_qs(parsed.query)
        plugin = params.get("plugin", [""])[0]
        
        node = {
            "name": name,
            "type": "ss",
            "server": parsed.hostname,
            "port": parsed.port,
            "cipher": method,
            "password": password,
        }
        # Parse v2ray-plugin params
        if "v2ray-plugin" in plugin or "obfs-local" in plugin:
            # Extract mode, host, path, tls from plugin string
            plugin_parts = urllib.parse.unquote(plugin)
            if "websocket" in plugin_parts or "mode=websocket" in plugin_parts:
                node["plugin"] = "v2ray-plugin"
                node["plugin-opts"] = {"mode": "websocket"}
                for part in plugin_parts.split(";"):
                    if "host=" in part:
                        node["plugin-opts"]["host"] = part.split("=", 1)[1]
                    if "path=" in part and "host=" not in part:
                        node["plugin-opts"]["path"] = part.split("=", 1)[1]
                    if part == "tls":
                        node["plugin-opts"]["tls"] = True
        return node
    except:
        return None

def decode_hysteria2(link):
    try:
        parsed = urllib.parse.urlparse(link)
        name = urllib.parse.unquote(parsed.fragment) if parsed.fragment else parsed.hostname
        params = urllib.parse.parse_qs(parsed.query)
        return {
            "name": name,
            "type": "hysteria2",
            "server": parsed.hostname,
            "port": parsed.port,
            "password": parsed.password or params.get("auth", [""])[0],
        }
    except:
        return None

def decode_vless(link):
    try:
        parsed = urllib.parse.urlparse(link)
        params = urllib.parse.parse_qs(parsed.query)
        name = urllib.parse.unquote(parsed.fragment) if parsed.fragment else parsed.hostname
        node = {
            "name": name,
            "type": "vless",
            "server": parsed.hostname,
            "port": parsed.port,
            "uuid": parsed.username,
            "tls": params.get("security", [""])[0] == "tls",
        }
        if params.get("type", [""])[0] == "ws":
            node["network"] = "ws"
            node["ws-opts"] = {"path": params.get("path", ["/"])[0]}
        return node
    except:
        return None

def is_hk_tw(name):
    """Check if node is from HK or TW"""
    name_upper = name.upper()
    for kw in TW_KW:
        if kw.upper() in name_upper:
            return True
    return False

# Parse all nodes
nodes = []
with open(nodes_file, "r", encoding="utf-8", errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        
        node = None
        if line.startswith("vmess://"):
            node = decode_vmess(line)
        elif line.startswith("trojan://"):
            node = decode_trojan(line)
        elif line.startswith("ss://"):
            node = decode_ss_plugin(line)
            if not node:
                node = decode_ss(line)
        elif line.startswith("ssr://"):
            continue  # skip SSR, rarely works
        elif line.startswith("hysteria2://") or line.startswith("hysteria://"):
            node = decode_hysteria2(line)
        elif line.startswith("vless://"):
            node = decode_vless(line)
        
        if node and node.get("server") and node.get("port"):
            node["name"] = re.sub(r'[^\w\u4e00-\u9fff\-+.]', '', node.get("name", "unknown"))[:50].strip()
            if not node["name"]:
                node["name"] = f"{node['type']}-{node['server']}"
            nodes.append(node)

if not nodes:
    print("❌ No valid nodes parsed")
    sys.exit(1)

# Deduplicate by server:port, unique names
seen = {}
unique_nodes = []
name_count = {}
for n in nodes:
    key = f"{n['server']}:{n['port']}"
    if key not in seen:
        seen[key] = True
        base_name = n["name"]
        if base_name in name_count:
            name_count[base_name] += 1
            n["name"] = f"{base_name}-{name_count[base_name]}"
        else:
            name_count[base_name] = 1
        unique_nodes.append(n)

# Split HK/TW vs others
hk_tw_nodes = [n for n in unique_nodes if is_hk_tw(n["name"])]
non_hk_tw_nodes = [n for n in unique_nodes if not is_hk_tw(n["name"])]

print(f"✅ Parsed {len(unique_nodes)} unique proxies")
print(f"   🌏 Non-HK/TW: {len(non_hk_tw_nodes)} | 🇭🇰🇹🇼 HK/TW: {len(hk_tw_nodes)}")

# Generate YAML config
config = f"""# mihomo config - auto-generated by mac-proxy skill
# {len(unique_nodes)} proxies loaded ({len(non_hk_tw_nodes)} non-HK/TW, {len(hk_tw_nodes)} HK/TW)

mixed-port: {proxy_port}
socks-port: {socks_port}
allow-lan: false
mode: rule
log-level: warning
ipv6: false
external-controller: :9090

# DNS
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

for n in unique_nodes:
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

# Proxy groups
def yaml_list(items, indent=6):
    return "\n".join(f"{' '*indent}- {item}" for item in items)

# Non-HK/TW auto-select (primary, for auto-switch)
non_hk_names = [n["name"] for n in non_hk_tw_nodes] if non_hk_tw_nodes else [n["name"] for n in unique_nodes]
all_names = [n["name"] for n in unique_nodes]

config += f"""
proxy-groups:
  - name: ⚡ 自动选择(非港台)
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 120
    tolerance: 50
    lazy: true
    proxies:
{yaml_list(non_hk_names)}

  - name: 🌏 全部自动选择
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
    lazy: true
    proxies:
{yaml_list(all_names)}

  - name: 🚀 手动选择
    type: select
    proxies:
      - ⚡ 自动选择(非港台)
      - 🌏 全部自动选择
      - DIRECT
{yaml_list(all_names[:50])}

  - name: 🎯 全球直连
    type: select
    proxies:
      - DIRECT
      - ⚡ 自动选择(非港台)

  - name: 🛑 全球拦截
    type: select
    proxies:
      - REJECT
      - DIRECT

rules:
  # Private/LAN
  - DOMAIN-SUFFIX,local,DIRECT
  - IP-CIDR,192.168.0.0/16,DIRECT
  - IP-CIDR,10.0.0.0/8,DIRECT
  - IP-CIDR,172.16.0.0/12,DIRECT
  - IP-CIDR,127.0.0.0/8,DIRECT
  - IP-CIDR,224.0.0.0/4,DIRECT
  - IP-CIDR,100.64.0.0/10,DIRECT
  - IP-CIDR,169.254.0.0/16,DIRECT
  - IP-CIDR,fe80::/10,DIRECT
  # China IPs → DIRECT (major ranges)
  - IP-CIDR,1.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,14.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,27.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,36.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,39.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,42.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,49.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,58.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,59.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,60.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,61.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,101.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,106.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,110.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,111.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,112.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,113.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,114.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,115.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,116.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,117.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,118.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,119.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,120.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,121.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,122.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,123.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,124.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,125.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,171.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,175.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,180.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,182.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,183.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,202.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,203.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,210.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,211.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,218.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,219.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,220.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,221.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,222.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,223.0.0.0/8,DIRECT,no-resolve
  # Common domestic domains → DIRECT
  - DOMAIN-SUFFIX,baidu.com,DIRECT
  - DOMAIN-SUFFIX,bdstatic.com,DIRECT
  - DOMAIN-SUFFIX,bilibili.com,DIRECT
  - DOMAIN-SUFFIX,biliapi.net,DIRECT
  - DOMAIN-SUFFIX,qq.com,DIRECT
  - DOMAIN-SUFFIX,weixin.qq.com,DIRECT
  - DOMAIN-SUFFIX,taobao.com,DIRECT
  - DOMAIN-SUFFIX,tmall.com,DIRECT
  - DOMAIN-SUFFIX,alipay.com,DIRECT
  - DOMAIN-SUFFIX,alibaba.com,DIRECT
  - DOMAIN-SUFFIX,jd.com,DIRECT
  - DOMAIN-SUFFIX,163.com,DIRECT
  - DOMAIN-SUFFIX,126.com,DIRECT
  - DOMAIN-SUFFIX,netease.com,DIRECT
  - DOMAIN-SUFFIX,weibo.com,DIRECT
  - DOMAIN-SUFFIX,zhihu.com,DIRECT
  - DOMAIN-SUFFIX,douyin.com,DIRECT
  - DOMAIN-SUFFIX,toutiao.com,DIRECT
  - DOMAIN-SUFFIX,bytedance.com,DIRECT
  - DOMAIN-SUFFIX,xiaomi.com,DIRECT
  - DOMAIN-SUFFIX,huawei.com,DIRECT
  - DOMAIN-SUFFIX,cn,DIRECT
  # DNS pollution protection
  - DOMAIN-KEYWORD,google,🚀 手动选择
  - DOMAIN-KEYWORD,youtube,🚀 手动选择
  - DOMAIN-KEYWORD,twitter,🚀 手动选择
  - DOMAIN-KEYWORD,facebook,🚀 手动选择
  - DOMAIN-KEYWORD,github,🚀 手动选择
  - DOMAIN-KEYWORD,telegram,🚀 手动选择
  # Everything else → proxy
  - MATCH,🚀 手动选择
"""

# Save non-HK/TW names for auto-switch script
with open(os.path.join(config_dir, "non_hk_tw_proxies.txt"), "w") as f:
    for n in non_hk_tw_nodes:
        f.write(f"{n['name']}|{n['server']}|{n['port']}\n")

with open(config_file, "w") as f:
    f.write(config)

print(f"✅ Config written to {config_file}")
PYEOF
}

# ---- Proxy control (macOS networksetup) ----

# Detect and set proxy on ALL active network interfaces
get_active_interfaces() {
    networksetup -listallnetworkservices | grep -v "^An asterisk" | while read -r s; do
        if networksetup -getinfo "$s" 2>/dev/null | grep -q "IP address"; then
            echo "$s"
        fi
    done
}

proxy_on() {
    echo "🔌 Enabling system proxy on all active interfaces..."
    local count=0
    while IFS= read -r service; do
        [ -z "$service" ] && continue
        networksetup -setwebproxy "$service" 127.0.0.1 "$PROXY_PORT" 2>/dev/null
        networksetup -setsecurewebproxy "$service" 127.0.0.1 "$PROXY_PORT" 2>/dev/null
        networksetup -setsocksfirewallproxy "$service" 127.0.0.1 "$SOCKS_PORT" 2>/dev/null
        networksetup -setwebproxystate "$service" on 2>/dev/null
        networksetup -setsecurewebproxystate "$service" on 2>/dev/null
        networksetup -setsocksfirewallproxystate "$service" on 2>/dev/null
        echo "  ✅ $service"
        count=$((count + 1))
    done < <(get_active_interfaces)
    echo "✅ System proxy enabled on $count interface(s)"
    
    # Set environment variables for CLI tools & Node.js
    set_proxy_env
}

proxy_off() {
    echo "🔌 Disabling system proxy on all interfaces..."
    local count=0
    while IFS= read -r service; do
        [ -z "$service" ] && continue
        networksetup -setwebproxystate "$service" off 2>/dev/null
        networksetup -setsecurewebproxystate "$service" off 2>/dev/null
        networksetup -setsocksfirewallproxystate "$service" off 2>/dev/null
        echo "  ✅ $service"
        count=$((count + 1))
    done < <(get_active_interfaces)
    echo "✅ System proxy disabled on $count interface(s)"
    
    # Clean up environment variables
    unset_proxy_env
}

proxy_status() {
    echo "📡 System proxy status:"
    while IFS= read -r service; do
        [ -z "$service" ] && continue
        local http https socks
        http=$(networksetup -getwebproxy "$service" 2>/dev/null | grep -E "^Enabled:" | awk '{print $2}')
        https=$(networksetup -getsecurewebproxy "$service" 2>/dev/null | grep -E "^Enabled:" | awk '{print $2}')
        socks=$(networksetup -getsocksfirewallproxy "$service" 2>/dev/null | grep -E "^Enabled:" | awk '{print $2}')
        echo "  $service: HTTP=$http HTTPS=$https SOCKS=$socks"
    done < <(get_active_interfaces)
    
    # Show env var status
    echo ""
    echo "📡 Proxy env vars:"
    echo "  http_proxy:  ${http_proxy:-(not set)}"
    echo "  https_proxy: ${https_proxy:-(not set)}"
    echo "  all_proxy:   ${all_proxy:-(not set)}"
}

# ---- Environment variable management ----

ZSHENV="$HOME/.zshenv"
ENV_MARKER="# mac-proxy-skill env vars"

set_proxy_env() {
    # Set in current process
    export http_proxy="http://127.0.0.1:$PROXY_PORT"
    export https_proxy="http://127.0.0.1:$PROXY_PORT"
    export all_proxy="socks5://127.0.0.1:$SOCKS_PORT"
    export HTTP_PROXY="$http_proxy"
    export HTTPS_PROXY="$https_proxy"
    export ALL_PROXY="$all_proxy"
    export NO_PROXY="localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.local"
    export NO_PROXY="$NO_PROXY"
    
    # Persist in ~/.zshenv for new terminal sessions
    # Remove old entries first
    if [ -f "$ZSHENV" ]; then
        grep -v "$ENV_MARKER" "$ZSHENV" > "$ZSHENV.tmp" 2>/dev/null
        mv "$ZSHENV.tmp" "$ZSHENV"
    fi
    
    cat >> "$ZSHENV" << EOF
$ENV_MARKER - BEGIN
export http_proxy="http://127.0.0.1:$PROXY_PORT"
export https_proxy="http://127.0.0.1:$PROXY_PORT"
export all_proxy="socks5://127.0.0.1:$SOCKS_PORT"
export HTTP_PROXY="http://127.0.0.1:$PROXY_PORT"
export HTTPS_PROXY="http://127.0.0.1:$PROXY_PORT"
export ALL_PROXY="socks5://127.0.0.1:$SOCKS_PORT"
export NO_PROXY="localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.local"
$ENV_MARKER - END
EOF
    
    echo "  📝 Proxy env vars set (current session + ~/.zshenv)"
    echo "  ℹ️  新开终端窗口自动生效，当前终端可手动: source ~/.zshenv"
}

unset_proxy_env() {
    # Unset in current process
    unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY 2>/dev/null
    
    # Remove from ~/.zshenv
    if [ -f "$ZSHENV" ]; then
        grep -v "$ENV_MARKER" "$ZSHENV" > "$ZSHENV.tmp" 2>/dev/null
        mv "$ZSHENV.tmp" "$ZSHENV"
    fi
    
    echo "  📝 Proxy env vars cleared"
}

# ---- mihomo API helpers ----

api_get() {
    curl -s --connect-timeout 5 "${MIHOMO_API}$1" 2>/dev/null
}

api_put() {
    curl -s --connect-timeout 5 -X PUT -d "$2" "${MIHOMO_API}$1" 2>/dev/null
}

# ---- Auto-test & switch (non-HK/TW fastest) ----

auto_test() {
    echo "🔍 Testing non-HK/TW proxies for speed..."
    
    # Get current selector group proxies
    local proxies
    proxies=$(api_get "/proxies/⚡%20%E8%87%AA%E5%8A%A8%E9%80%89%E6%8B%A9(%E9%9D%9E%E6%B8%AF%E5%8F%B0)")
    if [ -z "$proxies" ]; then
        echo "⚠️  mihomo API not available, trying URL-encoded group name..."
        proxies=$(api_get "/proxies/⚡ 自动选择(非港台)")
    fi
    
    if [ -z "$proxies" ]; then
        echo "❌ Cannot connect to mihomo API. Is mihomo running?"
        return 1
    fi
    
    # Use Python to test all proxies and find fastest non-HK/TW
    MIHOMO_API="$MIHOMO_API" python3 << 'PYEOF'
import json
import subprocess
import sys
import os
import urllib.parse
import time

api = os.environ.get("MIHOMO_API", "http://127.0.0.1:9090")
TW_KW = ['香港', 'Hong', 'HK', 'Taiwan', '台湾', 'Taipei', '臺北', 'TW']

def is_hk_tw(name):
    name_upper = name.upper()
    for kw in TW_KW:
        if kw.upper() in name_upper:
            return True
    return False

def api_get(path):
    try:
        result = subprocess.run(
            ["curl", "-s", "--connect-timeout", "5", f"{api}{path}"],
            capture_output=True, text=True, timeout=10
        )
        return json.loads(result.stdout) if result.stdout else None
    except:
        return None

def api_put(path, data):
    try:
        result = subprocess.run(
            ["curl", "-s", "--connect-timeout", "5", "-X", "PUT",
             "-H", "Content-Type: application/json",
             "-d", json.dumps(data), f"{api}{path}"],
            capture_output=True, text=True, timeout=10
        )
        return result.stdout
    except:
        return None

# Try to get proxies from url-test group
group_name = "⚡ 自动选择(非港台)"
group = api_get(f"/proxies/{urllib.parse.quote(group_name)}")
if not group:
    print(f"❌ Group '{group_name}' not found")
    sys.exit(1)

proxy_list = group.get("all", [])
if not proxy_list:
    print("❌ No proxies in group")
    sys.exit(1)

# Filter non-HK/TW
candidates = [p for p in proxy_list if not is_hk_tw(p)]
print(f"🔍 Testing {len(candidates)} non-HK/TW proxies...")

# Test latency via mihomo API (delay endpoint)
best_proxy = None
best_delay = float("inf")
tested = 0
failed = 0

for proxy_name in candidates[:50]:  # Test max 50
    try:
        encoded = urllib.parse.quote(proxy_name)
        result = subprocess.run(
            ["curl", "-s", "--connect-timeout", "8", "-X", "GET",
             f"{api}/proxies/{encoded}/delay?timeout=5000&url=http://www.gstatic.com/generate_204"],
            capture_output=True, text=True, timeout=10
        )
        if result.stdout:
            data = json.loads(result.stdout)
            delay = data.get("delay", -1)
            tested += 1
            if delay > 0 and delay < best_delay:
                best_delay = delay
                best_proxy = proxy_name
                print(f"  ⏱ {proxy_name}: {delay}ms ⭐ NEW BEST")
            elif delay > 0:
                print(f"  ⏱ {proxy_name}: {delay}ms")
            else:
                failed += 1
        else:
            failed += 1
    except:
        failed += 1
    time.sleep(0.1)  # Small delay between tests

print(f"\n📊 Tested: {tested} | Failed: {failed} | Best: {best_proxy} ({best_delay}ms)")

if best_proxy and best_delay < 99999:
    # Switch to best proxy by selecting it
    result = api_put(f"/proxies/{urllib.parse.quote(group_name)}", {"name": best_proxy})
    print(f"✅ Switched to: {best_proxy} ({best_delay}ms)")
else:
    print("❌ No working proxy found")
    sys.exit(1)
PYEOF
}

# ---- Background auto-switch daemon ----

auto_switch_daemon() {
    local interval="${1:-300}"  # default 5 minutes
    local daemon_pid_file="$CONFIG_DIR/auto_switch.pid"
    
    if [ -f "$daemon_pid_file" ] && kill -0 "$(cat "$daemon_pid_file")" 2>/dev/null; then
        echo "⚠️  Auto-switch daemon already running (PID $(cat "$daemon_pid_file"))"
        return 0
    fi
    
    echo "🔄 Starting auto-switch daemon (interval: ${interval}s)..."
    (
        while true; do
            sleep "$interval"
            # Check if mihomo is running
            if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
                echo "[$(date)] Auto-testing proxies..." >> "$CONFIG_DIR/auto_switch.log"
                auto_test >> "$CONFIG_DIR/auto_switch.log" 2>&1
            fi
        done
    ) &
    echo $! > "$daemon_pid_file"
    echo "✅ Auto-switch daemon started (PID $!, interval ${interval}s)"
}

stop_auto_daemon() {
    local daemon_pid_file="$CONFIG_DIR/auto_switch.pid"
    if [ -f "$daemon_pid_file" ]; then
        local pid
        pid=$(cat "$daemon_pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            echo "🛑 Auto-switch daemon stopped (PID $pid)"
        fi
        rm -f "$daemon_pid_file"
    fi
}

# ---- Process management ----

start_mihomo() {
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "⚠️  mihomo already running (PID $(cat "$PID_FILE"))"
        return 0
    fi
    
    if [ ! -f "$CONFIG" ]; then
        echo "⚠️  No config found, fetching nodes first..."
        generate_config || return 1
    fi
    
    echo "🚀 Starting mihomo..."
    nohup "$MIHOMO" -d "$CONFIG_DIR" -f "$CONFIG" > "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    sleep 2
    
    if kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "✅ mihomo started (PID $(cat "$PID_FILE"))"
        echo "   HTTP: 127.0.0.1:$PROXY_PORT | SOCKS: 127.0.0.1:$SOCKS_PORT | API: :9090"
    else
        echo "❌ Failed to start mihomo, check $LOG_FILE"
        return 1
    fi
}

stop_mihomo() {
    stop_auto_daemon
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "🛑 Stopping mihomo (PID $pid)..."
            kill "$pid" 2>/dev/null || true
            sleep 1
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$PID_FILE"
        echo "✅ mihomo stopped"
    else
        echo "ℹ️  mihomo is not running"
    fi
}

status_mihomo() {
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "✅ mihomo is running (PID $(cat "$PID_FILE"))"
        if [ -f "$CONFIG" ]; then
            local total non_hk
            total=$(grep -c "^  - name:" "$CONFIG" 2>/dev/null || echo 0)
            non_hk=$(wc -l < "$CONFIG_DIR/non_hk_tw_proxies.txt" 2>/dev/null | tr -d ' ')
            echo "   Total proxies: $total | Non-HK/TW: ${non_hk:-0}"
        fi
        # Check auto daemon
        if [ -f "$CONFIG_DIR/auto_switch.pid" ] && kill -0 "$(cat "$CONFIG_DIR/auto_switch.pid")" 2>/dev/null; then
            echo "   Auto-switch daemon: running (PID $(cat "$CONFIG_DIR/auto_switch.pid"))"
        else
            echo "   Auto-switch daemon: stopped"
        fi
    else
        echo "❌ mihomo is not running"
    fi
}

# ---- Main ----

case "${1:-help}" in
    start)       start_mihomo ;;
    stop)        proxy_off; stop_mihomo ;;
    restart)     stop_mihomo; generate_config; start_mihomo ;;
    status)      status_mihomo; echo ""; proxy_status ;;
    update)      generate_config
                 if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
                     echo "🔄 Restarting mihomo..."; stop_mihomo; start_mihomo
                 fi ;;
    proxy-on)    proxy_on ;;
    proxy-off)   proxy_off ;;
    proxy-status) proxy_status ;;
    generate)    generate_config ;;
    auto-test)   auto_test ;;
    auto-start)  auto_test; auto_switch_daemon "${2:-300}" ;;
    auto-stop)   stop_auto_daemon ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|update|proxy-on|proxy-off|proxy-status|generate|auto-test|auto-start|auto-stop}"
        echo ""
        echo "Commands:"
        echo "  start        Start mihomo"
        echo "  stop         Stop mihomo + disable system proxy"
        echo "  restart      Fetch nodes + generate config + start"
        echo "  status       Show mihomo + proxy status"
        echo "  update       Re-fetch nodes + restart"
        echo "  proxy-on     Enable macOS system proxy"
        echo "  proxy-off    Disable macOS system proxy"
        echo "  generate     Fetch nodes + generate config (no start)"
        echo "  auto-test    Test non-HK/TW proxies, switch to fastest"
        echo "  auto-start   Start auto-switch daemon (default 5min interval)"
        echo "  auto-stop    Stop auto-switch daemon"
        ;;
esac
