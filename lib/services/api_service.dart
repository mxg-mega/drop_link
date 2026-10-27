import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
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
    debugPrint(
      '[ApiService] setBaseUrl: $baseUrl (hasToken=${_token != null})',
    );

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
    debugPrint('[ApiService] setDeviceId: "$deviceId"');
    if (_deviceId != null) {
      _dio.options.headers['X-Device-Id'] = _deviceId;
    }
  }

  /// Use with Image.network(api.fileUrl(name), headers: api.authHeaders).
  Map<String, String> get authHeaders =>
      _token == null ? const {} : {'X-Token': _token!};

  String fileUrl(String filename) =>
      '$baseUrl/download/${Uri.encodeComponent(filename)}';

  /// Stable local identifier for a downloaded file, derived from its filename.
  String storageIdFor(String filename) =>
      base64Url.encode(utf8.encode(filename)).replaceAll('=', '');

  /// Returns the local path if this storage ID was previously downloaded.
  /// This works offline; null means the file is not present on this device.
  Future<String?> getDownloadedFilePath(String storageId) async {
    try {
      final filename = utf8.decode(
        base64Url.decode(base64Url.normalize(storageId)),
      );
      final path = await _downloadPath(storageId, filename);
      return await File(path).exists() ? path : null;
    } on FormatException {
      return null;
    }
  }

  Future<String> _downloadPath(String storageId, String filename) async {
    final dir = await getApplicationSupportDirectory();
    final downloadDir = Directory('${dir.path}/drop_link_downloads');
    await downloadDir.create(recursive: true);
    final safeName = filename.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return '${downloadDir.path}/${storageId}_$safeName';
  }

  // -------- Connection --------

  /// /ping is public, so when the server wants a token we prove ours with a
  /// protected route (/shared is cheap) before calling the laptop "connected".
  Future<ConnectionCheck> checkConnection() async {
    debugPrint('[ApiService] checkConnection() sending GET $baseUrl/ping...');
    try {
      final res = await _dio.get('/ping');
      final data = res.data;
      debugPrint(
        '[ApiService] checkConnection() /ping returned status=${res.statusCode}, data=$data',
      );
      if (data is! Map || data['ping'] != 'pong') {
        debugPrint(
          '[ApiService] checkConnection() invalid ping response: data=$data',
        );
        return const ConnectionCheck(
          ok: false,
          error: 'That address is not a DropLink server.',
        );
      }

      final authRequired = data['auth_required'] == true;
      if (authRequired) {
        debugPrint(
          '[ApiService] checkConnection() auth_required=true, testing protected /shared route...',
        );
        try {
          final sharedRes = await _dio.get('/shared');
          debugPrint(
            '[ApiService] checkConnection() /shared auth verification passed, status=${sharedRes.statusCode}',
          );
        } on DioException catch (e) {
          debugPrint(
            '[ApiService] checkConnection() /shared auth verification failed: statusCode=${e.response?.statusCode}',
          );
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
      final check = ConnectionCheck(
        ok: true,
        authRequired: authRequired,
        deviceId: data['device_id'] as String?,
        deviceName: data['device_name'] as String?,
        latestSeq: data['latest_seq'] as int?,
        phoneCursorSeq: data['phone_cursor_seq'] as int?,
      );
      debugPrint(
        '[ApiService] checkConnection() succeeded: deviceId=${check.deviceId}, deviceName=${check.deviceName}, latestSeq=${check.latestSeq}, phoneCursorSeq=${check.phoneCursorSeq}',
      );
      return check;
    } catch (e) {
      debugPrint('[ApiService] checkConnection() failed with error: $e');
      return const ConnectionCheck(
        ok: false,
        error: 'Could not connect. Check IP and hotspot.',
      );
    }
  }

  /// Raw /ping payload: {ping, app, phone_online, auth_required}.
  Future<Map<String, dynamic>> ping() async {
    debugPrint('[ApiService] ping() GET $baseUrl/ping');
    final res = await _dio.get('/ping');
    debugPrint('[ApiService] ping() result: ${res.data}');
    return Map<String, dynamic>.from(res.data as Map);
  }

  // -------- Sync --------

  Future<Map<String, dynamic>> sync(int after) async {
    debugPrint(
      '[ApiService] sync(after=$after) GET $baseUrl/sync?after=$after (headers=${_dio.options.headers})',
    );
    try {
      final res = await _dio.get(
        '/sync',
        queryParameters: {'after': after.toString()},
      );
      debugPrint(
        '[ApiService] sync(after=$after) response status=${res.statusCode}, data=${res.data}',
      );
      return Map<String, dynamic>.from(res.data as Map);
    } catch (e) {
      debugPrint('[ApiService] sync(after=$after) error: $e');
      rethrow;
    }
  }

  // -------- Files --------
  Future<List<dynamic>> getSharedFiles() async {
    debugPrint('[ApiService] getSharedFiles() GET $baseUrl/shared');
    final res = await _dio.get('/shared');
    final files = res.data['files'] ?? [];
    debugPrint('[ApiService] getSharedFiles() returned ${files.length} files');
    return files;
  }

  // -------- History --------

  /// With [since] (an item id) the server returns only newer items.
  /// Merge them into your list by `id`. If that id was deleted on the laptop
  /// the server returns everything, so replace-by-id keeps you consistent.
  Future<List<dynamic>> getHistory({String? since}) async {
    debugPrint('[ApiService] getHistory(since=$since) GET $baseUrl/history');
    final res = await _dio.get(
      '/history',
      queryParameters: since == null ? null : {'since': since},
    );
    final history = res.data['history'] ?? [];
    debugPrint(
      '[ApiService] getHistory(since=$since) returned ${history.length} items',
    );
    return history;
  }

  Future<Map<String, dynamic>> sendText({
    required String text,
    required String clientId,
    required String clientTime,
  }) async {
    debugPrint(
      '[ApiService] sendText() POST $baseUrl/text: clientId="$clientId", clientTime="$clientTime", text="$text"',
    );
    try {
      final res = await _dio.post(
        '/text',
        data: FormData.fromMap({
          'text': text,
          'origin': 'phone',
          'client_id': clientId,
          'client_time': clientTime,
        }),
      );
      debugPrint(
        '[ApiService] sendText() response status=${res.statusCode}, data=${res.data}',
      );
      return Map<String, dynamic>.from(res.data as Map);
    } catch (e) {
      debugPrint('[ApiService] sendText() error: $e');
      rethrow;
    }
  }

  Future<Map<String, dynamic>> uploadFile({
    required String filePath,
    required String clientId,
    required String clientTime,
    required Function(double) onProgress,
  }) async {
    final fileName = filePath.split(RegExp(r'[\\/]')).last;
    debugPrint(
      '[ApiService] uploadFile() POST $baseUrl/upload: fileName="$fileName", path="$filePath", clientId="$clientId"',
    );

    try {
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
          if (total > 0) {
            final fraction = sent / total;
            debugPrint(
              '[ApiService] uploadFile() progress: sent=$sent / total=$total (${(fraction * 100).toStringAsFixed(1)}%)',
            );
            onProgress(fraction);
          }
        },
      );
      debugPrint(
        '[ApiService] uploadFile() response status=${res.statusCode}, data=${res.data}',
      );
      return Map<String, dynamic>.from(res.data as Map);
    } catch (e) {
      debugPrint('[ApiService] uploadFile() error: $e');
      rethrow;
    }
  }

  Future<String> downloadFile(
    String filename, {
    required Function(double) onProgress,
  }) async {
    debugPrint('[ApiService] downloadFile() GET $baseUrl/download/$filename');
    final storageId = storageIdFor(filename);
    final savePath = await _downloadPath(storageId, filename);

    try {
      await _dio.download(
        '/download/${Uri.encodeComponent(filename)}',
        savePath,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            final fraction = received / total;
            debugPrint(
              '[ApiService] downloadFile() progress: $received / $total (${(fraction * 100).toStringAsFixed(1)}%)',
            );
            onProgress(fraction);
          }
        },
      );
      debugPrint(
        '[ApiService] downloadFile() saved successfully to "$savePath"',
      );
      return savePath;
    } catch (e) {
      debugPrint('[ApiService] downloadFile() error: $e');
      rethrow;
    }
  }

  Future<void> deleteItem(String id) async {
    debugPrint('[ApiService] deleteItem() DELETE $baseUrl/history/$id');
    try {
      final res = await _dio.delete('/history/${Uri.encodeComponent(id)}');
      debugPrint(
        '[ApiService] deleteItem($id) response: ${res.statusCode} ${res.data}',
      );
    } on DioException catch (e) {
      debugPrint(
        '[ApiService] deleteItem($id) DioException statusCode=${e.response?.statusCode}',
      );
      if (e.response?.statusCode == 404) {
        // Treat 404 as success - item already deleted
        debugPrint('[ApiService] deleteItem($id) got 404 (already deleted)');
        return;
      }
      rethrow;
    } catch (e) {
      debugPrint('[ApiService] deleteItem($id) error: $e');
      rethrow;
    }
  }
}
