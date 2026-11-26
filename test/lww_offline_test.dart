import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mini_siem_mobile/services/sync_service.dart';

void main() {
  group('Strategia rozwiązywania konfliktów Last-Write-Wins (LWW)', () {
    test('Nowsza zmiana klienta wygrywa z wersją na serwerze', () {
      const clientTs = '2026-11-26T16:10:00Z';
      const serverTs = '2026-11-26T16:05:00Z';
      expect(SyncService.isClientNewerOrEqual(clientTs, serverTs), isTrue);
    });

    test('Starsza zmiana z kolejki offline przegrywa z nowszą na serwerze', () {
      const clientTs = '2026-11-26T16:01:00Z';
      const serverTs = '2026-11-26T16:05:00Z';
      expect(SyncService.isClientNewerOrEqual(clientTs, serverTs), isFalse);
    });

    test('Identyczny znacznik czasu dopuszcza aktualizację klienta', () {
      const ts = '2026-11-26T16:05:00Z';
      expect(SyncService.isClientNewerOrEqual(ts, ts), isTrue);
    });

    test(
      'Konflikt offline LWW: serwer odrzuca starszą zmianę, aplikacja loguje konflikt i przyjmuje stan serwera',
      () async {
        String serverStatus = 'NEW';
        int patchCount = 0;

        final mockClient = MockClient((request) async {
          if (request.url.path.endsWith('/api/v1/login')) {
            return http.Response(
              jsonEncode({
                'access_token': 'jwt-test',
                'token_type': 'bearer',
                'username': 'admin',
                'role': 'admin',
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/api/v1/alerts') &&
              request.method == 'GET') {
            return http.Response(
              jsonEncode([
                {
                  'id': 1,
                  'timestamp': '2026-11-26T14:00:00Z',
                  'ip': '10.0.0.5',
                  'type': 'SQL_INJECTION',
                  'desc': 'Test konfliktu LWW',
                  'status': serverStatus,
                  'updated_at': '2026-11-26T20:00:00Z',
                }
              ]),
              200,
            );
          }
          if (request.url.path.endsWith('/api/v1/alerts/1') &&
              request.method == 'PATCH') {
            patchCount++;
            return http.Response(
              jsonEncode({
                'result': 'ignored_stale',
                'conflict_resolved': true,
                'winner': 'server',
                'reason': 'Serwer ma nowszą wersję (2026-11-26T20:00:00Z)',
                'alert': {'id': 1, 'status': 'RESOLVED'},
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response('{}', 200);
        });

        final syncService = SyncService(
          client: mockClient,
          enableConnectivity: false,
        );
        await syncService.init(inMemory: true);

        // Logowanie i pobranie początkowego stanu (status NEW)
        expect(await syncService.login('admin', 'admin123'), isNull);
        expect(syncService.cachedAlerts.first['status'], 'NEW');

        // Użytkownik traci sieć i zmienia status lokalnie na IN_PROGRESS
        syncService.isOnline = false;
        await syncService.updateAlertStatus(1, 'IN_PROGRESS');
        expect(syncService.pendingCount, 1);
        expect(syncService.cachedAlerts.first['status'], 'IN_PROGRESS');

        // W międzyczasie inny analityk zamknął alert na serwerze (RESOLVED)
        serverStatus = 'RESOLVED';

        // Powrót sieci i synchronizacja -> serwer wygrywa konflikt LWW
        syncService.isOnline = true;
        await syncService.syncAll();

        expect(patchCount, 1);
        expect(syncService.pendingCount, 0);
        expect(syncService.conflictLog.length, 1);
        expect(syncService.conflictLog.first, contains('Konflikt LWW #1'));
        expect(syncService.cachedAlerts.first['status'], 'RESOLVED');

        syncService.dispose();
      },
    );
  });
}
