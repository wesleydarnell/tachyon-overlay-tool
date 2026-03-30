#!/bin/bash
set -euo pipefail

if [ "${DEBUG:-}" = "true" ]; then
  set -x
fi

usage() {
  echo "Usage: $0 -f <filesystem> -s <stack> -r <resources> -d <debug> [-e <env_list>] [-E <efi_image>] [-O <overlay_root>] [-U <userdata_image>]"
  echo "  -f <filesystem>: Path to the EXT4 system/root filesystem image to modify (raw EXT4 or Android sparse)."
  echo "  -r <resources> : Path to extra resources directory."
  echo "  -s <stack>     : Stack name of the overlay stack to apply."
  echo "  -d <debug>     : true | false | chroot — Debug mode (optional)."
  echo "  -e <env_list>  : Comma-separated list of KEY=VALUE pairs to export (optional)."
  echo "  -E <efi_image> : OPTIONAL path to a FAT EFI image to mount at /boot/efi (24.04 flow)."
  echo "  -O <overlay_root>: OPTIONAL path to overlay root (parent dir of 'overlays/' and 'stacks/')."
  echo "                     Defaults to /tmp/work/input."
  echo "  -U <userdata_image>: OPTIONAL path to the raw ext4 userdata image file."
  echo "                       Mounted at /mnt/userdata inside the chroot so overlays can modify it."
  exit 1
}

# --- Parse args ---------------------------------------------------------------
DEBUG="false"
FILESYSTEM=""
RESOURCES=""
STACK=""
EFI_IMG=""
OVERLAY_ROOT="/tmp/work/input"   # NEW: default for Docker flow
VENDOR_IMG=""
USERDATA_IMG=""
ENV_LIST="${ENV_LIST:-}"

while getopts ":f:r:d:s:e:E:O:V:U:" opt; do
  case $opt in
    f) FILESYSTEM="$OPTARG" ;;
    r) RESOURCES="$OPTARG" ;;
    d) DEBUG="$OPTARG" ;;
    s) STACK="$OPTARG" ;;
    e) ENV_LIST="$OPTARG" ;;
    E) EFI_IMG="$OPTARG" ;;
    O) OVERLAY_ROOT="$OPTARG" ;;  # NEW
    V) VENDOR_IMG="$OPTARG" ;;
    U) USERDATA_IMG="$OPTARG" ;;
    *) usage ;;
  esac
done

# ENV_LIST contains "KEY=VAL,KEY2=VAL2,..."
if [ -n "${ENV_LIST:-}" ]; then
  OLDIFS="$IFS"; IFS=',' 
  for kv in $ENV_LIST; do 
    kv="$(echo "$kv" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"   # trim
    [ -n "$kv" ] && export "$kv"
  done
  IFS="$OLDIFS"
fi

[ -n "${FILESYSTEM:-}" ] && [ -n "${STACK:-}" ] && [ -n "${RESOURCES:-}" ] || usage
[ -f "$FILESYSTEM" ] || { echo "Error: Filesystem '$FILESYSTEM' does not exist." >&2; exit 1; }
if [ -n "$EFI_IMG" ] && [ ! -f "$EFI_IMG" ]; then
  echo "Error: EFI image '$EFI_IMG' does not exist." >&2
  ls -al "$EFI_IMG" || true
  exit 1
fi

if [ -n "$VENDOR_IMG" ] && [ ! -f "$VENDOR_IMG" ]; then
  echo "Error: vendor image '$VENDOR_IMG' does not exist." >&2
  ls -al "$VENDOR_IMG" || true
  exit 1
fi

if [ -n "$USERDATA_IMG" ] && [ ! -f "$USERDATA_IMG" ]; then
  echo "Error: userdata image '$USERDATA_IMG' does not exist." >&2
  exit 1
fi

# resolve overlay.py relative to this script (works in/out of Docker)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY_CLI="${OVERLAY_CLI:-$SCRIPT_DIR/overlay.py}"
if [ ! -f "$OVERLAY_CLI" ]; then
  # Fallback to CWD if someone runs from repo root
  if [ -f "./overlay.py" ]; then
    OVERLAY_CLI="./overlay.py"
  else
    echo "Error: overlay.py not found at '$OVERLAY_CLI' or './overlay.py'." >&2
    exit 1
  fi
fi

# Optional sanity: ensure OVERLAY_ROOT has overlays/ and stacks/ (warn only)
if [ ! -d "$OVERLAY_ROOT/overlays" ] || [ ! -d "$OVERLAY_ROOT/stacks" ]; then
  echo "Warning: OVERLAY_ROOT ($OVERLAY_ROOT) may be missing 'overlays/' or 'stacks/'." >&2
fi

# --- Safe defaults / PATH -----------------------------------------------------
# Use a fast, container-local scratch by default (overridable)
TMP_DIR="${TMP_DIR:-/var/tmp/tachyon_overlay}"   # was /tmp/work (bind mount; slow on Docker for Mac)
MOUNT_POINT="/mnt/tachyon"
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
mkdir -p "$TMP_DIR"

# Locate sparse-image tools (android-sdk-libsparse-utils)
SIMG2IMG="$(command -v simg2img 2>/dev/null || true)"
IMG2SIMG="$(command -v img2simg 2>/dev/null || true)"

# --- Print args ---------------------------------------------------------------
echo "==> process-release"
echo "    FILESYSTEM: $FILESYSTEM"
echo "    RESOURCES : $RESOURCES"
echo "    STACK     : $STACK"
echo "    DEBUG     : ${DEBUG:-auto}"
echo "    ENV_LIST  : ${ENV_LIST:-}"
echo "    EFI_IMG   : ${EFI_IMG:-<none>}"
echo "    VENDOR_IMG: ${VENDOR_IMG:-<none>}"
echo "    USERDATA  : ${USERDATA_IMG:-<none>}"
echo "    OVERLAYS  : ${OVERLAY_ROOT}"

# --- Helpers ------------------------------------------------------------------
RESOLV_BIND_TARGET=""

USERDATA_MNT="/mnt/userdata"
USERDATA_RAW=""

prepare_userdata() {
  # Copy userdata image for modification via debugfs (no mount needed).
  [ -z "$USERDATA_IMG" ] && return 0

  USERDATA_RAW="${TMP_DIR}/userdata.raw"
  echo "==> Copying userdata image for modification ..."
  echo "    Source: $USERDATA_IMG"
  cp "$USERDATA_IMG" "$USERDATA_RAW"
  echo "==> Userdata ready ($(stat -c%s "$USERDATA_RAW") bytes)."
}

mount_userdata() {
  # Userdata is NOT mounted. Chroot scripts stage files to /tmp/userdata_stage/
  # and persist_userdata injects them via debugfs after overlays complete.
  return 0
}

persist_userdata() {
  [ -z "$USERDATA_IMG" ] && return 0
  [ -z "$USERDATA_RAW" ] && return 0

  # Chroot scripts stage files under /tmp/userdata_stage/ (inside chroot = $MOUNT_POINT/tmp/)
  local stage_dir="$MOUNT_POINT/tmp/userdata_stage"
  if [ ! -d "$stage_dir" ]; then
    echo "==> No userdata staging directory found, skipping userdata injection."
    rm -f "$USERDATA_RAW"
    return 0
  fi

  echo "==> Injecting staged files into userdata image via debugfs ..."

  # Build debugfs command script
  local cmds_file="${TMP_DIR}/debugfs_cmds.txt"
  : > "$cmds_file"

  # Create directories first (sorted so parents come before children)
  (cd "$stage_dir" && find . -mindepth 1 -type d | sort) | while IFS= read -r d; do
    d="${d#.}"
    echo "mkdir $d" >> "$cmds_file"
  done

  # Then write files
  (cd "$stage_dir" && find . -type f | sort) | while IFS= read -r f; do
    f="${f#.}"
    echo "write ${stage_dir}${f} ${f}" >> "$cmds_file"
  done

  echo "    debugfs commands:"
  sed 's/^/      /' "$cmds_file"

  debugfs -w -f "$cmds_file" "$USERDATA_RAW" 2>&1 | grep -v '^debugfs:' || true

  # Copy modified image back over _1.ext4
  echo "==> Persisting userdata back to $USERDATA_IMG ..."
  cp "$USERDATA_RAW" "$USERDATA_IMG"
  rm -f "$USERDATA_RAW" "$cmds_file"

  # The EDL flasher writes _2.ext4 through _N.ext4 at scattered partition offsets
  # (superblock/block-group-descriptor backups). After our modification, those stale
  # chunks could overwrite our new data. Remove them and update the XML.
  local ud_dir
  ud_dir="$(dirname "$USERDATA_IMG")"
  local prefix="qti-ubuntu-robotics-image-qcs6490-odk-userdata"

  echo "==> Removing stale userdata chunk files ..."
  local i
  for i in "$ud_dir"/${prefix}_*.ext4; do
    [ -f "$i" ] || continue
    case "$(basename "$i")" in
      "${prefix}_1.ext4") continue ;;
      *) rm -f "$i"; echo "    Removed $(basename "$i")" ;;
    esac
  done

  # Update rawprogram_unsparse0.xml: fix _1 sector count, remove _2+ entries
  local xml="$ud_dir/rawprogram_unsparse0.xml"
  if [ -f "$xml" ]; then
    local new_sectors=$(( $(stat -c%s "$USERDATA_IMG") / 4096 ))
    echo "==> Updating $xml: _1.ext4 num_partition_sectors=$new_sectors, removing stale chunks ..."
    sed -i "s/filename=\"${prefix}_1\.ext4\" label=\"userdata\" num_partition_sectors=\"[0-9]*\"/filename=\"${prefix}_1.ext4\" label=\"userdata\" num_partition_sectors=\"${new_sectors}\"/" "$xml"
    sed -i -E "/${prefix}_(([2-9]|[1-9][0-9])\.ext4)/d" "$xml"
  fi
}

cleanup_mounts() {
  set +e
  sudo umount "${MOUNT_POINT}${USERDATA_MNT}" 2>/dev/null || true
  sudo umount "$MOUNT_POINT/boot/efi" 2>/dev/null || true
  sudo umount "$MOUNT_POINT/vendor" 2>/dev/null || true
  [ -n "${RESOLV_BIND_TARGET:-}" ] && { sudo umount "$RESOLV_BIND_TARGET" 2>/dev/null || true; }
  sudo umount "$MOUNT_POINT/dev/pts" 2>/dev/null || true
  sudo umount "$MOUNT_POINT/run"      2>/dev/null || true
  sudo umount "$MOUNT_POINT/sys"      2>/dev/null || true
  sudo umount "$MOUNT_POINT/proc"     2>/dev/null || true
  sudo umount "$MOUNT_POINT/dev"      2>/dev/null || true
  sudo umount "$MOUNT_POINT"          2>/dev/null || true
  [ -n "${LOOPDEV:-}" ] && {
    sudo partx -d "$LOOPDEV" 2>/dev/null || true
    sudo kpartx -d "$LOOPDEV" 2>/dev/null || true
    sudo losetup -d "$LOOPDEV" 2>/dev/null || true
  }
}
trap cleanup_mounts EXIT

mount_binds() {
  sudo mount --bind /dev     "$MOUNT_POINT/dev"
  sudo mount --bind /proc    "$MOUNT_POINT/proc"
  sudo mount --bind /sys     "$MOUNT_POINT/sys"
  sudo mount --bind /run     "$MOUNT_POINT/run"
  sudo mount --bind /dev/pts "$MOUNT_POINT/dev/pts"
  # Propagate host DNS into chroot so apt-get can resolve package mirrors.
  # resolve it so we bind-mount to the real file path inside the chroot.
  local resolv="$MOUNT_POINT/etc/resolv.conf"
  local max_depth=10
  while [ -L "$resolv" ] && [ "$max_depth" -gt 0 ]; do
    local link
    link="$(readlink "$resolv")"
    if [ "${link#/}" != "$link" ]; then
      resolv="$MOUNT_POINT$link"
    else
      resolv="$(dirname "$resolv")/$link"
    fi
    max_depth=$((max_depth - 1))
  done
  sudo mkdir -p "$(dirname "$resolv")"
  sudo touch "$resolv"
  sudo mount --bind /etc/resolv.conf "$resolv"
  RESOLV_BIND_TARGET="$resolv"
}

# --- Flow selector: ONLY by presence of EFI image -----------------------------
ftype="$(file -b "$FILESYSTEM" || true)"
IS_SPARSE=false
if echo "$ftype" | grep -qi 'Android sparse image'; then
  IS_SPARSE=true
fi

if [ -n "$EFI_IMG" ]; then
  echo "    TYPE: $ftype"
  echo "    FLOW: with-efi (partitioned loopdev)"
else
  echo "    TYPE: $ftype"
  echo "    FLOW: $([ "$IS_SPARSE" = true ] && echo 'sparse->raw (no-efi)' || echo 'raw ext4 (no-efi)')"
fi

# --- WITH EFI: CI-style GPT loopdev path -------------------------------------
if [ -n "$EFI_IMG" ]; then
  sudo mkdir -p "$MOUNT_POINT" "$MOUNT_POINT/boot/efi"

  # If the provided rootfs is Android sparse, unsparse to <file>.raw first.
  SPARSE_SOURCE=false
  raw_ext4="$FILESYSTEM"
  if [ "$IS_SPARSE" = true ]; then
    SPARSE_SOURCE=true
    raw_ext4="${FILESYSTEM}.raw"
    echo "==> Unsparsing Android sparse rootfs to $raw_ext4 ..."
    make docker-unsparse-image SYSTEM_IMAGE="$FILESYSTEM" SYSTEM_OUTPUT="$raw_ext4"
  fi

  # Create a temporary partitioned container image; p1 sized to the ext4.
  part_img="${TMP_DIR}/partitioned-$$.img"
  part_size=$(stat -c%s "$raw_ext4")
  img_size=$((part_size + 10 * 1024 * 1024)) # +10MiB slack
  echo "==> Creating temp GPT image: $part_img (size=$img_size; p1=$part_size)"
  truncate -s "$img_size" "$part_img"

  echo "==> Setting up loop device (4K alignment) ..."
  LOOPDEV="$(sudo losetup -b 4096 -f --show "$part_img")"
  echo "    LOOPDEV: $LOOPDEV"

  echo "==> Partitioning GPT (single Linux fs 'system_a') ..."
  sudo sgdisk -Z "$LOOPDEV"
  sudo sgdisk -a 2 -n 0:0:+$((part_size / 4096)) -t 0:0FC63DAF-8483-4772-8E79-3D69D8477DE4 -c 0:"system_a" "$LOOPDEV"
  sudo partx -a "$LOOPDEV"
  command -v udevadm >/dev/null 2>&1 && sudo udevadm settle || true
  sleep 1

  PART_ROOT="${LOOPDEV}p1"
  [ -e "$PART_ROOT" ] || { echo "ERROR: missing ${LOOPDEV}p1"; exit 1; }

  echo "==> dd rootfs -> ${PART_ROOT} ..."
  sudo dd if="$raw_ext4" of="${PART_ROOT}" bs=8M iflag=fullblock oflag=direct status=progress
  sync

  echo "==> Mounting root and EFI ..."
  sudo mount "${PART_ROOT}" "$MOUNT_POINT"
  mount_binds
  sudo mkdir -p "$MOUNT_POINT/boot/efi"
  sudo mount -o loop "$EFI_IMG" "$MOUNT_POINT/boot/efi"

  if [ -n "$VENDOR_IMG" ]; then
    sudo mkdir -p "$MOUNT_POINT/vendor"
    sudo mount -o loop "$VENDOR_IMG" "$MOUNT_POINT/vendor"
  fi

  prepare_userdata
  mount_userdata

  # GRUB device.map
  if [ -d "$MOUNT_POINT/boot/grub" ]; then
    printf "(hd0) %s\n(hd1) %sp1\n" "$LOOPDEV" "$LOOPDEV" | sudo tee "$MOUNT_POINT/boot/grub/device.map" >/dev/null || true
  fi

  # --- Run overlay -----------------------------------------------------------
  if [ "$DEBUG" = "chroot" ]; then
    echo "Applying stack: $STACK"
    python3 "$OVERLAY_CLI" apply --overlay-dirs "$OVERLAY_ROOT" --mount-point "$MOUNT_POINT" --resources "$RESOURCES" --stack="$STACK"
    echo "Entering chroot (debug mode). Type 'exit' to resume..."
    sudo chroot "$MOUNT_POINT" /bin/bash
  elif [ "$DEBUG" = "true" ]; then
    echo "Debugging enabled. Mounted at $MOUNT_POINT"
    echo "To call the overlay, run: python3 "$OVERLAY_CLI" apply --mount-point $MOUNT_POINT --resources $RESOURCES --stack $STACK"
    /bin/bash
  else
    echo "Applying stack: $STACK"
    python3 "$OVERLAY_CLI" apply --overlay-dirs "$OVERLAY_ROOT" --mount-point "$MOUNT_POINT" --resources "$RESOURCES" --stack="$STACK"
  fi

  # Clean device.map, unmount, persist back, cleanup
  [ -f "$MOUNT_POINT/boot/grub/device.map" ] && sudo rm -f "$MOUNT_POINT/boot/grub/device.map"

  echo "==> Unmounting root & EFI ..."
  persist_userdata
  sudo umount "$MOUNT_POINT/vendor" 2>/dev/null || true
  sudo umount "$MOUNT_POINT/boot/efi" 2>/dev/null || true
  sudo umount "$MOUNT_POINT/dev/pts" 2>/dev/null || true
  sudo umount "$MOUNT_POINT/run"      2>/dev/null || true
  sudo umount "$MOUNT_POINT/sys"      2>/dev/null || true
  sudo umount "$MOUNT_POINT/proc"     2>/dev/null || true
  sudo umount "$MOUNT_POINT/dev"      2>/dev/null || true
  sudo umount "$MOUNT_POINT"          2>/dev/null || true
  sync

  echo "==> dd ${PART_ROOT} -> $raw_ext4 (persist changes) ..."
  sudo dd if="${PART_ROOT}" of="$raw_ext4" bs=8M iflag=fullblock oflag=direct status=progress
  sync

  echo "==> Detaching loop & cleaning up ..."
  sudo partx -d "$LOOPDEV" 2>/dev/null || true
  sudo kpartx -d "$LOOPDEV" 2>/dev/null || true
  sudo losetup -d "$LOOPDEV" 2>/dev/null || true
  unset LOOPDEV
  rm -f "$part_img"

  # If source was sparse, re-sparsify back into the original path
  if [ "$SPARSE_SOURCE" = true ]; then
    echo "==> Re-sparsifying back into $FILESYSTEM ..."
    make docker-sparse-image SYSTEM_IMAGE="$FILESYSTEM"
  fi

  echo "Done."
  exit 0
fi

# --- WITHOUT EFI: simple overlay path ----------------------------------------
# Two sub-cases: Android sparse (unsparse->mount->overlay->re-sparse) or raw ext4.
if [ "$IS_SPARSE" = true ]; then
  RAW="${FILESYSTEM}.raw"
  echo "==> Unsparsing to $RAW ..."
  make docker-unsparse-image SYSTEM_IMAGE="$FILESYSTEM" SYSTEM_OUTPUT="$RAW"

  echo "==> Mounting raw filesystem ..."
  sudo mkdir -p "$MOUNT_POINT"
  sudo mount -o loop "$RAW" "$MOUNT_POINT"
  mount_binds

  if [ -n "$VENDOR_IMG" ]; then
    sudo mkdir -p "$MOUNT_POINT/vendor"
    sudo mount -o loop "$VENDOR_IMG" "$MOUNT_POINT/vendor"
  fi

  prepare_userdata
  mount_userdata

  # Optional, harmless for GRUB if present
  if [ -d "$MOUNT_POINT/boot/grub" ]; then
    printf "(hd0) %s\n(hd1) %s\n" "loopback" "loopback" | sudo tee "$MOUNT_POINT/boot/grub/device.map" >/dev/null || true
  fi

  if [ "$DEBUG" = "chroot" ]; then
    echo "Applying stack: $STACK"
    python3 "$OVERLAY_CLI" apply --overlay-dirs "$OVERLAY_ROOT" --mount-point "$MOUNT_POINT" --resources "$RESOURCES" --stack="$STACK"
    echo "Entering chroot (debug mode). Type 'exit' to resume..."
    sudo chroot "$MOUNT_POINT" /bin/bash
  elif [ "$DEBUG" = "true" ]; then
    echo "Debugging enabled. Mounted at $MOUNT_POINT"
    echo "To call the overlay, run: python3 "$OVERLAY_CLI" apply --mount-point $MOUNT_POINT --resources $RESOURCES --stack $STACK"
    /bin/bash
  else
    echo "Applying stack: $STACK"
    python3 "$OVERLAY_CLI" apply --overlay-dirs "$OVERLAY_ROOT" --mount-point "$MOUNT_POINT" --resources "$RESOURCES" --stack="$STACK"
  fi

  [ -f "$MOUNT_POINT/boot/grub/device.map" ] && sudo rm -f "$MOUNT_POINT/boot/grub/device.map"
  echo "==> Unmounting ..."
  persist_userdata
  cleanup_mounts

  echo "==> Re-sparsifying back into $FILESYSTEM ..."
  make docker-sparse-image SYSTEM_IMAGE="$FILESYSTEM"

  echo "Done."
  exit 0
fi

# Raw ext4, no EFI
echo "==> Mounting ext4 filesystem via loop (no-efi) ..."
sudo mkdir -p "$MOUNT_POINT"
sudo mount -o loop "$FILESYSTEM" "$MOUNT_POINT"
mount_binds

if [ -n "$VENDOR_IMG" ]; then
  sudo mkdir -p "$MOUNT_POINT/vendor"
  sudo mount -o loop "$VENDOR_IMG" "$MOUNT_POINT/vendor"
fi

prepare_userdata
mount_userdata

# If GRUB present, a minimal device.map can help; harmless if absent
if [ -d "$MOUNT_POINT/boot/grub" ]; then
  printf "(hd0) %s\n" "loopback" | sudo tee "$MOUNT_POINT/boot/grub/device.map" >/dev/null || true
fi

# Apply overlay, honouring DEBUG modes
if [ "$DEBUG" = "chroot" ]; then
  echo "Applying stack: $STACK"
  python3 "$OVERLAY_CLI" apply \
    --overlay-dirs "$OVERLAY_ROOT" \
    --mount-point "$MOUNT_POINT" \
    --resources "$RESOURCES" \
    --stack="$STACK"
  echo "Entering chroot (debug mode). Type 'exit' to resume..."
  sudo chroot "$MOUNT_POINT" /bin/bash
elif [ "$DEBUG" = "true" ]; then
  echo "Debugging enabled. Mounted at $MOUNT_POINT"
  echo "To call the overlay, run: python3 "$OVERLAY_CLI" apply --overlay-dirs $OVERLAY_ROOT --mount-point $MOUNT_POINT --resources $RESOURCES --stack $STACK"
  /bin/bash
else
  echo "Applying stack: $STACK"
  python3 "$OVERLAY_CLI" apply \
    --overlay-dirs "$OVERLAY_ROOT" \
    --mount-point "$MOUNT_POINT" \
    --resources "$RESOURCES" \
    --stack="$STACK"
fi

# Cleanup
[ -f "$MOUNT_POINT/boot/grub/device.map" ] && sudo rm -f "$MOUNT_POINT/boot/grub/device.map"
echo "==> Unmounting ..."
persist_userdata
cleanup_mounts

echo "Done."
exit 0