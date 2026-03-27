#!/usr/bin/env python3
"""
Mac Proxy Node Validator
- Fetches 1000+ nodes from multiple sources
- Tests all nodes concurrently via mihomo API
- Outputs top N fastest working nodes as config snippet
"""

import base64
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

# CRITICAL: Clear proxy env vars so we can reach node sources directly
for var in ['http_proxy', 'https_proxy', 'all_proxy', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY']:
    os.environ.pop(var, None)

CONFIG_DIR = os.path.expanduser("~/.openclaw/skills/mac-proxy/config")
MIHOMO_BIN = os.path.expanduser("~/.openclaw/skills/mac-proxy/mihomo")
MIHOMO_API = "http://127.0.0.1:9090"
TEST_URL = "http://www.gstatic.com/generate_204"
TEST_TIMEOUT = 5000  # ms
MAX_TEST_NODES = 300  # Test at most this many (API rate limit)
TOP_N = 50  # Output top N nodes

# ---- Node Sources ----
SOURCES = [
    # Pawdroid (base64 subscription)
    {"url": "https://proxy.v2gh.com/https://raw.githubusercontent.com/Pawdroid/Free-servers/main/sub", "type": "base64"},
    # xiaoji235 v2ray
    {"url": "https://cdn.jsdelivr.net/gh/xiaoji235/airport-free/v2ray.txt", "type": "raw"},
    # xiaoji235 v2rayshare
    {"url": "https://cdn.jsdelivr.net/gh/xiaoji235/airport-free/v2ray/v2rayshare.txt", "type": "raw"},
    # More sources from xiaoji235 clash files
    {"url": "https://cdn.jsdelivr.net/gh/xiaoji235/airport-free/v2ray/clashnodecc.txt", "type": "raw"},
    {"url": "https://cdn.jsdelivr.net/gh/xiaoji235/airport-free/v2ray/naidounode.txt", "type": "raw"},
    # xiaoji235 clash config (extract proxies section)
    {"url": "https://cdn.jsdelivr.net/gh/xiaoji235/airport-free/clash/naidounode.txt", "type": "clash_yaml"},
    {"url": "https://cdn.jsdelivr.net/gh/xiaoji235/airport-free/clash/clashnodecc.txt", "type": "clash_yaml"},
    {"url": "https://cdn.jsdelivr.net/gh/xiaoji235/airport-free/clash/v2rayshare.txt", "type": "clash_yaml"},
    # Additional aggregation sources
    {"url": "https://raw.githubusercontent.com/mahdibland/V2RayAggregator/master/sub/sub_merge.txt", "type": "raw"},
    {"url": "https://raw.githubusercontent.com/ermaozi/get_subscribe/main/subscribe/v2ray.txt", "type": "base64"},
    {"url": "https://raw.githubusercontent.com/anaer/Sub/main/clash.yaml", "type": "clash_yaml"},
    {"url": "https://raw.githubusercontent.com/aiboboxx/v2rayfree/main/v2", "type": "raw"},
    {"url": "https://raw.githubusercontent.com/Pawdroid/Free-servers/main/sub", "type": "base64"},
]

TW_KW = ['香港', 'Hong', 'HK', 'Taiwan', '台湾', 'Taipei', '臺北', 'TW', 'HKG', 'TPE']

def is_hk_tw(name):
    name_upper = name.upper()
    for kw in TW_KW:
        if kw.upper() in name_upper:
            return True
    return False

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
            node["ws-opts"] = {"path": data.get("path", "/"), "headers": {"Host": data.get("host", data.get("add", ""))}}
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
            "name": name, "type": "trojan", "server": parsed.hostname, "port": parsed.port,
            "password": parsed.username or "", "sni": params.get("sni", [parsed.hostname])[0],
        }
    except:
        return None

def decode_ss(link):
    try:
        parsed = urllib.parse.urlparse(link)
        name = urllib.parse.unquote(parsed.fragment) if parsed.fragment else parsed.hostname
        if not parsed.hostname or not parsed.username:
            return None
        try:
            userinfo = base64.b64decode(parsed.username + "==").decode()
        except:
            userinfo = parsed.username
        if ":" in userinfo:
            method, password = userinfo.split(":", 1)
        else:
            method, password = "aes-256-gcm", userinfo
        
        params = urllib.parse.parse_qs(parsed.query)
        plugin = params.get("plugin", [""])[0]
        
        node = {"name": name, "type": "ss", "server": parsed.hostname, "port": parsed.port,
                "cipher": method, "password": password}
        if "v2ray-plugin" in plugin:
            node["plugin"] = "v2ray-plugin"
            node["plugin-opts"] = {"mode": "websocket"}
            plugin_parts = urllib.parse.unquote(plugin)
            for part in plugin_parts.split(";"):
                if part.startswith("host="):
                    node["plugin-opts"]["host"] = part.split("=", 1)[1]
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
        return {"name": name, "type": "hysteria2", "server": parsed.hostname, "port": parsed.port,
                "password": parsed.password or params.get("auth", [""])[0]}
    except:
        return None

def decode_vless(link):
    try:
        parsed = urllib.parse.urlparse(link)
        params = urllib.parse.parse_qs(parsed.query)
        name = urllib.parse.unquote(parsed.fragment) if parsed.fragment else parsed.hostname
        node = {"name": name, "type": "vless", "server": parsed.hostname, "port": parsed.port,
                "uuid": parsed.username, "tls": params.get("security", [""])[0] == "tls"}
        if params.get("type", [""])[0] == "ws":
            node["network"] = "ws"
            node["ws-opts"] = {"path": params.get("path", ["/"])[0]}
        return node
    except:
        return None

def parse_node_line(line):
    line = line.strip()
    if not line or line.startswith("#"):
        return None
    if line.startswith("vmess://"): return decode_vmess(line)
    if line.startswith("trojan://"): return decode_trojan(line)
    if line.startswith("ss://"): return decode_ss(line)
    if line.startswith("hysteria2://") or line.startswith("hysteria://"): return decode_hysteria2(line)
    if line.startswith("vless://"): return decode_vless(line)
    return None

def parse_clash_yaml(text):
    """Extract proxy nodes from clash YAML format"""
    nodes = []
    in_proxies = False
    for line in text.split("\n"):
        if line.strip().startswith("proxies:"):
            in_proxies = True
            continue
        if in_proxies:
            if line.startswith("  - "):
                # Try to parse inline proxy dict
                try:
                    import ast
                    # Remove the leading "  - " and try to parse
                    proxy_str = line[4:].strip()
                    if proxy_str.startswith("{"):
                        proxy = ast.literal_eval(proxy_str)
                        if proxy.get("name") and proxy.get("server") and proxy.get("port"):
                            nodes.append(proxy)
                except:
                    pass
    return nodes

def fetch_source(src):
    """Fetch nodes from a single source"""
    nodes = []
    try:
        req = urllib.request.Request(src["url"], headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = resp.read().decode("utf-8", errors="replace")
        
        if src["type"] == "base64":
            try:
                decoded = base64.b64decode(data).decode("utf-8", errors="replace")
                for line in decoded.split("\n"):
                    node = parse_node_line(line)
                    if node:
                        nodes.append(node)
            except:
                pass
        elif src["type"] == "raw":
            for line in data.split("\n"):
                node = parse_node_line(line)
                if node:
                    nodes.append(node)
        elif src["type"] == "clash_yaml":
            nodes = parse_clash_yaml(data)
    except Exception as e:
        pass
    return nodes

def fetch_all_nodes():
    """Fetch nodes from all sources + current config"""
    all_nodes = []
    
    # Fetch from sources (parallel)
    print("📥 Fetching nodes from sources...", file=sys.stderr)
    with ThreadPoolExecutor(max_workers=8) as executor:
        futures = {executor.submit(fetch_source, src): src for src in SOURCES}
        for future in as_completed(futures):
            nodes = future.result()
            all_nodes.extend(nodes)
            src = futures[future]
            if nodes:
                print(f"  ✅ {src['url'].split('/')[-1]}: {len(nodes)} nodes", file=sys.stderr)
    
    # Load current config nodes
    config_file = os.path.join(CONFIG_DIR, "config.yaml")
    if os.path.exists(config_file):
        with open(config_file) as f:
            text = f.read()
        # Extract proxy names from current config
        current_nodes = parse_clash_yaml(text)
        all_nodes.extend(current_nodes)
        print(f"  ✅ Current config: {len(current_nodes)} nodes", file=sys.stderr)
    
    # Deduplicate by server:port AND by name
    seen = set()
    seen_names = {}
    unique = []
    for n in all_nodes:
        key = f"{n.get('server','')}:{n.get('port','')}"
        if key in seen or not n.get("server") or not n.get("port"):
            continue
        seen.add(key)
        # Clean name - strip spaces, remove special chars
        n["name"] = re.sub(r'[^\w\u4e00-\u9fff\-+.]', '', n.get("name", "unknown"))[:40].strip()
        if not n["name"]:
            n["name"] = f"{n.get('type','?')}-{n['server']}"
        # Deduplicate names
        base_name = n["name"]
        if base_name in seen_names:
            seen_names[base_name] += 1
            n["name"] = f"{base_name}-{seen_names[base_name]}"
        else:
            seen_names[base_name] = 1
        unique.append(n)
    
    print(f"📊 Total: {len(unique)} unique nodes", file=sys.stderr)
    return unique

def generate_temp_config(nodes):
    """Generate a temporary mihomo config with all nodes for testing"""
    config = f"""mixed-port: 17890
socks-port: 17891
allow-lan: false
mode: global
log-level: error
external-controller: :19090

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
    
    config += "\nproxy-groups:\n  - name: ALL\n    type: select\n    proxies:\n"
    for n in nodes[:100]:
        config += f"      - {n['name']}\n"
    config += "\nrules:\n  - MATCH,ALL\n"
    
    return config

def test_node_via_api(name, api_base="http://127.0.0.1:19090"):
    """Test a single node's latency via mihomo API"""
    try:
        encoded = urllib.parse.quote(name)
        url = f"{api_base}/proxies/{encoded}/delay?timeout={TEST_TIMEOUT}&url={TEST_URL}"
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=TEST_TIMEOUT//1000 + 5) as resp:
            data = json.loads(resp.read())
            delay = data.get("delay", -1)
            return name, delay if delay > 0 else -1
    except:
        return name, -1

def main():
    # 1. Fetch all nodes
    all_nodes = fetch_all_nodes()
    if not all_nodes:
        print("❌ No nodes found", file=sys.stderr)
        sys.exit(1)
    
    # Limit to MAX_TEST_NODES for testing speed
    # Prioritize non-HK/TW
    non_hk_tw = [n for n in all_nodes if not is_hk_tw(n["name"])]
    hk_tw = [n for n in all_nodes if is_hk_tw(n["name"])]
    test_nodes = (non_hk_tw + hk_tw)[:MAX_TEST_NODES]
    print(f"🧪 Testing {len(test_nodes)} nodes ({len(non_hk_tw)} non-HK/TW)...", file=sys.stderr)
    
    # 2. Generate temp config and start temp mihomo
    temp_config = generate_temp_config(test_nodes)
    temp_dir = os.path.join(CONFIG_DIR, "temp_validator")
    os.makedirs(temp_dir, exist_ok=True)
    
    temp_config_file = os.path.join(temp_dir, "config.yaml")
    with open(temp_config_file, "w") as f:
        f.write(temp_config)
    
    # Copy Country.mmdb if exists
    mmdb_src = os.path.join(CONFIG_DIR, "Country.mmdb")
    mmdb_dst = os.path.join(temp_dir, "Country.mmdb")
    if os.path.exists(mmdb_src) and not os.path.exists(mmdb_dst):
        import shutil
        shutil.copy2(mmdb_src, mmdb_dst)
    
    # Start temp mihomo
    print("🚀 Starting temp mihomo for testing...", file=sys.stderr)
    proc = subprocess.Popen(
        [MIHOMO_BIN, "-d", temp_dir, "-f", temp_config_file],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    time.sleep(3)
    
    if proc.poll() is not None:
        print("❌ Temp mihomo failed to start", file=sys.stderr)
        sys.exit(1)
    
    # 3. Test all nodes concurrently via API
    print(f"⚡ Testing {len(test_nodes)} nodes via API (max 20 concurrent)...", file=sys.stderr)
    results = []
    start_time = time.time()
    
    with ThreadPoolExecutor(max_workers=20) as executor:
        futures = {executor.submit(test_node_via_api, n["name"]): n for n in test_nodes}
        done = 0
        for future in as_completed(futures):
            name, delay = future.result()
            node = futures[future]
            done += 1
            if delay > 0:
                results.append((node, delay))
                # Progress
                if done % 20 == 0 or done == len(test_nodes):
                    print(f"  [{done}/{len(test_nodes)}] {len(results)} working so far", file=sys.stderr)
    
    elapsed = time.time() - start_time
    
    # 4. Kill temp mihomo
    proc.terminate()
    proc.wait(timeout=5)
    
    # 5. Sort by delay, output top N
    results.sort(key=lambda x: x[1])
    top = results[:TOP_N]
    
    print(f"\n📊 Results: {len(results)}/{len(test_nodes)} working ({elapsed:.1f}s)", file=sys.stderr)
    print(f"🏆 Top {len(top)} nodes:", file=sys.stderr)
    for i, (node, delay) in enumerate(top):
        hk = " 🇭🇰🇹🇼" if is_hk_tw(node["name"]) else ""
        print(f"  {i+1:3}. {node['name']}: {delay}ms{hk}", file=sys.stderr)
    
    # Output as JSON for the caller
    output = [{"node": n, "delay": d} for n, d in top]
    print(json.dumps(output, ensure_ascii=False))
    
    # Cleanup
    import shutil
    shutil.rmtree(temp_dir, ignore_errors=True)

if __name__ == "__main__":
    main()
