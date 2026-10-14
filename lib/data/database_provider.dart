import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'database.dart';
import 'database_helper.dart';
import 'repository.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  return AppDatabase(openDatabase());
});

final repositoryProvider = Provider<Repository>((ref) {
  final db = ref.watch(databaseProvider);
  return Repository(db);
});

class DeviceIdNotifier extends AsyncNotifier<String> {
  @override
  Future<String> build() async {
    final prefs = await SharedPreferences.getInstance();
    String? deviceId = prefs.getString('phone_device_id');
    if (deviceId == null || deviceId.isEmpty) {
      deviceId = const Uuid().v4();
      await prefs.setString('phone_device_id', deviceId);
    }
    return deviceId;
  }
}

final deviceIdProvider = AsyncNotifierProvider<DeviceIdNotifier, String>(DeviceIdNotifier.new);
