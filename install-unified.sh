#!/usr/bin/env bash
set -Eeuo pipefail

NVM_VERSION="${NVM_VERSION:-v0.40.3}"
CODEX_PACKAGE="${CODEX_PACKAGE:-@openai/codex}"
CODEX_MODEL="${CODEX_MODEL:-gpt-5.5}"
CODEX_REASONING_EFFORT="${CODEX_REASONING_EFFORT:-xhigh}"
CODEX_SERVICE_TIER="${CODEX_SERVICE_TIER:-fast}"
CODEX_BASE_URL="${CODEX_BASE_URL:-https://api.antithor.asia/v1}"
PROVIDER_NAME="${PROVIDER_NAME:-custom}"
CCSWITCH_VERSION="${CCSWITCH_VERSION:-latest}"
CCSWITCH_BASE_URL="${CCSWITCH_BASE_URL:-https://github.com/${CCSWITCH_REPO}/releases}"

log() {
  printf '\n[%s] %s\n' "$(date +'%H:%M:%S')" "$*"
}

die() {
  printf '\n错误: %s\n' "$*" >&2
  exit 1
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

sudo_if_needed() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" = "$2" ]
}

detect_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "x86_64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) die "不支持的架构: $arch" ;;
  esac
}

check_codex_installed() {
  if has_cmd codex; then
    if codex --version >/dev/null 2>&1; then
      return 0
    fi
  fi

  export NVM_DIR="$HOME/.nvm"
  if [ -s "$NVM_DIR/nvm.sh" ]; then
    # shellcheck source=/dev/null
    . "$NVM_DIR/nvm.sh"
    if has_cmd node && has_cmd npm; then
      local codex_js
      codex_js="$(npm root -g 2>/dev/null)/@openai/codex/bin/codex.js"
      if [ -f "$codex_js" ]; then
        return 0
      fi
    fi
  fi

  return 1
}

install_ccswitch() {
  local arch="$1"
  local version="$2"

  log "检测到 Ubuntu 22.04+，准备安装 CC Switch"

  if has_cmd ccswitch; then
    log "CC Switch 已安装，跳过"
    return 0
  fi

  local deb_file
  if [ "$version" = "latest" ]; then
    log "获取 CC Switch 最新版本"
    local latest_url
    latest_url="$(curl -fsSL https://api.github.com/repos/${CCSWITCH_REPO}/releases/latest | grep -o '"browser_download_url": *"[^"]*"' | grep "Linux-${arch}.deb" | head -1 | cut -d'"' -f4)"
    if [ -z "$latest_url" ]; then
      log "警告：无法获取 CC Switch 下载链接，跳过安装"
      return 0
    fi
    deb_file="/tmp/ccswitch_${arch}.deb"
    log "下载 CC Switch: $latest_url"
    curl -fsSL "$latest_url" -o "$deb_file"
  else
    deb_file="/tmp/ccswitch_${version}_${arch}.deb"
    local download_url="${CCSWITCH_BASE_URL}/download/v${version}/ccswitch_${version}_${arch}.deb"
    log "下载 CC Switch: $download_url"
    curl -fsSL "$download_url" -o "$deb_file"
  fi

  if [ ! -f "$deb_file" ]; then
    log "警告：CC Switch 下载失败，跳过安装"
    return 0
  fi

  log "安装 CC Switch"
  sudo_if_needed dpkg -i "$deb_file" || sudo_if_needed apt-get install -f -y
  rm -f "$deb_file"

  if has_cmd ccswitch; then
    log "CC Switch 安装成功: $(ccswitch --version 2>/dev/null || echo '已安装')"
  fi
}

upsert_managed_block() {
  local file="$1"
  local start_marker="$2"
  local end_marker="$3"
  local block_file="$4"

  mkdir -p "$(dirname "$file")"
  touch "$file"

  local tmp_file
  tmp_file="$(mktemp)"
  awk -v start="$start_marker" -v end="$end_marker" '
    $0 == start { skip = 1; next }
    $0 == end { skip = 0; next }
    !skip { print }
  ' "$file" > "$tmp_file"

  {
    cat "$tmp_file"
    printf '\n%s\n' "$start_marker"
    cat "$block_file"
    printf '%s\n' "$end_marker"
  } > "$file"

  rm -f "$tmp_file"
}

read_auth_json_key() {
  local auth_file="$HOME/.codex/auth.json"
  if [ ! -f "$auth_file" ]; then
    return 0
  fi

  node -e '
const fs = require("fs");
const file = process.argv[1];
try {
  const value = JSON.parse(fs.readFileSync(file, "utf8")).OPENAI_API_KEY || "";
  if (value) process.stdout.write(value);
} catch (_) {}
' "$auth_file" 2>/dev/null || true
}

write_auth_json_key() {
  AUTH_JSON_KEY="$1" node <<'NODE'
const fs = require("fs");
const path = require("path");

const home = process.env.HOME;
const key = process.env.AUTH_JSON_KEY;
if (!home || !key) {
  process.exit(1);
}

const codexDir = path.join(home, ".codex");
const authFile = path.join(codexDir, "auth.json");
fs.mkdirSync(codexDir, { recursive: true });
fs.writeFileSync(
  authFile,
  JSON.stringify({ OPENAI_API_KEY: key }, null, 2) + "\n",
  { mode: 0o600 }
);
fs.chmodSync(authFile, 0o600);
NODE
}

if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

log "检查系统信息"
uname -a

if [ ! -f /etc/os-release ]; then
  die "未找到 /etc/os-release，无法确认 Ubuntu 版本。"
fi

# shellcheck source=/dev/null
. /etc/os-release
printf 'OS: %s\n' "${PRETTY_NAME:-unknown}"

if [ "${ID:-}" != "ubuntu" ]; then
  die "此脚本仅面向 Ubuntu 系统。当前系统: ${PRETTY_NAME:-unknown}"
fi

UBUNTU_VERSION="${VERSION_ID:-0}"
ARCH="$(detect_arch)"

log "检测到 Ubuntu ${UBUNTU_VERSION}，架构 ${ARCH}"

# 根据 Ubuntu 版本选择 Node.js 版本
if version_ge "$UBUNTU_VERSION" "20.04"; then
  NODE_VERSION="${NODE_VERSION:-22}"
  log "使用 Node.js 22（Ubuntu 20.04+）"
else
  NODE_VERSION="${NODE_VERSION:-16}"
  log "使用 Node.js 16（Ubuntu 18.04）"
fi

# Ubuntu 22.04+ 安装 CC Switch
INSTALL_CCSWITCH=false
if version_ge "$UBUNTU_VERSION" "22.04"; then
  INSTALL_CCSWITCH=true
fi

case "$(uname -m)" in
  x86_64|aarch64|arm64|amd64) ;;
  *) die "不支持的系统架构: $(uname -m)" ;;
esac

log "检查 Codex 是否已安装"
if check_codex_installed; then
  log "检测到 Codex 已安装，跳过安装步骤"
  SKIP_INSTALL=true
else
  log "未检测到 Codex，将进行完整安装"
  SKIP_INSTALL=false
fi

if [ "$SKIP_INSTALL" = false ]; then
  missing=()
  for cmd in curl git tar xz; do
    if ! has_cmd "$cmd"; then
      missing+=("$cmd")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    if ! has_cmd apt-get; then
      die "缺少命令: ${missing[*]}，并且没有找到 apt-get。"
    fi
    log "安装基础依赖: ${missing[*]}"
    sudo_if_needed apt-get update
    sudo_if_needed apt-get install -y curl git ca-certificates tar xz-utils
  fi

  log "安装/加载 nvm ${NVM_VERSION}"
  export NVM_DIR="$HOME/.nvm"
  if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
  fi

  # shellcheck source=/dev/null
  . "$NVM_DIR/nvm.sh"

  log "安装/使用 Node.js ${NODE_VERSION}"
  nvm install "$NODE_VERSION"
  nvm alias default "$NODE_VERSION"
  nvm use "$NODE_VERSION"

  log "安装 Codex CLI: ${CODEX_PACKAGE}"
  npm install -g --force "$CODEX_PACKAGE"

  GLOBAL_NODE_ROOT="$(npm root -g)"
  CODEX_PACKAGE_DIR="$GLOBAL_NODE_ROOT/@openai/codex"
  CODEX_ENTRY_FILE="$CODEX_PACKAGE_DIR/bin/codex.js"

  if [ ! -f "$CODEX_ENTRY_FILE" ]; then
    die "Codex CLI 安装失败，未找到入口文件: $CODEX_ENTRY_FILE"
  fi
else
  export NVM_DIR="$HOME/.nvm"
  if [ -s "$NVM_DIR/nvm.sh" ]; then
    # shellcheck source=/dev/null
    . "$NVM_DIR/nvm.sh"
  fi
fi

# 安装 CC Switch（Ubuntu 22.04+）
if [ "$INSTALL_CCSWITCH" = true ]; then
  install_ccswitch "$ARCH" "$CCSWITCH_VERSION"
fi

mkdir -p "$HOME/.codex"

EXISTING_API_KEY="${OPENAI_API_KEY:-}"
if [ -z "$EXISTING_API_KEY" ]; then
  EXISTING_API_KEY="$(read_auth_json_key)"
fi

if [ -n "$EXISTING_API_KEY" ]; then
  printf '\n检测到已有 API Key。\n直接回车保留旧 Key；输入新 Key 则覆盖。输入时不会显示：\n> '
  IFS= read -r -s API_KEY_INPUT
  printf '\n'
  if [ -n "$API_KEY_INPUT" ]; then
    API_KEY_VALUE="$API_KEY_INPUT"
  else
    API_KEY_VALUE="$EXISTING_API_KEY"
  fi
else
  printf '\n请输入 API Key，然后回车。输入时不会显示，这是正常的：\n> '
  IFS= read -r -s API_KEY_VALUE
  printf '\n'
fi

if [ -z "${API_KEY_VALUE:-}" ]; then
  die "API Key 不能为空。"
fi

log "写入 Codex 认证文件 ~/.codex/auth.json"
if [ -f "$HOME/.codex/auth.json" ]; then
  cp "$HOME/.codex/auth.json" "$HOME/.codex/auth.json.bak-$(date +'%Y%m%d-%H%M%S')"
fi
write_auth_json_key "$API_KEY_VALUE"

log "写入 Codex 配置 ~/.codex/config.toml"
if [ -f "$HOME/.codex/config.toml" ]; then
  cp "$HOME/.codex/config.toml" "$HOME/.codex/config.toml.bak-$(date +'%Y%m%d-%H%M%S')"
fi

cat > "$HOME/.codex/config.toml" <<EOF
model_provider = "${PROVIDER_NAME}"
model = "${CODEX_MODEL}"
model_reasoning_effort = "${CODEX_REASONING_EFFORT}"
disable_response_storage = true
service_tier = "${CODEX_SERVICE_TIER}"

[model_providers.${PROVIDER_NAME}]
name = "${PROVIDER_NAME}"
wire_api = "responses"
requires_openai_auth = false
base_url = "${CODEX_BASE_URL}"
EOF

chmod 600 "$HOME/.codex/auth.json"
chmod 600 "$HOME/.codex/config.toml"

log "配置 Codex 命令，让登录 shell 和非交互 SSH 都能找到"
SHELL_BLOCK="$(mktemp)"
cat > "$SHELL_BLOCK" <<'EOF'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"
EOF

upsert_managed_block "$HOME/.profile" '# >>> codex-antithor-installer-ubuntu20-plus >>>' '# <<< codex-antithor-installer-ubuntu20-plus <<<' "$SHELL_BLOCK"
upsert_managed_block "$HOME/.bashrc" '# >>> codex-antithor-installer-ubuntu20-plus >>>' '# <<< codex-antithor-installer-ubuntu20-plus <<<' "$SHELL_BLOCK"
rm -f "$SHELL_BLOCK"

mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/codex" <<'EOF'
#!/usr/bin/env bash
set -e
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  echo "未找到 nvm: $NVM_DIR/nvm.sh" >&2
  exit 127
fi
. "$NVM_DIR/nvm.sh"
nvm use --silent default >/dev/null 2>&1 || true
CODEX_JS="$(npm root -g 2>/dev/null)/@openai/codex/bin/codex.js"
if [ ! -f "$CODEX_JS" ]; then
  echo "未找到 Codex CLI 文件: $CODEX_JS" >&2
  exit 127
fi
exec node "$CODEX_JS" "$@"
EOF
chmod +x "$HOME/.local/bin/codex"

if has_cmd sudo; then
  log "安装 /usr/local/bin/codex 包装脚本"
  sudo_if_needed install -m 0755 "$HOME/.local/bin/codex" /usr/local/bin/codex
else
  log "未找到 sudo；仅安装包装脚本到 $HOME/.local/bin/codex"
fi

log "配置完成检查"
printf 'Ubuntu: %s\n' "$UBUNTU_VERSION"
printf '架构: %s\n' "$ARCH"
if has_cmd node; then
  printf 'node: '
  node -v
fi
if has_cmd npm; then
  printf 'npm: '
  npm -v
fi
if has_cmd codex || [ -x "$HOME/.local/bin/codex" ]; then
  printf 'codex: '
  "$HOME/.local/bin/codex" --version 2>/dev/null || codex --version 2>/dev/null || echo "已安装"
fi
if has_cmd ccswitch; then
  printf 'ccswitch: '
  ccswitch --version 2>/dev/null || echo "已安装"
fi
printf '配置文件: %s\n' "$HOME/.codex/config.toml"
printf 'Codex 认证文件: %s\n' "$HOME/.codex/auth.json"

cat <<'EOF'

配置完成。

建议继续测试：
  hash -r
  /usr/local/bin/codex --version
  /usr/local/bin/codex exec --skip-git-repo-check "hello"

生成的配置文件：
  ~/.codex/config.toml
  ~/.codex/auth.json

注意：API Key 会明文保存在 ~/.codex/auth.json 中，脚本已设置权限为 600。

Ubuntu 版本适配说明：
  - Ubuntu 18.04: Node.js 16
  - Ubuntu 20.04+: Node.js 22
  - Ubuntu 22.04+: 额外安装 CC Switch
EOF

