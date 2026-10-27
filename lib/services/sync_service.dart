import 'dart:async';
import 'package:drift/drift.dart' as drift;
import 'package:drop_link/data/database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
    debugPrint('[SyncService] start() invoked: resetting sending items and starting connection monitor');
    _resetSendingOnStart();
    _startConnectionMonitor();
  }

  void stop() {
    debugPrint('[SyncService] stop() invoked: cancelling timers');
    _connectionMonitorTimer?.cancel();
    _syncPullTimer?.cancel();
  }

  Future<void> _resetSendingOnStart() async {
    debugPrint('[SyncService] _resetSendingOnStart(): calling repository.resetSendingToQueued()');
    await repository.resetSendingToQueued();
  }

  void _startConnectionMonitor() {
    debugPrint('[SyncService] _startConnectionMonitor(): monitoring every 5s');
    _connectionMonitorTimer?.cancel();
    _connectionMonitorTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      await _checkConnection();
    });
  }

  bool get isOnline => _isOnline || ref.read(connectionProvider).isConnected;

  void setOnline(bool online) {
    debugPrint('[SyncService] setOnline($online) called');
    final wasOnline = _isOnline;
    _isOnline = online;
    if (_isOnline && !wasOnline) {
      _onOnline();
    } else if (!_isOnline && wasOnline) {
      _onOffline();
    }
  }

  Future<void> _checkConnection() async {
    try {
      final connection = ref.read(connectionProvider);
      if (connection.ip.isEmpty) {
        debugPrint('[SyncService] _checkConnection(): IP is empty, skipping check');
        return;
      }

      api.setBaseUrl(connection.ip, port: connection.port, token: connection.token);
      final check = await api.checkConnection();

      final wasOnline = _isOnline;
      _isOnline = check.ok;

      debugPrint('[SyncService] _checkConnection(): check.ok=${check.ok}, wasOnline=$wasOnline, isOnline=$_isOnline (authRequired=${check.authRequired}, deviceId=${check.deviceId})');

      if (check.ok && check.deviceId != null && check.deviceId!.isNotEmpty) {
        final activeDevice = await repository.getActiveDevice();
        if (activeDevice == null || activeDevice.deviceId != check.deviceId) {
          debugPrint('[SyncService] Saving/updating active device from /ping: ${check.deviceId} (${check.deviceName})');
          await repository.saveDevice(Device(
            deviceId: check.deviceId!,
            name: check.deviceName ?? 'Laptop',
            lastIp: connection.ip,
            lastPort: connection.port,
            token: connection.token,
            authRequired: check.authRequired,
            lastSeenAt: DateTime.now(),
            isActive: true,
          ));
          await repository.setActiveDevice(check.deviceId!);
        }
      }

      if (_isOnline != wasOnline) {
        debugPrint('[SyncService] Connection state transition: wasOnline=$wasOnline -> isOnline=$_isOnline');
        if (_isOnline) {
          await _onOnline();
        } else {
          await _onOffline();
        }
      }

      if (_isOnline) {
        final notifier = ref.read(connectionProvider.notifier);
        if (!connection.isConnected) {
          debugPrint('[SyncService] _checkConnection(): Service is online but connectionProvider.isConnected is false. Reconnecting...');
          await notifier.connect();
        }
      } else if (!wasOnline) {
        // Try auto-reconnect after going offline
        debugPrint('[SyncService] _checkConnection(): Offline, attempting auto-reconnect...');
        await _tryAutoReconnect();
      }

      // Update pending count in the connection state
      final pendingCount = (await repository.getPendingOutbox()).length;
      debugPrint('[SyncService] _checkConnection(): Outbox pending count = $pendingCount');
      ref.read(connectionProvider.notifier).updatePendingCount(pendingCount);

      // Flush outbox if online and items are pending
      if (isOnline && pendingCount > 0 && !_isFlushing) {
        debugPrint('[SyncService] _checkConnection(): Found $pendingCount pending items while online, triggering flushOutbox()...');
        flushOutbox();
      }
    } catch (e) {
      debugPrint('[SyncService] _checkConnection() exception: $e');
      _isOnline = false;
    }
  }

  Future<void> _tryAutoReconnect() async {
    try {
      final activeDevice = await repository.getActiveDevice();
      if (activeDevice == null) {
        debugPrint('[SyncService] _tryAutoReconnect(): No activeDevice found in database');
        return;
      }
      debugPrint('[SyncService] _tryAutoReconnect(): Active device=${activeDevice.deviceId}, lastIp=${activeDevice.lastIp}:${activeDevice.lastPort}');

      // Try ping the saved IP first
      api.setBaseUrl(activeDevice.lastIp, port: activeDevice.lastPort, token: activeDevice.token);
      final check = await api.checkConnection();
      debugPrint('[SyncService] _tryAutoReconnect(): Ping to saved IP ok=${check.ok}');

      if (check.ok) {
        final notifier = ref.read(connectionProvider.notifier);
        await notifier.updateAddress(activeDevice.lastIp, activeDevice.lastPort, token: activeDevice.token);
        await notifier.connect();
        _isOnline = true;
        await _onOnline();
        return;
      }
    } catch (e) {
      debugPrint('[SyncService] _tryAutoReconnect() failed: $e');
    }
  }

  Future<void> _onOnline() async {
    debugPrint('[SyncService] _onOnline() called: flushing outbox and starting pull timer');
    await flushOutbox();
    _startSyncPull();
  }

  Future<void> _onOffline() async {
    debugPrint('[SyncService] _onOffline() called: cancelling sync pull timer');
    _syncPullTimer?.cancel();
  }

  void _startSyncPull() {
    debugPrint('[SyncService] _startSyncPull(): starting periodic sync pull every 3s');
    _syncPullTimer?.cancel();
    _syncPullTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (isOnline && !_isFlushing) {
        await pullSync();
      } else {
        debugPrint('[SyncService] Skipping pullSync(): isOnline=$isOnline, isFlushing=$_isFlushing');
      }
    });
  }

  Future<void> flushOutbox() async {
    if (_isFlushing) {
      debugPrint('[SyncService] flushOutbox(): Already flushing, skipping concurrent flush call');
      return;
    }
    _isFlushing = true;
    debugPrint('[SyncService] flushOutbox() started: isOnline=$isOnline');

    try {
      while (isOnline) {
        final pending = await repository.getPendingOutbox();
        debugPrint('[SyncService] flushOutbox(): Pending outbox items query returned ${pending.length} items');
        if (pending.isEmpty) {
          debugPrint('[SyncService] flushOutbox(): No more pending items to flush');
          break;
        }

        final operation = pending.first;
        debugPrint('[SyncService] flushOutbox(): Next operation to process -> id=${operation.id}, itemId=${operation.itemId}, kind=${operation.kind}, attempts=${operation.attempts}');
        final success = await _processOutboxItem(operation);
        debugPrint('[SyncService] flushOutbox(): Operation id=${operation.id} result -> success=$success');

        if (!success) {
          debugPrint('[SyncService] flushOutbox(): Operation id=${operation.id} failed, incrementing attempts and backing off');
          await repository.incrementOutboxAttempts(operation.id);
          break;
        }
      }
    } catch (e, stack) {
      debugPrint('[SyncService] flushOutbox() error: $e\n$stack');
    } finally {
      _isFlushing = false;
      debugPrint('[SyncService] flushOutbox() finished. _isFlushing set to false');
    }
  }

  Future<bool> _processOutboxItem(OutboxItem operation) async {
    debugPrint('[SyncService] _processOutboxItem() called: kind=${operation.kind}, itemId=${operation.itemId}');
    try {
      switch (operation.kind) {
        case 'text':
          final item = await (repository.db.select(repository.db.items)
                ..where((tbl) => tbl.id.equals(operation.itemId)))
              .getSingleOrNull();
          if (item == null) {
            debugPrint('[SyncService] _processOutboxItem(text): Item ${operation.itemId} not found in DB items table! Marking operation as done');
            return true;
          }

          debugPrint('[SyncService] _processOutboxItem(text): Found item in DB: id=${item.id}, content="${item.content}", deviceId=${item.deviceId}. Marking sending...');
          await repository.markSending(operation.itemId);

          final clientTime = item.createdAt?.toIso8601String() ?? DateTime.now().toUtc().toIso8601String();
          debugPrint('[SyncService] Calling api.sendText(text="${item.content}", clientId="${item.id}", clientTime="$clientTime")...');
          final response = await api.sendText(
            text: item.content ?? '',
            clientId: item.id,
            clientTime: clientTime,
          );
          debugPrint('[SyncService] api.sendText() response: $response');

          if (response['status'] == 'ok' || response['status'] == 'duplicate') {
            debugPrint('[SyncService] Message delivery SUCCESS. Marking item ${operation.itemId} as synced');
            await repository.markSynced(operation.itemId);
            return true;
          }
          if (response['deleted'] == true) {
            debugPrint('[SyncService] Server reported item ${operation.itemId} was deleted. Discarding from outbox');
            await repository.discardFailed(operation.itemId);
            return true;
          }
          debugPrint('[SyncService] Unexpected server response for text item: $response');
          return false;

        case 'file':
          final item = await (repository.db.select(repository.db.items)
                ..where((tbl) => tbl.id.equals(operation.itemId)))
              .getSingleOrNull();
          if (item == null || item.localPath == null) {
            debugPrint('[SyncService] _processOutboxItem(file): Item or localPath is null for ${operation.itemId}! Discarding');
            return true;
          }

          debugPrint('[SyncService] _processOutboxItem(file): Found file item in DB: name="${item.name}", localPath="${item.localPath}". Marking sending...');
          await repository.markSending(operation.itemId);

          final clientTime = item.createdAt?.toIso8601String() ?? DateTime.now().toIso8601String();
          final response = await api.uploadFile(
            filePath: item.localPath!,
            clientId: item.id,
            clientTime: clientTime,
            onProgress: (p) {
              debugPrint('[SyncService] File upload progress for ${item.id}: ${(p * 100).toStringAsFixed(1)}%');
            },
          );
          debugPrint('[SyncService] api.uploadFile() response: $response');

          if (response['status'] == 'ok' || response['status'] == 'duplicate') {
            debugPrint('[SyncService] File upload SUCCESS. Marking item ${operation.itemId} as synced');
            await repository.markSynced(operation.itemId);
            return true;
          }
          if (response['deleted'] == true) {
            debugPrint('[SyncService] Server reported file item was deleted. Discarding');
            await repository.discardFailed(operation.itemId);
            return true;
          }
          debugPrint('[SyncService] Unexpected server response for file upload: $response');
          return false;

        case 'delete':
          debugPrint('[SyncService] _processOutboxItem(delete): Deleting item ${operation.itemId} on server...');
          await api.deleteItem(operation.itemId);
          await repository.discardFailed(operation.itemId);
          debugPrint('[SyncService] _processOutboxItem(delete): Successfully deleted item ${operation.itemId}');
          return true;

        default:
          debugPrint('[SyncService] _processOutboxItem: Unknown kind "${operation.kind}", skipping');
          return true;
      }
    } catch (e, stack) {
      debugPrint('[SyncService] _processOutboxItem error for itemId=${operation.itemId}: $e\n$stack');
      return false;
    }
  }

  Future<void> pullSync() async {
    try {
      final connection = ref.read(connectionProvider);
      if (connection.ip.isEmpty) {
        debugPrint('[SyncService] pullSync(): connection.ip is empty, skipping pullSync');
        return;
      }

      final activeDevice = await repository.getActiveDevice();
      final deviceId = activeDevice?.deviceId;
      debugPrint('[SyncService] pullSync() started: connection.ip="${connection.ip}", resolved deviceId="$deviceId"');
      if (deviceId == null || deviceId.isEmpty) {
        debugPrint('[SyncService] pullSync(): No activeDevice found yet, skipping pull until device is registered');
        return;
      }

      final lastSeq = await repository.getLastSeq(deviceId) ?? 0;
      debugPrint('[SyncService] pullSync(): deviceId="$deviceId", lastSeq=$lastSeq. Querying api.sync(after: $lastSeq)...');

      final syncData = await api.sync(lastSeq);
      debugPrint('[SyncService] pullSync(): Received sync payload: latest_seq=${syncData['latest_seq']}, full_resync=${syncData['full_resync']}, itemsCount=${(syncData['items'] as List?)?.length}, deletedCount=${(syncData['deleted'] as List?)?.length}');
      debugPrint('[SyncService] pullSync(): Raw items list: ${syncData['items']}');

      final rawItems = syncData['items'] as List? ?? [];
      for (int i = 0; i < rawItems.length; i++) {
        final rawItem = rawItems[i];
        debugPrint('[SyncService]   rawItem[$i]: type=${rawItem.runtimeType}, keys=${rawItem is Map ? rawItem.keys : 'N/A'}, content=$rawItem');
      }

      debugPrint('[SyncService] pullSync(): Parsing SyncResponse.fromJson...');
      final syncResponse = SyncResponse.fromJson(syncData);
      debugPrint('[SyncService] pullSync(): SyncResponse parsed successfully! items.length=${syncResponse.items.length}, latestSeq=${syncResponse.latestSeq}');

      debugPrint('[SyncService] pullSync(): Applying sync to repository for deviceId="$deviceId"...');
      await repository.applySync(deviceId, syncResponse);
      debugPrint('[SyncService] pullSync(): repository.applySync completed successfully.');
    } catch (e, stack) {
      debugPrint('[SyncService] pullSync() FAILED with error: $e\n$stack');
    }
  }

  Future<void> retryItem(String itemId) async {
    debugPrint('[SyncService] retryItem($itemId) called');
    final outboxItems = await (repository.db.select(repository.db.outbox)
          ..where((tbl) => tbl.itemId.equals(itemId)))
        .get();

    debugPrint('[SyncService] retryItem($itemId): Found ${outboxItems.length} outbox items to reset');
    for (final item in outboxItems) {
      await (repository.db.update(repository.db.outbox)..where((tbl) => tbl.id.equals(item.id)))
          .write(OutboxCompanion(attempts: drift.Value(0), nextAttemptAt: drift.Value(null)));
    }

    if (_isOnline) {
      debugPrint('[SyncService] retryItem($itemId): Currently online, triggering flushOutbox()...');
      await flushOutbox();
    } else {
      debugPrint('[SyncService] retryItem($itemId): Currently offline, will flush when back online');
    }
  }
}

final syncServiceProvider = Provider<SyncService>((ref) {
  final repository = ref.watch(repositoryProvider);
  final api = ref.watch(apiServiceProvider);
  return SyncService(ref, repository, api);
});