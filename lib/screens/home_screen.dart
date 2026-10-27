import 'package:drop_link/screens/files_tab.dart';
import 'package:drop_link/screens/link_tab.dart';
import 'package:drop_link/screens/shelf_tab.dart';
import 'package:drop_link/widgets/pulsing_connection_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../core/theme.dart';
import '../providers/connection_provider.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _currentIndex = 0;

  final List<Widget> _tabs = const [ShelfTab(), FilesTab(), LinkTab()];

  // Timer? _timer;

  // void _startTimer() {
  //   _timer?.cancel();

  //   _timer = Timer.periodic(const Duration(seconds: 3), ((timer) async {
  //     await ref.watch(connectionProvider.notifier).connect();
  //     print("Started Connection Trial after 3 Seconds");
  //     print(ref.read(connectionProvider).isLoading);
  //     print(ref.read(connectionProvider).isConnected);
  //     timer.cancel();
  //   }));
  // }

  // @override
  // void initState() {
  //   _startTimer();
  //   super.initState();
  // }

  // @override
  // void dispose() {
  //   _timer?.cancel();
  //   super.dispose();
  // }

  @override
  Widget build(BuildContext context) {
    final connection = ref.watch(connectionProvider);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _currentIndex == 0
                        ? 'Shelf'
                        : _currentIndex == 1
                        ? 'Files'
                        : 'Link',
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      color: AppColors.ink,
                    ),
                  ),
                  GestureDetector(
                    onTap: () => setState(() => _currentIndex = 2),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        children: [
                          PulsingConnectionIndicator(
                            connection: connection,
                            child: Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: connection.isConnected
                                    ? AppColors.phone
                                    : AppColors.danger,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            connection.isConnected
                                ? 'Connected'
                                : (connection.pendingCount > 0
                                    ? 'Syncing ${connection.pendingCount}'
                                    : 'Offline'),
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Tab content
            Expanded(child: _tabs[_currentIndex]),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) => setState(() => _currentIndex = index),
        backgroundColor: AppColors.surface,
        indicatorColor: AppColors.bg,
        destinations: const [
          NavigationDestination(
            icon: Icon(LucideIcons.arrowDownLeft),
            label: 'Shelf',
          ),
          NavigationDestination(icon: Icon(LucideIcons.files), label: 'Files'),
          NavigationDestination(icon: Icon(LucideIcons.radio), label: 'Link'),
        ],
      ),
    );
  }
}
