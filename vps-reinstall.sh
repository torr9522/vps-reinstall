#!/bin/bash

set -euo pipefail

SCRIPT_NAME="vps-reinstall.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_OWNER="${VPS_REINSTALL_REPO_OWNER:-torr9522}"
REPO_NAME="${VPS_REINSTALL_REPO_NAME:-vps-reinstall}"
REPO_REF="${VPS_REINSTALL_REPO_REF:-vps-reinstall}"
RAW_BASE_URL="${VPS_REINSTALL_RAW_BASE_URL:-https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/$REPO_REF}"
REINSTALL_ENTRY="${VPS_REINSTALL_ENTRY:-$SCRIPT_DIR/vps-reinstall/reinstall.sh}"
DEFAULT_PASSWORD="${VPS_REINSTALL_DEFAULT_PASSWORD:-Dx@Debian.dx}"
WINDOWS_10_LTSC_2021_ISO="${VPS_REINSTALL_WINDOWS_10_LTSC_2021_ISO:-https://dlink.host/1drv/aHR0cHM6Ly8xZHJ2Lm1zL3UvYy8wYzMzNDNiZTA3ZWJmNTA4L0lRQjRQWklJbXlJaVNMdHdEbzJhbnRnbUFiQzJLdkJzUThFZjlUVER4aEx4dXFJ.iso}"

KERNEL_INFO=""
ARCH_INFO=""
ROOT_FS=""
ROOT_SOURCE=""
ROOT_DISK=""
LSBLK_SUMMARY=""
FINDMNT_SUMMARY=""
TARGET_OS=""
TARGET_VER=""
TARGET_LABEL=""
TARGET_LOG_TO_REINSTALL="0"
BOOTSTRAP_DIR=""

print_line() {
  printf '%s\n' "${1:-}"
}

warn() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*" >&2
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

fetch_file() {
  local url="$1"
  local output="$2"

  if command_exists curl; then
    curl -fsSL "$url" -o "$output"
    return
  fi

  if command_exists wget; then
    wget -qO "$output" "$url"
    return
  fi

  warn "neither curl nor wget is available"
  exit 1
}

safe_uname() {
  uname "$1" 2>/dev/null || printf 'unknown'
}

detect_root_source() {
  local source=""

  if command_exists findmnt; then
    source="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  fi

  if [ -z "$source" ] && command_exists mount; then
    source="$(mount | awk '$3=="/" {print $1; exit}' 2>/dev/null || true)"
  fi

  if [ -n "$source" ] && [ -e "$source" ]; then
    readlink -f "$source" 2>/dev/null || printf '%s' "$source"
  else
    printf '%s' "${source:-unknown}"
  fi
}

resolve_root_disk() {
  local source="$1"
  local pkname=""

  case "$source" in
    /dev/nvme*n*p[0-9]*)
      printf '%s' "${source%p[0-9]*}"
      return
      ;;
    /dev/mmcblk*p[0-9]*)
      printf '%s' "${source%p[0-9]*}"
      return
      ;;
    /dev/vd[a-z][0-9]*|/dev/sd[a-z][0-9]*|/dev/xvd[a-z][0-9]*)
      printf '%s' "${source%%[0-9]*}"
      return
      ;;
    /dev/vd[a-z]|/dev/sd[a-z]|/dev/xvd[a-z]|/dev/nvme[0-9]n[0-9]|/dev/mmcblk[0-9])
      printf '%s' "$source"
      return
      ;;
  esac

  if command_exists lsblk; then
    pkname="$(lsblk -ndo PKNAME "$source" 2>/dev/null | head -n1 || true)"
    if [ -n "$pkname" ]; then
      printf '/dev/%s' "$pkname"
      return
    fi
  fi

  printf 'unknown'
}

build_lsblk_summary() {
  if ! command_exists lsblk; then
    printf 'lsblk not available'
    return
  fi

  lsblk -rno NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT 2>/dev/null |
    awk '
      NR <= 8 {
        gsub(/[[:space:]]+$/, "", $0)
        print
      }
    ' |
    sed 's/[[:space:]]\+/ /g' || true
}

build_findmnt_summary() {
  if ! command_exists findmnt; then
    printf 'findmnt not available'
    return
  fi

  findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS / /boot /boot/efi 2>/dev/null |
    sed 's/[[:space:]]\+/ /g' || true
}

detect_system_info() {
  KERNEL_INFO="$(safe_uname -r)"
  ARCH_INFO="$(safe_uname -m)"

  if command_exists findmnt; then
    ROOT_FS="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"
  fi
  ROOT_FS="${ROOT_FS:-unknown}"

  ROOT_SOURCE="$(detect_root_source)"
  ROOT_DISK="$(resolve_root_disk "$ROOT_SOURCE")"
  LSBLK_SUMMARY="$(build_lsblk_summary)"
  FINDMNT_SUMMARY="$(build_findmnt_summary)"
}

show_menu() {
  cat <<EOF
========================
 一键重装系统菜单
========================

系统信息检测：
- 内核：$KERNEL_INFO
- 架构：$ARCH_INFO
- 根文件系统：$ROOT_FS
- 根磁盘：$ROOT_DISK

------------------------

1) Debian 11
2) Debian 12
3) Debian 13

4) Ubuntu 20.04
5) Ubuntu 22.04
6) Ubuntu 24.04

7) Windows Server 2022
8) Windows 10 LTSC 2021

9) 退出

------------------------

请选择系统 [1-9]:
EOF
  print_line
}

select_target() {
  local choice=""

  TARGET_LOG_TO_REINSTALL="0"

  while true; do
    read -r choice
    choice="$(trim "$choice")"

    case "$choice" in
      1) TARGET_OS="debian"; TARGET_VER="11"; TARGET_LABEL="Debian 11"; break ;;
      2) TARGET_OS="debian"; TARGET_VER="12"; TARGET_LABEL="Debian 12"; break ;;
      3) TARGET_OS="debian"; TARGET_VER="13"; TARGET_LABEL="Debian 13"; break ;;
      4) TARGET_OS="ubuntu"; TARGET_VER="20.04"; TARGET_LABEL="Ubuntu 20.04"; break ;;
      5) TARGET_OS="ubuntu"; TARGET_VER="22.04"; TARGET_LABEL="Ubuntu 22.04"; break ;;
      6) TARGET_OS="ubuntu"; TARGET_VER="24.04"; TARGET_LABEL="Ubuntu 24.04"; break ;;
      7) TARGET_OS="windows"; TARGET_VER="2022"; TARGET_LABEL="Windows Server 2022"; break ;;
      8) TARGET_OS="windows"; TARGET_VER="10-ltsc-2021"; TARGET_LABEL="Windows 10 LTSC 2021"; TARGET_LOG_TO_REINSTALL="1"; break ;;
      9)
        print_line "Exit"
        exit 0
        ;;
      *)
        warn "invalid selection: ${choice:-<empty>}"
        ;;
    esac
  done
}

ensure_reinstall_entry() {
  local remote_entry_url=""

  if [ -f "$REINSTALL_ENTRY" ]; then
    return
  fi

  remote_entry_url="$RAW_BASE_URL/vps-reinstall/reinstall.sh"
  BOOTSTRAP_DIR="$(mktemp -d /tmp/vps-reinstall.XXXXXX)"
  REINSTALL_ENTRY="$BOOTSTRAP_DIR/reinstall.sh"

  warn "reinstall entry not found locally, bootstrapping from: $remote_entry_url"
  fetch_file "$remote_entry_url" "$REINSTALL_ENTRY"
  chmod 700 "$REINSTALL_ENTRY"

  if [ ! -s "$REINSTALL_ENTRY" ]; then
    warn "failed to bootstrap reinstall entry: $remote_entry_url"
    exit 1
  fi
}

dispatch_reinstall() {
  local -a cmd=()

  print_line
  print_line "[系统选择]"
  print_line "- OS: $TARGET_OS"
  print_line "- Version: $TARGET_VER"
  print_line
  print_line "[调用reinstall核心逻辑]"
  print_line

  case "$TARGET_OS:$TARGET_VER" in
    debian:10)
      cmd=(bash "$REINSTALL_ENTRY" "$TARGET_OS" "$TARGET_VER" --ci --password "$DEFAULT_PASSWORD")
      ;;
    debian:11|debian:12|debian:13|ubuntu:20.04|ubuntu:22.04|ubuntu:24.04)
      cmd=(bash "$REINSTALL_ENTRY" "$TARGET_OS" "$TARGET_VER" --password "$DEFAULT_PASSWORD")
      ;;
    windows:2022)
      cmd=(bash "$REINSTALL_ENTRY" windows --image-name "Windows Server 2022 SERVERDATACENTER" --password "$DEFAULT_PASSWORD")
      ;;
    windows:10-ltsc-2021)
      cmd=(bash "$REINSTALL_ENTRY" windows --image-name "Windows 10 Enterprise LTSC 2021" --lang zh-cn --iso "$WINDOWS_10_LTSC_2021_ISO" --password "$DEFAULT_PASSWORD")
      ;;
    *)
      warn "unsupported selection mapping: $TARGET_OS $TARGET_VER"
      exit 1
      ;;
  esac

  if [ "$TARGET_LOG_TO_REINSTALL" = "1" ]; then
    "${cmd[@]}" 2>&1 | tee -a /reinstall.log
  else
    "${cmd[@]}"
  fi
}

main() {
  detect_system_info
  ensure_reinstall_entry
  show_menu
  select_target
  dispatch_reinstall
}

main "$@"
