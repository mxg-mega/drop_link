import 'package:drop_link/screens/qr_scanner_screen.dart';
import 'package:drop_link/screens/discover_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../core/theme.dart';
import '../providers/connection_provider.dart';

class LinkTab extends ConsumerStatefulWidget {
  const LinkTab({super.key});

  @override
  ConsumerState<LinkTab> createState() => _LinkTabState();
}

class _LinkTabState extends ConsumerState<LinkTab> {
  late TextEditingController _ipController;
  late TextEditingController _portController;
  String? _portError;

  @override
  void initState() {
    super.initState();
    final connection = ref.read(connectionProvider);
    _ipController = TextEditingController(text: connection.ip);
    _portController = TextEditingController(text: connection.port);
  }

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }

  bool _validatePort(String value) {
    if (value.isEmpty) {
      _portError = null;
      return true; // Empty means default 8000
    }
    final port = int.tryParse(value);
    if (port == null || port < 1 || port > 65535) {
      _portError = 'Port must be between 1 and 65535';
      return false;
    }
    _portError = null;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final connection = ref.watch(connectionProvider);
    final notifier = ref.read(connectionProvider.notifier);

    // Keep the text fields in sync when values change elsewhere
    // (QR scan, discovery, or the last laptop being restored on launch).
    ref.listen(connectionProvider, (previous, next) {
      if (next.ip != _ipController.text) {
        _ipController.text = next.ip;
      }
      if (next.port != _portController.text) {
        _portController.text = next.port;
      }
    });

    final subtitle = !connection.isConnected
        ? 'Scan the QR code or enter the address below'
        : connection.authRequired
        ? "Paired securely · over your phone's hotspot"
        : "Over your phone's hotspot";

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        // ===== Connection Status Card =====
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.ink,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      LucideIcons.laptop,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          connection.isConnected
                              ? 'Connected to laptop'
                              : 'Not connected',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.6),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    LucideIcons.wifi,
                    color: connection.isConnected
                        ? const Color(0xFF4ADE9F)
                        : AppColors.mute,
                    size: 22,
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${connection.ip}:${connection.port}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () {
                        Clipboard.setData(
                          ClipboardData(
                            text: 'http://${connection.ip}:${connection.port}',
                          ),
                        );
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Address copied')),
                        );
                      },
                      icon: const Icon(
                        LucideIcons.copy,
                        size: 18,
                        color: Colors.white70,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // ===== Laptop Address Card =====
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Laptop address',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),

              // IP Field
              TextField(
                controller: _ipController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                style: const TextStyle(fontSize: 15),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: AppColors.bg,
                  hintText: 'IP address',
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (value) => notifier.updateIp(value),
              ),

              const SizedBox(height: 10),

              // Port Field
              TextField(
                controller: _portController,
                keyboardType: TextInputType.number,
                style: const TextStyle(fontSize: 15),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: AppColors.bg,
                  hintText: 'Port',
                  helperText: 'Default 8000',
                  helperStyle: TextStyle(fontSize: 11, color: AppColors.mute),
                  errorText: _portError,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (value) {
                  setState(() {
                    _validatePort(value);
                  });
                  notifier.updatePort(value);
                },
              ),

              const SizedBox(height: 12),

              // Action Buttons Row
              Row(
                children: [
                  // Scan QR Button
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const QrScannerScreen(),
                          ),
                        );
                      },
                      icon: const Icon(LucideIcons.qrCode, size: 18),
                      label: const Text('Scan QR'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        side: BorderSide(color: AppColors.line),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),

                  // Find Devices Button
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const DiscoverScreen(),
                          ),
                        );
                      },
                      icon: const Icon(LucideIcons.search, size: 18),
                      label: const Text('Find devices'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        side: BorderSide(color: AppColors.line),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),

                  // Connect Button
                  SizedBox(
                    width: 100,
                    child: ElevatedButton(
                      onPressed: (connection.isLoading || _portError != null)
                          ? null
                          : () async {
                              await notifier.connect();
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.laptop,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: connection.isLoading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Connect'),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 10),
              Text(
                'The address changes when the hotspot restarts. Scan the QR code on the laptop page to reconnect without typing.',
                style: TextStyle(fontSize: 12, color: AppColors.mute),
              ),
              if (connection.error != null) ...[
                const SizedBox(height: 10),
                Text(
                  connection.error!,
                  style: const TextStyle(color: AppColors.danger, fontSize: 13),
                ),
              ],
            ],
          ),
        ),

        const SizedBox(height: 16),

        // ===== Settings Card =====
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            children: [
              _buildToggle(
                title: 'Save received photos to gallery',
                subtitle: 'Images from the laptop land in your Photos',
                value: true, // We'll make this real later
                onChanged: (v) {},
              ),
              const Divider(height: 28),
              _buildToggle(
                title: 'Share clipboard automatically',
                subtitle: 'Copied text appears on the laptop',
                value: false,
                onChanged: (v) {},
              ),
              const Divider(height: 28),
              _buildToggle(
                title: 'Keep screen on while sending',
                subtitle: 'Stops large transfers from pausing',
                value: true,
                onChanged: (v) {},
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildToggle({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(fontSize: 12, color: AppColors.mute),
              ),
            ],
          ),
        ),
        Switch(
          value: value,
          onChanged: onChanged,
          activeColor: AppColors.phone,
        ),
      ],
    );
  }
}