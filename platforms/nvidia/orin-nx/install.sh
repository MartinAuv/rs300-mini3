#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_RELEASE="$(uname -r)"
MODULE_DIR="/lib/modules/${KERNEL_RELEASE}/updates"
LEGACY_MODULE_DIR="/lib/modules/${KERNEL_RELEASE}/extra"
BOOT_DIR="/boot"
BACKUP_DIR="${BOOT_DIR}/rs300-backups"
EXTLINUX_CONF="/boot/extlinux/extlinux.conf"
DTBO_NAME="rs300-cam1.dtbo"
DTBO_DEST="${BOOT_DIR}/${DTBO_NAME}"
MERGED_DTB="${BOOT_DIR}/rs300-cam1-active.dtb"
MODPROBE_CONF="/etc/modprobe.d/rs300.conf"
VALIDATE_SCRIPT="/usr/local/sbin/rs300-validate.sh"
LOAD_SERVICE="/etc/systemd/system/rs300-load.service"
SET_DEFAULT=0
UPDATE_EXTLINUX=1
INSTALL_SERVICE=1
INSTALL_SLOT_DTB=1
VIDEO_DEV="auto"

usage() {
    cat <<'EOF'
Usage: sudo ./install.sh [options]

Options:
  --set-default       Add/update the rs300_cam1 extlinux entry and make it default.
  --no-extlinux       Do not modify /boot/extlinux/extlinux.conf.
  --no-slot-dtb       Do not update the active A/B kernel-dtb partition.
  --no-service        Do not install/enable rs300-load.service.
  --video-device DEV  Video node used by the validation service (default: auto-detect rs300).
  -h, --help          Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --set-default)
            SET_DEFAULT=1
            ;;
        --no-extlinux)
            UPDATE_EXTLINUX=0
            ;;
        --no-slot-dtb)
            INSTALL_SLOT_DTB=0
            ;;
        --no-service)
            INSTALL_SERVICE=0
            ;;
        --video-device)
            shift
            VIDEO_DEV="${1:?missing video device}"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Missing required command: $1" >&2
        exit 1
    }
}

backup_file() {
    local path="$1"
    local stamp

    [ -f "$path" ] || return 0
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    cp -a "$path" "${path}.bak-rs300-${stamp}"
}

extlinux_value() {
    local label="$1"
    local key="$2"
    awk -v label="$label" -v key="$key" '
        $1 == "LABEL" { in_label = ($2 == label) }
        in_label && $1 == key {
            sub("^[[:space:]]*" key "[[:space:]]+", "")
            print
            exit
        }
    ' "$EXTLINUX_CONF"
}

extlinux_has_label() {
    local label="$1"

    awk -v label="$label" '$1 == "LABEL" && $2 == label { found = 1 } END { exit(found ? 0 : 1) }' \
        "$EXTLINUX_CONF"
}

current_default_label() {
    awk '$1 == "DEFAULT" { print $2; exit }' "$EXTLINUX_CONF"
}

append_overlay_csv() {
    local current="$1"
    local addition="$2"

    case ",${current// /,}," in
        *",${addition},"*)
            printf '%s\n' "${current// /,}"
            ;;
        *)
            if [ -n "$current" ]; then
                printf '%s,%s\n' "${current// /,}" "$addition"
            else
                printf '%s\n' "$addition"
            fi
            ;;
    esac
}

rewrite_extlinux_label() {
    local label="$1"
    local menu_label="$2"
    local linux="$3"
    local initrd="$4"
    local fdt="$5"
    local overlays="$6"
    local append="$7"
    local tmp

    tmp="$(mktemp)"
    awk \
        -v label="$label" \
        -v menu_label="$menu_label" \
        -v linux="$linux" \
        -v initrd="$initrd" \
        -v fdt="$fdt" \
        -v overlays="$overlays" \
        -v append="$append" '
        function emit_label() {
            print "LABEL " label
            print "      MENU LABEL " menu_label
            print "      LINUX " linux
            print "      INITRD " initrd
            if (fdt != "")
                print "      FDT " fdt
            if (overlays != "")
                print "      OVERLAYS " overlays
            print "      APPEND " append
        }

        $1 == "LABEL" {
            if (in_target) {
                if (!emitted) {
                    emit_label()
                    emitted = 1
                }
                in_target = 0
            }
            if ($2 == label) {
                in_target = 1
                next
            }
        }

        !in_target { print }

        END {
            if (in_target) {
                if (!emitted) {
                    emit_label()
                    emitted = 1
                }
            } else if (!emitted) {
                print ""
                emit_label()
            }
        }
    ' "$EXTLINUX_CONF" > "$tmp"
    cat "$tmp" > "$EXTLINUX_CONF"
    rm -f "$tmp"
}

install_extlinux_entry() {
    local default_label source_label linux initrd append overlays rs300_fdt
    local primary_linux primary_initrd primary_append primary_overlays

    [ -f "$EXTLINUX_CONF" ] || {
        echo "No extlinux.conf at $EXTLINUX_CONF; skipping boot entry." >&2
        return 0
    }

    default_label="$(current_default_label)"
    [ -n "$default_label" ] || default_label="primary"
    source_label="$default_label"
    if [ "$source_label" = "rs300_cam1" ] && extlinux_has_label primary; then
        source_label="primary"
    fi

    linux="$(extlinux_value "$source_label" LINUX)"
    initrd="$(extlinux_value "$source_label" INITRD)"
    append="$(extlinux_value "$source_label" APPEND)"
    overlays="$(extlinux_value "$source_label" OVERLAYS)"
    rs300_fdt="$MERGED_DTB"

    [ -n "$linux" ] || linux="/boot/Image"
    [ -n "$initrd" ] || initrd="/boot/initrd"
    [ -n "$append" ] || append='${cbootargs}'

    overlays="$(append_overlay_csv "$overlays" "$DTBO_DEST")"

    backup_file "$EXTLINUX_CONF"
    rewrite_extlinux_label \
        "rs300_cam1" \
        "RS300/WN2640 CAM1 thermal camera: 640x512, 2 lanes, 80 MHz" \
        "$linux" \
        "$initrd" \
        "$rs300_fdt" \
        "$overlays" \
        "$append"

    if [ "$SET_DEFAULT" -eq 1 ]; then
        sed -i 's/^DEFAULT .*/DEFAULT rs300_cam1/' "$EXTLINUX_CONF"

        if extlinux_has_label primary; then
            primary_linux="$(extlinux_value primary LINUX)"
            primary_initrd="$(extlinux_value primary INITRD)"
            primary_append="$(extlinux_value primary APPEND)"
            primary_overlays="$(extlinux_value primary OVERLAYS)"

            [ -n "$primary_linux" ] || primary_linux="$linux"
            [ -n "$primary_initrd" ] || primary_initrd="$initrd"
            [ -n "$primary_append" ] || primary_append="$append"

            primary_overlays="$(append_overlay_csv "$primary_overlays" "$DTBO_DEST")"

            rewrite_extlinux_label \
                "primary" \
                "primary kernel with RS300/WN2640 CAM1 thermal camera" \
                "$primary_linux" \
                "$primary_initrd" \
                "$rs300_fdt" \
                "$primary_overlays" \
                "$primary_append"
        fi
    fi
}

dtb_has_symbols() {
    local dtb="$1"

    [ -f "$dtb" ] || return 1
    fdtget "$dtb" /__symbols__ gpio >/dev/null 2>&1 &&
        fdtget "$dtb" /__symbols__ gpio_aon >/dev/null 2>&1 &&
        fdtget "$dtb" /__symbols__ cam_i2c >/dev/null 2>&1
}

find_rs300_base_dtb() {
    local saved_fdt="${BACKUP_DIR}/base-fdt.dtb"
    local fdt cand pat
    shopt -s nullglob extglob

    mkdir -p "$BACKUP_DIR"

    # 1. Prefer a previously saved pristine snapshot of the live UEFI-merged
    #    /sys/firmware/fdt (preserves all JetPack 7.2 UEFI carrier/SKU/carveout
    #    overlays across repeated install.sh runs).
    if dtb_has_symbols "$saved_fdt"; then
        echo "Using base DTB for merge: $saved_fdt (cached live FDT snapshot)" >&2
        printf '%s\n' "$saved_fdt"
        return 0
    fi

    # 2. If running on the live Jetson and /sys/firmware/fdt has symbols and
    #    does not yet contain rs300@3c, snapshot it as our clean base-fdt.dtb.
    if [ -r /sys/firmware/fdt ] && dtb_has_symbols /sys/firmware/fdt; then
        if ! fdtget /sys/firmware/fdt /bus@0/cam_i2cmux/i2c@1/rs300@3c compatible >/dev/null 2>&1; then
            cp /sys/firmware/fdt "$saved_fdt"
            chmod 0644 "$saved_fdt"
            echo "Using base DTB for merge: $saved_fdt (captured from live /sys/firmware/fdt)" >&2
            printf '%s\n' "$saved_fdt"
            return 0
        fi
    fi

    # 3. Check explicit extlinux FDT entries (excluding our generated output).
    for label in primary rs300_cam1 rs300_cam1_dtb; do
        if [ -f "$EXTLINUX_CONF" ]; then
            fdt="$(extlinux_value "$label" FDT || true)"
            if [ -n "$fdt" ] && [ "$fdt" != "$MERGED_DTB" ] && dtb_has_symbols "$fdt"; then
                echo "Using base DTB for merge: $fdt (source: extlinux $label)" >&2
                printf '%s\n' "$fdt"
                return 0
            fi
        fi
    done

    # 4. Search /boot and /boot/dtb for JetPack 6.x (jnx120) and JetPack 7.2+ (jnx42) DTBs.
    local patterns=(
        "${BOOT_DIR}/dtb/kernel_tegra234-auvidea-jnx120?(x)+p3767-[0-9][0-9][0-9][0-9]-nv*.dtb"
        "${BOOT_DIR}/kernel_tegra234-auvidea-jnx120?(x)+p3767-[0-9][0-9][0-9][0-9]-nv*.dtb"
        "${BOOT_DIR}/dtb/tegra234-auvidea-jnx120?(x)+p3767-[0-9][0-9][0-9][0-9]-nv*.dtb"
        "${BOOT_DIR}/tegra234-auvidea-jnx120?(x)+p3767-[0-9][0-9][0-9][0-9]-nv*.dtb"
        "${BOOT_DIR}/dtb/kernel_tegra234-auvidea-jnx42+p3767-[0-9][0-9][0-9][0-9]-nv*.dtb"
        "${BOOT_DIR}/kernel_tegra234-auvidea-jnx42+p3767-[0-9][0-9][0-9][0-9]-nv*.dtb"
        "${BOOT_DIR}/dtb/tegra234-auvidea-jnx42+p3767-[0-9][0-9][0-9][0-9]-nv*.dtb"
        "${BOOT_DIR}/tegra234-auvidea-jnx42+p3767-[0-9][0-9][0-9][0-9]-nv*.dtb"
        "${BOOT_DIR}/dtb/tegra234-p3768-[0-9][0-9][0-9][0-9]+p3767-[0-9][0-9][0-9][0-9]-nv*.dtb"
        "${BOOT_DIR}/tegra234-p3768-[0-9][0-9][0-9][0-9]+p3767-[0-9][0-9][0-9][0-9]-nv*.dtb"
        "${BOOT_DIR}/tegra234-p3737-[0-9][0-9][0-9][0-9]+p3701-[0-9][0-9][0-9][0-9]-nv*.dtb"
    )

    for pat in "${patterns[@]}"; do
        for cand in $pat; do
            if [ "$cand" != "$MERGED_DTB" ] && dtb_has_symbols "$cand"; then
                echo "Using base DTB for merge: $cand" >&2
                printf '%s\n' "$cand"
                return 0
            fi
        done
    done

    # 5. Final fallback to live /sys/firmware/fdt even if rs300@3c was already merged.
    if [ -r /sys/firmware/fdt ] && dtb_has_symbols /sys/firmware/fdt; then
        cp /sys/firmware/fdt "$saved_fdt"
        chmod 0644 "$saved_fdt"
        echo "Using base DTB for merge: $saved_fdt (fallback from live /sys/firmware/fdt)" >&2
        printf '%s\n' "$saved_fdt"
        return 0
    fi

    echo "Could not find an RS300 base DTB in /sys/firmware/fdt or ${BOOT_DIR}" >&2
    return 1
}

build_merged_dtb() {
    local base_dtb tmp_dtb
    local overlays=()

    need_cmd fdtoverlay
    need_cmd fdtget

    base_dtb="$(find_rs300_base_dtb)"
    tmp_dtb="${MERGED_DTB}.tmp"

    if ! fdtget "$base_dtb" /reserved-memory/vpr-carveout compatible >/dev/null 2>&1; then
        [ -f "${BOOT_DIR}/tegra234-carveouts.dtbo" ] && overlays+=("${BOOT_DIR}/tegra234-carveouts.dtbo")
    fi
    if ! fdtget "$base_dtb" /firmware/optee compatible >/dev/null 2>&1; then
        [ -f "${BOOT_DIR}/tegra-optee.dtbo" ] && overlays+=("${BOOT_DIR}/tegra-optee.dtbo")
    fi
    overlays+=("$DTBO_DEST")

    fdtoverlay -i "$base_dtb" -o "$tmp_dtb" "${overlays[@]}"

    if command -v fdtput >/dev/null 2>&1; then
        fdtput -d "$tmp_dtb" /chosen linux,initrd-start 2>/dev/null || true
        fdtput -d "$tmp_dtb" /chosen linux,initrd-end 2>/dev/null || true
    fi

    fdtget "$tmp_dtb" /bus@0/cam_i2cmux/i2c@0/rs300@3c compatible >/dev/null
    fdtget "$tmp_dtb" /bus@0/cam_i2cmux/i2c@0/rs300@3c power-gpios >/dev/null
    fdtget "$tmp_dtb" /bus@0/cam_i2cmux/i2c@1/rs300@3c compatible >/dev/null
    fdtget "$tmp_dtb" /bus@0/cam_i2cmux/i2c@1/rs300@3c power-gpios >/dev/null
    fdtget "$tmp_dtb" /bus@0/gpio@c2f0000/gbe-switch-rst label >/dev/null

    chmod 0644 "$tmp_dtb"
    mv -f "$tmp_dtb" "$MERGED_DTB"
    echo "Built merged RS300 DTB: ${MERGED_DTB}"
}

active_slot_dtb_partlabel() {
    local slot

    slot="$(nvbootctrl get-current-slot 2>/dev/null || nvbootctrl -t rootfs get-current-slot 2>/dev/null || true)"
    case "$slot" in
        0|A|a) printf '%s\n' "A_kernel-dtb" ;;
        1|B|b) printf '%s\n' "B_kernel-dtb" ;;
        *)
            echo "Could not determine active boot slot from nvbootctrl output: ${slot:-<empty>}" >&2
            return 1
            ;;
    esac
}

install_active_slot_dtb() {
    local partlabel part size part_size backup

    need_cmd nvbootctrl
    need_cmd blockdev
    need_cmd dd

    [ -f "$MERGED_DTB" ] || build_merged_dtb

    partlabel="$(active_slot_dtb_partlabel)"
    part="/dev/disk/by-partlabel/${partlabel}"

    [ -e "$part" ] || {
        echo "Active DTB partition not found: $part" >&2
        return 1
    }

    size="$(stat -c%s "$MERGED_DTB")"
    part_size="$(blockdev --getsize64 "$part")"
    if [ "$size" -gt "$part_size" ]; then
        echo "Merged DTB (${size} bytes) is larger than ${part} (${part_size} bytes)" >&2
        return 1
    fi

    mkdir -p "$BACKUP_DIR"
    backup="${BACKUP_DIR}/${partlabel}-$(date -u +%Y%m%dT%H%M%SZ).dtb"
    dd if="$part" of="$backup" bs=1M status=none
    chmod 0644 "$backup"

    dd if="$MERGED_DTB" of="$part" bs=4K conv=fsync status=none
    echo "Installed merged RS300 DTB to ${part} (${partlabel}); backup: ${backup}"
}

install_validation_service() {
    cat >"$VALIDATE_SCRIPT" <<'EOF'
#!/bin/sh
set -u

DEV_ARG="${1:-auto}"
WIDTH=640
HEIGHT=512
PIX=UYVY
VALID_FRAMES=90
EXPECT=$((WIDTH * HEIGHT * 2 * VALID_FRAMES))
FRAME_SIZE=$((WIDTH * HEIGHT * 2))
CHECK_FRAME=80
OUT=/tmp/rs300-validate.raw

log() {
    logger -t rs300-validate "$*"
    echo "rs300-validate: $*"
}

find_rs300_videos() {
    found=0
    for candidate in /dev/video*; do
        [ -e "$candidate" ] || continue

        if v4l2-ctl -d "$candidate" --info 2>/dev/null |
            grep -Eiq 'Card type[[:space:]]*:.*(rs300|wn2640)'; then
            printf '%s\n' "$candidate"
            found=1
        fi
    done

    [ "$found" -eq 1 ]
}

frame_has_signal() {
    dd if="$OUT" bs="$FRAME_SIZE" skip="$CHECK_FRAME" count=1 2>/dev/null |
        od -An -tu1 -v |
        awk '
            { for (i = 1; i <= NF; i++) c[$i] = 1 }
            END { exit(length(c) > 10 ? 0 : 1) }
        '
}

validate_one_dev() {
    dev="$1"
    for attempt in 1 2; do
        log "attempt $attempt: validating $dev"
        rm -f "$OUT"

        timeout 15s v4l2-ctl -d "$dev" \
            --set-fmt-video=width=${WIDTH},height=${HEIGHT},pixelformat=${PIX} \
            --stream-mmap=4 --stream-count=${VALID_FRAMES} --stream-to="$OUT" >/dev/null 2>&1
        rc=$?
        size=0
        [ -f "$OUT" ] && size=$(stat -c%s "$OUT" 2>/dev/null || echo 0)

        if [ "$rc" -eq 0 ] && [ "$size" -eq "$EXPECT" ] && frame_has_signal; then
            log "$dev ready after attempt $attempt: ${VALID_FRAMES} frames, ${size} bytes"
            rm -f "$OUT"
            return 0
        fi

        log "$dev validation failed on attempt $attempt: rc=$rc size=$size expected=$EXPECT"
        rm -f "$OUT"
        sleep 2
    done
    return 1
}

wait_dev=0
if [ "$DEV_ARG" = "auto" ] || [ -z "$DEV_ARG" ]; then
    DEVS=""
    while [ "$wait_dev" -lt 30 ]; do
        DEVS="$(find_rs300_videos || true)"
        [ -n "$DEVS" ] && break
        sleep 1
        wait_dev=$((wait_dev + 1))
    done

    if [ -z "$DEVS" ]; then
        log "could not auto-detect any rs300 video nodes"
        exit 1
    fi
else
    DEVS="$DEV_ARG"
    while [ ! -e "$DEVS" ] && [ "$wait_dev" -lt 30 ]; do
        sleep 1
        wait_dev=$((wait_dev + 1))
    done

    if [ ! -e "$DEVS" ]; then
        log "device $DEVS did not appear"
        exit 1
    fi
fi

ready_count=0
for dev in $DEVS; do
    if validate_one_dev "$dev"; then
        ready_count=$((ready_count + 1))
    else
        log "$dev not connected or did not validate"
    fi
done

if [ "$ready_count" -gt 0 ]; then
    log "${ready_count} RS300 camera(s) validated and ready"
    exit 0
fi

log "no RS300 cameras validated"
exit 1
EOF
    chmod 0755 "$VALIDATE_SCRIPT"

    cat >"$LOAD_SERVICE" <<EOF
[Unit]
Description=Load and validate RS300/WN2640 CAM0/CAM1 thermal cameras (640x512)
After=systemd-udev-settle.service

[Service]
Type=oneshot
# 1. Wait 3 seconds for Jetson power domains and CSI/I2C mux to settle
ExecStartPre=/bin/sleep 3

# 2. Load driver (1st pass / power-on)
ExecStart=/sbin/modprobe rs300 set_fps_cmd=1 power_on_delay_ms=1500

# 3. Soft-reset: briefly wait, unload, and reload with full power_on_delay_ms
ExecStartPost=/bin/sleep 1
ExecStartPost=-/sbin/rmmod rs300
ExecStartPost=/bin/sleep 1
ExecStartPost=/sbin/modprobe rs300 set_fps_cmd=1 power_on_delay_ms=4500

# 4. Run readiness validation script
ExecStartPost=${VALIDATE_SCRIPT} ${VIDEO_DEV}

RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable rs300-load.service
}

ensure_custom_carrier_dpkg_safe() {
    # On custom carrier boards like Auvidea JNX120X (COMPATIBLE_SPEC=*auvidea*),
    # NVIDIA's stock nvidia-l4t-bootloader.postinst and
    # /etc/kernel/postinst.d/xx-nvidia-update-kernel-partitions fail with exit
    # code 3 ("Cannot get compatible board name") because NVIDIA's stock BUP
    # payload updater only recognizes stock *jetson-orin-nano*-devkit* specs.
    # Both scripts explicitly check for the sentinel file below to skip stock
    # devkit BUP flashing safely.
    if [ -f /etc/nv_boot_control.conf ] && grep -qi 'auvidea' /etc/nv_boot_control.conf; then
        mkdir -p /opt/nvidia/l4t-packages
        touch /opt/nvidia/l4t-packages/.nv-l4t-disable-boot-fw-update-in-preinstall
        apt-mark hold \
            nvidia-l4t-bootloader \
            nvidia-l4t-initrd \
            nvidia-l4t-kernel \
            nvidia-l4t-kernel-dtbs \
            nvidia-l4t-kernel-headers \
            nvidia-l4t-kernel-oot-headers \
            nvidia-l4t-kernel-oot-modules >/dev/null 2>&1 || true
    fi

    export DEBIAN_FRONTEND=noninteractive
    dpkg --configure -a || true
}

install_runtime_dependencies() {
    local pkgs=(
        device-tree-compiler
        gstreamer1.0-plugins-base
        gstreamer1.0-plugins-good
        gstreamer1.0-plugins-bad
        gstreamer1.0-plugins-ugly
        gstreamer1.0-libav
        gstreamer1.0-tools
        libgstreamer-plugins-base1.0-dev
        python3-opencv
        v4l-utils
    )
    local missing=()
    local pkg

    if ! dpkg -s nvidia-l4t-gstreamer >/dev/null 2>&1; then
        pkgs+=(nvidia-l4t-gstreamer)
    fi

    for pkg in "${pkgs[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    done

    if [ "${#missing[@]}" -eq 0 ]; then
        echo "All required runtime dependencies (GStreamer, OpenCV, v4l-utils, dtc) are already installed."
        return 0
    fi

    echo "Installing missing dependencies: ${missing[*]}..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y || true
    apt-get install -y --no-upgrade "${missing[@]}"
}

ensure_custom_carrier_dpkg_safe
install_runtime_dependencies

need_cmd make
need_cmd install
need_cmd depmod
need_cmd dtc

cd "$SCRIPT_DIR"

make clean
make
make dtbo

rm -f "${LEGACY_MODULE_DIR}/rs300.ko"
install -D -m 0644 rs300.ko "${MODULE_DIR}/rs300.ko"
install -D -m 0644 "${DTBO_NAME}" "$DTBO_DEST"
depmod -a

[ -f "${SCRIPT_DIR}/setup_streamIP.sh" ] && chmod 0755 "${SCRIPT_DIR}/setup_streamIP.sh"
[ -f "${SCRIPT_DIR}/stream_thermal.py" ] && chmod 0755 "${SCRIPT_DIR}/stream_thermal.py"

cat >"$MODPROBE_CONF" <<'EOF'
blacklist rs300
options rs300 mode=640 fps=60 set_fps_cmd=1 type=16 output_source=-1 yuv_order=2 start_path=1 start_dst=1 power_on_delay_ms=8000 auto_shutter=0 startup_ffc=0 native_y16=0
EOF

if [ "$UPDATE_EXTLINUX" -eq 1 ] || [ "$INSTALL_SLOT_DTB" -eq 1 ]; then
    build_merged_dtb
fi

if [ "$INSTALL_SERVICE" -eq 1 ]; then
    install_validation_service
fi

if [ "$UPDATE_EXTLINUX" -eq 1 ]; then
    install_extlinux_entry
fi

if [ "$INSTALL_SLOT_DTB" -eq 1 ]; then
    install_active_slot_dtb
fi

systemctl disable --now cam1-pac00-high.service >/dev/null 2>&1 || true

echo "Installed ${MODULE_DIR}/rs300.ko, ${DTBO_DEST}, and ${MODPROBE_CONF}."
if [ "$UPDATE_EXTLINUX" -eq 1 ]; then
    echo "Installed/updated extlinux label: rs300_cam1"
    [ "$SET_DEFAULT" -eq 1 ] && echo "Set DEFAULT rs300_cam1."
fi
if [ "$INSTALL_SLOT_DTB" -eq 1 ]; then
    echo "Updated active Jetson kernel-dtb partition with merged RS300 DTB."
fi
if [ "$INSTALL_SERVICE" -eq 1 ]; then
    echo "Enabled rs300-load.service with ${VIDEO_DEV} validation."
fi

echo "Installation complete. Reboot, then check: systemctl status rs300-load.service"
