#!/usr/bin/env bash
# Self-contained installer: no remote shell scripts and no firewall resets.
set -euo pipefail
if ! command -v python3 >/dev/null 2>&1; then
  for arg in "$@"; do
    if [[ "$arg" == '--dry-run' || "$arg" == '--help' || "$arg" == '-h' ]]; then
      echo '请先安装 Python 3；检查模式不会自动安装依赖。' >&2
      exit 1
    fi
  done
  if [[ ${EUID} -ne 0 ]] || ! command -v apt-get >/dev/null 2>&1; then
    echo '需要 Debian/Ubuntu、root 权限和 Python 3。' >&2
    exit 1
  fi
  apt-get update
  apt-get install -y python3 ca-certificates
fi
# /dev/tty is used for prompts so the script also works through a pipe.
