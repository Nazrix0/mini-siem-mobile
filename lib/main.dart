import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'services/push_service.dart';
import 'services/sync_service.dart';

void main() async {
  final startupSw = Stopwatch()..start();
  WidgetsFlutterBinding.ensureInitialized();

  final syncService = SyncService();
  await syncService.init();
  await PushService.init(syncService);

  WidgetsBinding.instance.addPostFrameCallback((_) {
    startupSw.stop();
    syncService.startupMs = startupSw.elapsedMilliseconds;
  });

  runApp(MiniSiemApp(syncService: syncService));
}

class MiniSiemApp extends StatelessWidget {
  final SyncService syncService;
  const MiniSiemApp({super.key, required this.syncService});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mini-SIEM Mobile',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
      ),
      home: AnimatedBuilder(
        animation: syncService,
        builder: (context, _) {
          if (!syncService.isLoggedIn) {
            return LoginScreen(syncService: syncService);
          }
          return HomeScreen(syncService: syncService);
        },
      ),
    );
  }
}

class LoginScreen extends StatefulWidget {
  final SyncService syncService;
  const LoginScreen({super.key, required this.syncService});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _userCtrl = TextEditingController(text: 'admin');
  final _passCtrl = TextEditingController(text: 'admin123');
  bool _loading = false;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final err = await widget.syncService.login(_userCtrl.text, _passCtrl.text);
    if (mounted) {
      setState(() {
        _loading = false;
        _error = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.security, size: 64, color: Colors.indigo),
                const SizedBox(height: 12),
                const Text(
                  'Mini-SIEM Mobile',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 24),
                TextField(
                  key: const Key('login_username'),
                  controller: _userCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Login',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('login_password'),
                  controller: _passCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Hasło',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: const TextStyle(color: Colors.red)),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const Key('login_button'),
                    onPressed: _loading ? null : _submit,
                    child: _loading
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Zaloguj (JWT)'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final SyncService syncService;
  const HomeScreen({super.key, required this.syncService});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tabIndex = 0;

  void _showTelemetryDialog() {
    final s = widget.syncService;
    final totalKb = ((s.bytesSent + s.bytesReceived) / 1024).toStringAsFixed(2);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Pomiary i Konflikty LWW'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Czas uruchomienia: ${s.startupMs} ms'),
              Text('Ostatnia synchronizacja: ${s.lastSyncMs} ms'),
              Text('Wysłano danych: ${s.bytesSent} B'),
              Text('Odebrano danych: ${s.bytesReceived} B'),
              Text('Łączny transfer sesji: $totalKb KB'),
              const Divider(),
              Text('Status Push (FCM): ${s.fcmStatus}'),
              const Divider(),
              const Text(
                'Historia konfliktów LWW:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              if (s.conflictLog.isEmpty)
                const Text('Brak konfliktów w tej sesji.')
              else
                ...s.conflictLog.map((c) => Text('• $c')),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Zamknij'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.syncService;
    return Scaffold(
      appBar: AppBar(
        title: Text('Mini-SIEM (${s.username ?? ''})'),
        actions: [
          IconButton(
            key: const Key('telemetry_button'),
            tooltip: 'Pomiary i konflikty',
            onPressed: _showTelemetryDialog,
            icon: const Icon(Icons.analytics_outlined),
          ),
          IconButton(
            tooltip: 'Synchronizuj teraz',
            onPressed: s.isSyncing ? null : () => s.syncAll(),
            icon: s.isSyncing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
          ),
          IconButton(
            tooltip: 'Wyloguj',
            onPressed: () => s.logout(),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: s.isOnline ? Colors.green.shade100 : Colors.orange.shade200,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Icon(s.isOnline ? Icons.wifi : Icons.wifi_off, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${s.isOnline ? "ONLINE" : "OFFLINE"} • Kolejka: ${s.pendingCount} • ${s.lastSyncInfo}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          if (s.lastPushNotice != null)
            MaterialBanner(
              content: Text('PUSH: ${s.lastPushNotice}'),
              backgroundColor: Colors.red.shade50,
              actions: [
                TextButton(
                  onPressed: () {
                    s.lastPushNotice = null;
                    setState(() {});
                  },
                  child: const Text('OK'),
                ),
              ],
            ),
          Expanded(
            child: _tabIndex == 0
                ? AlertsTab(syncService: s)
                : ReportIncidentTab(syncService: s),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (i) => setState(() => _tabIndex = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.warning_amber),
            label: 'Alerty (LWW)',
          ),
          NavigationDestination(
            icon: Icon(Icons.qr_code_scanner),
            label: 'Zgłoś incydent',
          ),
        ],
      ),
    );
  }
}

class AlertsTab extends StatelessWidget {
  final SyncService syncService;
  const AlertsTab({super.key, required this.syncService});

  @override
  Widget build(BuildContext context) {
    final alerts = syncService.cachedAlerts;
    if (alerts.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Brak alertów w lokalnej bazie.'),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () => syncService.syncAll(),
              child: const Text('Odśwież z serwera'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => syncService.syncAll(),
      child: ListView.builder(
        itemCount: alerts.length,
        itemBuilder: (context, index) {
          final a = alerts[index];
          final id = a['id'] as int;
          final currentStatus = (a['status'] ?? 'NEW').toString();
          final assetId = a['asset_id'];
          final lat = a['latitude'];
          final lon = a['longitude'];

          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: ListTile(
              title: Text(
                '#${a['id']} • ${a['type']}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${a['desc']}'),
                  const SizedBox(height: 4),
                  Text(
                    'IP/Źródło: ${a['ip']} | UTC: ${a['updated_at'] ?? a['timestamp']}',
                    style: const TextStyle(fontSize: 11, color: Colors.black54),
                  ),
                  if (assetId != null || lat != null)
                    Text(
                      'QR: ${assetId ?? "-"} | GPS: ${lat != null ? "$lat, $lon" : "brak"}',
                      style:
                          const TextStyle(fontSize: 11, color: Colors.indigo),
                    ),
                ],
              ),
              trailing: DropdownButton<String>(
                key: Key('alert_status_$id'),
                value: ['NEW', 'IN_PROGRESS', 'RESOLVED']
                        .contains(currentStatus)
                    ? currentStatus
                    : 'NEW',
                items: const [
                  DropdownMenuItem(value: 'NEW', child: Text('NEW')),
                  DropdownMenuItem(
                      value: 'IN_PROGRESS', child: Text('W TRAKCIE')),
                  DropdownMenuItem(value: 'RESOLVED', child: Text('ZAMKNIĘTY')),
                ],
                onChanged: (val) async {
                  if (val == null || val == currentStatus) return;
                  final msg = await syncService.updateAlertStatus(id, val);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(msg)));
                  }
                },
              ),
            ),
          );
        },
      ),
    );
  }
}

class ReportIncidentTab extends StatefulWidget {
  final SyncService syncService;
  const ReportIncidentTab({super.key, required this.syncService});

  @override
  State<ReportIncidentTab> createState() => _ReportIncidentTabState();
}

class _ReportIncidentTabState extends State<ReportIncidentTab> {
  final _assetCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  String _severity = 'HIGH';
  double? _lat;
  double? _lon;
  String _gpsInfo = 'Nie pobrano (opcjonalne)';
  bool _sending = false;

  Future<void> _scanQr() async {
    final scanned = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScannerPage()),
    );
    if (scanned != null && scanned.isNotEmpty) {
      setState(() => _assetCtrl.text = scanned);
    }
  }

  Future<void> _fetchGps() async {
    setState(() => _gpsInfo = 'Pobieranie GPS...');
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) {
        setState(() => _gpsInfo = 'Usługa lokalizacji wyłączona');
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        setState(() => _gpsInfo = 'Brak uprawnień GPS');
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 6),
        ),
      );
      setState(() {
        _lat = double.parse(pos.latitude.toStringAsFixed(5));
        _lon = double.parse(pos.longitude.toStringAsFixed(5));
        _gpsInfo = 'Pobrano: $_lat, $_lon';
      });
    } catch (_) {
      setState(() => _gpsInfo = 'GPS niedostępny (wyśle bez lokalizacji)');
    }
  }

  Future<void> _submit() async {
    if (_assetCtrl.text.trim().isEmpty || _descCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Podaj ID urządzenia (QR) oraz opis.')),
      );
      return;
    }
    setState(() => _sending = true);
    final msg = await widget.syncService.reportIncident(
      assetId: _assetCtrl.text,
      description: _descCtrl.text,
      severity: _severity,
      latitude: _lat,
      longitude: _lon,
    );
    if (mounted) {
      setState(() {
        _sending = false;
        _descCtrl.clear();
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('incident_asset'),
                  controller: _assetCtrl,
                  decoration: const InputDecoration(
                    labelText: 'ID komputera / serwera (z kodu QR)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: _scanQr,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Skanuj'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _severity,
            decoration: const InputDecoration(
              labelText: 'Priorytet incydentu',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: 'LOW', child: Text('LOW')),
              DropdownMenuItem(value: 'MEDIUM', child: Text('MEDIUM')),
              DropdownMenuItem(value: 'HIGH', child: Text('HIGH')),
              DropdownMenuItem(value: 'CRITICAL', child: Text('CRITICAL')),
            ],
            onChanged: (v) => setState(() => _severity = v ?? 'HIGH'),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('incident_desc'),
            controller: _descCtrl,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Opis incydentu bezpieczeństwa',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.location_on),
            title: const Text('Lokalizacja GPS (opcjonalnie)'),
            subtitle: Text(_gpsInfo),
            trailing: OutlinedButton(
              onPressed: _fetchGps,
              child: const Text('Pobierz GPS'),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('incident_submit'),
            onPressed: _sending ? null : _submit,
            icon: const Icon(Icons.send),
            label: Text(_sending ? 'Wysyłanie...' : 'Zgłoś incydent'),
          ),
        ],
      ),
    );
  }
}

class QrScannerPage extends StatefulWidget {
  const QrScannerPage({super.key});

  @override
  State<QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<QrScannerPage> {
  bool _handled = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Zeskanuj kod QR urządzenia')),
      body: MobileScanner(
        onDetect: (capture) {
          if (_handled) return;
          for (final barcode in capture.barcodes) {
            final value = barcode.rawValue;
            if (value != null && value.isNotEmpty) {
              _handled = true;
              Navigator.of(context).pop(value);
              break;
            }
          }
        },
      ),
    );
  }
}
