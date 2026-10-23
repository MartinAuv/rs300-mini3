#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_IP="192.168.103.166"
DEFAULT_PORT="5000"

find_rs300_video() {
    local candidate
    for candidate in /dev/video*; do
        [ -e "$candidate" ] || continue
        if command -v v4l2-ctl >/dev/null 2>&1; then
            if v4l2-ctl -d "$candidate" --info 2>/dev/null |
                grep -Eiq 'Card type[[:space:]]*:.*(rs300|wn2640)'; then
                printf '%s\n' "$candidate"
                return 0
            fi
        fi
    done

    if [ -e /dev/video0 ]; then
        printf '%s\n' "/dev/video0"
        return 0
    fi

    return 1
}

find_rs300_subdev() {
    local subdev name_file
    for name_file in /sys/class/video4linux/v4l-subdev*/name; do
        [ -r "$name_file" ] || continue
        if grep -Eiq '(rs300|wn2640)' "$name_file" 2>/dev/null; then
            subdev="/dev/$(basename "$(dirname "$name_file")")"
            [ -e "$subdev" ] && {
                printf '%s\n' "$subdev"
                return 0
            }
        fi
    done
    return 1
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

# 4. Auto-detect RS300 video device
RS300_DEVICE="$(find_rs300_video || true)"
if [ -z "$RS300_DEVICE" ]; then
    echo "Fehler: Keine RS300/WN2640 Kamera unter /dev/video* gefunden." >&2
    exit 1
fi

# 5. Ensure camera subdevice is in 16-bit thermal mode (output_mode=1) for 16-bit normalization
RS300_SUBDEV="$(find_rs300_subdev || true)"
if [ -n "$RS300_SUBDEV" ] && command -v v4l2-ctl >/dev/null 2>&1; then
    v4l2-ctl -d "$RS300_SUBDEV" --set-ctrl=output_mode=1 >/dev/null 2>&1 || true
fi

export RS300_DEVICE
export DEST_IP
export DEST_PORT

exec python3 "${SCRIPT_DIR}/stream_thermal.py" "$DEST_IP" "$DEST_PORT"
