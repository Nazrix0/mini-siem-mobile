import 'package:flutter/material.dart';
import '../services/sync_service.dart';

class MetricsSheet extends StatelessWidget {
  final SyncService syncService;
  const MetricsSheet({super.key, required this.syncService});

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(label, style: const TextStyle(color: Colors.black54)),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                value,
                textAlign: TextAlign.end,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: syncService,
      builder: (context, _) {
        final s = syncService;
        final totalBytes = s.bytesSent + s.bytesReceived;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Pomiary i Konflikty LWW',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      TextButton.icon(
                        onPressed: s.resetTelemetryCounters,
                        icon: const Icon(Icons.restart_alt, size: 18),
                        label: const Text('Zeruj liczniki'),
                      ),
                    ],
                  ),
                  const Divider(),
                  _row('Czas startu aplikacji (startupMs)', '${s.startupMs} ms'),
                  _row('Opóźnienie synchronizacji (lastSyncMs)',
                      '${s.lastSyncMs} ms'),
                  _row('Tryb ostatniej synchronizacji', s.lastSyncMode),
                  _row('Liczba synców (Delta / Full)',
                      '${s.deltaSyncCount} / ${s.fullSyncCount}'),
                  _row('Wysłane dane (bytesSent)', '${s.bytesSent} B'),
                  _row('Odebrane dane (bytesReceived)', '${s.bytesReceived} B'),
                  _row('Łączny transfer',
                      '${(totalBytes / 1024).toStringAsFixed(2)} KB ($totalBytes B)'),
                  _row('Status uwierzytelniania', s.authStatus),
                  _row('Status Push (FCM)', s.fcmStatus),
                  _row('Ostatni znacznik Delta (UTC)',
                      s.lastAlertsSyncAt ?? 'brak'),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: s.isSyncing
                              ? null
                              : () => s.syncAll(forceFull: false),
                          child: const Text('Delta Sync'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: s.isSyncing
                              ? null
                              : () => s.syncAll(forceFull: true),
                          child: const Text('Full Sync'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Log rozwiązanych konfliktów LWW:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  if (s.conflictLog.isEmpty)
                    const Text('Brak zarejestrowanych konfliktów.',
                        style: TextStyle(color: Colors.black54))
                  else
                    ...s.conflictLog.take(10).map(
                          (entry) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text('• $entry',
                                style: const TextStyle(fontSize: 12)),
                          ),
                        ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
