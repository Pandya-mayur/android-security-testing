#!/bin/bash
#
# Android Security Testing Setup Script for macOS
#
# Automates the setup of Android security testing environment including:
# - Burp Suite CA certificate installation (system + user level)
# - Frida server deployment and startup
# - Proxy configuration
# - SSL pinning bypass script deployment
#
# Author: Android Security Testing Toolkit
# Requires: ADB, Frida, OpenSSL (via Homebrew or system)
# License: MIT

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Default values
BURP_CERT="burp_cacert.crt"
FRIDA_SERVER=""
PROXY_HOST=""
PROXY_PORT=8080
SKIP_PROXY=false
SKIP_FRIDA=false
SKIP_CERT=false
CLEANUP=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Android Security Testing Setup Script for macOS

OPTIONS:
    -c, --cert FILE         Burp CA certificate file (default: burp_cacert.crt)
    -f, --frida FILE        Frida server binary path
    -h, --host HOST         Proxy host IP
    -p, --port PORT         Proxy port (default: 8080)
    --skip-proxy            Skip proxy configuration
    --skip-frida            Skip Frida installation
    --skip-cert             Skip certificate installation
    --cleanup               Remove proxy settings and stop Frida
    --help                  Show this help message

EXAMPLES:
    $0                      # Run full setup with defaults
    $0 -c my_cert.crt       # Use custom certificate
    $0 --cleanup            # Clean up and restore settings
    $0 --skip-frida         # Setup without Frida

EOF
    exit 0
}

log() {
    local type=$1
    local msg=$2
    case $type in
        INFO)  echo -e "${CYAN}[INFO]${NC} $msg" ;;
        OK)    echo -e "${GREEN}[OK]${NC} $msg" ;;
        WARN)  echo -e "${YELLOW}[WARN]${NC} $msg" ;;
        ERROR) echo -e "${RED}[ERROR]${NC} $msg" ;;
    esac
}

check_command() {
    command -v "$1" &> /dev/null
}

get_openssl_path() {
    # Prefer Homebrew OpenSSL (supports subject_hash_old)
    local brew_openssl="/usr/local/opt/openssl/bin/openssl"
    local brew_openssl_arm="/opt/homebrew/opt/openssl/bin/openssl"

    if [[ -f "$brew_openssl_arm" ]]; then
        echo "$brew_openssl_arm"
    elif [[ -f "$brew_openssl" ]]; then
        echo "$brew_openssl"
    elif check_command openssl; then
        echo "openssl"
    else
        echo ""
    fi
}

get_device_arch() {
    adb shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r\n'
}

get_android_version() {
    adb shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r\n'
}

find_frida_server() {
    local arch=$1
    local patterns=(
        "$SCRIPT_DIR/frida-server*$arch*"
        "$SCRIPT_DIR/frida-server/frida-server*$arch*"
        "$SCRIPT_DIR/*/frida-server*$arch*"
    )

    for pattern in "${patterns[@]}"; do
        local found=$(ls $pattern 2>/dev/null | head -1)
        if [[ -n "$found" ]]; then
            echo "$found"
            return 0
        fi
    done
    return 1
}

install_system_ca() {
    local cert_path=$1
    local openssl_bin=$2

    log INFO "Generating certificate hash..."

    local pem_path=$(mktemp).pem

    # Try DER format first, then PEM
    if ! "$openssl_bin" x509 -inform DER -in "$cert_path" -out "$pem_path" 2>/dev/null; then
        cp "$cert_path" "$pem_path"
    fi

    # Try subject_hash_old first (for Android compatibility), fallback to subject_hash
    local hash=$("$openssl_bin" x509 -inform PEM -subject_hash_old -in "$pem_path" -noout 2>/dev/null || \
                 "$openssl_bin" x509 -inform PEM -subject_hash -in "$pem_path" -noout)
    hash=$(echo "$hash" | tr -d '\r\n')

    local system_cert_name="${hash}.0"
    local system_cert_path="$SCRIPT_DIR/$system_cert_name"

    "$openssl_bin" x509 -inform PEM -in "$pem_path" -out "$system_cert_path" -outform PEM

    log OK "Certificate hash: $hash"

    # Push certs to device
    log INFO "Pushing certificates to device..."
    adb push "$cert_path" /data/local/tmp/cert-der.crt > /dev/null
    adb push "$system_cert_path" /data/local/tmp/$system_cert_name > /dev/null
    adb push "$cert_path" /sdcard/Download/burp_cacert.crt > /dev/null

    # Install to system CA store (Android 14+ APEX method)
    log INFO "Installing to system CA store (APEX method)..."

    local result=$(adb shell "
        mkdir -p /data/local/tmp/cacerts
        cp /apex/com.android.conscrypt/cacerts/* /data/local/tmp/cacerts/ 2>/dev/null || \
            cp /system/etc/security/cacerts/* /data/local/tmp/cacerts/
        cp /data/local/tmp/$system_cert_name /data/local/tmp/cacerts/
        chmod 644 /data/local/tmp/cacerts/*

        if mount -t tmpfs tmpfs /apex/com.android.conscrypt/cacerts 2>/dev/null; then
            cp /data/local/tmp/cacerts/* /apex/com.android.conscrypt/cacerts/
            chmod 644 /apex/com.android.conscrypt/cacerts/*
            chcon u:object_r:system_security_cacerts_file:s0 /apex/com.android.conscrypt/cacerts/*
            echo 'APEX_SUCCESS'
        elif mount -o rw,remount /system 2>/dev/null; then
            cp /data/local/tmp/$system_cert_name /system/etc/security/cacerts/
            chmod 644 /system/etc/security/cacerts/$system_cert_name
            echo 'SYSTEM_SUCCESS'
        else
            echo 'MOUNT_FAILED'
        fi
    " 2>&1)

    if echo "$result" | grep -q "APEX_SUCCESS"; then
        log OK "System CA installed via APEX overlay"
    elif echo "$result" | grep -q "SYSTEM_SUCCESS"; then
        log OK "System CA installed to /system"
    else
        log WARN "Could not install system CA (read-only system). User CA install required."
    fi

    rm -f "$pem_path"
}

install_frida_server() {
    local frida_path=$1

    log INFO "Pushing Frida server to device..."
    adb push "$frida_path" /data/local/tmp/frida-server > /dev/null

    log INFO "Setting permissions and starting Frida..."
    adb shell "chmod 755 /data/local/tmp/frida-server"
    adb shell "pkill -9 frida-server 2>/dev/null; /data/local/tmp/frida-server -D &"

    sleep 2

    local pid=$(adb shell "pgrep frida-server" 2>/dev/null | tr -d '\r\n')
    if [[ -n "$pid" ]]; then
        log OK "Frida server running (PID: $pid)"
        return 0
    else
        log ERROR "Failed to start Frida server"
        return 1
    fi
}

set_device_proxy() {
    local host=$1
    local port=$2

    log INFO "Configuring proxy: ${host}:${port}..."
    adb shell "settings put global http_proxy ${host}:${port}"

    local current=$(adb shell "settings get global http_proxy" | tr -d '\r\n')
    log OK "Proxy set to: $current"
}

clear_device_proxy() {
    log INFO "Clearing proxy settings..."
    adb shell "settings put global http_proxy :0"
    log OK "Proxy cleared"
}

stop_frida_server() {
    log INFO "Stopping Frida server..."
    adb shell "pkill -9 frida-server 2>/dev/null" || true
    log OK "Frida server stopped"
}

get_host_ip() {
    # Get primary interface IP on macOS
    local ip=""

    # Method 1: route get
    ip=$(route get default 2>/dev/null | grep interface | awk '{print $2}' | xargs -I{} ipconfig getifaddr {} 2>/dev/null)

    # Method 2: en0 (common default)
    if [[ -z "$ip" ]]; then
        ip=$(ipconfig getifaddr en0 2>/dev/null)
    fi

    # Method 3: any non-loopback
    if [[ -z "$ip" ]]; then
        ip=$(ifconfig | grep "inet " | grep -v "127.0.0.1" | head -1 | awk '{print $2}')
    fi

    echo "$ip"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--cert)      BURP_CERT="$2"; shift 2 ;;
        -f|--frida)     FRIDA_SERVER="$2"; shift 2 ;;
        -h|--host)      PROXY_HOST="$2"; shift 2 ;;
        -p|--port)      PROXY_PORT="$2"; shift 2 ;;
        --skip-proxy)   SKIP_PROXY=true; shift ;;
        --skip-frida)   SKIP_FRIDA=true; shift ;;
        --skip-cert)    SKIP_CERT=true; shift ;;
        --cleanup)      CLEANUP=true; shift ;;
        --help)         usage ;;
        *)              echo "Unknown option: $1"; usage ;;
    esac
done

# Main execution
echo ""
echo -e "${CYAN}========================================"
echo "  Android Security Testing Setup"
echo "  macOS Edition"
echo -e "========================================${NC}"
echo ""

# Cleanup mode
if $CLEANUP; then
    log INFO "Running cleanup..."
    clear_device_proxy
    stop_frida_server
    log OK "Cleanup complete!"
    exit 0
fi

# Check prerequisites
log INFO "Checking prerequisites..."

if ! check_command adb; then
    log ERROR "ADB not found in PATH"
    log INFO "Install with: brew install android-platform-tools"
    exit 1
fi

if ! adb devices | grep -q "device$"; then
    log ERROR "No Android device/emulator connected"
    exit 1
fi
log OK "Device connected"

# Check root access
whoami_result=$(adb shell whoami 2>/dev/null | tr -d '\r\n')
if [[ "$whoami_result" != "root" ]]; then
    log INFO "Attempting to restart ADB as root..."
    adb root > /dev/null 2>&1 || true
    sleep 2
fi

arch=$(get_device_arch)
sdk=$(get_android_version)
log OK "Device: Android API $sdk ($arch)"

# Certificate installation
if ! $SKIP_CERT; then
    cert_path="$SCRIPT_DIR/$BURP_CERT"
    if [[ ! -f "$cert_path" ]]; then
        log ERROR "Burp certificate not found: $cert_path"
        log INFO "Export from Burp: Proxy > Options > Import/Export CA Certificate > Export Certificate in DER format"
        exit 1
    fi

    openssl_bin=$(get_openssl_path)
    if [[ -z "$openssl_bin" ]]; then
        log ERROR "OpenSSL not found. Install with: brew install openssl"
        exit 1
    fi
    log OK "Using OpenSSL: $openssl_bin"

    install_system_ca "$cert_path" "$openssl_bin"

    echo ""
    log WARN "IMPORTANT: Also install CA via Settings for full coverage:"
    log INFO "  Settings > Security > Encryption & credentials > Install certificate > CA certificate"
    log INFO "  Select: /sdcard/Download/burp_cacert.crt"
    echo ""
fi

# Frida installation
if ! $SKIP_FRIDA; then
    if [[ -n "$FRIDA_SERVER" && -f "$FRIDA_SERVER" ]]; then
        frida_path="$FRIDA_SERVER"
    else
        frida_path=$(find_frida_server "$arch") || frida_path=""
    fi

    if [[ -z "$frida_path" ]]; then
        log WARN "Frida server not found for architecture: $arch"
        log INFO "Download from: https://github.com/frida/frida/releases"
        log INFO "Look for: frida-server-*-android-$arch.xz"
    else
        log INFO "Found Frida server: $frida_path"
        install_frida_server "$frida_path"
    fi
fi

# Proxy configuration
if ! $SKIP_PROXY; then
    if [[ -z "$PROXY_HOST" ]]; then
        # Auto-detect: use 10.0.2.2 for emulator, otherwise get host IP
        route=$(adb shell "ip route" 2>/dev/null)
        if echo "$route" | grep -q "10\.0\.2\."; then
            PROXY_HOST="10.0.2.2"
            log INFO "Detected emulator, using host: $PROXY_HOST"
        else
            PROXY_HOST=$(get_host_ip)
            log INFO "Using host IP: $PROXY_HOST"
        fi
    fi

    set_device_proxy "$PROXY_HOST" "$PROXY_PORT"
fi

# Summary
echo ""
echo -e "${GREEN}========================================"
echo "  Setup Complete!"
echo -e "========================================${NC}"
echo ""
log INFO "To intercept traffic with SSL pinning bypass:"
log INFO "  frida -U -f <package.name> -l sslbypass.js"
echo ""
log INFO "To clear proxy when done:"
log INFO "  ./setup-macos.sh --cleanup"
echo ""
log INFO "To list installed apps:"
log INFO "  adb shell pm list packages -3"
echo ""
