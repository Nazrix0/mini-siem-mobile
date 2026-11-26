class AppConfig {
  // Adres backendu mini-SIEM przez VPN (HTTPS na porcie 8443)
  static const String baseUrl = 'https://serwer1pk:8443';

  // Odcisk SHA-256 z nginx/certs/selfsigned.crt (bez dwukropków, wielkie litery)
  // Używany do Certificate Pinning na Androidzie.
  static const String pinnedCertSha256 = 'F4D4A0D0753F6188BCF55A064C3998DE1808DCE0783E10A1C3102DDB1914D573';
}