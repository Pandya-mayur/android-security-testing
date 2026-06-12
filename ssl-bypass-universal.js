/*
 * Universal Android SSL Pinning Bypass
 *
 * Bypasses SSL pinning for most common implementations:
 * - TrustManager
 * - OkHttp (v3/v4)
 * - Retrofit
 * - HttpsURLConnection
 * - WebView
 * - TrustKit
 * - Network Security Config
 * - Conscrypt
 * - Apache HttpClient
 *
 * Usage:
 *   frida -U -f <package> -l ssl-bypass-universal.js
 *   frida -U -n <process> -l ssl-bypass-universal.js
 *
 * For apps with custom cert pinning, also push Burp cert:
 *   adb push burp_cacert.crt /data/local/tmp/cert-der.crt
 *
 * Author: Android Security Testing Toolkit
 * License: MIT
 */

Java.perform(function() {
    console.log("\n[*] Universal SSL Pinning Bypass loaded");
    console.log("[*] Targeting multiple SSL implementations...\n");

    var X509TrustManager = Java.use('javax.net.ssl.X509TrustManager');
    var SSLContext = Java.use('javax.net.ssl.SSLContext');

    // === TrustManager Bypass ===
    try {
        var TrustManagerImpl = Java.use('com.android.org.conscrypt.TrustManagerImpl');
        TrustManagerImpl.verifyChain.implementation = function(untrustedChain, trustAnchorChain, host, clientAuth, ocspData, tlsSctData) {
            console.log('[+] Bypassing TrustManagerImpl: ' + host);
            return untrustedChain;
        };
        console.log('[OK] TrustManagerImpl hooked');
    } catch(e) {
        console.log('[--] TrustManagerImpl not found (may be older Android)');
    }

    // === X509TrustManager Bypass ===
    try {
        var TrustManager = Java.registerClass({
            name: 'com.bypass.TrustManager',
            implements: [X509TrustManager],
            methods: {
                checkClientTrusted: function(chain, authType) {},
                checkServerTrusted: function(chain, authType) {},
                getAcceptedIssuers: function() { return []; }
            }
        });

        SSLContext.init.overload('[Ljavax.net.ssl.KeyManager;', '[Ljavax.net.ssl.TrustManager;', 'java.security.SecureRandom').implementation = function(km, tm, sr) {
            console.log('[+] Bypassing SSLContext.init()');
            this.init(km, [TrustManager.$new()], sr);
        };
        console.log('[OK] SSLContext.init hooked');
    } catch(e) {
        console.log('[--] SSLContext hook failed: ' + e);
    }

    // === OkHttp v3/v4 CertificatePinner ===
    try {
        var CertificatePinner = Java.use('okhttp3.CertificatePinner');
        CertificatePinner.check.overload('java.lang.String', 'java.util.List').implementation = function(hostname, peerCertificates) {
            console.log('[+] Bypassing OkHttp CertificatePinner: ' + hostname);
        };
        CertificatePinner.check$okhttp.overload('java.lang.String', 'kotlin.jvm.functions.Function0').implementation = function(hostname, peerCertificates) {
            console.log('[+] Bypassing OkHttp CertificatePinner$okhttp: ' + hostname);
        };
        console.log('[OK] OkHttp CertificatePinner hooked');
    } catch(e) {
        console.log('[--] OkHttp CertificatePinner not found');
    }

    // === OkHttp v3 Older versions ===
    try {
        var CertificatePinnerOld = Java.use('com.squareup.okhttp.CertificatePinner');
        CertificatePinnerOld.check.overload('java.lang.String', 'java.util.List').implementation = function(hostname, peerCertificates) {
            console.log('[+] Bypassing OkHttp (old) CertificatePinner: ' + hostname);
        };
        console.log('[OK] OkHttp (old) CertificatePinner hooked');
    } catch(e) {
        console.log('[--] OkHttp (old) CertificatePinner not found');
    }

    // === HttpsURLConnection ===
    try {
        var HttpsURLConnection = Java.use('javax.net.ssl.HttpsURLConnection');
        HttpsURLConnection.setDefaultHostnameVerifier.implementation = function(hostnameVerifier) {
            console.log('[+] Bypassing HttpsURLConnection.setDefaultHostnameVerifier');
        };
        HttpsURLConnection.setSSLSocketFactory.implementation = function(sslSocketFactory) {
            console.log('[+] Bypassing HttpsURLConnection.setSSLSocketFactory');
        };
        HttpsURLConnection.setHostnameVerifier.implementation = function(hostnameVerifier) {
            console.log('[+] Bypassing HttpsURLConnection.setHostnameVerifier');
        };
        console.log('[OK] HttpsURLConnection hooked');
    } catch(e) {
        console.log('[--] HttpsURLConnection hook failed: ' + e);
    }

    // === HostnameVerifier ===
    try {
        var HostnameVerifier = Java.use('javax.net.ssl.HostnameVerifier');
        var AllowAllHostnameVerifier = Java.registerClass({
            name: 'com.bypass.AllowAllHostnameVerifier',
            implements: [HostnameVerifier],
            methods: {
                verify: function(hostname, session) {
                    console.log('[+] Allowing hostname: ' + hostname);
                    return true;
                }
            }
        });
        console.log('[OK] Custom HostnameVerifier registered');
    } catch(e) {
        console.log('[--] HostnameVerifier registration failed: ' + e);
    }

    // === WebView SSL Error Handler ===
    try {
        var WebViewClient = Java.use('android.webkit.WebViewClient');
        WebViewClient.onReceivedSslError.implementation = function(view, handler, error) {
            console.log('[+] Bypassing WebView SSL error');
            handler.proceed();
        };
        console.log('[OK] WebViewClient.onReceivedSslError hooked');
    } catch(e) {
        console.log('[--] WebViewClient hook failed: ' + e);
    }

    // === TrustKit ===
    try {
        var TrustKit = Java.use('com.datatheorem.android.trustkit.pinning.OkHostnameVerifier');
        TrustKit.verify.overload('java.lang.String', 'javax.net.ssl.SSLSession').implementation = function(hostname, session) {
            console.log('[+] Bypassing TrustKit: ' + hostname);
            return true;
        };
        TrustKit.verify.overload('java.lang.String', 'java.security.cert.X509Certificate').implementation = function(hostname, certificate) {
            console.log('[+] Bypassing TrustKit (cert): ' + hostname);
            return true;
        };
        console.log('[OK] TrustKit hooked');
    } catch(e) {
        console.log('[--] TrustKit not found');
    }

    // === Apache HttpClient (legacy) ===
    try {
        var AbstractVerifier = Java.use('org.apache.http.conn.ssl.AbstractVerifier');
        AbstractVerifier.verify.overload('java.lang.String', '[Ljava.lang.String;', '[Ljava.lang.String;', 'boolean').implementation = function(host, cns, subjectAlts, strictWithSubDomains) {
            console.log('[+] Bypassing Apache HttpClient: ' + host);
        };
        console.log('[OK] Apache HttpClient AbstractVerifier hooked');
    } catch(e) {
        console.log('[--] Apache HttpClient not found');
    }

    // === Conscrypt (newer Android) ===
    try {
        var ConscryptOpenSSLSocketImpl = Java.use('com.android.org.conscrypt.OpenSSLSocketImpl');
        ConscryptOpenSSLSocketImpl.verifyCertificateChain.implementation = function(certRefs, authMethod) {
            console.log('[+] Bypassing Conscrypt certificate chain verification');
        };
        console.log('[OK] Conscrypt OpenSSLSocketImpl hooked');
    } catch(e) {
        console.log('[--] Conscrypt OpenSSLSocketImpl not found');
    }

    // === Conscrypt Platform ===
    try {
        var Platform = Java.use('com.android.org.conscrypt.Platform');
        Platform.checkServerTrusted.overload('javax.net.ssl.X509TrustManager', '[Ljava.security.cert.X509Certificate;', 'java.lang.String', 'com.android.org.conscrypt.AbstractConscryptSocket').implementation = function(tm, chain, authType, socket) {
            console.log('[+] Bypassing Conscrypt Platform.checkServerTrusted');
            return Java.use('java.util.ArrayList').$new();
        };
        console.log('[OK] Conscrypt Platform hooked');
    } catch(e) {
        console.log('[--] Conscrypt Platform not found');
    }

    // === Network Security Config ===
    try {
        var NetworkSecurityConfig = Java.use('android.security.net.config.NetworkSecurityConfig');
        NetworkSecurityConfig.getTrustAnchors.implementation = function() {
            console.log('[+] Bypassing NetworkSecurityConfig.getTrustAnchors');
            var result = this.getTrustAnchors();
            return result;
        };
        console.log('[OK] NetworkSecurityConfig hooked');
    } catch(e) {
        console.log('[--] NetworkSecurityConfig not found');
    }

    // === Retrofit/OkHttp Interceptor Logging ===
    try {
        var Interceptor = Java.use('okhttp3.Interceptor');
        console.log('[OK] OkHttp Interceptor available for request/response logging');
    } catch(e) {
        console.log('[--] OkHttp Interceptor not found');
    }

    // === SSL Pinning via custom TrustManagerFactory ===
    try {
        var TrustManagerFactory = Java.use('javax.net.ssl.TrustManagerFactory');
        TrustManagerFactory.getTrustManagers.implementation = function() {
            console.log('[+] Intercepting TrustManagerFactory.getTrustManagers');
            var EmptyTrustManager = Java.registerClass({
                name: 'com.bypass.EmptyTrustManager',
                implements: [X509TrustManager],
                methods: {
                    checkClientTrusted: function(chain, authType) {},
                    checkServerTrusted: function(chain, authType) {},
                    getAcceptedIssuers: function() { return []; }
                }
            });
            return [EmptyTrustManager.$new()];
        };
        console.log('[OK] TrustManagerFactory.getTrustManagers hooked');
    } catch(e) {
        console.log('[--] TrustManagerFactory hook failed: ' + e);
    }

    // === Flutter/Dart SSL Pinning ===
    try {
        var module = Process.findModuleByName("libflutter.so");
        if (module) {
            console.log('[*] Flutter detected, attempting native SSL bypass...');
            var ssl_verify = Module.findExportByName("libflutter.so", "ssl_crypto_x509_session_verify_cert_chain");
            if (ssl_verify) {
                Interceptor.attach(ssl_verify, {
                    onLeave: function(retval) {
                        console.log('[+] Bypassing Flutter SSL verification');
                        retval.replace(0x1);
                    }
                });
                console.log('[OK] Flutter SSL bypass hooked');
            }
        }
    } catch(e) {
        console.log('[--] Flutter not found or hook failed');
    }

    console.log('\n[*] SSL Pinning Bypass active!\n');
    console.log('[*] If app still shows SSL errors, it may use custom pinning.');
    console.log('[*] Check logcat for more details: adb logcat -s Frida\n');
});
