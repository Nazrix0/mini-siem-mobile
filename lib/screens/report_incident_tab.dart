import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import '../services/sync_service.dart';
import 'qr_scanner_page.dart';

class ReportIncidentTab extends StatefulWidget {
  final SyncService syncService;
  const ReportIncidentTab({super.key, required this.syncService});

  @override
  State<ReportIncidentTab> createState() => _ReportIncidentTabState();
}

class _ReportIncidentTabState extends State<ReportIncidentTab> {
  final _assetCtrl = TextEditingController();
  final _sourceIpCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  String _severity = 'HIGH';
  double? _lat;
  double? _lon;
  String _gpsInfo = 'Nie pobrano (opcjonalne)';
  bool _sending = false;

  @override
  void dispose() {
    _assetCtrl.dispose();
    _sourceIpCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

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
      sourceIp: _sourceIpCtrl.text,
      latitude: _lat,
      longitude: _lon,
    );
    if (mounted) {
      setState(() {
        _sending = false;
        _sourceIpCtrl.clear();
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
          TextField(
            key: const Key('incident_source_ip'),
            controller: _sourceIpCtrl,
            decoration: const InputDecoration(
              labelText: 'Adres IP / źródło (opcjonalnie)',
              hintText: 'Puste = automatyczne IP telefonu z VPN',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _severity,
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
