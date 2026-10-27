import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

QueryExecutor openDatabase() {
  return driftDatabase(
    name: 'droplink',
    native: DriftNativeOptions(
      databasePath: () async {
        final dbFolder = await getApplicationDocumentsDirectory();
        return p.join(dbFolder.path, 'droplink.db');
      },
    ),
  );
}

