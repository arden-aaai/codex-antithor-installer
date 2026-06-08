# Codex Antithor 一键安装脚本

这个仓库用于在 Ubuntu 服务器上一键安装 Codex CLI，并配置为使用 Antithor 中转站。

适合给多人批量配置服务器。用户只需要在服务器里运行安装命令，脚本会暂停并提示输入自己的 API Key。

## 一键安装

### 推荐：统一安装脚本

推荐所有 Ubuntu 18.04 及以上系统优先使用统一脚本：

```bash
curl -fsSL "https://raw.githubusercontent.com/771373073/codex-antithor-installer/main/install-unified.sh?$(date +%s)" -o install-unified.sh
bash install-unified.sh
```

统一脚本会自动检测系统版本：

```text
Ubuntu 18.04  -> Node.js 16
Ubuntu 20.04+ -> Node.js 22
Ubuntu 22.04+ -> 额外安装 CC Switch，并创建桌面快捷方式
```

脚本会提示输入 API Key，输入时不会显示，回车后自动写入：

```text
~/.codex/config.toml
~/.codex/auth.json
```

统一脚本生成的 `~/.codex/config.toml` 为：

```toml
model_provider = "custom"
model = "gpt-5.5"
model_reasoning_effort = "xhigh"
disable_response_storage = true
service_tier = "fast"

[model_providers.custom]
name = "custom"
wire_api = "responses"
requires_openai_auth = false
base_url = "https://api.antithor.asia/v1"
```

生成的 `~/.codex/auth.json` 为：

```json
{
  "OPENAI_API_KEY": "你的 API Key"
}
```

### 备用：Ubuntu 20.04 及以上专用脚本

如果不想安装 CC Switch，只想使用 Codex CLI 配置脚本，可以运行：

```bash
curl -fsSL "https://raw.githubusercontent.com/771373073/codex-antithor-installer/main/install-ubuntu20-plus.sh?$(date +%s)" -o install-ubuntu20-plus.sh
bash install-ubuntu20-plus.sh
```

### Ubuntu 18.04

在服务器终端运行：

```bash
curl -fsSL "https://raw.githubusercontent.com/771373073/codex-antithor-installer/main/install.sh?$(date +%s)" -o install.sh
bash install.sh
```

安装过程中会提示：

```text
请输入 API Key，然后回车。输入时不会显示，这是正常的：
>
```

粘贴你的 API Key 后回车即可。输入过程中不会显示，这是正常的。

如果服务器里已经有旧 Key，脚本会提示：

```text
检测到已有 API Key。
直接回车保留旧 Key；输入新 Key 则覆盖。输入时不会显示：
>
```

如果要换 Key，就输入新 Key；如果继续用旧 Key，直接回车。

## 脚本会做什么

- 自动检测 Ubuntu 版本。
- Ubuntu 18.04 安装 Node.js 16。
- Ubuntu 20.04 及以上安装 Node.js 22。
- 安装 `@openai/codex`。
- 写入 Codex 配置文件：`~/.codex/config.toml`。
- 把 API Key 明文保存到 Codex 会读取的认证文件：`~/.codex/auth.json`。
- 设置 `~/.codex/auth.json` 和 `~/.codex/config.toml` 权限为 `600`。
- 如果 Codex 是本脚本安装的 nvm/npm 版本，会创建 `~/.local/bin/codex` 包装脚本。
- 如果有 sudo，会尝试安装 `/usr/local/bin/codex`，方便 Codex Desktop 远程 SSH 检测。
- Ubuntu 22.04 及以上会额外安装 CC Switch，并创建桌面快捷方式。

## 默认配置

```text
Base URL: https://api.antithor.asia
Model: gpt-5.5
Wire API: responses
Provider: custom
Reasoning effort: xhigh
Service tier: fast
认证文件: ~/.codex/auth.json
```

统一脚本生成的 Codex 配置如下：

```toml
model_provider = "custom"
model = "gpt-5.5"
model_reasoning_effort = "xhigh"
disable_response_storage = true
service_tier = "fast"

[model_providers.custom]
name = "custom"
wire_api = "responses"
requires_openai_auth = false
base_url = "https://api.antithor.asia/v1"
```

统一脚本生成的 `~/.codex/auth.json` 如下：

```json
{
  "OPENAI_API_KEY": "你的 API Key"
}
```

注意：API Key 会明文保存在服务器当前用户的 `~/.codex/auth.json` 中。脚本会设置文件权限为 `600`，但不要把这个文件上传到 GitHub。

## 安装后测试

```bash
hash -r
codex --version
codex exec --skip-git-repo-check "hello"
```

如果 `codex --version` 能输出版本号，说明 Codex CLI 已经安装成功。

如果 `codex exec --skip-git-repo-check "hello"` 能正常返回，说明中转站和 API Key 配置可用。

## 常见问题

如果看到：

```text
Missing environment variable: `ANTITHOR_API_KEY`.
```

说明你还在用旧配置。重新拉取最新脚本并运行：

```bash
curl -fsSL "https://raw.githubusercontent.com/771373073/codex-antithor-installer/main/install-unified.sh?$(date +%s)" -o install-unified.sh
bash install-unified.sh
```

统一脚本不会在 `config.toml` 里写 `env_key = "ANTITHOR_API_KEY"`，而是使用 `requires_openai_auth = false` 和 `~/.codex/auth.json`。

如果看到：

```text
SyntaxError: Unexpected token 'export'
```

说明旧脚本曾经误覆盖过 npm 原始的 Codex 入口文件。重新运行最新脚本，它会自动清理并重装 Codex CLI。

如果看到：

```text
Not inside a trusted directory and --skip-git-repo-check was not specified.
```

这不是 API Key 问题。测试时使用：

```bash
codex exec --skip-git-repo-check "hello"
```

如果看到 bubblewrap 警告：

```text
Codex could not find bubblewrap on PATH
```

这也不是 API Key 问题。想消除警告可以安装：

```bash
sudo apt update && sudo apt install -y bubblewrap
```

## 给 Codex Desktop 远程 SSH 使用

如果要在本地 Codex Desktop 连接这台服务器：

1. 先确保本地可以正常 SSH 进入服务器。
2. 在服务器上运行本脚本并完成 API Key 配置。
3. 回到 Codex Desktop 重新连接远程 SSH 主机。
4. 如果仍提示“未安装 Codex”，退出服务器重新登录，或者重启 Codex Desktop 后再试。

## 修改默认模型

可以在运行脚本前指定模型：

```bash
CODEX_MODEL=gpt-5.4 CODEX_REASONING_EFFORT=medium bash install-unified.sh
```

也可以修改中转站地址：

```bash
CODEX_BASE_URL=https://你的中转站地址 bash install-unified.sh
```

## 注意事项

- 不要把 API Key 写进 GitHub。
- 脚本会交互式读取 API Key，并保存到服务器当前用户自己的 `~/.codex/auth.json`。
- 如果之前已经有 `~/.codex/config.toml`，脚本会先自动备份。
- Ubuntu 18.04 使用 Node.js 16；Ubuntu 20.04 及以上使用 Node.js 22。
