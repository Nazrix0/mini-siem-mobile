import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'sync_service.dart';

class PushService {
  static Future<void> init(SyncService syncService) async {
    if (kIsWeb) {
      syncService.fcmStatus = 'Tryb Web (Push FCM aktywny w aplikacji Android)';
      return;
    }

    try {
      await Firebase.initializeApp();
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(alert: true, badge: true, sound: true);

      final token = await messaging.getToken();
      if (token != null && token.isNotEmpty) {
        syncService.setFcmToken(token);
      }

      messaging.onTokenRefresh.listen((newToken) {
        syncService.setFcmToken(newToken);
      });

      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        final title = message.notification?.title ?? 'Nowy alert SIEM';
        final body = message.notification?.body ?? '';
        syncService.handleIncomingPush(title, body);
      });
    } catch (e) {
      syncService.fcmStatus = 'Brak konfiguracji google-services.json';
      debugPrint('[PushService] Pominięto Firebase: $e');
    }
  }
}
