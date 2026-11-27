import 'dart:async';
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

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _tabIndex = 0;
  Timer? _autoRefreshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startAutoRefresh();
  }

  void _startAutoRefresh() {
    if (!widget.syncService.autoRefreshEnabled) return;
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      final s = widget.syncService;
      if (s.isLoggedIn &&
          s.isOnline &&
          !s.isSyncing &&
          !s.pendingOnlineVerification) {
        unawaited(s.fetchAlerts());
      }
    });
  }

  void _stopAutoRefresh() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Natychmiastowe odświeżenie po powrocie do aplikacji lub kliknięciu w Push
      if (widget.syncService.isLoggedIn) {
        unawaited(widget.syncService.syncAll());
      }
      _startAutoRefresh();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      // W tle wyłączamy timer, aby nie zużywać baterii
      _stopAutoRefresh();
    }
  }

  @override
  void dispose() {
    _stopAutoRefresh();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

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
          if (s.lastLwwNotice != null)
            Container(
              width: double.infinity,
              color: s.lastLwwClientWon
                  ? Colors.teal.shade100
                  : Colors.amber.shade200,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  Icon(
                    s.lastLwwClientWon ? Icons.check_circle : Icons.merge_type,
                    size: 16,
                    color: s.lastLwwClientWon
                        ? Colors.teal.shade900
                        : Colors.brown.shade900,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      s.lastLwwNotice!,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: s.lastLwwClientWon
                            ? Colors.teal.shade900
                            : Colors.brown.shade900,
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: s.clearLwwNotice,
                    child: const Padding(
                      padding: EdgeInsets.all(2),
                      child: Icon(Icons.close, size: 16),
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
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'PUSH: ${s.lastPushNotice}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.red.shade900,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: s.clearPushNotice,
                    child: const Padding(
                      padding: EdgeInsets.all(2),
                      child: Icon(Icons.close, size: 16),
                    ),
                  ),
                ],
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
