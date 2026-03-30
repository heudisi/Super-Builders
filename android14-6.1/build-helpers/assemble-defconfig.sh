#!/bin/bash
set -euo pipefail
set -x  # 🔍 打开调试（CI必备）

FRAGMENT_SRC="${1:?}"
FRAGMENT_DST="${2:?}"
DEFCONFIG="${3:?}"
shift 3

ADD_SUSFS=false
ADD_OVERLAYFS=false
ADD_ZRAM=false
ADD_KPM=false
USE_KLEAF=false

for arg in "$@"; do
  case "$arg" in
    --susfs) ADD_SUSFS=true ;;
    --overlayfs) ADD_OVERLAYFS=true ;;
    --zram) ADD_ZRAM=true ;;
    --kpm) ADD_KPM=true ;;
    --kleaf) USE_KLEAF=true ;;
  esac
done

echo "==== INPUT FILES ===="
echo "FRAGMENT_SRC=$FRAGMENT_SRC"
echo "FRAGMENT_DST=$FRAGMENT_DST"
echo "DEFCONFIG=$DEFCONFIG"

echo "==== ORIGINAL FRAGMENT ===="
cat "$FRAGMENT_SRC" || true

# ----------------------------
# section 提取函数
# ----------------------------
extract_section() {
  awk "/^# \\[$1\\]/{found=1; next} /^# \\[/{found=0} found && NF" "$FRAGMENT_SRC"
}

# ----------------------------
# 生成 fragment
# ----------------------------
> "$FRAGMENT_DST"

extract_section "base" >> "$FRAGMENT_DST" || true
$ADD_SUSFS && extract_section "susfs" >> "$FRAGMENT_DST" || true
$ADD_OVERLAYFS && extract_section "overlayfs" >> "$FRAGMENT_DST" || true
$ADD_ZRAM && extract_section "zram" >> "$FRAGMENT_DST" || true
$ADD_KPM && extract_section "kpm" >> "$FRAGMENT_DST" || true

# ----------------------------
# fallback：没有 section 时直接用整个 fragment
# ----------------------------
if [ ! -s "$FRAGMENT_DST" ]; then
  echo "[WARN] No section detected, fallback to full fragment"
  cp "$FRAGMENT_SRC" "$FRAGMENT_DST"
fi

echo "==== AFTER EXTRACT ===="
cat "$FRAGMENT_DST" || true

# ----------------------------
# 去重 fragment（防止 tac 崩）
# ----------------------------
if [ -s "$FRAGMENT_DST" ]; then
  tac "$FRAGMENT_DST" | awk -F= '/^CONFIG_/{if(seen[$1]++)next} {print}' | tac > "${FRAGMENT_DST}.tmp"
  mv "${FRAGMENT_DST}.tmp" "$FRAGMENT_DST"
fi

# ----------------------------
# Kleaf / Legacy 分支
# ----------------------------
if $USE_KLEAF; then
  echo "[INFO] Using Kleaf mode"

  # =n → "# CONFIG_xxx is not set"
  sed -i 's/^\(CONFIG_[A-Za-z0-9_]*\)=n$/# \1 is not set/' "$FRAGMENT_DST"

else
  echo "[INFO] Using legacy build.sh mode"

  # 处理 =n
  grep '=n$' "$FRAGMENT_DST" >> "$DEFCONFIG" 2>/dev/null || true
  sed -i '/=n$/d' "$FRAGMENT_DST"

  # 合并 fragment
  if [ -s "$FRAGMENT_DST" ]; then
    cat "$FRAGMENT_DST" >> "$DEFCONFIG"
  fi
fi

# ----------------------------
# ZRAM 强制内建
# ----------------------------
if $ADD_ZRAM; then
  sed -i 's/CONFIG_ZRAM=m/CONFIG_ZRAM=y/g' "$DEFCONFIG" 2>/dev/null || true
  sed -i 's/CONFIG_ZSMALLOC=m/CONFIG_ZSMALLOC=y/g' "$DEFCONFIG" 2>/dev/null || true
fi

# ----------------------------
# defconfig 去重（仅 legacy）
# ----------------------------
if ! $USE_KLEAF; then
  if [ -s "$DEFCONFIG" ]; then
    tac "$DEFCONFIG" | awk -F= '/^CONFIG_/{if(seen[$1]++)next} {print}' | tac > "${DEFCONFIG}.tmp"
    mv "${DEFCONFIG}.tmp" "$DEFCONFIG"
  fi
fi

echo "==== FINAL DEFCONFIG ===="
tail -n 50 "$DEFCONFIG" || true

echo "[SUCCESS] Defconfig assembled successfully"