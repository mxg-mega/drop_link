import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../data/database.dart';
import '../data/database_provider.dart';
import '../services/discovery_service.dart';
import '../services/sync_service.dart';

class LinkState {
  final String ip;
  final String port;
  final String? token; // pairing token from the QR code, if the server uses one
  final bool isConnected;
  final bool isLoading;
  final bool authRequired;
  final String? error;
  final int pendingCount;

  const LinkState({
    this.ip = '127.0.0.1',
    this.port = '8000',
    this.token,
    this.isConnected = false,
    this.isLoading = false,
    this.authRequired = false,
    this.error,
    this.pendingCount = 0,
  });

  LinkState copyWith({
    String? ip,
    String? port,
    String? token,
    bool clearToken = false,
    bool? isConnected,
    bool? isLoading,
    bool? authRequired,
    String? error, // always replaced: pass nothing to clear it
    int? pendingCount,
  }) {
    return LinkState(
      ip: ip ?? this.ip,
      port: port ?? this.port,
      token: clearToken ? null : (token ?? this.token),
      isConnected: isConnected ?? this.isConnected,
      isLoading: isLoading ?? this.isLoading,
      authRequired: authRequired ?? this.authRequired,
      error: error,
      pendingCount: pendingCount ?? this.pendingCount,
    );
  }
}

final apiServiceProvider = Provider<ApiService>((ref) => ApiService());

class ConnectionNotifier extends Notifier<LinkState> {
  @override
  LinkState build() {
    debugPrint('[ConnectionNotifier] build() initializing state and restoring last connection...');
    _restore();
    return const LinkState();
  }

  ApiService get _api => ref.read(apiServiceProvider);

  /// Loads the last laptop and quietly tries to reconnect to it.
  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final ip = prefs.getString('last_ip');
    if (ip == null || ip.isEmpty) {
      debugPrint('[ConnectionNotifier] _restore(): No saved IP found in SharedPreferences');
      return;
    }

    final port = prefs.getString('last_port') ?? '8000';
    final token = prefs.getString('last_token');
    debugPrint('[ConnectionNotifier] _restore(): Restoring saved connection target: $ip:$port (hasToken=${token != null})');

    state = state.copyWith(
      ip: ip,
      port: port,
      token: token,
    );
    await connect();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    debugPrint('[ConnectionNotifier] _save(): Saving last_ip=${state.ip}, last_port=${state.port}, token=${state.token}');
    await prefs.setString('last_ip', state.ip);
    await prefs.setString('last_port', state.port);
    final token = state.token;
    if (token == null) {
      await prefs.remove('last_token');
    } else {
      await prefs.setString('last_token', token);
    }
  }

  /// Updates the IP address without changing port or token.
  Future<void> updateIp(String ip) async {
    debugPrint('[ConnectionNotifier] updateIp: "$ip"');
    state = state.copyWith(ip: ip.trim());
    await _save();
  }

  /// Updates the port without changing IP or token.
  Future<void> updatePort(String port) async {
    debugPrint('[ConnectionNotifier] updatePort: "$port"');
    state = state.copyWith(port: port.isEmpty ? '8000' : port);
    await _save();
  }

  /// Updates both IP and port (used by QR scan and discovery).
  Future<void> updateAddress(String ip, String port, {String? token, bool clearToken = false}) async {
    debugPrint('[ConnectionNotifier] updateAddress: ip="$ip", port="$port", token=$token, clearToken=$clearToken');
    state = state.copyWith(
      ip: ip.trim(),
      port: port.isEmpty ? '8000' : port,
      token: token,
      clearToken: clearToken,
    );
    await _save();
  }

  /// Updates the pending count of items in the outbox.
  void updatePendingCount(int count) {
    if (state.pendingCount != count) {
      debugPrint('[ConnectionNotifier] updatePendingCount: $count (was ${state.pendingCount})');
    }
    state = state.copyWith(pendingCount: count);
  }

  Future<bool> connect({String? port}) async {
    if (port != null && port.isNotEmpty) {
      state = state.copyWith(port: port);
    }
    debugPrint('[ConnectionNotifier] connect() initiated to http://${state.ip}:${state.port} (token: ${state.token != null ? "[REDACTED]" : "none"})');
    state = state.copyWith(isLoading: true);
    _api.setBaseUrl(state.ip, port: state.port, token: state.token);

    final check = await _api.checkConnection();
    debugPrint('[ConnectionNotifier] connect() checkConnection result: ok=${check.ok}, authRequired=${check.authRequired}, deviceId=${check.deviceId}, deviceName=${check.deviceName}, latestSeq=${check.latestSeq}, error=${check.error}');
    if (check.ok) {
      await _save();
      if (check.deviceId != null && check.deviceId!.isNotEmpty) {
        final repository = ref.read(repositoryProvider);
        debugPrint('[ConnectionNotifier] Saving and activating device in DB: ${check.deviceId}');
        await repository.saveDevice(Device(
          deviceId: check.deviceId!,
          name: check.deviceName ?? 'Laptop',
          lastIp: state.ip,
          lastPort: state.port,
          token: state.token,
          authRequired: check.authRequired,
          lastSeenAt: DateTime.now(),
          isActive: true,
        ));
        await repository.setActiveDevice(check.deviceId!);
      }
      ref.read(syncServiceProvider).setOnline(true);
    }

    state = state.copyWith(
      isConnected: check.ok,
      authRequired: check.authRequired,
      isLoading: false,
      error: check.ok ? null : check.error,
    );
    debugPrint('[ConnectionNotifier] connect() finished: state.isConnected=${state.isConnected}, error=${state.error}');
    return check.ok;
  }

  /// Handles the laptop's QR code, e.g. http://192.168.43.12:8000/?token=abc
  /// (the ?token part only exists when the server requires one).
  Future<bool> pairFromQr(String raw) async {
    debugPrint('[ConnectionNotifier] pairFromQr() received raw input: "$raw"');
    final uri = Uri.tryParse(raw.trim());
    final valid = uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
    if (!valid) {
      debugPrint('[ConnectionNotifier] pairFromQr(): Invalid QR code URI: "$raw"');
      state = state.copyWith(error: 'That QR code is not a DropLink address.');
      return false;
    }

    final token = uri.queryParameters['token'];
    final hasToken = token != null && token.isNotEmpty;
    debugPrint('[ConnectionNotifier] pairFromQr(): Validated address host=${uri.host}, port=${uri.hasPort ? uri.port.toString() : "8000"}, token=$token');
    await updateAddress(
      uri.host,
      uri.hasPort ? uri.port.toString() : '8000',
      token: hasToken ? token : null,
      clearToken: !hasToken,
    );
    return connect();
  }

  /// Cheap re-check for a polling timer, so the status pill notices when the
  /// laptop goes away or comes back. Does not show the loading spinner.
  Future<void> refreshStatus() async {
    if (state.isLoading) return;
    debugPrint('[ConnectionNotifier] refreshStatus() running periodic check...');
    final check = await _api.checkConnection();
    debugPrint('[ConnectionNotifier] refreshStatus() result: check.ok=${check.ok}, previous isConnected=${state.isConnected}');
    if (check.ok != state.isConnected) {
      debugPrint('[ConnectionNotifier] refreshStatus() connection status flipped to: ${check.ok}');
      state = state.copyWith(
        isConnected: check.ok,
        authRequired: check.authRequired,
        error: check.ok ? null : check.error,
      );
    }
  }

  void disconnect() {
    debugPrint('[ConnectionNotifier] disconnect() called: marking state.isConnected=false');
    state = state.copyWith(isConnected: false);
    ref.read(syncServiceProvider).setOnline(false);
  }

  /// Attempt to auto-reconnect to the saved device when IP changes
  Future<bool> tryAutoReconnect() async {
    debugPrint('[ConnectionNotifier] tryAutoReconnect() started');
    final repository = ref.read(repositoryProvider);
    final activeDevice = await repository.getActiveDevice();
    if (activeDevice == null) {
      debugPrint('[ConnectionNotifier] tryAutoReconnect(): No activeDevice found in database');
      return false;
    }
    debugPrint('[ConnectionNotifier] tryAutoReconnect(): Active device found: id=${activeDevice.deviceId}, name=${activeDevice.name}, lastIp=${activeDevice.lastIp}:${activeDevice.lastPort}');

    // 1. Try ping the saved IP (2s timeout)
    _api.setBaseUrl(activeDevice.lastIp, port: activeDevice.lastPort, token: activeDevice.token);
    final check = await _api.checkConnection();
    debugPrint('[ConnectionNotifier] tryAutoReconnect(): Direct ping to ${activeDevice.lastIp}:${activeDevice.lastPort} ok=${check.ok}');

    if (check.ok) {
      state = state.copyWith(
        ip: activeDevice.lastIp,
        port: activeDevice.lastPort,
        token: activeDevice.token,
        isConnected: true,
        authRequired: check.authRequired,
      );
      await _save();
      debugPrint('[ConnectionNotifier] tryAutoReconnect(): Direct ping succeeded, reconnected!');
      return true;
    }

    // 2. Try discovery to find the device by ID (up to 4s)
    debugPrint('[ConnectionNotifier] tryAutoReconnect(): Direct ping failed, attempting subnet/mDNS discovery for deviceId=${activeDevice.deviceId}...');
    final discovery = DiscoveryService(repository);
    final foundDevices = <DiscoveredDevice>[];

    try {
      // We use a shorter timeout for auto-reconnect
      await for (final device in discovery.discover(timeout: const Duration(seconds: 4))) {
        debugPrint('[ConnectionNotifier] tryAutoReconnect() discovery observed: ${device.deviceId} at ${device.ip}:${device.port}');
        if (device.deviceId == activeDevice.deviceId) {
          debugPrint('[ConnectionNotifier] tryAutoReconnect() MATCHED target deviceId=${device.deviceId} at new IP ${device.ip}:${device.port}!');
          foundDevices.add(device);
          break;
        }
      }
    } catch (e) {
      debugPrint('[ConnectionNotifier] tryAutoReconnect(): Discovery threw error: $e');
    }

    if (foundDevices.isNotEmpty) {
      final device = foundDevices.first;
      debugPrint('[ConnectionNotifier] tryAutoReconnect(): Connecting to discovered device at ${device.ip}:${device.port}');
      state = state.copyWith(
        ip: device.ip,
        port: device.port.toString(),
        token: activeDevice.token,
        isConnected: false, // connect() will set this to true
        authRequired: device.authRequired,
      );
      await _save();
      return connect();
    }

    debugPrint('[ConnectionNotifier] tryAutoReconnect(): Could not find or reconnect to device ${activeDevice.deviceId}');
    return false;
  }
}

final connectionProvider =
    NotifierProvider<ConnectionNotifier, LinkState>(
      ConnectionNotifier.new,
    );