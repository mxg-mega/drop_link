import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

/// Result of probing the laptop server.
class ConnectionCheck {
  final bool ok;
  final bool authRequired;
  final String? error;
  final String? deviceId;
  final String? deviceName;
  final int? latestSeq;
  final int? phoneCursorSeq;

  const ConnectionCheck({
    required this.ok,
    this.authRequired = false,
    this.error,
    this.deviceId,
    this.deviceName,
    this.latestSeq,
    this.phoneCursorSeq,
  });
}

class ApiService {
  final Dio _dio = Dio();

  String baseUrl = '';
  String? _token;
  String? _deviceId;

  /// Points the client at the laptop. [token] comes from the pairing QR code
  /// (only present when the server runs with DROPLINK_REQUIRE_TOKEN=1).
  void setBaseUrl(String ip, {String port = '8000', String? token}) {
    baseUrl = 'http://$ip:$port';
    _token = (token != null && token.isNotEmpty) ? token : null;

    _dio.options
      ..baseUrl = baseUrl
      ..connectTimeout = const Duration(seconds: 5)
      ..receiveTimeout = const Duration(seconds: 15);

    if (_token != null) {
      _dio.options.headers['X-Token'] = _token;
    } else {
      _dio.options.headers.remove('X-Token');
    }

    if (_deviceId != null) {
      _dio.options.headers['X-Device-Id'] = _deviceId;
    }
  }

  void setDeviceId(String deviceId) {
    _deviceId = deviceId;
    if (_deviceId != null) {
      _dio.options.headers['X-Device-Id'] = _deviceId;
    }
  }

  /// Use with Image.network(api.fileUrl(name), headers: api.authHeaders).
  Map<String, String> get authHeaders =>
      _token == null ? const {} : {'X-Token': _token!};

  String fileUrl(String filename) =>
      '$baseUrl/download/${Uri.encodeComponent(filename)}';

  // -------- Connection --------

  /// /ping is public, so when the server wants a token we prove ours with a
  /// protected route (/shared is cheap) before calling the laptop "connected".
  Future<ConnectionCheck> checkConnection() async {
    try {
      final res = await _dio.get('/ping');
      final data = res.data;
      if (data is! Map || data['ping'] != 'pong') {
        return const ConnectionCheck(
          ok: false,
          error: 'That address is not a DropLink server.',
        );
      }

      final authRequired = data['auth_required'] == true;
      if (authRequired) {
        try {
          await _dio.get('/shared');
        } on DioException catch (e) {
          if (e.response?.statusCode == 401) {
            return const ConnectionCheck(
              ok: false,
              authRequired: true,
              error:
                  'Pairing token missing or wrong. Scan the QR code on the laptop.',
            );
          }
          rethrow;
        }
      }
      return ConnectionCheck(
        ok: true,
        authRequired: authRequired,
        deviceId: data['device_id'] as String?,
        deviceName: data['device_name'] as String?,
        latestSeq: data['latest_seq'] as int?,
        phoneCursorSeq: data['phone_cursor_seq'] as int?,
      );
    } catch (_) {
      return const ConnectionCheck(
        ok: false,
        error: 'Could not connect. Check IP and hotspot.',
      );
    }
  }

  /// Raw /ping payload: {ping, app, phone_online, auth_required}.
  Future<Map<String, dynamic>> ping() async {
    final res = await _dio.get('/ping');
    return Map<String, dynamic>.from(res.data as Map);
  }

  // -------- Sync --------

  Future<Map<String, dynamic>> sync(int after) async {
    final res = await _dio.get(
      '/sync',
      queryParameters: {'after': after.toString()},
    );
    return Map<String, dynamic>.from(res.data as Map);
  }

  // -------- Files --------
  Future<List<dynamic>> getSharedFiles() async {
    final res = await _dio.get('/shared');
    return res.data['files'] ?? [];
  }

  // -------- History --------

  /// With [since] (an item id) the server returns only newer items.
  /// Merge them into your list by `id`. If that id was deleted on the laptop
  /// the server returns everything, so replace-by-id keeps you consistent.
  Future<List<dynamic>> getHistory({String? since}) async {
    final res = await _dio.get(
      '/history',
      queryParameters: since == null ? null : {'since': since},
    );
    return res.data['history'] ?? [];
  }

  Future<Map<String, dynamic>> sendText({
    required String text,
    required String clientId,
    required String clientTime,
  }) async {
    final res = await _dio.post(
      '/text',
      data: FormData.fromMap({
        'text': text,
        'origin': 'phone',
        'client_id': clientId,
        'client_time': clientTime,
      }),
    );
    return Map<String, dynamic>.from(res.data as Map);
  }

  Future<Map<String, dynamic>> uploadFile({
    required String filePath,
    required String clientId,
    required String clientTime,
    required Function(double) onProgress,
  }) async {
    final fileName = filePath.split(RegExp(r'[\\/]')).last;

    final formData = FormData.fromMap({
      'file': await MultipartFile.fromFile(filePath, filename: fileName),
      'origin': 'phone',
      'client_id': clientId,
      'client_time': clientTime,
    });

    final res = await _dio.post(
      '/upload',
      data: formData,
      onSendProgress: (sent, total) {
        if (total > 0) onProgress(sent / total);
      },
    );
    return Map<String, dynamic>.from(res.data as Map);
  }

  Future<String> downloadFile(
    String filename, {
    required Function(double) onProgress,
  }) async {
    final dir = await getTemporaryDirectory();
    final safeName = filename.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final savePath = '${dir.path}/$safeName';

    await _dio.download(
      '/download/${Uri.encodeComponent(filename)}',
      savePath,
      onReceiveProgress: (received, total) {
        if (total > 0) onProgress(received / total);
      },
    );
    return savePath;
  }

  Future<void> deleteItem(String id) async {
    try {
      await _dio.delete('/history/${Uri.encodeComponent(id)}');
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        // Treat 404 as success - item already deleted
        return;
      }
      rethrow;
    }
  }
}