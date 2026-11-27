import 'dart:async';
import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'services/push_service.dart';
import 'services/sync_service.dart';

void main() async {
  final startupSw = Stopwatch()..start();
  WidgetsFlutterBinding.ensureInitialized();

  final syncService = SyncService();
  await syncService.init();
  startupSw.stop();
  syncService.startupMs = startupSw.elapsedMilliseconds;

  unawaited(PushService.init(syncService));

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
