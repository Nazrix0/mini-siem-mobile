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

    test(
      'Logowanie offline (SHA-256) i ponowna weryfikacja JWT z serwerem po powrocie sieci',
      () async {
        int loginCalls = 0;

        final mockClient = MockClient((request) async {
          if (request.url.path.endsWith('/api/v1/login')) {
            loginCalls++;
            return http.Response(
              jsonEncode({
                'access_token': 'jwt-token-$loginCalls',
                'token_type': 'bearer',
                'username': 'admin',
                'role': 'admin',
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/api/v1/alerts')) {
            return http.Response('[]', 200);
          }
          return http.Response('{}', 200);
        });

        final syncService = SyncService(
          client: mockClient,
          enableConnectivity: false,
        );
        await syncService.init(inMemory: true);

        // 1. Pierwsze logowanie online zapisuje skrót SHA-256 w lokalnym magazynie
        expect(await syncService.login('admin', 'admin123'), isNull);
        expect(loginCalls, 1);
        expect(syncService.isLoggedIn, isTrue);

        // 2. Wylogowanie i przejście w tryb offline
        await syncService.logout();
        syncService.isOnline = false;
        expect(syncService.isLoggedIn, isFalse);

        // 3. Błędne hasło offline musi zostać odrzucone
        final badErr = await syncService.login('admin', 'zle_haslo');
        expect(badErr, contains('weryfikacja offline'));
        expect(syncService.isLoggedIn, isFalse);

        // 4. Poprawne hasło offline odblokowuje sesję z flagą oczekiwania na serwer
        expect(await syncService.login('admin', 'admin123'), isNull);
        expect(syncService.isLoggedIn, isTrue);
        expect(syncService.pendingOnlineVerification, isTrue);
        expect(loginCalls, 1);

        // 5. Powrót sieci i synchronizacja -> automatyczna weryfikacja na serwerze
        syncService.isOnline = true;
        await syncService.syncAll();
        expect(loginCalls, 2);
        expect(syncService.pendingOnlineVerification, isFalse);
        expect(syncService.token, 'jwt-token-2');

        syncService.dispose();
      },
    );

    test(
      'Synchronizacja przyrostowa (Delta Sync): wysyła ?since= i scala nowe alerty bez nadpisywania starych',
      () async {
        final seenQueries = <Map<String, String>>[];

        final mockClient = MockClient((request) async {
          if (request.url.path.endsWith('/api/v1/login')) {
            return http.Response(
              jsonEncode({
                'access_token': 'jwt-delta',
                'token_type': 'bearer',
                'username': 'admin',
                'role': 'admin',
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/api/v1/alerts')) {
            seenQueries.add(Map<String, String>.from(request.url.queryParameters));
            if (!request.url.queryParameters.containsKey('since')) {
              return http.Response(
                jsonEncode([
                  {
                    'id': 1,
                    'timestamp': '2026-11-27T07:00:00Z',
                    'ip': '10.0.0.1',
                    'type': 'SQL_INJECTION',
                    'desc': 'Pierwszy alert',
                    'status': 'NEW',
                    'updated_at': '2026-11-27T07:00:00Z',
                  }
                ]),
                200,
              );
            }
            return http.Response(
              jsonEncode([
                {
                  'id': 2,
                  'timestamp': '2026-11-27T07:05:00Z',
                  'ip': '10.0.0.2',
                  'type': 'XSS_ATTACK',
                  'desc': 'Nowy alert przyrostowy',
                  'status': 'NEW',
                  'updated_at': '2026-11-27T07:05:00Z',
                }
              ]),
              200,
            );
          }
          return http.Response('{}', 200);
        });

        final syncService = SyncService(
          client: mockClient,
          enableConnectivity: false,
        );
        await syncService.init(inMemory: true);

        // 1. Pierwsze logowanie -> Full Sync (bez parametru since)
        expect(await syncService.login('admin', 'admin123'), isNull);
        expect(seenQueries.first.containsKey('since'), isFalse);
        expect(syncService.fullSyncCount, 1);
        expect(syncService.alerts.length, 1);

        // 2. Kolejna synchronizacja -> Delta Sync (?since=2026-11-27T07:00:00Z)
        await syncService.syncAll();
        expect(seenQueries.last['since'], '2026-11-27T07:00:00Z');
        expect(syncService.deltaSyncCount, 1);
        expect(syncService.alerts.length, 2);
        expect(syncService.alerts.first.id, 2);
        expect(syncService.alerts.last.id, 1);

        syncService.dispose();
      },
    );
  });
}
