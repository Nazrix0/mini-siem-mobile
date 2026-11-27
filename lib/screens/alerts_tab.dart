import 'package:flutter/material.dart';
import '../services/sync_service.dart';

class AlertsTab extends StatelessWidget {
  final SyncService syncService;
  const AlertsTab({super.key, required this.syncService});

  @override
  Widget build(BuildContext context) {
    final alerts = syncService.alerts;
    if (alerts.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Brak alertów w lokalnej bazie.'),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () => syncService.syncAll(forceFull: true),
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
          final currentStatus =
              ['NEW', 'IN_PROGRESS', 'RESOLVED'].contains(a.status)
                  ? a.status
                  : 'NEW';

          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: ListTile(
              title: Text(
                '#${a.id} • ${a.type}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(a.desc),
                  const SizedBox(height: 4),
                  Text(
                    'Adres IP/Źródło: ${a.ip}${a.reportedBy != null ? " (${a.reportedBy})" : ""} | UTC: ${a.updatedAt}',
                    style: const TextStyle(fontSize: 11, color: Colors.black54),
                  ),
                  if (a.assetId != null || a.latitude != null)
                    Text(
                      'QR: ${a.assetId ?? "-"} | GPS: ${a.latitude != null ? "${a.latitude}, ${a.longitude}" : "brak"}',
                      style:
                          const TextStyle(fontSize: 11, color: Colors.indigo),
                    ),
                ],
              ),
              trailing: DropdownButton<String>(
                value: currentStatus,
                items: const [
                  DropdownMenuItem(value: 'NEW', child: Text('NEW')),
                  DropdownMenuItem(
                      value: 'IN_PROGRESS', child: Text('W TRAKCIE')),
                  DropdownMenuItem(value: 'RESOLVED', child: Text('ZAMKNIĘTY')),
                ],
                onChanged: (val) async {
                  if (val == null || val == currentStatus) return;
                  final msg = await syncService.updateAlertStatus(a.id, val);
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
