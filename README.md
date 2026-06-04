# realmctl

`realm` 端口转发的轻量管理工具 + 自动保活。一行命令加规则、删规则、看状态，进程崩了自动拉起。

为 **128 MB 小容器**（Debian/Alpine，LXC/KVM 均可）设计——无外部依赖（纯 bash），不假设 systemd 一定可用，watchdog 自身占用 ~2 MB 内存。

## 解决什么问题

如果你在用 [EZRealm](https://github.com/BrunuhVille/EZRealm) 之类的 realm 一键脚本，常见痛点：

| 痛点 | realmctl 的方案 |
|---|---|
| realm 崩了不自动重启（`Restart=on-failure` 在反复失败后会放弃） | 独立 watchdog 进程，每 5 秒探活，**永远拉起** |
| 只有交互菜单，没法脚本化批量操作 | 提供完整 CLI：`realmctl add 8080 1.2.3.4 80` 一行搞定 |
| realm 死了无感知 | watchdog 日志记录每次崩溃和拉起时间；`realmctl status` 一眼看清 |
| 假设 systemd 一定可用（在 Alpine LXC 上会崩） | 自动探测 **systemd / openrc / 纯进程** 三种环境 |

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/x-socks/realmctl/main/realmctl.sh \
  -o /usr/local/bin/realmctl && chmod +x /usr/local/bin/realmctl \
  && realmctl install && realmctl enable
```

大陆访问 GitHub 慢可以套 [ghfast.top](https://ghfast.top/) 镜像：

```bash
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/x-socks/realmctl/main/realmctl.sh \
  -o /usr/local/bin/realmctl && chmod +x /usr/local/bin/realmctl \
  && realmctl install && realmctl enable
```

跑完上面三件事已经做掉：
1. realm 二进制下载（自动按 `glibc/musl` + `x86_64/aarch64/armv7` 匹配）
2. 初始化 `/root/realm/config.toml`
3. 注册 watchdog 自动保活（systemd / openrc 自动选）

接下来加转发规则：

```bash
realmctl add 8080 1.2.3.4 80 香港中转
realmctl list
realmctl status
```

## 用法速查

```
realmctl                                  进入交互菜单（与原 EZRealm 风格类似）
realmctl install                          下载并安装 realm
realmctl add <本地端口> <远端IP> <端口> [备注]   添加规则（自动重启 realm）
realmctl del <序号|本地端口>              删除规则（按序号或按端口都行）
realmctl list                             列出规则
realmctl start | stop | restart | status  进程管理
realmctl enable                           启用自动保活
realmctl disable                          停用自动保活
realmctl uninstall                        卸载（清理所有文件 + 服务）
realmctl help                             查看完整帮助
```

IPv6 远端会自动加方括号：

```bash
realmctl add 9000 2001:db8::1 443 IPv6测试
# 自动写成 remote = "[2001:db8::1]:443"
```

## 环境兼容矩阵

| 系统 | 虚拟化 | init | libc | 实测 |
|---|---|---|---|---|
| Debian 13 (trixie) | LXC | systemd | glibc | ✅ |
| Debian 13 (trixie) | KVM | systemd | glibc | ✅（与 LXC 等同） |
| Alpine 3.23 | LXC | openrc | musl | ✅ |
| Alpine | KVM | openrc | musl | ✅（与 LXC 等同） |
| 任意发行版无 init | Docker/纯进程 | nohup + cron 兜底 | 任意 | ⚠️ 代码完整，未实测 |

测试方法：在两台真实样机上跑完整流程，包括 kill -9 后验证 watchdog 自动拉起 realm。

## 保活原理

```
┌─────────────────────────────────────────────────────┐
│  systemd / openrc (Restart=always)                  │
│         │                                           │
│         ▼                                           │
│  ┌────────────────┐                                 │
│  │  watchdog      │  every 5s: pgrep realm?         │
│  │  (bash loop)   │                                 │
│  │  ~2 MB RSS     │  no → nohup $REALM_BIN          │
│  └────────────────┘                                 │
│         │                                           │
│         ▼                                           │
│  ┌────────────────┐                                 │
│  │  realm         │  port forwarding                │
│  └────────────────┘                                 │
└─────────────────────────────────────────────────────┘
```

**双层守护**：
- watchdog 通过 `pgrep` 探测 realm 是否在跑，挂了用 `nohup` 拉起，记日志
- watchdog 自身由 systemd/openrc 守护（`Restart=always`，崩了 3 秒内重启）

**规则数为 0 时智能停止**：删完最后一条规则会自动 stop realm 并阻止 watchdog 瞎拉（realm 要求至少 1 条 endpoint，否则启动即崩）。

## 文件与日志

| 路径 | 用途 |
|---|---|
| `/root/realm/realm` | realm 二进制 |
| `/root/realm/config.toml` | 转发规则（与 EZRealm 格式兼容） |
| `/root/realm/realm.pid` | realm 进程 PID |
| `/root/realm/watchdog.pid` | watchdog PID（systemd/openrc 接管时由它们持有） |
| `/root/realm/logs/realm.log` | realm 标准输出/错误 |
| `/root/realm/logs/watchdog.log` | watchdog 每次探测和拉起记录 |
| `/etc/systemd/system/realm-watchdog.service` | systemd unit（仅 systemd 环境） |
| `/etc/init.d/realm-watchdog` | openrc init 脚本（仅 openrc 环境） |

## 环境变量（可选）

通过环境变量改默认行为，例如换安装目录或自托管 realm 二进制：

```bash
REALM_HOME=/opt/realm \
REALM_VERSION=v2.9.3 \
REALM_MIRROR=https://ghfast.top/ \
REALM_WATCHDOG_INTERVAL=5 \
realmctl install
```

| 变量 | 默认值 | 说明 |
|---|---|---|
| `REALM_HOME` | `/root/realm` | 安装目录 |
| `REALM_VERSION` | `v2.9.3` | realm 版本 |
| `REALM_MIRROR` | `https://ghfast.top/` | github 加速前缀（置空 = 直连） |
| `REALM_WATCHDOG_INTERVAL` | `5` | watchdog 探测间隔（秒） |

## 卸载

```bash
realmctl uninstall
```

会清理：watchdog service、realm 进程、`/root/realm` 目录、`/usr/local/bin/realmctl` 本身。

## 与 EZRealm 的关系

`config.toml` 格式完全兼容（同样的 `[[endpoints]]` + `# 备注:` + `listen` + `remote`）。也就是说，**EZRealm 装过的机器可以直接 `realmctl enable` 接管保活，规则不会丢**；反之，realmctl 装过的机器也可以回退到 EZRealm 交互菜单管理规则。

## License

MIT
