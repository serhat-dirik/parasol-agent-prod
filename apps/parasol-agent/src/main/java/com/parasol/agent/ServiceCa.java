package com.parasol.agent;

import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyStore;
import java.security.cert.Certificate;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;

import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManager;
import javax.net.ssl.TrustManagerFactory;
import javax.net.ssl.X509TrustManager;

/**
 * TLS trust for in-cluster calls: the JDK's default CAs plus the cluster service CA from {@code SERVICE_CA_FILE}
 * (the namespace's openshift-service-ca.crt ConfigMap, mounted in secured), so Keycloak's in-cluster Service
 * (a service-serving certificate) verifies. Without the file: the JDK default.
 */
final class ServiceCa {

    private ServiceCa() {
    }

    static SSLContext sslContext() {
        try {
            String file = System.getenv("SERVICE_CA_FILE");
            if (file == null || file.isBlank() || !Files.isReadable(Path.of(file))) {
                return SSLContext.getDefault();
            }
            KeyStore ks = KeyStore.getInstance(KeyStore.getDefaultType());
            ks.load(null, null);
            TrustManagerFactory def = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
            def.init((KeyStore) null);
            int i = 0;
            for (TrustManager tm : def.getTrustManagers()) {
                if (tm instanceof X509TrustManager x) {
                    for (X509Certificate c : x.getAcceptedIssuers()) {
                        ks.setCertificateEntry("default-" + i++, c);
                    }
                }
            }
            try (InputStream in = Files.newInputStream(Path.of(file))) {
                for (Certificate c : CertificateFactory.getInstance("X.509").generateCertificates(in)) {
                    ks.setCertificateEntry("service-ca-" + i++, c);
                }
            }
            TrustManagerFactory tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
            tmf.init(ks);
            SSLContext ctx = SSLContext.getInstance("TLS");
            ctx.init(null, tmf.getTrustManagers(), null);
            return ctx;
        } catch (Exception e) {
            throw new IllegalStateException("cannot build the TLS trust store", e);
        }
    }
}
