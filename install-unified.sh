#!/usr/bin/env bash
set -Eeuo pipefail

NVM_VERSION="${NVM_VERSION:-v0.40.3}"
CODEX_PACKAGE="${CODEX_PACKAGE:-@openai/codex}"
CODEX_MODEL="${CODEX_MODEL:-gpt-5.5}"
CODEX_REASONING_EFFORT="${CODEX_REASONING_EFFORT:-xhigh}"
CODEX_SERVICE_TIER="${CODEX_SERVICE_TIER:-fast}"
CODEX_BASE_URL="${CODEX_BASE_URL:-https://api.antithor.asia/v1}"
PROVIDER_NAME="${PROVIDER_NAME:-custom}"
CCSWITCH_REPO="${CCSWITCH_REPO:-farion1231/cc-switch}"
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

log_error_excerpt() {
  local file="$1"

  if [ ! -s "$file" ]; then
    return 0
  fi

  while IFS= read -r line; do
    [ -n "$line" ] && log "  $line"
  done < <(sed -n '1,3p' "$file")
}

sudo_if_needed() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif has_cmd sudo; then
    sudo "$@"
  else
    die "当前用户不是 root，且系统未安装 sudo，无法执行需要管理员权限的命令: $*"
  fi
}

version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" = "$2" ]
}

normalize_version() {
  local version="$1"

  if [ "$version" = "latest" ]; then
    printf '%s' "$version"
  else
    printf '%s' "${version#v}"
  fi
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

codex_npm_entry_exists() {
  export NVM_DIR="$HOME/.nvm"
  if [ -s "$NVM_DIR/nvm.sh" ]; then
    # shellcheck source=/dev/null
    . "$NVM_DIR/nvm.sh"
  fi

  if ! has_cmd node || ! has_cmd npm; then
    return 1
  fi

  local codex_js
  codex_js="$(npm root -g 2>/dev/null)/@openai/codex/bin/codex.js"
  [ -f "$codex_js" ]
}

backup_stale_codex_wrapper() {
  local wrapper="$HOME/.local/bin/codex"

  if [ ! -f "$wrapper" ]; then
    return 0
  fi

  if grep -q '@openai/codex/bin/codex.js' "$wrapper" 2>/dev/null; then
    local backup="${wrapper}.bak-$(date +'%Y%m%d-%H%M%S')"
    mv "$wrapper" "$backup"
    log "检测到旧的 Codex npm 包装脚本，但当前没有 npm 版 Codex，已备份: $backup"
  fi
}

check_apt_dns() {
  if ! has_cmd getent; then
    return 0
  fi

  local source_files=()
  local host
  local hosts

  if [ -f /etc/apt/sources.list ]; then
    source_files+=("/etc/apt/sources.list")
  fi

  if [ -d /etc/apt/sources.list.d ]; then
    while IFS= read -r file; do
      source_files+=("$file")
    done < <(find /etc/apt/sources.list.d -type f \( -name '*.list' -o -name '*.sources' \) 2>/dev/null || true)
  fi

  if [ "${#source_files[@]}" -eq 0 ]; then
    return 0
  fi

  hosts="$(
    awk '
      ($1 == "deb" || $1 == "deb-src") {
        for (i = 2; i <= NF; i++) {
          if ($i ~ /^[A-Za-z][A-Za-z0-9+.-]*:\/\//) print $i
        }
      }
      $1 == "URIs:" {
        for (i = 2; i <= NF; i++) print $i
      }
    ' "${source_files[@]}" 2>/dev/null |
      sed -E 's#^[A-Za-z][A-Za-z0-9+.-]*://([^/]+).*#\1#' |
      sort -u
  )"

  while IFS= read -r host; do
    [ -z "$host" ] && continue
    if ! getent hosts "$host" >/dev/null 2>&1; then
      log "Warning: DNS cannot resolve apt source host: $host"
      log "         If apt-get fails, check /etc/resolv.conf or the container network."
    fi
  done <<< "$hosts"
}

ensure_base_dependencies() {
  local missing=()
  for cmd in curl git tar xz; do
    if ! has_cmd "$cmd"; then
      missing+=("$cmd")
    fi
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    return 0
  fi

  if ! has_cmd apt-get; then
    die "缺少命令: ${missing[*]}，并且没有找到 apt-get。"
  fi

  log "安装基础依赖: ${missing[*]}"
  check_apt_dns
  sudo_if_needed apt-get update
  sudo_if_needed apt-get install -y curl git ca-certificates tar xz-utils
}

ccswitch_asset_name() {
  local arch="$1"
  local version="$2"

  printf 'CC-Switch-v%s-Linux-%s.deb' "$version" "$arch"
}

ccswitch_download_url_for_version() {
  local arch="$1"
  local version
  version="$(normalize_version "$2")"

  printf '%s/download/v%s/%s' "$CCSWITCH_BASE_URL" "$version" "$(ccswitch_asset_name "$arch" "$version")"
}

extract_ccswitch_download_url() {
  local release_json="$1"
  local arch="$2"
  local target="Linux-${arch}.deb"
  local url=""

  if has_cmd node; then
    url="$(
      printf '%s' "$release_json" |
        TARGET_ASSET="$target" node -e '
const fs = require("fs");
const target = process.env.TARGET_ASSET;
try {
  const release = JSON.parse(fs.readFileSync(0, "utf8"));
  const asset = (release.assets || []).find((item) =>
    item && item.name && item.name.endsWith(target) && item.browser_download_url
  );
  if (asset) process.stdout.write(asset.browser_download_url);
} catch (_) {}
' 2>/dev/null || true
    )"
  fi

  if [ -z "$url" ]; then
    url="$(
      printf '%s' "$release_json" |
        grep -o '"browser_download_url": *"[^"]*"' |
        grep "$target" |
        head -1 |
        cut -d'"' -f4 || true
    )"
  fi

  printf '%s' "$url"
}

extract_ccswitch_tag() {
  local release_json="$1"
  local tag=""

  if has_cmd node; then
    tag="$(
      printf '%s' "$release_json" |
        node -e '
const fs = require("fs");
try {
  const release = JSON.parse(fs.readFileSync(0, "utf8"));
  if (release.tag_name) process.stdout.write(release.tag_name);
} catch (_) {}
' 2>/dev/null || true
    )"
  fi

  if [ -z "$tag" ]; then
    tag="$(
      printf '%s' "$release_json" |
        grep -o '"tag_name": *"[^"]*"' |
        head -1 |
        cut -d'"' -f4 || true
    )"
  fi

  printf '%s' "$tag"
}

resolve_ccswitch_latest_tag_from_redirect() {
  local err_file
  local effective_url
  err_file="$(mktemp)"

  effective_url="$(
    curl -fsSLI -o /dev/null -w '%{url_effective}' \
      --retry 2 --retry-delay 2 --connect-timeout 10 --max-time 45 \
      "${CCSWITCH_BASE_URL}/latest" 2>"$err_file" || true
  )"

  if [ -n "$effective_url" ] && [ "$effective_url" != "${CCSWITCH_BASE_URL}/latest" ]; then
    rm -f "$err_file"
    printf '%s' "${effective_url##*/}"
    return 0
  fi

  log "Warning: GitHub latest redirect lookup failed for ${CCSWITCH_BASE_URL}/latest"
  log_error_excerpt "$err_file"
  rm -f "$err_file"
  return 0
}

download_file_with_diagnostics() {
  local url="$1"
  local output="$2"
  local label="$3"
  local err_file
  local status

  err_file="$(mktemp)"
  if curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 180 "$url" -o "$output" 2>"$err_file"; then
    rm -f "$err_file"
    return 0
  fi

  status=$?
  log "Warning: ${label} download failed, curl exit ${status}: $url"
  log_error_excerpt "$err_file"
  rm -f "$err_file"
  return "$status"
}

install_ccswitch() {
  local arch="$1"
  local version
  version="$(normalize_version "$2")"

  log "检测到 Ubuntu 22.04+，准备安装 CC Switch"

  if has_cmd cc-switch; then
    log "CC Switch 已安装，跳过"
    create_ccswitch_desktop_shortcut || true
    return 0
  fi

  if [ "$(id -u)" -ne 0 ] && ! has_cmd sudo; then
    log "警告：当前用户不是 root 且未安装 sudo，跳过 CC Switch 安装"
    return 0
  fi

  local deb_file
  if [ "$version" = "latest" ]; then
    log "获取 CC Switch 最新版本"
    local latest_url
    local latest_json
    local latest_tag
    local latest_err
    latest_url=""
    latest_tag=""
    latest_err="$(mktemp)"

    if latest_json="$(curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60 "https://api.github.com/repos/${CCSWITCH_REPO}/releases/latest" 2>"$latest_err")"; then
      latest_url="$(extract_ccswitch_download_url "$latest_json" "$arch")"
      latest_tag="$(extract_ccswitch_tag "$latest_json")"
      if [ -z "$latest_url" ] && [ -n "$latest_tag" ]; then
        log "Warning: GitHub API returned latest tag $latest_tag, but no matching Linux-${arch}.deb asset was parsed."
        latest_url="$(ccswitch_download_url_for_version "$arch" "$latest_tag")"
        log "         Trying constructed URL: $latest_url"
      fi
    else
      log "Warning: GitHub API request failed for ${CCSWITCH_REPO}/releases/latest"
      log_error_excerpt "$latest_err"
    fi
    rm -f "$latest_err"

    if [ -z "$latest_url" ]; then
      latest_tag="$(resolve_ccswitch_latest_tag_from_redirect)"
      if [ -n "$latest_tag" ]; then
        latest_url="$(ccswitch_download_url_for_version "$arch" "$latest_tag")"
        log "Fallback: resolved latest CC Switch tag from release redirect: $latest_tag"
      fi
    fi

    if [ -z "$latest_url" ]; then
      log "Warning: Cannot resolve CC Switch Linux-${arch}.deb download URL; skipping optional CC Switch install."
      log "         Codex CLI installation will continue."
      log "         You can retry with: CCSWITCH_VERSION=3.16.3 bash install-unified.sh"
    fi
    if [ -z "$latest_url" ]; then
      log "警告：无法获取 CC Switch 下载链接，跳过安装"
      return 0
    fi
    deb_file="/tmp/ccswitch_${arch}.deb"
    log "下载 CC Switch: $latest_url"
    if ! download_file_with_diagnostics "$latest_url" "$deb_file" "CC Switch"; then
      log "警告：CC Switch 下载失败，跳过安装"
      rm -f "$deb_file"
      return 0
    fi
  else
    deb_file="/tmp/$(ccswitch_asset_name "$arch" "$version")"
    local download_url
    download_url="$(ccswitch_download_url_for_version "$arch" "$version")"
    log "下载 CC Switch: $download_url"
    if ! download_file_with_diagnostics "$download_url" "$deb_file" "CC Switch"; then
      log "警告：CC Switch 下载失败，跳过安装"
      rm -f "$deb_file"
      return 0
    fi
  fi

  if [ ! -s "$deb_file" ]; then
    log "警告：CC Switch 下载失败，跳过安装"
    rm -f "$deb_file"
    return 0
  fi

  log "安装 CC Switch"
  if ! sudo_if_needed apt-get install -y "$deb_file"; then
    log "apt 安装 CC Switch 失败，尝试修复依赖"
    sudo_if_needed apt-get install -f -y || true
  fi
  rm -f "$deb_file"

  if has_cmd cc-switch; then
    log "CC Switch 安装成功: $(cc-switch --version 2>/dev/null || echo '已安装')"
    create_ccswitch_desktop_shortcut || true
  else
    log "警告：CC Switch 安装后未找到 cc-switch 命令"
  fi
}

create_ccswitch_desktop_shortcut() {
  local src="/usr/share/applications/CC Switch.desktop"

  if [ ! -f "$src" ]; then
    log "未找到 CC Switch 桌面入口: $src"
    return 0
  fi

  local desktop_dir=""
  if has_cmd xdg-user-dir; then
    desktop_dir="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
  fi

  if [ -z "$desktop_dir" ] && [ -f "$HOME/.config/user-dirs.dirs" ]; then
    desktop_dir="$(
      awk -F= '$1 == "XDG_DESKTOP_DIR" {
        gsub(/"/, "", $2)
        gsub(/\$HOME/, ENVIRON["HOME"], $2)
        print $2
        exit
      }' "$HOME/.config/user-dirs.dirs" 2>/dev/null || true
    )"
  fi

  if [ -z "$desktop_dir" ]; then
    if [ -d "$HOME/桌面" ]; then
      desktop_dir="$HOME/桌面"
    elif [ -d "$HOME/Desktop" ]; then
      desktop_dir="$HOME/Desktop"
    else
      desktop_dir="$HOME/Desktop"
    fi
  fi

  mkdir -p "$desktop_dir"
  cp "$src" "$desktop_dir/"
  chmod +x "$desktop_dir/CC Switch.desktop"

  if has_cmd gio; then
    gio set "$desktop_dir/CC Switch.desktop" metadata::trusted true 2>/dev/null || true
  fi

  log "已创建桌面快捷方式: $desktop_dir/CC Switch.desktop"
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

  if has_cmd node; then
    node -e '
const fs = require("fs");
const file = process.argv[1];
try {
  const value = JSON.parse(fs.readFileSync(file, "utf8")).OPENAI_API_KEY || "";
  if (value) process.stdout.write(value);
} catch (_) {}
' "$auth_file" 2>/dev/null || true
    return 0
  fi

  if has_cmd python3; then
    python3 - "$auth_file" <<'PY' 2>/dev/null || true
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        value = json.load(f).get("OPENAI_API_KEY", "")
    if value:
        print(value, end="")
except Exception:
    pass
PY
  fi
}

write_auth_json_key() {
  local key="$1"

  if has_cmd node; then
    AUTH_JSON_KEY="$key" node <<'NODE'
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
    return 0
  fi

  if has_cmd python3; then
    AUTH_JSON_KEY="$key" python3 <<'PY'
import json
import os
from pathlib import Path

home = Path(os.environ["HOME"])
key = os.environ["AUTH_JSON_KEY"]
codex_dir = home / ".codex"
auth_file = codex_dir / "auth.json"
codex_dir.mkdir(parents=True, exist_ok=True)
auth_file.write_text(json.dumps({"OPENAI_API_KEY": key}, indent=2) + "\n", encoding="utf-8")
auth_file.chmod(0o600)
PY
    return 0
  fi

  local escaped_key
  escaped_key="${key//\\/\\\\}"
  escaped_key="${escaped_key//\"/\\\"}"
  mkdir -p "$HOME/.codex"
  umask 077
  printf '{\n  "OPENAI_API_KEY": "%s"\n}\n' "$escaped_key" > "$HOME/.codex/auth.json"
  chmod 600 "$HOME/.codex/auth.json"
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

ensure_base_dependencies

log "检查 Codex 是否已安装"
if check_codex_installed; then
  log "检测到 Codex 已安装，跳过安装步骤"
  SKIP_INSTALL=true
else
  log "未检测到 Codex，将进行完整安装"
  SKIP_INSTALL=false
fi

if [ "$SKIP_INSTALL" = false ]; then
  log "安装/加载 nvm ${NVM_VERSION}"
  export NVM_DIR="$HOME/.nvm"
  if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 120 "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
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

if codex_npm_entry_exists; then
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
else
  backup_stale_codex_wrapper
  log "Codex 已安装但不是本脚本管理的 nvm/npm 入口，跳过包装脚本覆盖"
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
if has_cmd cc-switch; then
  printf 'ccswitch: '
  cc-switch --version 2>/dev/null || echo "已安装"
fi
printf '配置文件: %s\n' "$HOME/.codex/config.toml"
printf 'Codex 认证文件: %s\n' "$HOME/.codex/auth.json"

cat <<'EOF'

配置完成。

生成的配置文件：
  ~/.codex/config.toml
  ~/.codex/auth.json

注意：API Key 会明文保存在 ~/.codex/auth.json 中，脚本已设置权限为 600。

Ubuntu 版本适配说明：
  - Ubuntu 18.04: Node.js 16
  - Ubuntu 20.04+: Node.js 22
  - Ubuntu 22.04+: 额外安装 CC Switch
EOF
