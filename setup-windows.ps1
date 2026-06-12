<#
.SYNOPSIS
    Android Security Testing Setup Script for Windows
.DESCRIPTION
    Automates the setup of Android security testing environment including:
    - Burp Suite CA certificate installation (system + user level)
    - Frida server deployment and startup
    - Proxy configuration
    - SSL pinning bypass script deployment
.NOTES
    Author: Android Security Testing Toolkit
    Requires: ADB, Frida, PowerShell 5.1+
    License: MIT
#>

param(
    [string]$BurpCert = "burp_cacert.crt",
    [string]$FridaServer = "",
    [string]$ProxyHost = "",
    [int]$ProxyPort = 8080,
    [switch]$SkipProxy,
    [switch]$SkipFrida,
    [switch]$SkipCert,
    [switch]$Cleanup
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Status { param($Message, $Type = "INFO")
    $colors = @{ "INFO" = "Cyan"; "OK" = "Green"; "WARN" = "Yellow"; "ERROR" = "Red" }
    Write-Host "[$Type] " -ForegroundColor $colors[$Type] -NoNewline
    Write-Host $Message
}

function Test-Command { param($Command)
    $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

function Get-OpenSSLPath {
    $paths = @(
        "C:\Program Files\Git\usr\bin\openssl.exe",
        "C:\Program Files\OpenSSL-Win64\bin\openssl.exe",
        "C:\Program Files (x86)\OpenSSL\bin\openssl.exe",
        "C:\OpenSSL-Win64\bin\openssl.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { return $p }
    }
    if (Test-Command "openssl") { return "openssl" }
    return $null
}

function Get-DeviceArch {
    $arch = adb shell getprop ro.product.cpu.abi 2>$null
    return $arch.Trim()
}

function Get-AndroidVersion {
    $sdk = adb shell getprop ro.build.version.sdk 2>$null
    return [int]$sdk.Trim()
}

function Find-FridaServer {
    param($ScriptDir, $Arch)

    $patterns = @(
        "$ScriptDir\frida-server*$Arch*",
        "$ScriptDir\frida-server\frida-server*$Arch*",
        "$ScriptDir\*\frida-server*$Arch*"
    )

    foreach ($pattern in $patterns) {
        $found = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

function Install-SystemCA {
    param($CertPath, $OpenSSL)

    Write-Status "Generating certificate hash..."

    $pemPath = [System.IO.Path]::GetTempFileName() + ".pem"

    # Try DER format first, then PEM
    & $OpenSSL x509 -inform DER -in $CertPath -out $pemPath 2>$null
    if ($LASTEXITCODE -ne 0) {
        Copy-Item $CertPath $pemPath
    }

    $hash = & $OpenSSL x509 -inform PEM -subject_hash_old -in $pemPath -noout 2>$null
    if (-not $hash) {
        $hash = & $OpenSSL x509 -inform PEM -subject_hash -in $pemPath -noout
    }
    $hash = $hash.Trim()

    $systemCertName = "$hash.0"
    $systemCertPath = Join-Path $ScriptDir $systemCertName

    & $OpenSSL x509 -inform PEM -in $pemPath -out $systemCertPath -outform PEM

    Write-Status "Certificate hash: $hash" "OK"

    # Push certs to device
    Write-Status "Pushing certificates to device..."
    adb push $CertPath /data/local/tmp/cert-der.crt | Out-Null
    adb push $systemCertPath /data/local/tmp/$systemCertName | Out-Null
    adb push $CertPath /sdcard/Download/burp_cacert.crt | Out-Null

    # Install to system CA store (Android 14+ APEX method)
    Write-Status "Installing to system CA store (APEX method)..."

    $installScript = @"
mkdir -p /data/local/tmp/cacerts
cp /apex/com.android.conscrypt/cacerts/* /data/local/tmp/cacerts/ 2>/dev/null || cp /system/etc/security/cacerts/* /data/local/tmp/cacerts/
cp /data/local/tmp/$systemCertName /data/local/tmp/cacerts/
chmod 644 /data/local/tmp/cacerts/*
mount -t tmpfs tmpfs /apex/com.android.conscrypt/cacerts 2>/dev/null && {
    cp /data/local/tmp/cacerts/* /apex/com.android.conscrypt/cacerts/
    chmod 644 /apex/com.android.conscrypt/cacerts/*
    chcon u:object_r:system_security_cacerts_file:s0 /apex/com.android.conscrypt/cacerts/*
    echo "APEX_SUCCESS"
} || {
    mount -o rw,remount /system 2>/dev/null && {
        cp /data/local/tmp/$systemCertName /system/etc/security/cacerts/
        chmod 644 /system/etc/security/cacerts/$systemCertName
        echo "SYSTEM_SUCCESS"
    } || echo "MOUNT_FAILED"
}
"@

    $result = adb shell $installScript 2>&1

    if ($result -match "APEX_SUCCESS") {
        Write-Status "System CA installed via APEX overlay" "OK"
    } elseif ($result -match "SYSTEM_SUCCESS") {
        Write-Status "System CA installed to /system" "OK"
    } else {
        Write-Status "Could not install system CA (read-only system). User CA install required." "WARN"
    }

    # Cleanup temp files
    Remove-Item $pemPath -ErrorAction SilentlyContinue

    return $systemCertName
}

function Install-FridaServer {
    param($FridaPath)

    Write-Status "Pushing Frida server to device..."
    adb push $FridaPath /data/local/tmp/frida-server | Out-Null

    Write-Status "Setting permissions and starting Frida..."
    adb shell "chmod 755 /data/local/tmp/frida-server"
    adb shell "pkill -9 frida-server 2>/dev/null; /data/local/tmp/frida-server -D &"

    Start-Sleep -Seconds 2

    $pid = adb shell "pgrep frida-server" 2>$null
    if ($pid) {
        Write-Status "Frida server running (PID: $($pid.Trim()))" "OK"
        return $true
    } else {
        Write-Status "Failed to start Frida server" "ERROR"
        return $false
    }
}

function Set-DeviceProxy {
    param($Host, $Port)

    Write-Status "Configuring proxy: ${Host}:${Port}..."
    adb shell "settings put global http_proxy ${Host}:${Port}"

    $current = adb shell "settings get global http_proxy"
    Write-Status "Proxy set to: $($current.Trim())" "OK"
}

function Clear-DeviceProxy {
    Write-Status "Clearing proxy settings..."
    adb shell "settings put global http_proxy :0"
    Write-Status "Proxy cleared" "OK"
}

function Stop-FridaServer {
    Write-Status "Stopping Frida server..."
    adb shell "pkill -9 frida-server 2>/dev/null"
    Write-Status "Frida server stopped" "OK"
}

# Main execution
Write-Host ""
Write-Host "========================================" -ForegroundColor Magenta
Write-Host "  Android Security Testing Setup" -ForegroundColor Magenta
Write-Host "  Windows Edition" -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta
Write-Host ""

# Cleanup mode
if ($Cleanup) {
    Write-Status "Running cleanup..."
    Clear-DeviceProxy
    Stop-FridaServer
    Write-Status "Cleanup complete!" "OK"
    exit 0
}

# Check prerequisites
Write-Status "Checking prerequisites..."

if (-not (Test-Command "adb")) {
    Write-Status "ADB not found in PATH" "ERROR"
    exit 1
}

$devices = adb devices | Select-String "device$"
if (-not $devices) {
    Write-Status "No Android device/emulator connected" "ERROR"
    exit 1
}
Write-Status "Device connected" "OK"

# Check root access
$whoami = adb shell whoami 2>$null
if ($whoami.Trim() -ne "root") {
    Write-Status "Attempting to restart ADB as root..."
    adb root | Out-Null
    Start-Sleep -Seconds 2
}

$arch = Get-DeviceArch
$sdk = Get-AndroidVersion
Write-Status "Device: Android API $sdk ($arch)" "OK"

# Certificate installation
if (-not $SkipCert) {
    $certPath = Join-Path $ScriptDir $BurpCert
    if (-not (Test-Path $certPath)) {
        Write-Status "Burp certificate not found: $certPath" "ERROR"
        Write-Status "Export from Burp: Proxy > Options > Import/Export CA Certificate > Export Certificate in DER format"
        exit 1
    }

    $openssl = Get-OpenSSLPath
    if (-not $openssl) {
        Write-Status "OpenSSL not found. Install Git for Windows or OpenSSL." "ERROR"
        exit 1
    }
    Write-Status "Using OpenSSL: $openssl" "OK"

    Install-SystemCA -CertPath $certPath -OpenSSL $openssl

    Write-Host ""
    Write-Status "IMPORTANT: Also install CA via Settings for full coverage:" "WARN"
    Write-Status "  Settings > Security > Encryption & credentials > Install certificate > CA certificate"
    Write-Status "  Select: /sdcard/Download/burp_cacert.crt"
    Write-Host ""
}

# Frida installation
if (-not $SkipFrida) {
    if ($FridaServer -and (Test-Path $FridaServer)) {
        $fridaPath = $FridaServer
    } else {
        $fridaPath = Find-FridaServer -ScriptDir $ScriptDir -Arch $arch
    }

    if (-not $fridaPath) {
        Write-Status "Frida server not found for architecture: $arch" "WARN"
        Write-Status "Download from: https://github.com/frida/frida/releases" "WARN"
        Write-Status "Look for: frida-server-*-android-$arch.xz"
    } else {
        Write-Status "Found Frida server: $fridaPath"
        Install-FridaServer -FridaPath $fridaPath
    }
}

# Proxy configuration
if (-not $SkipProxy) {
    if (-not $ProxyHost) {
        # Auto-detect: use 10.0.2.2 for emulator, otherwise prompt
        $route = adb shell "ip route" 2>$null
        if ($route -match "10\.0\.2\.") {
            $ProxyHost = "10.0.2.2"
            Write-Status "Detected emulator, using host: $ProxyHost"
        } else {
            # Get host IP
            $hostIP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
                $_.InterfaceAlias -notmatch 'Loopback' -and $_.IPAddress -ne '127.0.0.1'
            } | Select-Object -First 1).IPAddress
            $ProxyHost = $hostIP
            Write-Status "Using host IP: $ProxyHost"
        }
    }

    Set-DeviceProxy -Host $ProxyHost -Port $ProxyPort
}

# Summary
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Setup Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Status "To intercept traffic with SSL pinning bypass:"
Write-Status "  frida -U -f <package.name> -l sslbypass.js"
Write-Host ""
Write-Status "To clear proxy when done:"
Write-Status "  .\setup-windows.ps1 -Cleanup"
Write-Host ""
Write-Status "To list installed apps:"
Write-Status "  adb shell pm list packages -3"
Write-Host ""
