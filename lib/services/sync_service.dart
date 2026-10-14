import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../data/repository.dart';
import '../data/database_provider.dart';
import '../providers/connection_provider.dart';
import '../services/api_service.dart';

class SyncService {
  final Ref ref;
  final Repository repository;
  final ApiService api;
  Timer? _connectionMonitorTimer;
  Timer? _syncPullTimer;
  bool _isFlushing = false;
  bool _isOnline = false;

  SyncService(this.ref, this.repository, this.api);

  void start() {
    _resetSendingOnStart();
    _startConnectionMonitor();
  }

  void stop() {
    _connectionMonitorTimer?.cancel();
    _syncPullTimer?.cancel();
  }

  Future<void> _resetSendingOnStart() async {
    await repository.resetSendingToQueued();
  }

  void _startConnectionMonitor() {
    _connectionMonitorTimer?.cancel();
    _connectionMonitorTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      await _checkConnection();
    });
  }

  Future<void> _checkConnection() async {
    try {
      final connection = ref.read(connectionProvider);
      if (connection.ip.isEmpty) return;

      api.setBaseUrl(connection.ip, port: connection.port, token: connection.token);
      final check = await api.checkConnection();

      final wasOnline = _isOnline;
      _isOnline = check.ok;

      if (_isOnline != wasOnline) {
        if (_isOnline) {
          await _onOnline();
        } else {
          await _onOffline();
        }
      }

      if (_isOnline) {
        final notifier = ref.read(connectionProvider.notifier);
        if (!connection.isConnected) {
          await notifier.connect();
        }
      } else if (!wasOnline) {
        // Try auto-reconnect after going offline
        await _tryAutoReconnect();
      }
    } catch (e) {
      _isOnline = false;
    }
  }

  Future<void> _tryAutoReconnect() async {
    try {
      final activeDevice = await repository.getActiveDevice();
      if (activeDevice == null) return;

      // Try ping the saved IP first
      api.setBaseUrl(activeDevice.lastIp, port: activeDevice.lastPort, token: activeDevice.token);
      final check = await api.checkConnection();

      if (check.ok) {
        final notifier = ref.read(connectionProvider.notifier);
        await notifier.updateAddress(activeDevice.lastIp, activeDevice.lastPort, token: activeDevice.token);
        await notifier.connect();
        _isOnline = true;
        await _onOnline();
        return;
      }

      // Try discovery to find the device by ID (simplified for now)
      // In a full implementation, this would run a quick discovery
      // looking for the specific deviceId
    } catch (e) {
      // Auto-reconnect failed, will retry next cycle
    }
  }

  Future<void> _onOnline() async {
    await flushOutbox();
    _startSyncPull();
  }

  Future<void> _onOffline() async {
    _syncPullTimer?.cancel();
  }

  void _startSyncPull() {
    _syncPullTimer?.cancel();
    _syncPullTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (_isOnline && !_isFlushing) {
        await pullSync();
      }
    });
  }

  Future<void> flushOutbox() async {
    if (_isFlushing) return;
    _isFlushing = true;

    try {
      while (_isOnline) {
        final pending = await repository.getPendingOutbox();
        if (pending.isEmpty) break;

        final operation = pending.first;
        final success = await _processOutboxItem(operation);

        if (!success) {
          await repository.incrementOutboxAttempts(operation.id);
          break;
        }
      }
    } finally {
      _isFlushing = false;
    }
  }

  Future<bool> _processOutboxItem(OutboxItem operation) async {
    try {
      switch (operation.kind) {
        case 'text':
          final item = await (repository.db.select(repository.db.items)
                ..where((tbl) => tbl.id.equals(operation.itemId)))
              .getSingleOrNull();
          if (item == null) return true;

          await repository.markSending(operation.itemId);

          final response = await api.sendText(
            text: item.text ?? '',
            clientId: item.id,
            clientTime: item.createdAt?.toIso8601String() ?? DateTime.now().toIso8601String(),
          );

          if (response['status'] == 'ok' || response['status'] == 'duplicate') {
            await repository.markSynced(operation.itemId);
            return true;
          }
          if (response['deleted'] == true) {
            await repository.discardFailed(operation.itemId);
            return true;
          }
          return false;

        case 'file':
          final item = await (repository.db.select(repository.db.items)
                ..where((tbl) => tbl.id.equals(operation.itemId)))
              .getSingleOrNull();
          if (item == null || item.localPath == null) return true;

          await repository.markSending(operation.itemId);

          final response = await api.uploadFile(
            filePath: item.localPath!,
            clientId: item.id,
            clientTime: item.createdAt?.toIso8601String() ?? DateTime.now().toIso8601String(),
            onProgress: (_) {},
          );

          if (response['status'] == 'ok' || response['status'] == 'duplicate') {
            await repository.markSynced(operation.itemId);
            return true;
          }
          if (response['deleted'] == true) {
            await repository.discardFailed(operation.itemId);
            return true;
          }
          return false;

        case 'delete':
          await api.deleteItem(operation.itemId);
          await repository.discardFailed(operation.itemId);
          return true;

        default:
          return true;
      }
    } catch (e) {
      return false;
    }
  }

  Future<void> pullSync() async {
    try {
      final connection = ref.read(connectionProvider);
      final deviceId = connection.ip; // Use IP as deviceId for now, will update with real ID
      if (deviceId.isEmpty) return;

      final lastSeq = await repository.getLastSeq(deviceId) ?? 0;
      final syncData = await api.sync(lastSeq);

      final syncResponse = SyncResponse.fromJson(syncData);
      await repository.applySync(deviceId, syncResponse);
    } catch (e) {
      // Ignore sync errors, will retry
    }
  }

  Future<void> retryItem(String itemId) async {
    final outboxItems = await (repository.db.select(repository.db.outbox)
          ..where((tbl) => tbl.itemId.equals(itemId)))
        .get();

    for (final item in outboxItems) {
      await (repository.db.update(repository.db.outbox)..where((tbl) => tbl.id.equals(item.id)))
          .write(const OutboxCompanion(attempts: Value(0), nextAttemptAt: Value(null)));
    }

    if (_isOnline) {
      await flushOutbox();
    }
  }
}

final syncServiceProvider = Provider<SyncService>((ref) {
  final repository = ref.watch(repositoryProvider);
  final api = ref.watch(apiServiceProvider);
  return SyncService(ref, repository, api);
});
