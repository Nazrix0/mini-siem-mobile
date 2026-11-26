import 'package:flutter_test/flutter_test.dart';
import 'package:mini_siem_mobile/services/sync_service.dart';

void main() {
  group('Strategia rozwiązywania konfliktów Last-Write-Wins (LWW)', () {
    test('Nowsza zmiana klienta wygrywa z wersją na serwerze', () {
      const clientTs = '2026-11-25T16:10:00Z';
      const serverTs = '2026-11-25T16:05:00Z';
      expect(SyncService.isClientNewerOrEqual(clientTs, serverTs), isTrue);
    });

    test('Starsza zmiana z kolejki offline przegrywa z nowszą na serwerze', () {
      const clientTs = '2026-11-25T16:01:00Z';
      const serverTs = '2026-11-25T16:05:00Z';
      expect(SyncService.isClientNewerOrEqual(clientTs, serverTs), isFalse);
    });

    test('Identyczny znacznik czasu dopuszcza aktualizację klienta', () {
      const ts = '2026-11-25T16:05:00Z';
      expect(SyncService.isClientNewerOrEqual(ts, ts), isTrue);
    });
  });
}