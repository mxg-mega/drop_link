import 'package:drift/drift.dart';

part 'database.g.dart';

@DataClassName('Device')
class Devices extends Table {
  TextColumn get deviceId => text()();
  TextColumn get name => text()();
  TextColumn get lastIp => text()();
  TextColumn get lastPort => text()();
  TextColumn get token => text().nullable()();
  BoolColumn get authRequired => boolean().withDefault(const Constant(false))();
  DateTimeColumn get lastSeenAt => dateTime()();
  BoolColumn get isActive => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {deviceId};
}

@DataClassName('Item')
class Items extends Table {
  TextColumn get id => text()();
  TextColumn get deviceId => text()();
  IntColumn get seq => integer().nullable()();
  TextColumn get origin => text()(); // 'phone' or 'laptop'
  TextColumn get type => text()(); // 'text', 'link', 'file'
  TextColumn get text => text().nullable()();
  TextColumn get name => text().nullable()();
  IntColumn get sizeBytes => integer().nullable()();
  TextColumn get sizeLabel => text().nullable()();
  DateTimeColumn get createdAt => dateTime().nullable()();
  TextColumn get timeLabel => text()();
  TextColumn get localPath => text().nullable()();
  TextColumn get syncState => text()(); // 'synced', 'queued', 'sending', 'failed', 'pendingDelete'
  TextColumn get errorMessage => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('OutboxItem')
class Outbox extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get itemId => text()();
  TextColumn get kind => text()(); // 'text', 'file', 'delete'
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  DateTimeColumn get nextAttemptAt => dateTime().nullable()();
  TextColumn get lastError => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
}

@DataClassName('SyncCursor')
class SyncCursors extends Table {
  TextColumn get deviceId => text()();
  IntColumn get lastSeq => integer()();

  @override
  Set<Column> get primaryKey => {deviceId};
}

@DriftDatabase(tables: [Devices, Items, Outbox, SyncCursors])
class AppDatabase extends _$AppDatabase {
  AppDatabase(QueryExecutor e) : super(e);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        await m.createAll();
      },
    );
  }
}
