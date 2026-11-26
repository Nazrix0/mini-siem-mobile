import 'dart:async';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import 'http_client_stub.dart' if (dart.library.io) 'http_client_io.dart';

class SyncService extends ChangeNotifier {
  static const _authBoxName = 'auth_box';
  static const _alertsBoxName = 'alerts_box';
  static const _pendingIncidentsBoxName = 'pending_incidents_box';
  static const _pendingUpdatesBoxName = 'pending_updates_box';

  final http.Client _client;
  final bool _enableConnectivity;

  SyncService({http.Client? client, bool enableConnectivity = true})
      : _client = client ?? createSecureHttpClient(),
        _enableConnectivity = enableConnectivity;

  late Box _authBox;
  late Box _alertsBox;
  late Box _pendingIncidentsBox;
  late Box _pendingUpdatesBox;

  StreamSubscription<List<ConnectivityResult>>? _connSub;

  bool isOnline = true;
  bool isSyncing = false;
  String lastSyncInfo = 'Brak synchronizacji';
  List<String> conflictLog = [];

  // Telemetria pod pomiary na rzeczywistym telefonie (Projekt 2)
  int startupMs = 0;
  int lastSyncMs = 0;
  int bytesSent = 0;
  int bytesReceived = 0;
  String fcmStatus = 'Nieaktywny (brak klucza Firebase)';
  String? _cachedFcmToken;
  String? lastPushNotice;

  String? get token => _authBox.get('token') as String?;
  String? get username => _authBox.get('username') as String?;
  bool get isLoggedIn => token != null && token!.isNotEmpty;

  int get pendingCount =>
      _pendingIncidentsBox.length + _pendingUpdatesBox.length;

  List< Map<String, dynamic> > get cachedAlerts {
    final raw = _alertsBox.get('list');
    if (raw is! List) return [];
    return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<void> init({String? testPath}) async {
    if (testPath != null) {
      Hive.init(testPath);
    } else {
      await Hive.initFlutter();
    }
    _authBox = await Hive.openBox(_authBoxName);
    _alertsBox = await Hive.openBox(_alertsBoxName);
    _pendingIncidentsBox = await Hive.openBox(_pendingIncidentsBoxName);
    _pendingUpdatesBox = await Hive.openBox(_pendingUpdatesBoxName);

    if (_enableConnectivity) {
      final initial = await Connectivity().checkConnectivity();
      isOnline = initial.any((r) => r != ConnectivityResult.none);

      _connSub = Connectivity().onConnectivityChanged.listen((results) {
        final onlineNow = results.any((r) => r != ConnectivityResult.none);
        final wasOffline = !isOnline;
        isOnline = onlineNow;
        notifyListeners();

        if (onlineNow && wasOffline && isLoggedIn) {
          syncAll();
        }
      });

      if (isOnline && isLoggedIn) {
        unawaited(syncAll());
      }
    }
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _client.close();
    super.dispose();
  }

  Map<String, String> _authHeaders() => {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  void _trackTraffic(String? sentBody, http.Response res) {
    if (sentBody != null) {
      bytesSent += utf8.encode(sentBody).length;
    }
    bytesReceived += res.bodyBytes.length;
  }

  /// Czysta funkcja porównująca LWW (używana także w testach jednostkowych)
  static bool isClientNewerOrEqual(String clientIsoUtc, String serverIsoUtc) {
    final clientDt = DateTime.parse(clientIsoUtc).toUtc();
    final serverDt = DateTime.parse(serverIsoUtc).toUtc();
    return !clientDt.isBefore(serverDt);
  }

  void setFcmToken(String fcmToken) {
    _cachedFcmToken = fcmToken;
    fcmStatus = 'Gotowy (token pozyskany)';
    notifyListeners();
    if (isLoggedIn && isOnline) {
      unawaited(registerFcmToken(fcmToken));
    }
  }

  void handleIncomingPush(String title, String body) {
    lastPushNotice = '$title: $body';
    notifyListeners();
    if (isLoggedIn && isOnline) {
      unawaited(fetchAlerts());
    }
  }

  Future<void> registerFcmToken(String fcmToken) async {
    if (!isLoggedIn) return;
    try {
      final body = jsonEncode({'fcm_token': fcmToken});
      final res = await _client.post(
        Uri.parse('${AppConfig.baseUrl}/api/v1/devices'),
        headers: _authHeaders(),
        body: body,
      );
      _trackTraffic(body, res);
      if (res.statusCode == 200) {
        fcmStatus = 'Zarejestrowany na serwerze';
        notifyListeners();
      }
    } catch (_) {
      fcmStatus = 'Oczekuje na rejestrację (offline)';
    }
  }

  Future<String?> login(String user, String password) async {
    try {
      final body = jsonEncode({'username': user.trim(), 'password': password});
      final res = await _client.post(
        Uri.parse('${AppConfig.baseUrl}/api/v1/login'),
        headers: {'Content-Type': 'application/json'},
        body: body,
      );
      _trackTraffic(body, res);
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        await _authBox.put('token', data['access_token']);
        await _authBox.put('username', data['username']);
        notifyListeners();
        if (_cachedFcmToken != null) {
          unawaited(registerFcmToken(_cachedFcmToken!));
        }
        await syncAll();
        return null;
      }
      final err = jsonDecode(res.body);
      return err['detail']?.toString() ?? 'Błąd logowania (${res.statusCode})';
    } catch (e) {
      return 'Brak połączenia z ${AppConfig.baseUrl}: $e';
    }
  }

  Future<void> logout() async {
    await _authBox.clear();
    notifyListeners();
  }

  Future<String> reportIncident({
    required String assetId,
    required String description,
    required String severity,
    String? sourceIp,
    double? latitude,
    double? longitude,
  }) async {
    final cleanedIp = sourceIp?.trim();
    final payload = {
      'asset_id': assetId.trim(),
      'description': description.trim(),
      'severity': severity,
      if (cleanedIp != null && cleanedIp.isNotEmpty) 'source_ip': cleanedIp,
      'latitude': latitude,
      'longitude': longitude,
      'client_created_at': DateTime.now().toUtc().toIso8601String(),
    };

    if (isOnline) {
      try {
        final body = jsonEncode(payload);
        final res = await _client.post(
          Uri.parse('${AppConfig.baseUrl}/api/v1/incidents'),
          headers: _authHeaders(),
          body: body,
        );
        _trackTraffic(body, res);
        if (res.statusCode == 202 || res.statusCode == 200) {
          unawaited(fetchAlerts());
          return 'Wysłano do mini-SIEM';
        }
      } catch (_) {}
    }

    await _pendingIncidentsBox.add(payload);
    notifyListeners();
    return 'Zapisano w kolejce offline (wyśle się po powrocie sieci)';
  }

  Future<String> updateAlertStatus(int alertId, String newStatus) async {
    final nowUtc = DateTime.now().toUtc().toIso8601String();

    final list = cachedAlerts;
    for (final item in list) {
      if (item['id'] == alertId) {
        item['status'] = newStatus;
        item['updated_at'] = nowUtc;
        break;
      }
    }
    await _alertsBox.put('list', list);

    final updateTask = {
      'alert_id': alertId,
      'status': newStatus,
      'client_updated_at': nowUtc,
    };

    if (isOnline) {
      final result = await _sendStatusPatch(updateTask);
      if (result != null) {
        await fetchAlerts();
        notifyListeners();
        return result;
      }
    }

    await _pendingUpdatesBox.put('alert_$alertId', updateTask);
    notifyListeners();
    return 'Zmiana statusu zapisana offline (LWW: $nowUtc)';
  }

  Future<String?> _sendStatusPatch(Map<String, dynamic> task) async {
    try {
      final body = jsonEncode({
        'status': task['status'],
        'client_updated_at': task['client_updated_at'],
      });
      final res = await _client.patch(
        Uri.parse('${AppConfig.baseUrl}/api/v1/alerts/${task['alert_id']}'),
        headers: _authHeaders(),
        body: body,
      );
      _trackTraffic(body, res);
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        if (data['conflict_resolved'] == true) {
          final msg =
              'Konflikt LWW #${task['alert_id']}: wygrał serwer (${data['reason']})';
          conflictLog.insert(0, msg);
          return msg;
        }
        return 'Zaktualizowano status alertu #${task['alert_id']}';
      }
      if (res.statusCode == 404) {
        return 'Alert #${task['alert_id']} nie istnieje na serwerze';
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  Future<void> syncAll() async {
    if (isSyncing || !isLoggedIn) return;
    isSyncing = true;
    notifyListeners();

    final sw = Stopwatch()..start();
    try {
      final incidentKeys = _pendingIncidentsBox.keys.toList();
      for (final key in incidentKeys) {
        final raw = _pendingIncidentsBox.get(key);
        if (raw == null) continue;
        final body = jsonEncode(Map<String, dynamic>.from(raw as Map));
        final res = await _client.post(
          Uri.parse('${AppConfig.baseUrl}/api/v1/incidents'),
          headers: _authHeaders(),
          body: body,
        );
        _trackTraffic(body, res);
        if (res.statusCode == 202 || res.statusCode == 200) {
          await _pendingIncidentsBox.delete(key);
        }
      }

      final updateKeys = _pendingUpdatesBox.keys.toList();
      for (final key in updateKeys) {
        final raw = _pendingUpdatesBox.get(key);
        if (raw == null) continue;
        final task = Map<String, dynamic>.from(raw as Map);
        final outcome = await _sendStatusPatch(task);
        if (outcome != null) {
          await _pendingUpdatesBox.delete(key);
        }
      }

      await fetchAlerts();
      sw.stop();
      lastSyncMs = sw.elapsedMilliseconds;
      lastSyncInfo =
          'Sync: ${lastSyncMs} ms (${DateTime.now().toIso8601String().substring(11, 19)})';
    } catch (_) {
      sw.stop();
      lastSyncInfo = 'Błąd synchronizacji (tryb offline)';
    } finally {
      isSyncing = false;
      notifyListeners();
    }
  }

  Future<void> fetchAlerts() async {
    final res = await _client.get(
      Uri.parse('${AppConfig.baseUrl}/api/v1/alerts?limit=50'),
      headers: _authHeaders(),
    );
    _trackTraffic(null, res);
    if (res.statusCode == 200) {
      final decoded = jsonDecode(res.body) as List<dynamic>;
      await _alertsBox.put('list', decoded);
      notifyListeners();
    }
  }
}
