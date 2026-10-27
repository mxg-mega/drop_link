import 'package:drop_link/data/database.dart';
import 'package:drop_link/data/database_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../core/theme.dart';
import '../providers/connection_provider.dart';
import '../services/discovery_service.dart';
import 'qr_scanner_screen.dart';

class DiscoverScreen extends ConsumerStatefulWidget {
  const DiscoverScreen({super.key});

  @override
  ConsumerState<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends ConsumerState<DiscoverScreen> {
  final List<DiscoveredDevice> _devices = [];
  bool _isScanning = false;
  String? _progress;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  @override
  void dispose() {
    _cancelled = true;
    super.dispose();
  }

  Future<void> _startScan() async {
    setState(() {
      _devices.clear();
      _isScanning = true;
      _progress = 'Scanning...';
      _cancelled = false;
    });

    final connection = ref.read(connectionProvider);
    final repository = ref.read(repositoryProvider);
    final discovery = DiscoveryService(repository);

    try {
      await for (final device in discovery.discover(
        timeout: const Duration(seconds: 6),
        configuredPort: connection.port,
      )) {
        if (_cancelled) break;

        setState(() {
          // De-duplicate by deviceId
          if (!_devices.any((d) => d.deviceId == device.deviceId)) {
            _devices.add(device);
          }
        });
      }
    } catch (e) {
      // Scan completed or failed
    }

    if (mounted) {
      setState(() {
        _isScanning = false;
        _progress = null;
      });
    }
  }

  Future<void> _onDeviceTap(DiscoveredDevice device) async {
    final repository = ref.read(repositoryProvider);
    final notifier = ref.read(connectionProvider.notifier);

    // Check if auth-protected and no token
    if (device.authRequired && !device.hasToken) {
      _showAuthBottomSheet(device);
      return;
    }

    // Save device and connect
    await repository.saveDevice(Device(
      deviceId: device.deviceId,
      name: device.name,
      lastIp: device.ip,
      lastPort: device.port.toString(),
      token: null,
      authRequired: device.authRequired,
      lastSeenAt: DateTime.now(),
      isActive: true,
    ));

    await repository.setActiveDevice(device.deviceId);

    await notifier.updateAddress(device.ip, device.port.toString());

    final success = await notifier.connect();

    if (mounted) {
      Navigator.pop(context);
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connected to ${device.name}')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to connect')),
        );
      }
    }
  }

  void _showAuthBottomSheet(DiscoveredDevice device) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        padding: const EdgeInsets.all(24),
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.lock, size: 32, color: AppColors.laptop),
            const SizedBox(height: 16),
            Text(
              'This laptop needs pairing',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppColors.ink,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Scan the QR code on its screen',
              style: TextStyle(fontSize: 14, color: AppColors.mute),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () async {
                Navigator.pop(context);
                final result = await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const QrScannerScreen()),
                );

                if (result == true && mounted) {
                  // Verify the scanned device matches
                  final connection = ref.read(connectionProvider);
                  if (connection.ip == device.ip) {
                    await _onDeviceTap(device);
                  } else {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('That QR belongs to a different laptop')),
                      );
                    }
                  }
                }
              },
              icon: const Icon(LucideIcons.qrCode, size: 18),
              label: const Text('Scan QR Code'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.laptop,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 48),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Find devices'),
        actions: [
          if (!_isScanning)
            IconButton(
              onPressed: _startScan,
              icon: const Icon(LucideIcons.refreshCw),
              tooltip: 'Rescan',
            ),
        ],
      ),
      body: Column(
        children: [
          if (_isScanning)
            Container(
              padding: const EdgeInsets.all(16),
              color: AppColors.bg,
              child: Row(
                children: [
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _progress ?? 'Scanning...',
                      style: TextStyle(color: AppColors.mute),
                    ),
                  ),
                ],
              ),
            ),

          Expanded(
            child: _devices.isEmpty
                ? _buildEmptyState()
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _devices.length,
                    itemBuilder: (context, index) {
                      return _DeviceCard(
                        device: _devices[index],
                        onTap: () => _onDeviceTap(_devices[index]),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(LucideIcons.search, size: 48, color: AppColors.mute),
            const SizedBox(height: 16),
            Text(
              'No devices found',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppColors.ink,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Make sure:\n'
              '• Hotspot is turned on\n'
              '• DropLink server is running on the laptop\n'
              '• The laptop is on the same network',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: AppColors.mute),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: _startScan,
                  icon: const Icon(LucideIcons.refreshCw, size: 16),
                  label: const Text('Rescan'),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(LucideIcons.keyboard, size: 16),
                  label: const Text('Enter manually'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  final DiscoveredDevice device;
  final VoidCallback onTap;

  const _DeviceCard({
    required this.device,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            // Icon
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: AppColors.laptopSoft,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                LucideIcons.laptop,
                size: 24,
                color: AppColors.laptop,
              ),
            ),
            const SizedBox(width: 12),

            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        device.name,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (device.authRequired) ...[
                        const SizedBox(width: 6),
                        Icon(LucideIcons.lock, size: 14, color: AppColors.mute),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${device.ip}:${device.port}',
                    style: TextStyle(fontSize: 13, color: AppColors.mute),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (device.isPaired)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.phoneSoft,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            'Paired',
                            style: TextStyle(
                              fontSize: 11,
                              color: AppColors.phone,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      const SizedBox(width: 6),
                      Text(
                        'via ${device.via}',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.mute,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Arrow
            Icon(
              LucideIcons.chevronRight,
              size: 20,
              color: AppColors.mute,
            ),
          ],
        ),
      ),
    );
  }
}
