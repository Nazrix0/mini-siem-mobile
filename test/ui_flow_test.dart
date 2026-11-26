import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mini_siem_mobile/main.dart';
import 'package:mini_siem_mobile/services/sync_service.dart';

void main() {
  testWidgets(
    'Pełny przepływ UI: logowanie JWT, podgląd alertów, zgłoszenie offline i synchronizacja',
    (WidgetTester tester) async {
      int incidentsPosted = 0;

      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('/api/v1/login')) {
          return http.Response(
            jsonEncode({
              'access_token': 'fake-jwt-token',
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
                'desc': 'Testowy alert SQLi',
                'status': 'NEW',
                'updated_at': '2026-11-26T14:00:00Z',
              }
            ]),
            200,
          );
        }
        if (request.url.path.endsWith('/api/v1/incidents') &&
            request.method == 'POST') {
          incidentsPosted++;
          return http.Response(jsonEncode({'status': 'queued'}), 202);
        }
        return http.Response('{}', 200);
      });

      final syncService = SyncService(
        client: mockClient,
        enableConnectivity: false,
      );
      await syncService.init(inMemory: true);

      await tester.pumpWidget(MiniSiemApp(syncService: syncService));
      await tester.pumpAndSettle();

      // 1. Logowanie JWT
      expect(find.byKey(const Key('login_button')), findsOneWidget);
      await tester.tap(find.byKey(const Key('login_button')));
      await tester.pumpAndSettle();

      // 2. Weryfikacja pobranego alertu na ekranie głównym
      expect(find.textContaining('SQL_INJECTION'), findsOneWidget);

      // 3. Symulacja trybu offline i przejście do zakładki Zgłoś incydent
      syncService.isOnline = false;
      await tester.tap(find.text('Zgłoś incydent'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(const Key('incident_asset')), 'SRV-LAB-07');
      await tester.enterText(
          find.byKey(const Key('incident_desc')), 'Nieautoryzowany pendrive');

      final submitBtn = find.byKey(const Key('incident_submit'));
      await tester.ensureVisible(submitBtn);
      await tester.pumpAndSettle();
      await tester.tap(submitBtn);
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.textContaining('kolejce offline'), findsOneWidget);
      expect(syncService.pendingCount, 1);
      expect(incidentsPosted, 0);

      // 4. Powrót sieci i automatyczna synchronizacja kolejki
      syncService.isOnline = true;
      await syncService.syncAll();
      await tester.pumpAndSettle();

      expect(syncService.pendingCount, 0);
      expect(incidentsPosted, 1);

      syncService.dispose();
    },
  );
}
