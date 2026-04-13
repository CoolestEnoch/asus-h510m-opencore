#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
用法:
  sudo ./oc_nvme_entry.sh /dev/nvme0n1p1 '\EFI\refind\refind_x64.efi' [PciRootUID]

示例:
  sudo ./oc_nvme_entry.sh /dev/nvme0n1p1 '\EFI\refind\refind_x64.efi'
  sudo ./oc_nvme_entry.sh /dev/nvme0n1p1 '\EFI\Microsoft\Boot\bootmgfw.efi' 0

说明:
  - 目前这版只处理 NVMe 盘。
  - 第三个参数是可选的 PciRoot UID，默认 0。
  - 输出的是可直接放进 OpenCore Misc -> Entries -> Path 的字符串。
EOF
}

[[ $# -ge 2 ]] || { usage; exit 1; }

PART="$(readlink -f "$1")"
LOADER="$2"
PCI_ROOT_UID="${3:-0}"

[[ -b "$PART" ]] || die "$PART 不是块设备"

# 统一 EFI 路径风格
LOADER="${LOADER//\//\\}"
[[ "$LOADER" == \\* ]] || LOADER="\\$LOADER"

PART_BASENAME="$(basename "$PART")"
DISK_BASENAME="$(lsblk -no PKNAME "$PART" 2>/dev/null || true)"
[[ -n "$DISK_BASENAME" ]] || die "无法解析父磁盘"
DISK="/dev/$DISK_BASENAME"

# 只支持 NVMe
if [[ ! "$DISK_BASENAME" =~ ^nvme[0-9]+n[0-9]+$ ]]; then
  die "这版脚本当前只支持 NVMe，检测到的是: $DISK_BASENAME"
fi

PART_NUM="$(lsblk -no PARTN "$PART" 2>/dev/null || true)"
[[ -n "$PART_NUM" ]] || die "无法读取分区号"

PARTUUID="$(blkid -s PARTUUID -o value "$PART" 2>/dev/null | tr '[:lower:]' '[:upper:]')"
[[ -n "$PARTUUID" ]] || die "无法读取 PARTUUID"

START_SECTORS="$(cat "/sys/class/block/$PART_BASENAME/start" 2>/dev/null || true)"
SIZE_SECTORS="$(cat "/sys/class/block/$PART_BASENAME/size" 2>/dev/null || true)"
[[ "$START_SECTORS" =~ ^[0-9]+$ ]] || die "无法读取分区起始扇区"
[[ "$SIZE_SECTORS" =~ ^[0-9]+$ ]] || die "无法读取分区总扇区数"

hex_u() {
  printf '%x' "$1"
}

hex_from_hexbyte() {
  local x="$1"
  printf '%x' "$((16#$x))"
}

build_pci_chain() {
  local sys_path
  local chain
  local comp
  local dev fn

  # 取真实 sysfs 路径，沿路抓 PCI BDF
  sys_path="$(readlink -f "/sys/class/block/$DISK_BASENAME")"
  chain="PciRoot(0x${PCI_ROOT_UID#0x})"

  IFS='/' read -r -a comps <<< "$sys_path"
  for comp in "${comps[@]}"; do
    if [[ "$comp" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:([0-9a-fA-F]{2})\.([0-7])$ ]]; then
      dev="${BASH_REMATCH[1]}"
      fn="${BASH_REMATCH[2]}"
      chain+="/Pci(0x$(hex_from_hexbyte "$dev"),0x$(hex_from_hexbyte "$fn"))"
    fi
  done

  echo "$chain"
}

get_nsid() {
  local nsid=""

  if command -v nvme >/dev/null 2>&1; then
    nsid="$(nvme get-ns-id "$DISK" 2>/dev/null | awk '/^[0-9]+$/ {print $1; exit}')"
  fi

  if [[ -z "$nsid" && "$DISK_BASENAME" =~ ^nvme[0-9]+n([0-9]+)$ ]]; then
    nsid="${BASH_REMATCH[1]}"
  fi

  [[ "$nsid" =~ ^[0-9]+$ ]] || die "无法确定 NVMe namespace id"
  echo "$nsid"
}

get_eui64() {
  local raw=""
  local pretty=""
  local i

  # 优先用 nvme-cli
  if command -v nvme >/dev/null 2>&1; then
    raw="$(nvme id-ns "$DISK" 2>/dev/null \
      | awk -F: 'BEGIN{IGNORECASE=1}
                 /^[[:space:]]*eui64[[:space:]]*:/ {
                   gsub(/[[:space:]-]/, "", $2);
                   print tolower($2);
                   exit
                 }')"
  fi

  # 某些系统可能在 sysfs 暴露 eui
  if [[ -z "$raw" ]]; then
    for f in "/sys/class/block/$DISK_BASENAME/eui" "/sys/class/block/$PART_BASENAME/eui"; do
      if [[ -r "$f" ]]; then
        raw="$(tr -d '[:space:]-' < "$f" | tr '[:upper:]' '[:lower:]')"
        break
      fi
    done
  fi

  # UEFI 规范要求：没有 EUI-64 时填 0
  if [[ ! "$raw" =~ ^[0-9a-f]{16}$ ]]; then
    raw="0000000000000000"
  fi

  # 按 UEFI 文本显示习惯：byte7 在最左，byte0 在最右
  pretty=""
  for (( i=14; i>=0; i-=2 )); do
    pretty+="${raw:$i:2}"
    [[ $i -gt 0 ]] && pretty+="-"
  done

  echo "${pretty^^}"
}

PCI_CHAIN="$(build_pci_chain)"
NSID="$(get_nsid)"
EUI64="$(get_eui64)"

NVME_NODE="NVMe(0x$(hex_u "$NSID"),${EUI64})"
HD_NODE="HD(${PART_NUM},GPT,${PARTUUID},0x$(hex_u "$START_SECTORS"),0x$(hex_u "$SIZE_SECTORS"))"

FULL_PATH="${PCI_CHAIN}/${NVME_NODE}/${HD_NODE}/${LOADER}"

echo "$FULL_PATH"
