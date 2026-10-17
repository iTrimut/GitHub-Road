---
name: github-road-linux
description: 让普通用户（无需 root、无需代理）在中国大陆的 Linux 机器上稳定访问 GitHub。这是 Windows 技能 GitHub-Road 的 Linux 移植版：用 getaddrinfo 的 LD_PRELOAD shim 替代 hosts 改写（免 root），用 crontab 替代计划任务，并保留"多 IP 实测择优 + 定时自愈"，另加多 IP 失败转移以对抗封锁抖动。当用户说"Linux 上 GitHub 打不开/连不上/DNS 指向的 IP 是黑洞/连接被 reset"、需要 git push 到 GitHub 官网但 SSH 被墙、或想把 GitHub-Road 用到服务器/集群节点上时使用。覆盖 HTTPS 网页与 git over HTTPS 推送；SSH(22/443) 推送在这类网络下无法修复。
---

# 🛣️ github-road-linux：Linux（无 root）稳定访问 GitHub

> 这是 Windows 技能 [`GitHub-Road`](../GitHub-Road/SKILL.md) 的 Linux 移植版。核心逻辑一致（**实测择优 + 定时自愈**），但两处 Windows 专属机制被替换：
> **改 `C:\...\hosts` → `getaddrinfo` 的 `LD_PRELOAD` shim**（无需 root）；**计划任务 → `crontab`**。

## 何时使用

- Linux 服务器 / HPC 集群节点上 `github.com` 打不开：DNS 能解析，但连上就 reset / 超时。
- `git clone`/`git push` 走 `git@github.com`（SSH）被墙，想改走 HTTPS 官网。
- 没有 root（改不了 `/etc/hosts`）、不想折腾代理。
- 从 Windows 的 `GitHub-Road` 迁移过来，需要等价能力。

## 为什么 Linux 版要这样改（原理）

**问题本质**：运营商对 `github.com` 按 **IP / SNI** 做封锁，且**被封锁的 IP 集合会轮换**。所以"把某个 IP 写死到 hosts"注定过一阵失效——这正是原技能要自愈的原因。

**Linux 上的两个现实约束**：
1. **写 `/etc/hosts` 需要 root**。集群/服务器上普通用户往往没有 root，`sudo` 也要密码 → 不能照搬 hosts 方案。
   → 用 **`LD_PRELOAD` 拦截 `getaddrinfo`**：任何用 getaddrinfo 的程序（`curl`、`git`/libcurl 等）解析 `github.com` 时，被重定向到 pin 文件里的 IP。**完全用户态，无需 root。**
2. **没有 Windows 计划任务**。
   → 用 **`crontab`** 每 30 分钟重跑择优脚本（本机无 user-systemd，故不用 systemd timer）。

**针对"封锁抖动"的关键增强（相对原版）**：某些网络下**任何单个 IP 都可能在几分钟内从可用变 reset**。因此：
- 择优时对每个候选 IP **重复探测多次**，按（通过次数↓，平均时延↑）排序；
- pin 文件**每台主机保留多个 IP**，`libpin.so` 把它们作为一个 **addrinfo 失败转移列表**返回——客户端连不上就自动试下一个。

## 前置条件

- Linux（已在 CentOS 7 / x86_64 验证），普通用户即可，**无需 root**。
- `bash`、`curl`（系统自带）、`gcc`（仅安装时编译一次，之后运行不需要）、`crontab`。
- 网络本身通（能开国内网站）。

## 安装（一次）

```bash
cd <本技能目录>/files
bash install.sh
```

`install.sh` 会：
1. 编译 `libpin.so` 并做健全性检查；
2. 运行一次 `select-github-ip.sh` 生成 `~/.hermes/github-pin`；
3. 在 `~/.bashrc` 追加一段 **幂等** 的激活块（存在 `libpin.so` 与 pin 文件时才 `export LD_PRELOAD`）；
4. 追加一条 **幂等** 的 crontab（`*/30 * * * *` 重跑择优）。

安装后：`source ~/.bashrc`（或开新 shell）使当前会话生效。

## 验证

```bash
SO="<本技能目录>/files/libpin.so"
env LD_PRELOAD="$SO" curl -s -o /dev/null -w '%{http_code} %{remote_ip}\n' https://github.com
# 期望：200 <pin 文件里的某个 IP>

crontab -l | grep github-road-linux     # 看到 */30 那条
cat ~/.hermes/github-pin                # 看到 github.com / api.github.com 的 IP 列表
```

## 常用操作

| 目的 | 命令 |
|---|---|
| 立即修复（重选 IP 并验证） | `bash files/fix-now.sh` |
| 仅在当前 shell 激活 | `source files/gh-road-env.sh` |
| 手动重选 IP | `bash files/select-github-ip.sh` |
| 查看自愈日志 | `tail -f ~/.hermes/github-road.log` |
| 卸载（去 bashrc/crontab） | `bash files/uninstall.sh` |

## 关键设计说明

- **pin 文件** `~/.hermes/github-pin`：`<hostname> <ip>` 每行一条，同主机可多行（按优先级从上到下）。`libpin.so` 运行期读取，**改 IP 无需重新编译**。
- **`libpin.so`**：只重写 pin 文件里出现的 hostname；其它域名一律走真实 `getaddrinfo`，对系统无副作用。
- **`GITHUB_ROAD_PIN`**：可指定 pin 文件位置；`libpin.so` 遵循同一环境变量（技能包内所有脚本一致）。
- 可用 `GITHUB_ROAD_PROBES`（默认 5）调探测次数、`GITHUB_ROAD_TOP_K`（默认 3）调每主机保留的 IP 数。

## ⚠️ 局限性（如实说明）

- **SSH 推送（`ssh github.com` 22 或 443）无法在本方案下修复**：这类网络对 GitHub 的 SSH 端口整体超时/重置，与按 IP 轮换无关。请把远端改成 **HTTPS**（`https://github.com/<org>/<repo>.git`）。
- **`codeload.github.com`（下载源码压缩包）** 与浏览器 **gist** 不在覆盖范围。
- 若运营商升级为"对 github.com 全量封锁"（所有 IP 全 reset），择优脚本会如实报告"无可用 IP"，此时需用代理。
- **`LD_PRELOAD` 全局注入**：安装脚本把它写进 `~/.bashrc`，只重写 pin 中的域名，风险低；若担心，可改用 `gh-road-env.sh` 按需 `source`。
- 择优结果依赖**当下**的探测；网络剧烈抖动时，crontab 每 30 分钟会重新择优劣化。

## 📁 文件说明（files/）

| 文件 | 用途 |
|---|---|
| `libpin.c` | `getaddrinfo` 的 `LD_PRELOAD` shim；读取 pin 文件，返回多 IP 失败转移列表。 |
| `libpin.so` | `install.sh` 用 gcc 编译产物（运行期依赖，不纳入版本库）。 |
| `select-github-ip.sh` | 择优核心：并行探测候选 IP，按通过次数/时延排序，写 top-K 到 pin 文件。 |
| `install.sh` | 一键安装：编译 + 初次择优 + bashrc 钩子 + crontab 自愈（幂等）。 |
| `uninstall.sh` | 卸载 bashrc / crontab 钩子。 |
| `fix-now.sh` | 立即重选并验证。 |
| `gh-road-env.sh` | 当前 shell 激活（`source`）。 |

> 本技能是 Windows 版 [`GitHub-Road`](../GitHub-Road/SKILL.md) 的 Linux 等价实现，二者可共存。
