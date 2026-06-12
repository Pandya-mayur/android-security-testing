<#
.SYNOPSIS
    Quick reconnect script for Android Security Testing (run after reboot)
.DESCRIPTION
    Re-establishes the security testing environment after device/emulator reboot:
    - Remounts system CA via APEX overlay
    - Restarts Frida server
    - Reconfigures proxy
.NOTES
    Run this instead of full setup after rebooting your device/emulator
#>

param(
    [string]$ProxyHost = "",
    [int]$ProxyPort = 8080,
    [switch]$SkipProxy,
    [switch]$SkipFrida,
    [switch]$SkipCert
)

$ErrorActionPreference = "Stop"

function Write-Status { param($Message, $Type = "INFO")
    $colors = @{ "INFO" = "Cyan"; "OK" = "Green"; "WARN" = "Yellow"; "ERROR" = "Red" }
    Write-Host "[$Type] " -ForegroundColor $colors[$Type] -NoNewline
    Write-Host $Message
}

Write-Host ""
Write-Host "======================================" -ForegroundColor Magenta
Write-Host "  Android Security Testing Reconnect" -ForegroundColor Magenta
Write-Host "======================================" -ForegroundColor Magenta
Write-Host ""

# Check device
$devices = adb devices | Select-String "device$"
if (-not $devices) {
    Write-Status "No device connected. Waiting..." "WARN"
    adb wait-for-device
}
Write-Status "Device connected" "OK"

# Restart ADB as root
adb root 2>$null | Out-Null
Start-Sleep -Seconds 2

# Re-mount system CA (APEX overlay)
if (-not $SkipCert) {
    Write-Status "Re-mounting system CA..."

    $certFile = adb shell "ls /data/local/tmp/*.0 2>/dev/null | head -1" | ForEach-Object { $_.Trim() }

    if ($certFile) {
        $certName = Split-Path $certFile -Leaf

        $result = adb shell "
            mount -t tmpfs tmpfs /apex/com.android.conscrypt/cacerts 2>/dev/null && {
                cp /data/local/tmp/cacerts/* /apex/com.android.conscrypt/cacerts/ 2>/dev/null
                chmod 644 /apex/com.android.conscrypt/cacerts/*
                chcon u:object_r:system_security_cacerts_file:s0 /apex/com.android.conscrypt/cacerts/* 2>/dev/null
                echo 'SUCCESS'
            } || echo 'FAILED'
        "

        if ($result -match "SUCCESS") {
            Write-Status "System CA re-mounted" "OK"
        } else {
            Write-Status "Could not mount APEX overlay (may need full setup)" "WARN"
        }
    } else {
        Write-Status "No cached cert found. Run full setup-windows.ps1 first." "WARN"
    }
}

# Restart Frida server
if (-not $SkipFrida) {
    Write-Status "Starting Frida server..."
    adb shell "pkill -9 frida-server 2>/dev/null; /data/local/tmp/frida-server -D &"
    Start-Sleep -Seconds 2

    $pid = adb shell "pgrep frida-server" 2>$null
    if ($pid) {
        Write-Status "Frida server running (PID: $($pid.Trim()))" "OK"
    } else {
        Write-Status "Frida server failed to start" "ERROR"
    }
}

# Set proxy
if (-not $SkipProxy) {
    if (-not $ProxyHost) {
        $route = adb shell "ip route" 2>$null
        if ($route -match "10\.0\.2\.") {
            $ProxyHost = "10.0.2.2"
        } else {
            $ProxyHost = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
                $_.InterfaceAlias -notmatch 'Loopback' -and $_.IPAddress -ne '127.0.0.1'
            } | Select-Object -First 1).IPAddress
        }
    }

    adb shell "settings put global http_proxy ${ProxyHost}:${ProxyPort}"
    Write-Status "Proxy set to ${ProxyHost}:${ProxyPort}" "OK"
}

Write-Host ""
Write-Host "======================================" -ForegroundColor Green
Write-Host "  Ready for testing!" -ForegroundColor Green
Write-Host "======================================" -ForegroundColor Green
Write-Host ""
Write-Status "Usage: frida -U -f <package> -l ssl-bypass-universal.js"
Write-Host ""
