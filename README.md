# Codex Antithor 一键安装脚本

在 Ubuntu 服务器上一键安装 Codex CLI，并配置为使用 Antithor 中转站。

适合给多人批量配置服务器：用户在服务器里运行一条命令，脚本会提示输入自己的 API Key，其余全部自动完成。

## 当前版本与兼容性

| 组件 | 版本 / 说明 |
| --- | --- |
| Codex CLI | `@openai/codex` 最新版（当前 `0.163.x`），默认装 `latest` |
| Node.js | Ubuntu 18.04 → 16；Ubuntu 20.04 及以上 → 24（当前 LTS） |
| nvm | `v0.40.8` |
| CC Switch | 最新版（当前 `4.0.x`），仅 Ubuntu 22.04+ 安装 |
| 默认模型 | `gpt-6.1-sol` |
| 接口 | Responses API（`wire_api = "responses"`） |
| 认证 | `~/.codex/auth.json` + `requires_openai_auth = true` |

## 一键安装

在服务器终端运行：

```bash
curl -fsSL "https://raw.githubusercontent.com/arden-aaai/codex-antithor-installer/main/install-unified.sh?$(date +%s)" -o install-unified.sh
bash install-unified.sh
```

脚本会暂停并提示输入 API Key（输入时不会显示，这是正常的）：

```text
请输入 API Key，然后回车。输入时不会显示，这是正常的：
>
```

如果服务器里已经有旧 Key，会提示：

```text
检测到已有 API Key。
直接回车保留旧 Key；输入新 Key 则覆盖。输入时不会显示：
>
```

### 非交互式安装（批量部署 / 自动化）

```bash
CODEX_API_KEY=sk-你的key bash install-unified.sh -y
```

`-y` 表示所有确认都按“是”处理。Key 通过环境变量传入，不会出现在 shell 历史和 `ps` 输出里。

不设置 `CODEX_API_KEY` 时，行为和以前完全一样：脚本会暂停并等待你手动输入 Key。这个变量只是给批量部署、自动化脚本用的可选通道。

## 脚本会做什么

- 检测 Ubuntu 版本与 CPU 架构（x86_64 / arm64）。
- 安装基础依赖：`curl`、`git`、`ca-certificates`、`tar`、`xz-utils`。
- Ubuntu 18.04 使用 Node.js 16；Ubuntu 20.04 及以上使用 Node.js 24。
- 通过 nvm 安装 Node.js，并写进 `~/.profile` / `~/.bashrc`，让登录 shell 和非交互 SSH 都能找到 `codex`。
- 安装 `@openai/codex`（默认最新版）。
- 写入 `~/.codex/config.toml` 与 `~/.codex/auth.json`，权限 `600`。
- 创建 `~/.local/bin/codex` 包装脚本；有 sudo 时再装一份到 `/usr/local/bin/codex`（方便 Codex Desktop 远程 SSH 检测）。
- Ubuntu 22.04 及以上额外安装 CC Switch，并创建桌面快捷方式；不想装可加 `--no-ccswitch`。
- 覆盖旧配置前自动备份为 `config.toml.bak-时间戳`、`auth.json.bak-时间戳`。

## 生成的配置

`~/.codex/config.toml`：

```toml
model_provider = "custom"
model = "gpt-6.1-sol"
model_reasoning_effort = "xhigh"
service_tier = "fast"

[model_providers.custom]
name = "custom"
wire_api = "responses"
requires_openai_auth = true
base_url = "https://api.antithor.asia/v1"
```

`~/.codex/auth.json`：

```json
{
  "auth_mode": "apikey",
  "OPENAI_API_KEY": "你的 API Key"
}
```

两个 `600` 权限的文件都是明文保存 Key，请不要上传到 GitHub，也不要把服务器上的这两个文件提交进任何仓库。

> **为什么是 `requires_openai_auth = true`？**
> 新版 Codex 对自定义 provider 只有在 `requires_openai_auth = true` 时，才会把 `auth.json` 里的 `OPENAI_API_KEY` 作为 `Authorization: Bearer` 发出去。旧版脚本用的 `false` 会让请求不带任何 Key，中转站直接返回 `API_KEY_REQUIRED`。
>
> 旧配置里的 `disable_response_storage` 已被新版移除，继续写入会触发 `unrecognized configuration setting` 警告，因此新脚本不再生成它。

## 常用参数

| 参数 | 说明 |
| --- | --- |
| `-u`, `--upgrade` | 即使已是最新，也强制重装/升级 Codex CLI |
| `--no-upgrade` | 跳过版本检查，不改动已安装的 Codex CLI |
| `--no-ccswitch` | 不安装 CC Switch（Ubuntu 22.04+ 默认安装） |
| `-y`, `--yes` | 所有确认都按“是”处理 |
| `-h`, `--help` | 显示帮助 |

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `CODEX_MODEL` | `gpt-6.1-sol` | 模型名称 |
| `CODEX_REASONING_EFFORT` | `xhigh` | 推理强度；留空则不写入该行 |
| `CODEX_SERVICE_TIER` | `fast` | 服务等级（`fast` 会映射为请求里的 `priority`）；留空则不写入 |
| `CODEX_BASE_URL` | `https://api.antithor.asia/v1` | 中转站地址 |
| `CODEX_VERSION` | `latest` | 锁定 Codex CLI 版本，例如 `0.163.0` |
| `CODEX_API_KEY` | 空 | 非交互式提供 Key（也可用 `OPENAI_API_KEY`） |
| `NODE_VERSION` | 18.04 用 16，其余 24 | 覆盖 Node.js 版本 |
| `NVM_VERSION` | `v0.40.8` | 覆盖 nvm 版本 |
| `CCSWITCH_VERSION` | `latest` | 覆盖 CC Switch 版本 |
| `INSTALL_GLOBAL_WRAPPER` | `auto` | `auto` / `1` / `0`，控制 `/usr/local/bin/codex` |

示例：

```bash
# 换模型
CODEX_MODEL=gpt-6-astra bash install-unified.sh

# 换中转站
CODEX_BASE_URL=https://你的中转站/v1 bash install-unified.sh

# 锁定版本 + 不装 CC Switch
CODEX_VERSION=0.163.0 bash install-unified.sh --no-ccswitch
```

可用的模型以你的中转站为准，目前常见的有 `gpt-6.1-sol`、`gpt-6-astra`、`gpt-6-sol`、`gpt-5.6-terra`、`gpt-5.6-sol` 等。

## 更新已安装的 Codex

直接重跑统一脚本即可，脚本会自动比较版本：

```bash
curl -fsSL "https://raw.githubusercontent.com/arden-aaai/codex-antithor-installer/main/install-unified.sh?$(date +%s)" -o install-unified.sh
bash install-unified.sh
```

- 已是最新：跳过安装，只更新配置。
- 发现新版本：提示后升级（`-y` 时直接升级）。
- 想强制重装：加 `--upgrade`。
- 只想换 Key、完全不动 Codex：加 `--no-upgrade`。

## 验证安装

```bash
hash -r
codex --version
codex login status
codex exec --skip-git-repo-check "hello"
```

- `codex --version` 输出版本号 → CLI 安装成功。
- `codex login status` 显示 `Logged in using an API key - sk-xxx***` → 认证文件生效。
- `codex exec ...` 能正常返回 → 中转站和 Key 可用。

## 常见问题

**`401 API_KEY_REQUIRED` / `API key is required in Authorization header`**

说明你还在用旧配置（`requires_openai_auth = false`），请求根本没有携带 Key。重新拉取并运行最新脚本即可：

```bash
curl -fsSL "https://raw.githubusercontent.com/arden-aaai/codex-antithor-installer/main/install-unified.sh?$(date +%s)" -o install-unified.sh
bash install-unified.sh
```

**`401 INVALID_API_KEY` / `Invalid API key`**

Key 本身不对：确认复制完整、没有多余空格，或到中转站后台重新生成后重跑脚本。

**`unrecognized configuration setting: disable_response_storage is ignored`**

旧脚本生成的配置行。重跑最新脚本会重写 `config.toml`；也可以手动删掉这一行。

**`Missing environment variable: ANTITHOR_API_KEY`**

更早期的配置方式，现在已改为 `auth.json`。重跑最新脚本。

**`SyntaxError: Unexpected token 'export'`**

旧脚本曾误覆盖 npm 原始的 Codex 入口文件。用 `--upgrade` 重跑本脚本会自动重装：

```bash
bash install-unified.sh --upgrade
```

**`Not inside a trusted directory and --skip-git-repo-check was not specified`**

不是 Key 问题，测试时加 `--skip-git-repo-check` 即可。

**`Codex could not find bubblewrap on PATH`**

也不是 Key 问题。想消除警告：

```bash
sudo apt update && sudo apt install -y bubblewrap
```

**升级后 `codex` 还是旧版本**

检查是不是先命中了别的 `codex`：

```bash
type -a codex
hash -r
```

脚本会把包装脚本装到 `~/.local/bin/codex` 和 `/usr/local/bin/codex`，并让它们优先于其他路径。

## 给 Codex Desktop 远程 SSH 使用

1. 确认本地能正常 SSH 进入服务器。
2. 在服务器上运行本脚本并完成 API Key 配置。
3. 回到 Codex Desktop 重新连接远程 SSH 主机。
4. 如果仍提示“未安装 Codex”，退出服务器重新登录，或重启 Codex Desktop 再试。

## 兼容入口

`install.sh`（原 Ubuntu 18.04 专用）和 `install-ubuntu20-plus.sh`（原 20.04+ 专用）现在都只是转发器：下载并执行 `install-unified.sh`，参数会原样传递。

保留它们只是为了兼容文档里已经发出去的旧链接：

```bash
bash install.sh                        # 等价于 bash install-unified.sh
bash install-ubuntu20-plus.sh --no-ccswitch
```

新用户请直接用 `install-unified.sh`。

## 非 Ubuntu 系统

脚本只做 Ubuntu 适配（apt / nvm）。其他系统可以手动做三件事：

1. 安装 Node.js 18+ 和 `npm i -g @openai/codex`。
2. 按上面的内容写 `~/.codex/config.toml`。
3. 按上面的内容写 `~/.codex/auth.json` 并 `chmod 600`。

## 安全说明

- API Key 明文保存在 `~/.codex/auth.json`，权限 `600`，属于当前登录用户。
- 脚本不会把 Key 写进任何日志或仓库；非交互模式下 Key 通过环境变量传入。
- 共用服务器时请注意：同机的 root 仍然可以读取该文件，敏感环境建议用独立账号。
