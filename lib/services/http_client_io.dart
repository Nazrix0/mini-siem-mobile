import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import '../config.dart';

http.Client createSecureHttpClient() {
  final ioClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 6)
    ..badCertificateCallback = (X509Certificate cert, String host, int port) {
      final fingerprint = sha256.convert(cert.der).toString().toUpperCase();
      final expected = AppConfig.pinnedCertSha256.trim().toUpperCase();

      if (expected.isEmpty || expected == 'WKLEJ_TU_SHA256_Z_OPENSSL') {
        // Tryb startowy przed wklejeniem hasha – akceptuje tylko serwer1pk
        return host == 'serwer1pk' || host == 'localhost';
      }
      return fingerprint == expected;
    };

  return IOClient(ioClient);
}