import 'package:flutter/material.dart';
import '../services/sync_service.dart';
import 'alerts_tab.dart';
import 'metrics_sheet.dart';
import 'report_incident_tab.dart';

class HomeScreen extends StatefulWidget {
  final SyncService syncService;
  const HomeScreen({super.key, required this.syncService});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tabIndex = 0;

  void _openMetrics() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => MetricsSheet(syncService: widget.syncService),
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
            tooltip: 'Pomiary i Konflikty LWW',
            onPressed: _openMetrics,
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
            color: s.isOnline ? Colors.green.shade100 : Colors.red.shade600,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Icon(
                  s.isOnline ? Icons.wifi : Icons.wifi_off,
                  size: 16,
                  color: s.isOnline ? Colors.green.shade900 : Colors.white,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${s.isOnline ? "ONLINE" : "OFFLINE"}${s.pendingOnlineVerification ? " (AUTORYZACJA OFFLINE)" : ""} • Kolejka: ${s.pendingCount} • ${s.lastSyncInfo}',
                    style: TextStyle(
                      fontSize: 12,
                      color: s.isOnline ? Colors.black87 : Colors.white,
                      fontWeight:
                          s.isOnline ? FontWeight.normal : FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (s.lastPushNotice != null)
            Container(
              width: double.infinity,
              color: Colors.red.shade100,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text(
                'PUSH: ${s.lastPushNotice}',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.red.shade900,
                  fontWeight: FontWeight.bold,
                ),
              ),
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
            label: 'Alerty',
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
