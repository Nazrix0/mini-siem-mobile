import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'sync_service.dart';

class PushService {
  static Future<void> init(SyncService syncService) async {
    try {
      await Firebase.initializeApp();
      final messaging = FirebaseMessaging.instance;

      await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      final token = await messaging.getToken();
      if (token != null && token.isNotEmpty) {
        syncService.setFcmToken(token);
      }

      messaging.onTokenRefresh.listen((newToken) {
        if (newToken.isNotEmpty) {
          syncService.setFcmToken(newToken);
        }
      });

      // 1. Powiadomienie przyszło, gdy aplikacja była otwarta na ekranie
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        final title = message.notification?.title ?? 'Alert mini-SIEM';
        final body = message.notification?.body ?? 'Wykryto nowe zdarzenie';
        syncService.handleIncomingPush(title, body);
      });

      // 2. Użytkownik kliknął w powiadomienie, gdy aplikacja była w tle
      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        final title = message.notification?.title ?? 'Alert mini-SIEM';
        final body = message.notification?.body ?? 'Odświeżanie po kliknięciu alertu';
        syncService.handleIncomingPush(title, body);
      });

      // 3. Użytkownik kliknął w powiadomienie, gdy aplikacja była zamknięta
      final initialMsg = await messaging.getInitialMessage();
      if (initialMsg != null) {
        final title = initialMsg.notification?.title ?? 'Alert mini-SIEM';
        final body = initialMsg.notification?.body ?? 'Otwarto z powiadomienia';
        syncService.handleIncomingPush(title, body);
      }
    } catch (_) {
      syncService.fcmStatus = 'Brak konfiguracji Firebase (tryb lokalny)';
    }
  }
}
