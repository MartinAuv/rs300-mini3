#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_IP="192.168.103.166"
DEFAULT_PORT="5000"
STREAM_LAYOUT="${STREAM_LAYOUT:-separate}"

if [ "${1:-}" = "--sbs" ]; then
    STREAM_LAYOUT="sbs"
    shift
fi

find_rs300_videos() {
    local candidate found=0
    local list=()
    for candidate in /dev/video*; do
        [ -e "$candidate" ] || continue
        if command -v v4l2-ctl >/dev/null 2>&1; then
            if v4l2-ctl -d "$candidate" --info 2>/dev/null |
                grep -Eiq 'Card type[[:space:]]*:.*(rs300|wn2640)'; then
                list+=("$candidate")
                found=1
            fi
        fi
    done

    if [ "$found" -eq 1 ]; then
        printf '%s\n' "${list[*]}"
        return 0
    fi

    if [ -e /dev/video0 ]; then
        printf '%s\n' "/dev/video0"
        return 0
    fi

    return 1
}

configure_rs300_subdevs() {
    local subdev name_file
    command -v v4l2-ctl >/dev/null 2>&1 || return 0
    for name_file in /sys/class/video4linux/v4l-subdev*/name; do
        [ -r "$name_file" ] || continue
        if grep -Eiq '(rs300|wn2640)' "$name_file" 2>/dev/null; then
            subdev="/dev/$(basename "$(dirname "$name_file")")"
            if [ -e "$subdev" ]; then
                v4l2-ctl -d "$subdev" --set-ctrl=output_mode=1 >/dev/null 2>&1 || true
            fi
        fi
    done
}

valid_ipv4() {
    local ip="$1"
    local IFS='.'
    local -a octets
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    read -r -a octets <<<"$ip"
    for o in "${octets[@]}"; do
        ((10#$o >= 0 && 10#$o <= 255)) || return 1
    done
    return 0
}

# 1. Ask for Target IP (or take from 1st CLI argument)
DEST_IP="${1:-}"
DEST_PORT="${2:-$DEFAULT_PORT}"

if [ -z "$DEST_IP" ]; then
    while true; do
        read -r -p "Ziel-IP-Adresse eingeben [${DEFAULT_IP}]: " input_ip
        DEST_IP="${input_ip:-$DEFAULT_IP}"
        if valid_ipv4 "$DEST_IP"; then
            break
        fi
        echo "Ungültige IPv4-Adresse: '${DEST_IP}'. Bitte erneut eingeben."
    done
else
    if ! valid_ipv4 "$DEST_IP"; then
        echo "Fehler: Ungültige IPv4-Adresse '${DEST_IP}'." >&2
        exit 1
    fi
fi

# 2. Wait if rs300-load.service is still initializing after boot
if command -v systemctl >/dev/null 2>&1; then
    state="$(systemctl is-active rs300-load.service 2>/dev/null || true)"
    if [ "$state" = "activating" ]; then
        echo "Warte auf Abschluss der Kamera-Initialisierung (rs300-load.service)..."
        while [ "$(systemctl is-active rs300-load.service 2>/dev/null || true)" = "activating" ]; do
            sleep 1
        done
    fi
fi

# 3. Ensure rs300 kernel module is loaded
if ! lsmod | grep -q '^rs300\b'; then
    echo "Lade rs300 Treiber..."
    sudo modprobe rs300 set_fps_cmd=1 power_on_delay_ms=4500
fi

# 4. Auto-detect all RS300 video devices (CSI 0 /dev/video0 and CSI 1 /dev/video1)
RS300_DEVICES="$(find_rs300_videos || true)"
if [ -z "$RS300_DEVICES" ]; then
    echo "Fehler: Keine RS300/WN2640 Kamera unter /dev/video* gefunden." >&2
    exit 1
fi

# 5. Ensure all RS300 camera subdevices are in 16-bit thermal mode (output_mode=1)
configure_rs300_subdevs

export RS300_DEVICES
export DEST_IP
export DEST_PORT
export STREAM_LAYOUT

exec python3 "${SCRIPT_DIR}/stream_thermal.py" "$DEST_IP" "$DEST_PORT"
