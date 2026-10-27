import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'dart:io';
import 'database.dart';

class SyncResponse {
  final int latestSeq;
  final bool fullResync;
  final List<Map<String, dynamic>> items;
  final List<String> deleted;

  SyncResponse({
    required this.latestSeq,
    required this.fullResync,
    required this.items,
    required this.deleted,
  });

  factory SyncResponse.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'] as List?;
    final itemsList = <Map<String, dynamic>>[];
    if (rawItems != null) {
      for (final it in rawItems) {
        if (it is Map) {
          itemsList.add(Map<String, dynamic>.from(it));
        }
      }
    }

    final rawDeleted = json['deleted'] as List?;
    final deletedList = <String>[];
    if (rawDeleted != null) {
      for (final d in rawDeleted) {
        if (d != null) deletedList.add(d.toString());
      }
    }

    return SyncResponse(
      latestSeq: json['latest_seq'] as int? ?? 0,
      fullResync: json['full_resync'] as bool? ?? false,
      items: itemsList,
      deleted: deletedList,
    );
  }
}

class Repository {
  final AppDatabase db;
  final Uuid _uuid = const Uuid();

  Repository(this.db);

  Stream<List<Item>> watchItems(String? deviceId) {
    if (deviceId == null || deviceId.isEmpty) {
      return Stream.value([]);
    }
    return (db.select(db.items)
          ..where((tbl) => tbl.deviceId.equals(deviceId))
          ..where((tbl) => tbl.syncState.isNotIn(['pendingDelete']))
          ..orderBy([(tbl) => OrderingTerm.asc(tbl.createdAt)]))
        .watch();
  }

  Future<void> enqueueText(String deviceId, String text) async {
    final itemId = _uuid.v4();
    final now = DateTime.now().toUtc();
    final timeLabel = _formatTime(now);

    await db.transaction(() async {
      await db.into(db.items).insert(ItemsCompanion(
        id: Value(itemId),
        deviceId: Value(deviceId),
        seq: const Value.absent(),
        origin: const Value('phone'),
        type: Value(text.startsWith('http') ? 'link' : 'text'),
        content: Value(text),
        createdAt: Value(now),
        timeLabel: Value(timeLabel),
        syncState: const Value('queued'),
      ));

      await db.into(db.outbox).insert(OutboxCompanion(
        itemId: Value(itemId),
        kind: const Value('text'),
        createdAt: Value(now),
      ));
    });
  }

  Future<void> enqueueFile(String deviceId, String pickedPath, String fileName, int sizeBytes) async {
    final itemId = _uuid.v4();
    final now = DateTime.now().toUtc();
    final timeLabel = _formatTime(now);
    final sizeLabel = _formatBytes(sizeBytes);

    // 1. Copy file to app-owned persistent storage
    final appDocs = await getApplicationDocumentsDirectory();
    final outboxDir = Directory(p.join(appDocs.path, 'outbox'));
    if (!await outboxDir.exists()) {
      await outboxDir.create(recursive: true);
    }
    final persistentPath = p.join(outboxDir.path, '${itemId}_$fileName');
    await File(pickedPath).copy(persistentPath);

    await db.transaction(() async {
      await db.into(db.items).insert(ItemsCompanion(
        id: Value(itemId),
        deviceId: Value(deviceId),
        seq: const Value.absent(),
        origin: const Value('phone'),
        type: Value('file'),
        name: Value(fileName),
        sizeBytes: Value(sizeBytes),
        sizeLabel: Value(sizeLabel),
        createdAt: Value(now),
        timeLabel: Value(timeLabel),
        localPath: Value(persistentPath),
        syncState: const Value('queued'),
      ));

      await db.into(db.outbox).insert(OutboxCompanion(
        itemId: Value(itemId),
        kind: const Value('file'),
        createdAt: Value(now),
      ));
    });
  }

  Future<void> enqueueDelete(String itemId) async {
    final item = await (db.select(db.items)..where((tbl) => tbl.id.equals(itemId))).getSingleOrNull();
    if (item == null) return;

    if (item.syncState == 'queued') {
      await db.transaction(() async {
        await (db.delete(db.items)..where((tbl) => tbl.id.equals(itemId))).go();
        await (db.delete(db.outbox)..where((tbl) => tbl.itemId.equals(itemId))).go();
      });
      return;
    }

    await db.transaction(() async {
      await (db.update(db.items)..where((tbl) => tbl.id.equals(itemId)))
          .write(ItemsCompanion(syncState: Value('pendingDelete')));
      await db.into(db.outbox).insert(OutboxCompanion(
        itemId: Value(itemId),
        kind: const Value('delete'),
        createdAt: Value(DateTime.now().toUtc()),
      ));
    });
  }

  Future<void> applySync(String deviceId, SyncResponse response) async {
    await db.transaction(() async {
      if (response.fullResync) {
        final unsentItemIds = await (db.select(db.items)
              ..where((tbl) => tbl.deviceId.equals(deviceId))
              ..where((tbl) => tbl.syncState.isIn(['queued', 'sending', 'failed'])))
            .map((item) => item.id)
            .get();

        await (db.delete(db.items)..where((tbl) => tbl.deviceId.equals(deviceId))).go();
        await (db.delete(db.outbox)..where((tbl) => tbl.itemId.isNotIn(unsentItemIds))).go();
      }

      for (final itemJson in response.items) {
        final id = itemJson['id'] as String?;
        if (id == null) continue;

        final existing = await (db.select(db.items)..where((tbl) => tbl.id.equals(id))).getSingleOrNull();

        if (existing != null) {
          if (existing.syncState == 'queued' || existing.syncState == 'sending' || existing.syncState == 'failed') {
            continue;
          }
          await (db.update(db.items)..where((tbl) => tbl.id.equals(id))).write(_itemFromJson(deviceId, itemJson));
        } else {
          await db.into(db.items).insert(_itemFromJson(deviceId, itemJson));
        }
      }

      for (final deletedId in response.deleted) {
        final item = await (db.select(db.items)..where((tbl) => tbl.id.equals(deletedId))).getSingleOrNull();
        if (item != null) {
          if (item.localPath != null) {
            try {
              final file = File(item.localPath!);
              if (await file.exists()) {
                await file.delete();
              }
            } catch (_) {}
          }
          await (db.delete(db.items)..where((tbl) => tbl.id.equals(deletedId))).go();
        }
      }

      await db.into(db.syncCursors).insert(
        SyncCursorsCompanion(
          deviceId: Value(deviceId),
          lastSeq: Value(response.latestSeq),
        ),
        mode: InsertMode.insertOrReplace,
      );
    });
  }

  Future<void> markSynced(String itemId) async {
    await db.transaction(() async {
      await (db.update(db.items)..where((tbl) => tbl.id.equals(itemId)))
          .write(ItemsCompanion(syncState: const Value('synced'), errorMessage: const Value(null)));
      await (db.delete(db.outbox)..where((tbl) => tbl.itemId.equals(itemId))).go();
    });
  }

  Future<void> markSending(String itemId) async {
    await (db.update(db.items)..where((tbl) => tbl.id.equals(itemId)))
        .write(ItemsCompanion(syncState: const Value('sending')));
  }

  Future<void> markFailed(String itemId, String error) async {
    await (db.update(db.items)..where((tbl) => tbl.id.equals(itemId)))
        .write(ItemsCompanion(syncState: const Value('failed'), errorMessage: Value(error)));
  }

  Future<void> incrementOutboxAttempts(int outboxId) async {
    final outbox = await (db.select(db.outbox)..where((tbl) => tbl.id.equals(outboxId))).getSingleOrNull();
    if (outbox == null) return;

    final attempts = outbox.attempts + 1;
    final delays = [2, 5, 15, 30];
    final delay = attempts <= delays.length ? delays[attempts - 1] : 30;
    final nextAttempt = DateTime.now().toUtc().add(Duration(seconds: delay));

    await (db.update(db.outbox)..where((tbl) => tbl.id.equals(outboxId))).write(
      OutboxCompanion(
        attempts: Value(attempts),
        nextAttemptAt: Value(nextAttempt),
      ),
    );
  }

  Future<void> resetSendingToQueued() async {
    await (db.update(db.items)..where((tbl) => tbl.syncState.equals('sending')))
        .write(ItemsCompanion(syncState: const Value('queued')));
  }

  Future<List<OutboxItem>> getPendingOutbox() async {
    return (db.select(db.outbox)
          ..where((tbl) =>
              tbl.nextAttemptAt.isSmallerOrEqualValue(DateTime.now().toUtc()) |
              tbl.nextAttemptAt.isNull())
          ..orderBy([(tbl) => OrderingTerm.asc(tbl.createdAt)]))
        .get();
  }

  Future<void> markCached(String itemId, String path) async {
    await (db.update(db.items)..where((tbl) => tbl.id.equals(itemId)))
        .write(ItemsCompanion(localPath: Value(path)));
  }

  Future<void> discardFailed(String itemId) async {
    await db.transaction(() async {
      await (db.delete(db.items)..where((tbl) => tbl.id.equals(itemId))).go();
      await (db.delete(db.outbox)..where((tbl) => tbl.itemId.equals(itemId))).go();
    });
  }

  Future<int?> getLastSeq(String deviceId) async {
    final cursor = await (db.select(db.syncCursors)..where((tbl) => tbl.deviceId.equals(deviceId))).getSingleOrNull();
    return cursor?.lastSeq;
  }

  Future<void> saveDevice(Device device) async {
    await db.into(db.devices).insert(device, mode: InsertMode.insertOrReplace);
  }

  Future<Device?> getDevice(String deviceId) async {
    return (db.select(db.devices)..where((tbl) => tbl.deviceId.equals(deviceId))).getSingleOrNull();
  }

  Future<Device?> getActiveDevice() async {
    return (db.select(db.devices)..where((tbl) => tbl.isActive.equals(true))).getSingleOrNull();
  }

  Stream<Device?> watchActiveDevice() {
    return (db.select(db.devices)..where((tbl) => tbl.isActive.equals(true)))
        .watchSingleOrNull();
  }

  Future<void> setActiveDevice(String deviceId) async {
    await db.transaction(() async {
      await (db.update(db.devices)..where((tbl) => tbl.isActive.equals(true)))
          .write(const DevicesCompanion(isActive: Value(false)));
      await (db.update(db.devices)..where((tbl) => tbl.deviceId.equals(deviceId)))
          .write(const DevicesCompanion(isActive: Value(true)));
    });
  }

  ItemsCompanion _itemFromJson(String deviceId, Map<String, dynamic> json) {
    final createdAtStr = json['created_at'] as String?;
    DateTime? createdAt;
    if (createdAtStr != null) {
      createdAt = DateTime.tryParse(createdAtStr);
    }

    final id = (json['id'] ?? '').toString();
    final origin = (json['from'] ?? json['origin'] ?? 'laptop').toString();
    final type = (json['type'] ?? 'text').toString();
    final content = (json['text'] ?? json['content']) as String?;
    final timeStr = json['time'] as String? ?? (createdAt != null ? _formatTime(createdAt) : _formatTime(DateTime.now().toUtc()));

    return ItemsCompanion(
      id: Value(id),
      deviceId: Value(deviceId),
      seq: Value(json['seq'] as int?),
      origin: Value(origin),
      type: Value(type),
      content: Value(content),
      name: Value(json['name'] as String?),
      sizeBytes: Value(json['size_bytes'] as int?),
      sizeLabel: Value(json['size'] as String? ?? ''),
      createdAt: createdAt != null ? Value(createdAt) : const Value.absent(),
      timeLabel: Value(timeStr),
      syncState: const Value('synced'),
    );
  }

  String _formatTime(DateTime utc) {
    final local = utc.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(2)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
