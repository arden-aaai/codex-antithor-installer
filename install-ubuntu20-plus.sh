#!/usr/bin/env bash
# 兼容入口（Ubuntu 20.04+ 用户仍可用这个地址）
#
# 安装逻辑已经统一到 install-unified.sh；需要“不装 CC Switch”时，
# 直接给统一脚本加 --no-ccswitch 即可，这里会原样转发参数。
set -Eeuo pipefail

REPO_SLUG="arden-aaai/codex-antithor-installer"
SCRIPT_URL="https://raw.githubusercontent.com/${REPO_SLUG}/main/install-unified.sh"
TMP_SCRIPT=""

cleanup() {
  [ -n "$TMP_SCRIPT" ] && rm -f "$TMP_SCRIPT"
}

main() {
  TMP_SCRIPT="$(mktemp)"
  trap cleanup EXIT

  printf '\n[%s] 该入口已并入 install-unified.sh，正在获取最新版本...\n' "$(date +'%H:%M:%S')"

  if ! curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 120 \
    "${SCRIPT_URL}?$(date +%s)" -o "$TMP_SCRIPT"; then
    printf '错误: 下载 install-unified.sh 失败，请检查网络或代理后重试。\n' >&2
    exit 1
  fi

  bash "$TMP_SCRIPT" "$@"
}

main "$@"
