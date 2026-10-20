#!/usr/bin/env bash
# Codex CLI + Antithor 中转站一键安装脚本（Ubuntu 18.04 及以上）
#
# 用法:
#   bash install-unified.sh [选项]
#
# 所有默认值都可以用环境变量覆盖，详见 --help。
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# 版本与默认值
# ---------------------------------------------------------------------------
NVM_VERSION="${NVM_VERSION:-v0.40.8}"
NODE_VERSION_UBUNTU20="${NODE_VERSION_UBUNTU20:-24}"
NODE_VERSION_UBUNTU18="${NODE_VERSION_UBUNTU18:-16}"
CODEX_PACKAGE="${CODEX_PACKAGE:-@openai/codex}"
CODEX_VERSION="${CODEX_VERSION:-latest}"
CODEX_MODEL="${CODEX_MODEL:-gpt-6.1-sol}"
CODEX_REASONING_EFFORT="${CODEX_REASONING_EFFORT:-xhigh}"
CODEX_SERVICE_TIER="${CODEX_SERVICE_TIER:-fast}"
CODEX_BASE_URL="${CODEX_BASE_URL:-https://api.antithor.asia/v1}"
PROVIDER_NAME="${PROVIDER_NAME:-custom}"
CCSWITCH_REPO="${CCSWITCH_REPO:-farion1231/cc-switch}"
CCSWITCH_VERSION="${CCSWITCH_VERSION:-latest}"
CCSWITCH_BASE_URL="${CCSWITCH_BASE_URL:-https://github.com/${CCSWITCH_REPO}/releases}"

# 非交互式安装时可直接用 CODEX_API_KEY（或 OPENAI_API_KEY）提供 Key
CODEX_API_KEY="${CODEX_API_KEY:-${OPENAI_API_KEY:-}}"

# auto: 有 sudo/root 就装到 /usr/local/bin；1: 必须装；0: 跳过
INSTALL_GLOBAL_WRAPPER="${INSTALL_GLOBAL_WRAPPER:-auto}"

MANAGED_BLOCK_NAME="codex-antithor-installer"
LEGACY_BLOCK_NAME="codex-antithor-installer-ubuntu20-plus"

FORCE_UPGRADE=false
NO_UPGRADE=false
WANT_CCSWITCH=true
ASSUME_YES=false

# ---------------------------------------------------------------------------
# 基础函数
# ---------------------------------------------------------------------------
log() {
  printf '\n[%s] %s\n' "$(date +'%H:%M:%S')" "$*"
}

warn() {
  printf '\n[%s] 警告: %s\n' "$(date +'%H:%M:%S')" "$*" >&2
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
  elif has_cmd sudo; then
    sudo "$@"
  else
    die "当前用户不是 root，且系统未安装 sudo，无法执行需要管理员权限的命令: $*"
  fi
}

# 判断 $1 是否在版本上大于 $2
version_gt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

# 判断 $1 是否 >= $2
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
    x86_64 | amd64) echo "x86_64" ;;
    aarch64 | arm64) echo "arm64" ;;
    *) die "不支持的架构: $arch" ;;
  esac
}

confirm() {
  local prompt="$1"

  if [ "$ASSUME_YES" = true ] || [ ! -t 0 ]; then
    return 0
  fi

  printf '%s [Y/n] ' "$prompt"
  local reply=""
  IFS= read -r reply || true
  case "$reply" in
    "" | [yY] | [yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

usage() {
  cat <<'EOF'
Codex CLI + Antithor 中转站一键安装脚本（Ubuntu 18.04 及以上）

用法:
  bash install-unified.sh [选项]

选项:
  -u, --upgrade       即使已是最新，也强制重新安装/升级 Codex CLI
      --no-upgrade    跳过版本检查，不改动已安装的 Codex CLI
      --no-ccswitch   不安装 CC Switch（Ubuntu 22.04+ 默认安装）
  -y, --yes           所有确认都按“是”处理
  -h, --help          显示本帮助

环境变量:
  CODEX_MODEL             模型，默认 gpt-6.1-sol
  CODEX_REASONING_EFFORT  推理强度，默认 xhigh（留空则不写入）
  CODEX_SERVICE_TIER      服务等级，默认 fast（留空则不写入）
  CODEX_BASE_URL          中转站地址，默认 https://api.antithor.asia/v1
  CODEX_VERSION           Codex CLI 版本，默认 latest
  CODEX_API_KEY           API Key；不设置则交互式输入（也可用 OPENAI_API_KEY）
  NODE_VERSION            Node.js 版本；默认 Ubuntu 18.04 用 16，其余用 24
  NVM_VERSION             nvm 版本，默认 v0.40.8
  CCSWITCH_VERSION        CC Switch 版本，默认 latest
  INSTALL_GLOBAL_WRAPPER  auto|1|0，是否安装 /usr/local/bin/codex，默认 auto

示例:
  CODEX_MODEL=gpt-6-astra bash install-unified.sh
  CODEX_BASE_URL=https://example.com/v1 bash install-unified.sh -y
  CODEX_API_KEY=sk-xxx bash install-unified.sh --no-ccswitch
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      -u | --upgrade)
        FORCE_UPGRADE=true
        ;;
      --no-upgrade)
        NO_UPGRADE=true
        ;;
      --no-ccswitch)
        WANT_CCSWITCH=false
        ;;
      -y | --yes)
        ASSUME_YES=true
        ;;
      *)
        die "未知参数: $1（用 --help 查看用法）"
        ;;
    esac
    shift
  done
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

# ---------------------------------------------------------------------------
# 系统与依赖
# ---------------------------------------------------------------------------
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
      warn "DNS 无法解析 apt 源地址: $host（如果 apt-get 失败，先检查 /etc/resolv.conf 或容器网络）"
    fi
  done <<< "$hosts"
}

ensure_base_dependencies() {
  local missing=()
  local cmd

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

# ---------------------------------------------------------------------------
# nvm / Node.js
# ---------------------------------------------------------------------------
load_nvm_if_present() {
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  if [ -s "$NVM_DIR/nvm.sh" ]; then
    # shellcheck source=/dev/null
    . "$NVM_DIR/nvm.sh"
    return 0
  fi
  return 1
}

ensure_nvm() {
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

  if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    log "安装 nvm ${NVM_VERSION}"
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 120 \
      "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
  fi

  [ -s "$NVM_DIR/nvm.sh" ] || die "nvm 安装失败，未找到 $NVM_DIR/nvm.sh"
  # shellcheck source=/dev/null
  . "$NVM_DIR/nvm.sh"
}

ensure_node() {
  local node_version="$1"

  ensure_nvm

  log "安装/切换到 Node.js ${node_version}"
  nvm install "$node_version"
  nvm alias default "$node_version" >/dev/null
  nvm use "$node_version" >/dev/null
}

# ---------------------------------------------------------------------------
# Codex CLI 检测与安装
# ---------------------------------------------------------------------------
codex_version() {
  local out=""
  out="$(codex --version 2>/dev/null || true)"
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | awk '{print $NF}'
}

latest_codex_version() {
  has_cmd npm || return 1
  npm view "${CODEX_PACKAGE}" version 2>/dev/null | tail -n 1
}

install_codex_cli() {
  local spec="${CODEX_PACKAGE}@${CODEX_VERSION}"

  log "安装 Codex CLI: ${spec}"
  if ! npm install -g --no-fund --no-audit "$spec"; then
    warn "常规安装失败，使用 --force 重试"
    npm install -g --force --no-fund --no-audit "$spec"
  fi

  local entry
  entry="$(npm root -g)/@openai/codex/bin/codex.js"
  if [ ! -f "$entry" ]; then
    die "Codex CLI 安装失败，未找到入口文件: $entry"
  fi

  hash -r 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# CC Switch（可选，Ubuntu 22.04+）
# ---------------------------------------------------------------------------
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

  warn "GitHub latest 重定向查询失败: ${CCSWITCH_BASE_URL}/latest"
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
  warn "${label} 下载失败，curl 退出码 ${status}: $url"
  log_error_excerpt "$err_file"
  rm -f "$err_file"
  return "$status"
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

install_ccswitch() {
  local arch="$1"
  local version
  version="$(normalize_version "$2")"

  log "Ubuntu 22.04+：准备安装 CC Switch"

  if has_cmd cc-switch; then
    log "CC Switch 已安装，跳过"
    create_ccswitch_desktop_shortcut || true
    return 0
  fi

  if [ "$(id -u)" -ne 0 ] && ! has_cmd sudo; then
    warn "当前用户不是 root 且未安装 sudo，跳过 CC Switch 安装"
    return 0
  fi

  local deb_file=""
  local latest_url=""
  local latest_json=""
  local latest_tag=""
  local latest_err=""
  local download_url=""

  if [ "$version" = "latest" ]; then
    log "获取 CC Switch 最新版本"
    latest_err="$(mktemp)"

    if latest_json="$(curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60 \
      "https://api.github.com/repos/${CCSWITCH_REPO}/releases/latest" 2>"$latest_err")"; then
      latest_url="$(extract_ccswitch_download_url "$latest_json" "$arch")"
      latest_tag="$(extract_ccswitch_tag "$latest_json")"
      if [ -z "$latest_url" ] && [ -n "$latest_tag" ]; then
        warn "GitHub API 返回 $latest_tag，但没有匹配的 Linux-${arch}.deb，尝试拼接下载地址"
        latest_url="$(ccswitch_download_url_for_version "$arch" "$latest_tag")"
      fi
    else
      warn "GitHub API 请求失败: ${CCSWITCH_REPO}/releases/latest"
      log_error_excerpt "$latest_err"
    fi
    rm -f "$latest_err"

    if [ -z "$latest_url" ]; then
      latest_tag="$(resolve_ccswitch_latest_tag_from_redirect)"
      if [ -n "$latest_tag" ]; then
        latest_url="$(ccswitch_download_url_for_version "$arch" "$latest_tag")"
        log "回退方案：从 release 重定向解析到版本 $latest_tag"
      fi
    fi

    if [ -z "$latest_url" ]; then
      warn "无法解析 CC Switch 下载地址，跳过安装（不影响 Codex CLI）"
      log "  可手动指定版本重试: CCSWITCH_VERSION=4.0.16 bash install-unified.sh"
      return 0
    fi

    deb_file="/tmp/ccswitch_${arch}.deb"
    if ! download_file_with_diagnostics "$latest_url" "$deb_file" "CC Switch"; then
      warn "CC Switch 下载失败，跳过安装"
      rm -f "$deb_file"
      return 0
    fi
  else
    deb_file="/tmp/$(ccswitch_asset_name "$arch" "$version")"
    download_url="$(ccswitch_download_url_for_version "$arch" "$version")"
    log "下载 CC Switch: $download_url"
    if ! download_file_with_diagnostics "$download_url" "$deb_file" "CC Switch"; then
      warn "CC Switch 下载失败，跳过安装"
      rm -f "$deb_file"
      return 0
    fi
  fi

  if [ ! -s "$deb_file" ]; then
    warn "CC Switch 安装包为空，跳过安装"
    rm -f "$deb_file"
    return 0
  fi

  log "安装 CC Switch"
  if ! sudo_if_needed apt-get install -y "$deb_file"; then
    warn "apt 安装 CC Switch 失败，尝试修复依赖"
    sudo_if_needed apt-get install -f -y || true
  fi
  rm -f "$deb_file"

  if has_cmd cc-switch; then
    log "CC Switch 安装成功: $(cc-switch --version 2>/dev/null || echo '已安装')"
    create_ccswitch_desktop_shortcut || true
  else
    warn "CC Switch 安装后未找到 cc-switch 命令"
  fi
}

# ---------------------------------------------------------------------------
# 配置写入
# ---------------------------------------------------------------------------
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

remove_managed_block() {
  local file="$1"
  local start_marker="$2"
  local end_marker="$3"

  [ -f "$file" ] || return 0
  grep -qF "$start_marker" "$file" 2>/dev/null || return 0

  local tmp_file
  tmp_file="$(mktemp)"
  awk -v start="$start_marker" -v end="$end_marker" '
    $0 == start { skip = 1; next }
    $0 == end { skip = 0; next }
    !skip { print }
  ' "$file" > "$tmp_file"

  cat "$tmp_file" > "$file"
  rm -f "$tmp_file"
}

read_auth_json_key() {
  local auth_file="$HOME/.codex/auth.json"
  [ -f "$auth_file" ] || return 0

  if has_cmd node; then
    node -e '
const fs = require("fs");
try {
  const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).OPENAI_API_KEY || "";
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
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        value = json.load(handle).get("OPENAI_API_KEY", "")
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
if (!home || !key) process.exit(1);

const codexDir = path.join(home, ".codex");
const authFile = path.join(codexDir, "auth.json");
fs.mkdirSync(codexDir, { recursive: true });
fs.writeFileSync(
  authFile,
  JSON.stringify({ auth_mode: "apikey", OPENAI_API_KEY: key }, null, 2) + "\n",
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
payload = {"auth_mode": "apikey", "OPENAI_API_KEY": key}
auth_file.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
auth_file.chmod(0o600)
PY
    return 0
  fi

  # 没有 node / python3 时退回纯 shell 写入（Key 里的反斜杠和引号需要转义）
  local escaped_key
  escaped_key="${key//\\/\\\\}"
  escaped_key="${escaped_key//\"/\\\"}"
  mkdir -p "$HOME/.codex"
  umask 077
  printf '{\n  "auth_mode": "apikey",\n  "OPENAI_API_KEY": "%s"\n}\n' "$escaped_key" \
    > "$HOME/.codex/auth.json"
  chmod 600 "$HOME/.codex/auth.json"
}

write_codex_config() {
  local config_file="$HOME/.codex/config.toml"

  mkdir -p "$HOME/.codex"
  if [ -f "$config_file" ]; then
    cp "$config_file" "$config_file.bak-$(date +'%Y%m%d-%H%M%S')"
  fi

  # 说明：新版 Codex 对自定义 provider 只有在 requires_openai_auth = true 时
  # 才会把 ~/.codex/auth.json 里的 OPENAI_API_KEY 作为 Bearer 发出去。
  # disable_response_storage 已在 0.16x 起被移除，写入会触发 unrecognized 警告。
  {
    printf 'model_provider = "%s"\n' "$PROVIDER_NAME"
    printf 'model = "%s"\n' "$CODEX_MODEL"
    if [ -n "$CODEX_REASONING_EFFORT" ]; then
      printf 'model_reasoning_effort = "%s"\n' "$CODEX_REASONING_EFFORT"
    fi
    if [ -n "$CODEX_SERVICE_TIER" ]; then
      printf 'service_tier = "%s"\n' "$CODEX_SERVICE_TIER"
    fi
    printf '\n[model_providers.%s]\n' "$PROVIDER_NAME"
    printf 'name = "%s"\n' "$PROVIDER_NAME"
    printf 'wire_api = "responses"\n'
    printf 'requires_openai_auth = true\n'
    printf 'base_url = "%s"\n' "$CODEX_BASE_URL"
  } > "$config_file"

  chmod 600 "$config_file"
}

configure_shell_paths() {
  log "配置 Codex 命令，让登录 shell 和非交互 SSH 都能找到"

  local shell_block
  shell_block="$(mktemp)"
  cat > "$shell_block" <<'EOF'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"
EOF

  local start_marker="# >>> ${MANAGED_BLOCK_NAME} >>>"
  local end_marker="# <<< ${MANAGED_BLOCK_NAME} <<<"
  local legacy_start="# >>> ${LEGACY_BLOCK_NAME} >>>"
  local legacy_end="# <<< ${LEGACY_BLOCK_NAME} <<<"

  # 老版本脚本用的是 ...-ubuntu20-plus 标记，先清掉避免重复加载 nvm
  remove_managed_block "$HOME/.profile" "$legacy_start" "$legacy_end"
  remove_managed_block "$HOME/.bashrc" "$legacy_start" "$legacy_end"

  upsert_managed_block "$HOME/.profile" "$start_marker" "$end_marker" "$shell_block"
  upsert_managed_block "$HOME/.bashrc" "$start_marker" "$end_marker" "$shell_block"
  rm -f "$shell_block"
}

write_codex_wrapper() {
  local npm_entry="$1"

  if [ ! -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]; then
    log "未找到 nvm，跳过 ~/.local/bin/codex 包装脚本（保留现有的 codex 命令）"
    return 0
  fi

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

  log "已写入包装脚本: $HOME/.local/bin/codex"

  case "$INSTALL_GLOBAL_WRAPPER" in
    0 | false | no)
      log "按 INSTALL_GLOBAL_WRAPPER=$INSTALL_GLOBAL_WRAPPER 跳过 /usr/local/bin/codex"
      ;;
    1 | true | yes)
      log "安装 /usr/local/bin/codex 包装脚本"
      sudo_if_needed install -m 0755 "$HOME/.local/bin/codex" /usr/local/bin/codex
      ;;
    *)
      if has_cmd sudo || [ "$(id -u)" -eq 0 ]; then
        log "安装 /usr/local/bin/codex 包装脚本（方便 Codex Desktop 远程 SSH 检测）"
        sudo_if_needed install -m 0755 "$HOME/.local/bin/codex" /usr/local/bin/codex
      else
        log "未找到 sudo；仅保留 $HOME/.local/bin/codex"
      fi
      ;;
  esac

  # 兜底：如果 npm 入口不在，但已有别的 codex，就别覆盖用户原有的命令
  if [ ! -f "$npm_entry" ]; then
    warn "未找到 npm 入口 $npm_entry，包装脚本可能无法运行"
  fi
}

# 结果写入全局变量 API_KEY_VALUE（不能把提示信息混进命令替换）
resolve_api_key() {
  local existing="$1"
  local value=""

  if [ -n "$CODEX_API_KEY" ]; then
    log "使用环境变量中提供的 API Key"
    API_KEY_VALUE="$CODEX_API_KEY"
    return 0
  fi

  if [ -n "$existing" ] && [ ! -t 0 ]; then
    API_KEY_VALUE="$existing"
    return 0
  fi

  if [ -n "$existing" ]; then
    printf '\n检测到已有 API Key。\n直接回车保留旧 Key；输入新 Key 则覆盖。输入时不会显示：\n> ' >&2
    IFS= read -r -s value || true
    printf '\n' >&2
    [ -n "$value" ] || value="$existing"
  else
    if [ ! -t 0 ]; then
      die "当前不是交互式终端，且未提供 CODEX_API_KEY。请用 CODEX_API_KEY=sk-xxx bash install-unified.sh"
    fi
    printf '\n请输入 API Key，然后回车。输入时不会显示，这是正常的：\n> ' >&2
    IFS= read -r -s value || true
    printf '\n' >&2
  fi

  API_KEY_VALUE="$value"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
parse_args "$@"

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

# Ubuntu 18.04 用 Node 16，20.04+ 用 Node 24（当前 LTS）
if version_ge "$UBUNTU_VERSION" "20.04"; then
  DEFAULT_NODE_VERSION="$NODE_VERSION_UBUNTU20"
else
  DEFAULT_NODE_VERSION="$NODE_VERSION_UBUNTU18"
fi
NODE_VERSION="${NODE_VERSION:-$DEFAULT_NODE_VERSION}"
log "Node.js 版本: ${NODE_VERSION}"

case "$(uname -m)" in
  x86_64 | aarch64 | arm64 | amd64) ;;
  *) die "不支持的系统架构: $(uname -m)" ;;
esac

ensure_base_dependencies

# 已安装的 Codex（可能来自 nvm，需要先加载）
load_nvm_if_present || true
INSTALLED_VERSION="$(codex_version || true)"

NEED_INSTALL=false
if [ "$NO_UPGRADE" = true ] && [ -n "$INSTALLED_VERSION" ]; then
  log "按 --no-upgrade 跳过 Codex CLI 安装/升级（当前 ${INSTALLED_VERSION}）"
elif [ -z "$INSTALLED_VERSION" ]; then
  log "未检测到 Codex CLI，开始安装"
  NEED_INSTALL=true
elif [ "$FORCE_UPGRADE" = true ]; then
  log "按 --upgrade 强制重装 Codex CLI（当前 ${INSTALLED_VERSION}）"
  NEED_INSTALL=true
else
  log "检测到 Codex CLI ${INSTALLED_VERSION}"
  if [ "$CODEX_VERSION" != "latest" ]; then
    TARGET_VERSION="$(normalize_version "$CODEX_VERSION")"
    if [ "$INSTALLED_VERSION" = "$TARGET_VERSION" ]; then
      log "已是指定版本 ${TARGET_VERSION}，跳过升级"
    else
      log "将切换到指定版本 ${TARGET_VERSION}"
      NEED_INSTALL=true
    fi
  elif LATEST_VERSION="$(latest_codex_version)" && [ -n "$LATEST_VERSION" ]; then
    if version_gt "$LATEST_VERSION" "$INSTALLED_VERSION"; then
      log "发现新版本: ${INSTALLED_VERSION} -> ${LATEST_VERSION}"
      if confirm "是否升级 Codex CLI 到 ${LATEST_VERSION}？"; then
        NEED_INSTALL=true
      else
        log "已跳过升级（当前 ${INSTALLED_VERSION}）"
      fi
    else
      log "已是最新版本 ${INSTALLED_VERSION}"
    fi
  else
    log "无法查询最新版本（缺少 npm 或网络不可用），跳过升级检查"
    log "  如需强制重装: bash install-unified.sh --upgrade"
  fi
fi

if [ "$NEED_INSTALL" = true ]; then
  ensure_node "$NODE_VERSION"
  install_codex_cli
  INSTALLED_VERSION="$(codex_version || true)"
  [ -n "$INSTALLED_VERSION" ] || die "Codex CLI 安装后无法执行 codex --version，请检查 Node.js 环境"
  log "Codex CLI 版本: ${INSTALLED_VERSION}"
else
  load_nvm_if_present || true
fi

if [ "$WANT_CCSWITCH" = true ] && version_ge "$UBUNTU_VERSION" "22.04"; then
  install_ccswitch "$ARCH" "$CCSWITCH_VERSION"
fi

mkdir -p "$HOME/.codex"

EXISTING_API_KEY="$(read_auth_json_key)"
API_KEY_VALUE=""
resolve_api_key "$EXISTING_API_KEY"

if [ -z "$API_KEY_VALUE" ]; then
  die "API Key 不能为空。"
fi

log "写入 Codex 认证文件 ~/.codex/auth.json"
if [ -f "$HOME/.codex/auth.json" ]; then
  cp "$HOME/.codex/auth.json" "$HOME/.codex/auth.json.bak-$(date +'%Y%m%d-%H%M%S')"
fi
write_auth_json_key "$API_KEY_VALUE"

log "写入 Codex 配置 ~/.codex/config.toml"
write_codex_config

configure_shell_paths

NPM_ENTRY=""
if has_cmd npm; then
  NPM_ENTRY="$(npm root -g 2>/dev/null)/@openai/codex/bin/codex.js"
fi

if [ -n "$NPM_ENTRY" ] && [ -f "$NPM_ENTRY" ]; then
  write_codex_wrapper "$NPM_ENTRY"
else
  log "当前没有 npm 版 Codex 入口，跳过包装脚本（已安装的 codex 保持原样）"
fi

log "配置完成检查"
printf 'Ubuntu: %s\n' "$UBUNTU_VERSION"
printf '架构: %s\n' "$ARCH"
printf '模型: %s\n' "$CODEX_MODEL"
printf '中转站: %s\n' "$CODEX_BASE_URL"
if has_cmd node; then
  printf 'node: '
  node -v
fi
if has_cmd npm; then
  printf 'npm: '
  npm -v
fi
for candidate in "$HOME/.local/bin/codex" "/usr/local/bin/codex"; do
  if [ -x "$candidate" ]; then
    printf 'codex: %s (%s)\n' "$candidate" "$("$candidate" --version 2>/dev/null || echo '无法执行')"
    break
  fi
done
if has_cmd cc-switch; then
  printf 'cc-switch: '
  cc-switch --version 2>/dev/null || echo '已安装'
fi
printf '配置文件: %s\n' "$HOME/.codex/config.toml"
printf '认证文件: %s\n' "$HOME/.codex/auth.json"

cat <<'EOF'

配置完成。

生成的配置文件：
  ~/.codex/config.toml
  ~/.codex/auth.json

注意：API Key 会明文保存在 ~/.codex/auth.json 中，脚本已设置权限为 600。

验证安装：
  hash -r
  codex --version
  codex exec --skip-git-repo-check "hello"
EOF

