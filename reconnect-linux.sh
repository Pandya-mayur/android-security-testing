#!/bin/bash
#
# Quick reconnect script for Android Security Testing (run after reboot)
#
# Re-establishes the security testing environment after device/emulator reboot:
# - Remounts system CA via APEX overlay
# - Restarts Frida server
# - Reconfigures proxy

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PROXY_HOST=""
PROXY_PORT=8080
SKIP_PROXY=false
SKIP_FRIDA=false
SKIP_CERT=false

log() {
    local type=$1; local msg=$2
    case $type in
        INFO)  echo -e "${CYAN}[INFO]${NC} $msg" ;;
        OK)    echo -e "${GREEN}[OK]${NC} $msg" ;;
        WARN)  echo -e "${YELLOW}[WARN]${NC} $msg" ;;
        ERROR) echo -e "${RED}[ERROR]${NC} $msg" ;;
    esac
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--host)      PROXY_HOST="$2"; shift 2 ;;
        -p|--port)      PROXY_PORT="$2"; shift 2 ;;
        --skip-proxy)   SKIP_PROXY=true; shift ;;
        --skip-frida)   SKIP_FRIDA=true; shift ;;
        --skip-cert)    SKIP_CERT=true; shift ;;
        *)              shift ;;
    esac
done

echo ""
echo -e "${CYAN}======================================"
echo "  Android Security Testing Reconnect"
echo -e "======================================${NC}"
echo ""

# Check device
if ! adb devices | grep -q "device$"; then
    log WARN "No device connected. Waiting..."
    adb wait-for-device
fi
log OK "Device connected"

# Restart ADB as root
adb root > /dev/null 2>&1 || true
sleep 2

# Re-mount system CA
if ! $SKIP_CERT; then
    log INFO "Re-mounting system CA..."

    result=$(adb shell "
        mount -t tmpfs tmpfs /apex/com.android.conscrypt/cacerts 2>/dev/null && {
            cp /data/local/tmp/cacerts/* /apex/com.android.conscrypt/cacerts/ 2>/dev/null
            chmod 644 /apex/com.android.conscrypt/cacerts/*
            chcon u:object_r:system_security_cacerts_file:s0 /apex/com.android.conscrypt/cacerts/* 2>/dev/null
            echo 'SUCCESS'
        } || echo 'FAILED'
    " 2>&1)

    if echo "$result" | grep -q "SUCCESS"; then
        log OK "System CA re-mounted"
    else
        log WARN "Could not mount APEX overlay (may need full setup)"
    fi
fi

# Restart Frida
if ! $SKIP_FRIDA; then
    log INFO "Starting Frida server..."
    adb shell "pkill -9 frida-server 2>/dev/null; /data/local/tmp/frida-server -D &"
    sleep 2

    pid=$(adb shell "pgrep frida-server" 2>/dev/null | tr -d '\r\n')
    if [[ -n "$pid" ]]; then
        log OK "Frida server running (PID: $pid)"
    else
        log ERROR "Frida server failed to start"
    fi
fi

# Set proxy
if ! $SKIP_PROXY; then
    if [[ -z "$PROXY_HOST" ]]; then
        route=$(adb shell "ip route" 2>/dev/null)
        if echo "$route" | grep -q "10\.0\.2\."; then
            PROXY_HOST="10.0.2.2"
        else
            PROXY_HOST=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[\d.]+' | head -1)
            [[ -z "$PROXY_HOST" ]] && PROXY_HOST=$(hostname -I | awk '{print $1}')
        fi
    fi

    adb shell "settings put global http_proxy ${PROXY_HOST}:${PROXY_PORT}"
    log OK "Proxy set to ${PROXY_HOST}:${PROXY_PORT}"
fi

echo ""
echo -e "${GREEN}======================================"
echo "  Ready for testing!"
echo -e "======================================${NC}"
echo ""
log INFO "Usage: frida -U -f <package> -l ssl-bypass-universal.js"
echo ""
