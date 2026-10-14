import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/repository.dart';
import '../data/database.dart';
import '../models/transfer_item.dart';
import 'connection_provider.dart';
import '../services/sync_service.dart';

class ItemsNotifier extends StateNotifier<List<TransferItem>> {
  final Repository repository;
  final Ref ref;
  StreamSubscription? _subscription;

  ItemsNotifier(this.repository, this.ref) : super([]) {
    _loadFromDatabase();
  }

  Future<void> _loadFromDatabase() async {
    final connection = ref.read(connectionProvider);
    // For now, use IP as deviceId. Will update to use actual device ID
    final deviceId = connection.ip.isEmpty ? null : connection.ip;
    if (deviceId == null) return;

    _subscription?.cancel();
    _subscription = repository.watchItems(deviceId).listen((items) {
      state = items.map(_dbItemToTransferItem).toList();
    });
  }

  Future<void> sendText(String text) async {
    final connection = ref.read(connectionProvider);
    final deviceId = connection.ip.isEmpty ? 'default' : connection.ip;

    await repository.enqueueText(deviceId, text);
  }

  Future<void> sendFile(String filePath, String fileName, int sizeBytes) async {
    final connection = ref.read(connectionProvider);
    final deviceId = connection.ip.isEmpty ? 'default' : connection.ip;

    await repository.enqueueFile(deviceId, filePath, fileName, sizeBytes);
  }

  Future<void> deleteItem(String id) async {
    await repository.enqueueDelete(id);
  }

  Future<void> retryItem(String id) async {
    final syncService = ref.read(syncServiceProvider);
    await syncService.retryItem(id);
  }

  Future<void> discardItem(String id) async {
    await repository.discardFailed(id);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  TransferItem _dbItemToTransferItem(Item item) {
    return TransferItem(
      id: item.id,
      from: item.origin,
      type: _parseType(item.type),
      text: item.text,
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
        return ItemType.text;
    }
  }
}

final itemsProvider = StateNotifierProvider<ItemsNotifier, List<TransferItem>>((ref) {
  final repository = ref.watch(repositoryProvider);
  return ItemsNotifier(repository, ref);
});
