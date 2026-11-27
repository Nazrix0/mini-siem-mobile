import 'dart:async';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/alert_model.dart';
import '../storage/box_store.dart';
import 'http_client_stub.dart' if (dart.library.io) 'http_client_io.dart';

class SyncService extends ChangeNotifier {
  static const _authBoxName = 'auth_box';
  static const _alertsBoxName = 'alerts_box';
  static const _pendingIncidentsBoxName = 'pending_incidents_box';
  static const _pendingUpdatesBoxName = 'pending_updates_box';
  static const _localAuthSalt = 'mini-siem-mobile-offline-salt-v1';
  static const _maxCachedAlerts = 50;

  final http.Client _client;
  final bool _enableConnectivity;

  SyncService({http.Client? client, bool enableConnectivity = true})
      : _client = client ?? createSecureHttpClient(),
        _enableConnectivity = enableConnectivity;

  late BoxStore _authBox;
  late BoxStore _alertsBox;
  late BoxStore _pendingIncidentsBox;
  late BoxStore _pendingUpdatesBox;

  StreamSubscription<List<ConnectivityResult>>? _connSub;

  // Sesja zawsze wymaga logowania po uruchomieniu aplikacji
  bool _sessionUnlocked = false;
  bool pendingOnlineVerification = false;
  String? _pendingOfflineUsername;
  String? _pendingOfflinePassword;
  String authStatus = 'Wymagane logowanie';
  String? sessionError;

  bool isOnline = true;
  bool isSyncing = false;
  String lastSyncInfo = 'Brak synchronizacji';
  List<String> conflictLog = [];

  // Telemetria pomiarowa (Projekt 2)
  int startupMs = 0;
  int lastSyncMs = 0;
  int bytesSent = 0;
  int bytesReceived = 0;
  int fullSyncCount = 0;
  int deltaSyncCount = 0;
  String lastSyncMode = 'Brak';
  String fcmStatus = 'Nieaktywny (brak klucza Firebase)';
  String? _cachedFcmToken;
  String? lastPushNotice;

  String? get token => _authBox.get('token') as String?;
  String? get username => _authBox.get('username') as String?;
  String? get lastAlertsSyncAt => _alertsBox.get('last_sync_at') as String?;
  bool get isLoggedIn =>
      _sessionUnlocked && username != null && username!.isNotEmpty;

  int get pendingCount =>
      _pendingIncidentsBox.length + _pendingUpdatesBox.length;

  List<AlertMap> get cachedAlerts {
    final raw = _alertsBox.get('list');
    if (raw is! List) return [];
    return raw.map((e) => AlertMap.from(e as Map)).toList();
  }

  List<AlertItem> get alerts =>
      cachedAlerts.map((m) => AlertItem.fromMap(m)).toList();

  static String _hashLocalCredentials(String user, String password) {
    final normalized = '$_localAuthSalt|${user.trim().toLowerCase()}|$password';
    return sha256.convert(utf8.encode(normalized)).toString();
  }

  Future<void> init({String? testPath, bool inMemory = false}) async {
    if (inMemory) {
      _authBox = MemoryBoxStore();
      _alertsBox = MemoryBoxStore();
      _pendingIncidentsBox = MemoryBoxStore();
      _pendingUpdatesBox = MemoryBoxStore();
    } else {
      if (testPath != null) {
        Hive.init(testPath);
      } else {
        await Hive.initFlutter();
      }
      _authBox = HiveBoxStore(await Hive.openBox(_authBoxName));
      _alertsBox = HiveBoxStore(await Hive.openBox(_alertsBoxName));
      _pendingIncidentsBox =
          HiveBoxStore(await Hive.openBox(_pendingIncidentsBoxName));
      _pendingUpdatesBox =
          HiveBoxStore(await Hive.openBox(_pendingUpdatesBoxName));
    }

    if (_enableConnectivity) {
      final initial = await Connectivity().checkConnectivity();
      isOnline = initial.any((r) => r != ConnectivityResult.none);
      if (isOnline) {
        unawaited(checkServerConnection());
      }

      _connSub = Connectivity().onConnectivityChanged.listen((results) {
        final hasNet = results.any((r) => r != ConnectivityResult.none);
        if (!hasNet) {
          isOnline = false;
          lastSyncInfo = 'Brak połączenia z serwerem';
          notifyListeners();
        } else if (isLoggedIn) {
          syncAll();
        } else {
          unawaited(checkServerConnection());
        }
      });
    }
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _client.close();
    super.dispose();
  }

  void resetTelemetryCounters() {
    bytesSent = 0;
    bytesReceived = 0;
    fullSyncCount = 0;
    deltaSyncCount = 0;
    lastSyncMs = 0;
    notifyListeners();
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

  static bool isClientNewerOrEqual(String clientIsoUtc, String serverIsoUtc) {
    final clientDt = DateTime.parse(clientIsoUtc).toUtc();
    final serverDt = DateTime.parse(serverIsoUtc).toUtc();
    return !clientDt.isBefore(serverDt);
  }

  void setFcmToken(String fcmToken) {
    _cachedFcmToken = fcmToken;
    fcmStatus = 'Gotowy (token pozyskany)';
    notifyListeners();
    if (isLoggedIn && isOnline && !pendingOnlineVerification) {
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
    if (!isLoggedIn || token == null) return;
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

  Future<bool> checkServerConnection() async {
    if (!_enableConnectivity && !isOnline) return false;
    try {
      final res = await _client
          .get(Uri.parse('${AppConfig.baseUrl}/health'))
          .timeout(const Duration(seconds: 4));
      final ok = res.statusCode == 200;
      if (isOnline != ok) {
        isOnline = ok;
        notifyListeners();
      }
      return ok;
    } catch (_) {
      if (isOnline) {
        isOnline = false;
        notifyListeners();
      }
      return false;
    }
  }

  Future<String?> _verifyOfflineLogin(String user, String password) async {
    final normalizedUser = user.trim();
    final cachedUser = _authBox.get('cached_user') as String?;
    final cachedHash = _authBox.get('cached_pass_hash') as String?;

    if (cachedUser == null || cachedHash == null) {
      return 'Brak połączenia z serwerem. Pierwsze logowanie wymaga sieci.';
    }

    final inputHash = _hashLocalCredentials(normalizedUser, password);
    if (normalizedUser.toLowerCase() != cachedUser.toLowerCase() ||
        inputHash != cachedHash) {
      return 'Błędny login lub hasło (weryfikacja offline).';
    }

    await _authBox.put('username', cachedUser);
    _sessionUnlocked = true;
    pendingOnlineVerification = true;
    _pendingOfflineUsername = cachedUser;
    _pendingOfflinePassword = password;
    sessionError = null;
    authStatus = 'Zweryfikowano offline (czeka na serwer)';
    lastSyncInfo = 'Sesja offline – zweryfikuje się po powrocie sieci';
    notifyListeners();
    return null;
  }

  Future<String?> login(String user, String password) async {
    final trimmedUser = user.trim();
    sessionError = null;

    if (_enableConnectivity) {
      final conn = await Connectivity().checkConnectivity();
      if (!conn.any((r) => r != ConnectivityResult.none)) {
        isOnline = false;
        notifyListeners();
        return _verifyOfflineLogin(trimmedUser, password);
      }
    } else if (!isOnline) {
      return _verifyOfflineLogin(trimmedUser, password);
    }

    try {
      final body = jsonEncode({'username': trimmedUser, 'password': password});
      final res = await _client.post(
        Uri.parse('${AppConfig.baseUrl}/api/v1/login'),
        headers: {'Content-Type': 'application/json'},
        body: body,
      );
      _trackTraffic(body, res);

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as AlertMap;
        final verifiedUser = (data['username'] ?? trimmedUser).toString();
        await _authBox.put('token', data['access_token']);
        await _authBox.put('username', verifiedUser);
        await _authBox.put('cached_user', verifiedUser);
        await _authBox.put(
          'cached_pass_hash',
          _hashLocalCredentials(verifiedUser, password),
        );

        isOnline = true;
        _sessionUnlocked = true;
        pendingOnlineVerification = false;
        _pendingOfflineUsername = null;
        _pendingOfflinePassword = null;
        authStatus = 'Zweryfikowano z serwerem (JWT)';
        notifyListeners();

        if (_cachedFcmToken != null) {
          unawaited(registerFcmToken(_cachedFcmToken!));
        }
        await syncAll();
        return null;
      }

      if (res.statusCode == 401 || res.statusCode == 403) {
        final err = jsonDecode(res.body);
        return err['detail']?.toString() ?? 'Błędny login lub hasło';
      }
      return 'Błąd serwera (${res.statusCode})';
    } catch (_) {
      isOnline = false;
      notifyListeners();
      return _verifyOfflineLogin(trimmedUser, password);
    }
  }

  Future<bool> _verifyPendingOnlineSession() async {
    if (!pendingOnlineVerification) return true;
    final u = _pendingOfflineUsername;
    final p = _pendingOfflinePassword;
    if (u == null || p == null) {
      await _forceRelogin('Wymagana ponowna weryfikacja na serwerze.');
      return false;
    }

    try {
      final body = jsonEncode({'username': u, 'password': p});
      final res = await _client.post(
        Uri.parse('${AppConfig.baseUrl}/api/v1/login'),
        headers: {'Content-Type': 'application/json'},
        body: body,
      );
      _trackTraffic(body, res);

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as AlertMap;
        await _authBox.put('token', data['access_token']);
        await _authBox.put('username', data['username'] ?? u);
        pendingOnlineVerification = false;
        _pendingOfflineUsername = null;
        _pendingOfflinePassword = null;
        authStatus = 'Zweryfikowano z serwerem (JWT)';
        if (_cachedFcmToken != null) {
          unawaited(registerFcmToken(_cachedFcmToken!));
        }
        notifyListeners();
        return true;
      }

      if (res.statusCode == 401 || res.statusCode == 403) {
        await _forceRelogin(
          'Serwer odrzucił sesję offline (hasło zmienione lub konto nieaktywne). Zaloguj się ponownie.',
        );
        return false;
      }
      return false;
    } catch (_) {
      isOnline = false;
      lastSyncInfo = 'Brak połączenia z serwerem (sesja offline)';
      return false;
    }
  }

  Future<void> _forceRelogin(String reason) async {
    _sessionUnlocked = false;
    pendingOnlineVerification = false;
    _pendingOfflineUsername = null;
    _pendingOfflinePassword = null;
    await _authBox.delete('token');
    authStatus = 'Sesja odrzucona';
    sessionError = reason;
    notifyListeners();
  }

  Future<void> logout() async {
    _sessionUnlocked = false;
    pendingOnlineVerification = false;
    _pendingOfflineUsername = null;
    _pendingOfflinePassword = null;
    sessionError = null;
    authStatus = 'Wylogowano';
    await _authBox.delete('token');
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

    if (isOnline && !pendingOnlineVerification && token != null) {
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
      } catch (_) {
        isOnline = false;
      }
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

    if (isOnline && !pendingOnlineVerification && token != null) {
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

  Future<void> _applySingleAlertToCache(AlertMap serverAlert) async {
    final normalized = AlertItem.fromMap(serverAlert).toMap();
    final current = cachedAlerts;
    final idx = current.indexWhere((a) => a['id'] == normalized['id']);
    if (idx >= 0) {
      current[idx] = normalized;
    } else {
      current.insert(0, normalized);
    }
    await _alertsBox.put('list', current);
  }

  Future<String?> _sendStatusPatch(AlertMap task) async {
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
        final data = jsonDecode(res.body) as AlertMap;
        if (data['alert'] is Map) {
          final serverAlert = AlertMap.from(data['alert'] as Map);
          // Uzupełnij istniejący rekord polami z serwera (np. status, updated_at)
          final existing = cachedAlerts.firstWhere(
            (a) => a['id'] == task['alert_id'],
            orElse: () => <String, dynamic>{},
          );
          await _applySingleAlertToCache({...existing, ...serverAlert});
        }
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
      isOnline = false;
      return null;
    }
    return null;
  }

  Future<void> syncAll({bool forceFull = false}) async {
    if (isSyncing || !isLoggedIn) return;
    isSyncing = true;
    notifyListeners();

    final sw = Stopwatch()..start();
    try {
      final reachable = await checkServerConnection();
      if (!reachable) {
        sw.stop();
        isOnline = false;
        lastSyncInfo = 'Brak połączenia z serwerem';
        return;
      }
      isOnline = true;

      if (pendingOnlineVerification) {
        final verified = await _verifyPendingOnlineSession();
        if (!verified) {
          sw.stop();
          return;
        }
      }

      final incidentKeys = _pendingIncidentsBox.keys.toList();
      for (final key in incidentKeys) {
        final raw = _pendingIncidentsBox.get(key);
        if (raw == null) continue;
        final body = jsonEncode(AlertMap.from(raw as Map));
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
        final task = AlertMap.from(raw as Map);
        final outcome = await _sendStatusPatch(task);
        if (outcome != null) {
          await _pendingUpdatesBox.delete(key);
        }
      }

      await fetchAlerts(forceFull: forceFull);
      sw.stop();
      lastSyncMs = sw.elapsedMilliseconds;
      lastSyncInfo =
          'Sync ($lastSyncMode): $lastSyncMs ms (${DateTime.now().toIso8601String().substring(11, 19)})';
    } catch (_) {
      sw.stop();
      isOnline = false;
      lastSyncInfo = 'Brak połączenia z serwerem';
    } finally {
      isSyncing = false;
      notifyListeners();
    }
  }

  /// Synchronizacja przyrostowa (Delta Sync): wysyła ?since=<ostatni_updated_at>
  /// i scala wyłącznie nowe/zmienione alerty z lokalną bazą Hive.
  Future<void> fetchAlerts({bool forceFull = false}) async {
    final currentList = cachedAlerts;
    final since = (!forceFull && currentList.isNotEmpty) ? lastAlertsSyncAt : null;

    final queryParams = <String, String>{
      'limit': '$_maxCachedAlerts',
      if (since != null && since.isNotEmpty) 'since': since,
    };
    final uri = Uri.parse('${AppConfig.baseUrl}/api/v1/alerts')
        .replace(queryParameters: queryParams);

    final res = await _client.get(uri, headers: _authHeaders());
    _trackTraffic(null, res);

    if (res.statusCode == 200) {
      final decoded = (jsonDecode(res.body) as List<dynamic>)
          .map((e) => AlertItem.fromMap(AlertMap.from(e as Map)).toMap())
          .toList();

      List<AlertMap> merged;
      if (since != null) {
        deltaSyncCount++;
        lastSyncMode = 'Delta +${decoded.length}';
        final byId = <int, AlertMap>{
          for (final item in currentList) (item['id'] as num).toInt(): item,
        };
        for (final item in decoded) {
          byId[(item['id'] as num).toInt()] = item;
        }
        merged = byId.values.toList()
          ..sort((a, b) => (b['id'] as num).compareTo(a['id'] as num));
        if (merged.length > _maxCachedAlerts) {
          merged = merged.sublist(0, _maxCachedAlerts);
        }
      } else {
        fullSyncCount++;
        lastSyncMode = 'Full (${decoded.length})';
        merged = decoded;
      }

      String? maxTs = since;
      for (final item in merged) {
        final ts = (item['updated_at'] ?? item['timestamp'])?.toString();
        if (ts == null || ts.isEmpty) continue;
        if (maxTs == null || ts.compareTo(maxTs) > 0) {
          maxTs = ts;
        }
      }

      await _alertsBox.put('list', merged);
      if (maxTs != null) {
        await _alertsBox.put('last_sync_at', maxTs);
      }
      notifyListeners();
    }
  }
}
