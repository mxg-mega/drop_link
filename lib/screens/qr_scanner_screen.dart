import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../core/theme.dart';
import '../providers/connection_provider.dart';

class QrScannerScreen extends ConsumerStatefulWidget {
  const QrScannerScreen({super.key});

  @override
  ConsumerState<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends ConsumerState<QrScannerScreen> {
  bool _isProcessing = false;

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_isProcessing) return;

    final raw = capture.barcodes.isEmpty
        ? null
        : capture.barcodes.first.rawValue;
    if (raw == null || raw.isEmpty) return;

    setState(() => _isProcessing = true);

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final notifier = ref.read(connectionProvider.notifier);

    // Expected: http://192.168.x.x:8000/  or  http://192.168.x.x:8000/?token=...
    final ok = await notifier.pairFromQr(raw);
    if (!mounted) return;

    if (ok) {
      final ip = ref.read(connectionProvider).ip;
      navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text('Connected to $ip')));
      return;
    }

    final error =
        ref.read(connectionProvider).error ?? 'Could not connect to the laptop.';
    messenger.showSnackBar(SnackBar(content: Text(error)));

    // Pause so the camera doesn't re-read the same code and spam errors.
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _isProcessing = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Scan QR Code'),
        leading: IconButton(
          icon: const Icon(LucideIcons.x),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Stack(
        children: [
          MobileScanner(onDetect: _onDetect),

          // Overlay
          Center(
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.phone, width: 3),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),

          Positioned(
            bottom: 80,
            left: 0,
            right: 0,
            child: Text(
              _isProcessing
                  ? 'Connecting...'
                  : 'Point at the QR code on your laptop',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }
}