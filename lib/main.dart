import 'package:drop_link/providers/connection_provider.dart';
import 'package:drop_link/data/database_provider.dart';
import 'package:drop_link/services/sync_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const ProviderScope(child: DropLinkApp()));
}

class DropLinkApp extends ConsumerStatefulWidget {
  const DropLinkApp({super.key});

  @override
  ConsumerState<DropLinkApp> createState() => _DropLinkAppState();
}

class _DropLinkAppState extends ConsumerState<DropLinkApp> {
  @override
  void initState() {
    super.initState();
    _initializeServices();
  }

  Future<void> _initializeServices() async {
    // Wait for device ID to be generated
    final deviceId = await ref.read(deviceIdProvider.future);

    // Set device ID on API service
    final api = ref.read(apiServiceProvider);
    api.setDeviceId(deviceId);

    // Start sync service
    final syncService = ref.read(syncServiceProvider);
    syncService.start();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DropLink',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const HomeScreen(),
    );
  }
}
