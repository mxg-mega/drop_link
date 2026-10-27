import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import '../data/repository.dart';
import '../data/database.dart';
import '../data/database_provider.dart';
import '../models/transfer_item.dart';
import '../services/sync_service.dart';
import 'dart:async';

class ItemsNotifier extends StateNotifier<List<TransferItem>> {
  final Repository repository;
  final Ref ref;
  StreamSubscription? _deviceSubscription;
  StreamSubscription? _itemsSubscription;
  String? _currentDeviceId;

  ItemsNotifier(this.repository, this.ref) : super([]) {
    debugPrint('[ItemsNotifier] Initialized ItemsNotifier. Setting up active device watcher...');
    _watchActiveDevice();
  }

  void _watchActiveDevice() {
    _deviceSubscription?.cancel();
    _deviceSubscription = repository.watchActiveDevice().listen((activeDevice) {
      final deviceId = activeDevice?.deviceId;
      debugPrint('[ItemsNotifier] watchActiveDevice emitted: deviceId="$deviceId", name="${activeDevice?.name}", lastIp="${activeDevice?.lastIp}" (previous was "$_currentDeviceId")');

      if (deviceId != _currentDeviceId) {
        _currentDeviceId = deviceId;
        _subscribeToItems(deviceId);
      }
    });
  }

  void _subscribeToItems(String? deviceId) {
    _itemsSubscription?.cancel();
    if (deviceId == null || deviceId.isEmpty) {
      debugPrint('[ItemsNotifier] No active device (deviceId is null). State reset to empty list ([]).');
      state = [];
      return;
    }

    debugPrint('[ItemsNotifier] Subscribing to repository.watchItems(deviceId="$deviceId")...');
    _itemsSubscription = repository.watchItems(deviceId).listen((items) {
      debugPrint('[ItemsNotifier] watchItems stream emitted ${items.length} items from database for deviceId="$deviceId"');
      for (int i = 0; i < items.length; i++) {
        final item = items[i];
        debugPrint('[ItemsNotifier]   DB item[$i]: id=${item.id}, deviceId=${item.deviceId}, origin=${item.origin}, type=${item.type}, content="${item.content}", name="${item.name}", syncState=${item.syncState}, seq=${item.seq}, timeLabel="${item.timeLabel}"');
      }
      state = items.map(_dbItemToTransferItem).toList();
      debugPrint('[ItemsNotifier] itemsProvider state updated with ${state.length} TransferItems');
    });
  }

  Future<void> sendText(String text) async {
    debugPrint('[ItemsNotifier] sendText() called: text="$text"');
    final repository = ref.read(repositoryProvider);
    final activeDevice = await repository.getActiveDevice();
    final deviceId = activeDevice?.deviceId ?? _currentDeviceId ?? 'default';

    debugPrint('[ItemsNotifier] sendText(): activeDevice=${activeDevice?.deviceId}, target deviceId="$deviceId"');
    if (activeDevice == null && _currentDeviceId == null) {
      debugPrint('[ItemsNotifier] WARNING: activeDevice is null! Enqueueing text under fallback deviceId="$deviceId".');
    }

    debugPrint('[ItemsNotifier] Calling repository.enqueueText(deviceId="$deviceId", text="$text")...');
    await repository.enqueueText(deviceId, text);
    debugPrint('[ItemsNotifier] repository.enqueueText() finished: item stored in items (syncState="queued") and outbox');

    // Trigger immediate outbox flush so the message is delivered without waiting for reconnect
    debugPrint('[ItemsNotifier] Triggering immediate flushOutbox()...');
    ref.read(syncServiceProvider).flushOutbox();
  }

  Future<void> sendFile(String filePath, String fileName, int sizeBytes) async {
    debugPrint('[ItemsNotifier] sendFile() called: filePath="$filePath", fileName="$fileName", sizeBytes=$sizeBytes');
    final repository = ref.read(repositoryProvider);
    final activeDevice = await repository.getActiveDevice();
    final deviceId = activeDevice?.deviceId ?? _currentDeviceId ?? 'default';

    debugPrint('[ItemsNotifier] sendFile(): activeDevice=${activeDevice?.deviceId}, target deviceId="$deviceId"');
    if (activeDevice == null && _currentDeviceId == null) {
      debugPrint('[ItemsNotifier] WARNING: activeDevice is null! Enqueueing file under fallback deviceId="$deviceId"');
    }

    debugPrint('[ItemsNotifier] Calling repository.enqueueFile(deviceId="$deviceId", ...)...');
    await repository.enqueueFile(deviceId, filePath, fileName, sizeBytes);
    debugPrint('[ItemsNotifier] repository.enqueueFile() finished: file stored in items (syncState="queued") and outbox');

    // Trigger immediate outbox flush
    debugPrint('[ItemsNotifier] Triggering immediate flushOutbox()...');
    ref.read(syncServiceProvider).flushOutbox();
  }

  Future<void> deleteItem(String id) async {
    debugPrint('[ItemsNotifier] deleteItem() called for id="$id"');
    await repository.enqueueDelete(id);
    debugPrint('[ItemsNotifier] repository.enqueueDelete("$id") finished');

    // Trigger immediate outbox flush for delete operation
    ref.read(syncServiceProvider).flushOutbox();
  }

  Future<void> retryItem(String id) async {
    debugPrint('[ItemsNotifier] retryItem() called for id="$id"');
    final syncService = ref.read(syncServiceProvider);
    await syncService.retryItem(id);
    debugPrint('[ItemsNotifier] syncService.retryItem("$id") finished');
  }

  Future<void> discardItem(String id) async {
    debugPrint('[ItemsNotifier] discardItem() called for id="$id"');
    await repository.discardFailed(id);
    debugPrint('[ItemsNotifier] repository.discardFailed("$id") finished');
  }

  @override
  void dispose() {
    debugPrint('[ItemsNotifier] dispose() called: cancelling subscriptions');
    _deviceSubscription?.cancel();
    _itemsSubscription?.cancel();
    super.dispose();
  }

  TransferItem _dbItemToTransferItem(Item item) {
    final parsedType = _parseType(item.type);
    debugPrint('[ItemsNotifier] Mapping DB Item -> TransferItem: id=${item.id}, origin=${item.origin}, type="${item.type}"->$parsedType, content="${item.content}", name="${item.name}", syncState=${item.syncState}');
    return TransferItem(
      id: item.id,
      from: item.origin,
      type: parsedType,
      text: item.content,
      name: item.name,
      size: item.sizeLabel,
      time: item.timeLabel,
      status: item.syncState,
    );
  }

  ItemType _parseType(String? type) {
    switch (type) {
      case 'link':
        return ItemType.link;
      case 'file':
        return ItemType.file;
      case 'image':
        return ItemType.image;
      default:
        if (type != 'text') {
          debugPrint('[ItemsNotifier] _parseType: unknown type "$type", defaulting to ItemType.text');
        }
        return ItemType.text;
    }
  }
}

final itemsProvider = StateNotifierProvider<ItemsNotifier, List<TransferItem>>((
  ref,
) {
  final repository = ref.watch(repositoryProvider);
  return ItemsNotifier(repository, ref);
});
