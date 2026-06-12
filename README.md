# Android Security Testing Toolkit

Automated setup scripts for Android application security testing and bug bounty hunting. This toolkit configures your environment for intercepting HTTPS traffic from Android apps using Burp Suite and bypassing SSL pinning with Frida.

## Features

- **Cross-platform support**: Windows, Linux, macOS
- **Automated CA installation**: System-level (APEX/tmpfs overlay for Android 14+) and user-level
- **Frida server deployment**: Auto-detects device architecture
- **Proxy configuration**: Auto-detects emulator vs physical device
- **Universal SSL bypass**: Hooks multiple SSL implementations (OkHttp, TrustManager, WebView, etc.)

## Prerequisites

### Required Tools

| Tool | Installation |
|------|-------------|
| **ADB** | [Android Platform Tools](https://developer.android.com/studio/releases/platform-tools) |
| **Frida** | `pip install frida-tools` |
| **Burp Suite** | [PortSwigger](https://portswigger.net/burp/communitydownload) |
| **OpenSSL** | Git for Windows / `apt install openssl` / `brew install openssl` |

### Android Requirements

- Rooted Android device or emulator with root access
- USB debugging enabled
- For emulators: Use Google APIs (not Play Store) images for root access

## Quick Start

### 1. Export Burp CA Certificate

1. Open Burp Suite → **Proxy** → **Options**
2. Click **Import / export CA certificate**
3. Select **Certificate in DER format**
4. Save as `burp_cacert.crt` in this directory

### 2. Download Frida Server

1. Check your device architecture:
   ```bash
   adb shell getprop ro.product.cpu.abi
   ```

2. Download matching frida-server from [Frida Releases](https://github.com/frida/frida/releases)
   - `frida-server-X.X.X-android-arm64` for ARM64 devices
   - `frida-server-X.X.X-android-arm` for ARM devices
   - `frida-server-X.X.X-android-x86_64` for x86_64 emulators
   - `frida-server-X.X.X-android-x86` for x86 emulators

3. Extract and place in `frida-server/` subdirectory

### 3. Run Setup Script

**Windows (PowerShell):**
```powershell
.\setup-windows.ps1
```

**Linux:**
```bash
chmod +x setup-linux.sh
./setup-linux.sh
```

**macOS:**
```bash
chmod +x setup-macos.sh
./setup-macos.sh
```

### 4. Install User CA (Manual Step)

On the Android device:
1. **Settings** → **Security** → **Encryption & credentials**
2. **Install a certificate** → **CA certificate**
3. Tap **Install anyway**
4. Select `/sdcard/Download/burp_cacert.crt`

### 5. Configure Burp Suite

1. **Proxy** → **Options** → **Proxy Listeners**
2. Edit listener → **Binding** tab
3. Select **All interfaces** (or specific IP)
4. Port: `8080`

## Usage

### Intercept Traffic with SSL Pinning Bypass

```bash
# List installed apps
adb shell pm list packages -3

# Start app with SSL bypass
frida -U -f com.target.app -l ssl-bypass-universal.js

# Or attach to running app
frida -U -n "App Name" -l ssl-bypass-universal.js
```

### Script Options

| Script | Options |
|--------|---------|
| `setup-windows.ps1` | `-BurpCert`, `-FridaServer`, `-ProxyHost`, `-ProxyPort`, `-SkipProxy`, `-SkipFrida`, `-SkipCert`, `-Cleanup` |
| `setup-linux.sh` | `-c/--cert`, `-f/--frida`, `-h/--host`, `-p/--port`, `--skip-proxy`, `--skip-frida`, `--skip-cert`, `--cleanup` |
| `setup-macos.sh` | Same as Linux |

### Examples

```bash
# Custom certificate
./setup-linux.sh -c my_custom_cert.crt

# Skip Frida (only install cert and configure proxy)
./setup-linux.sh --skip-frida

# Specify proxy host manually
./setup-linux.sh -h 192.168.1.100 -p 8081

# Cleanup (remove proxy, stop Frida)
./setup-linux.sh --cleanup
```

## SSL Bypass Scripts

### `ssl-bypass-universal.js`
Comprehensive bypass covering:
- TrustManager / TrustManagerImpl
- OkHttp CertificatePinner (v3/v4)
- HttpsURLConnection
- WebView SSL errors
- TrustKit
- Conscrypt
- Apache HttpClient
- Flutter apps (native hook)

### `sslbypass.js`
Legacy script that re-pins to Burp certificate. Requires:
```bash
adb push burp_cacert.crt /data/local/tmp/cert-der.crt
```

## Troubleshooting

### No traffic in Burp

1. **Check proxy connectivity:**
   ```bash
   adb shell ping -c 2 10.0.2.2  # For emulator
   ```

2. **Verify Burp is listening on all interfaces:**
   - Proxy → Options → Proxy Listeners → All interfaces

3. **Check proxy setting on device:**
   ```bash
   adb shell settings get global http_proxy
   ```

4. **For physical devices, use your machine's IP:**
   ```bash
   # Windows
   ipconfig
   # Linux/macOS
   ip addr  # or ifconfig
   ```

### SSL errors / Certificate not trusted

1. **Re-run APEX overlay (after reboot):**
   ```bash
   # The tmpfs mount is lost on reboot
   ./setup-linux.sh --skip-frida --skip-proxy
   ```

2. **Install user CA manually** via Settings

3. **Check if app uses Network Security Config:**
   - Decompile APK with apktool
   - Check `res/xml/network_security_config.xml`

### Frida connection issues

1. **Check Frida server is running:**
   ```bash
   adb shell pgrep frida-server
   ```

2. **Version mismatch:**
   ```bash
   frida --version  # Client version
   # Ensure server version matches
   ```

3. **Restart Frida server:**
   ```bash
   adb shell "pkill -9 frida-server; /data/local/tmp/frida-server -D &"
   ```

### App crashes with Frida

- Try spawning instead of attaching: `frida -U -f <package>`
- Check for anti-Frida detection, may need custom bypass
- Try older/newer Frida version

## File Structure

```
android-testing/
├── setup-windows.ps1       # Windows setup script
├── setup-linux.sh          # Linux setup script
├── setup-macos.sh          # macOS setup script
├── ssl-bypass-universal.js # Universal SSL bypass
├── sslbypass.js            # Legacy re-pinning bypass
├── burp_cacert.crt         # Your Burp CA certificate
├── frida-server/           # Frida server binaries
│   └── frida-server-*-android-*
└── README.md
```

## Security Considerations

- Only use on applications you have permission to test
- This toolkit is for authorized security testing and bug bounty programs
- Do not use for malicious purposes
- Respect responsible disclosure policies

## Contributing

Pull requests welcome! Areas for improvement:
- Additional SSL bypass techniques
- Anti-Frida bypass scripts
- Root detection bypass
- Support for more pinning libraries

## License

MIT License - See LICENSE file

## Resources

- [Frida Documentation](https://frida.re/docs/)
- [Burp Suite Documentation](https://portswigger.net/burp/documentation)
- [Android Security Testing Guide (OWASP)](https://mas.owasp.org/MASTG/)
- [Mobile Security Framework (MobSF)](https://github.com/MobSF/Mobile-Security-Framework-MobSF)
