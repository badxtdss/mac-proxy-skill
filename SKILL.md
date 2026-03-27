# Mac Proxy Skill

macOS 系统代理管理。**mihomo**（Clash.Meta，⭐26k）+ **3 个免费节点源**（700+节点，自动更新）+ **后台自动测速切换**。

## 触发条件

用户提到：**翻墙、科学上网、代理、proxy、梯子、开启/关闭/切换代理、更新节点、测速** 时使用。

## 核心命令

```bash
SKILL=~/.openclaw/skills/mac-proxy/proxy-manager.sh
```

| 命令 | 作用 |
|------|------|
| `$SKILL restart` | 拉取 3 个源节点 → 生成配置 → 启动 mihomo |
| `$SKILL proxy-on` | 开启 macOS 系统代理（HTTP/HTTPS/SOCKS） |
| `$SKILL proxy-off` | 关闭系统代理（保留 mihomo 运行） |
| `$SKILL stop` | 关闭系统代理 + 停止 mihomo + 停止自动测速 |
| `$SKILL start` | 仅启动 mihomo |
| `$SKILL update` | 重新拉取全部节点 → 重启 mihomo |
| `$SKILL status` | 查看运行状态 |
| `$SKILL auto-test` | 测速非港台节点，自动切换到最快的 |
| `$SKILL auto-start` | 启动后台自动测速守护进程（默认 5 分钟一轮） |
| `$SKILL auto-stop` | 停止后台自动测速 |

## 自然语言 → 命令

| 用户说 | 执行 |
|--------|------|
| "开启代理" / "翻墙" | `restart && proxy-on` |
| "关闭代理" | `stop` |
| "代理状态" | `status` |
| "更新节点" | `update` |
| "测速找最快节点" | `auto-test` |
| "启动后台自动切换" | `auto-start` |
| "停止自动切换" | `auto-stop` |

## 节点源

| # | 来源 | 节点数 | 格式 | 更新频率 |
|---|------|--------|------|----------|
| 1 | [Pawdroid/Free-servers](https://github.com/Pawdroid/Free-servers) ⭐16.7k | ~4 | base64 订阅 | 6h |
| 2 | [xiaoji235/airport-free](https://github.com/xiaoji235/airport-free) ⭐472 | ~600 | raw vmess/ss/trojan | 3h |
| 3 | xiaoji235 v2rayshare | ~25 | raw vmess/ss/trojan | 3h |

## 自动测速切换

- 测试范围：**非港台节点**（自动过滤香港、台湾节点）
- 测试方法：通过 mihomo API 逐个测延迟（`gstatic.com/generate_204`）
- 自动切换：将 `⚡ 自动选择(非港台)` 组切到最快节点
- 后台守护：`auto-start` 启动后每 5 分钟自动测试一轮
- 日志：`config/auto_switch.log`

## 首次使用

```bash
# 一键搞定
$SKILL restart && $SKILL proxy-on

# 验证
curl -s -x http://127.0.0.1:7890 https://httpbin.org/ip
```

## 技术细节

- **代理端口**：HTTP `127.0.0.1:7890`，SOCKS `127.0.0.1:7891`
- **mihomo API**：`http://127.0.0.1:9090`（用于自动测速切换）
- **系统代理**：`networksetup` 自动检测网络接口
- **代理组**：⚡非港台自动选择 → 🌏全部自动选择 → 🚀手动选择 → 直连/拦截
- **支持协议**：vmess、trojan、ss、vless、hysteria2
- **配置目录**：`~/.openclaw/skills/mac-proxy/config/`

## 注意事项

- 免费节点质量波动大，自动测速会跳过不工作的节点
- 非港台节点优先（适合需要日本/美国/欧洲 IP 的场景）
- 节点过多时 auto-test 最多测 50 个，耗时约 1-2 分钟
- 关代理用 `stop`（会一并清理系统代理和后台守护进程）
