import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../data/database_provider.dart';
import '../data/repository.dart';

class LinkState {
  final String ip;
  final String port;
  final String? token; // pairing token from the QR code, if the server uses one
  final bool isConnected;
  final bool isLoading;
  final bool authRequired;
  final String? error;

  const LinkState({
    this.ip = '127.0.0.1',
    this.port = '8000',
    this.token,
    this.isConnected = false,
    this.isLoading = false,
    this.authRequired = false,
    this.error,
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
  }) {
    return LinkState(
      ip: ip ?? this.ip,
      port: port ?? this.port,
      token: clearToken ? null : (token ?? this.token),
      isConnected: isConnected ?? this.isConnected,
      isLoading: isLoading ?? this.isLoading,
      authRequired: authRequired ?? this.authRequired,
      error: error,
    );
  }
}

final apiServiceProvider = Provider<ApiService>((ref) => ApiService());

class ConnectionNotifier extends Notifier<LinkState> {
  @override
  LinkState build() {
    _restore();
    return const LinkState();
  }

  ApiService get _api => ref.read(apiServiceProvider);

  /// Loads the last laptop and quietly tries to reconnect to it.
  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final ip = prefs.getString('last_ip');
    if (ip == null || ip.isEmpty) return;

    state = state.copyWith(
      ip: ip,
      port: prefs.getString('last_port') ?? '8000',
      token: prefs.getString('last_token'),
    );
    await connect();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
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
    state = state.copyWith(ip: ip.trim());
    await _save();
  }

  /// Updates the port without changing IP or token.
  Future<void> updatePort(String port) async {
    state = state.copyWith(port: port.isEmpty ? '8000' : port);
    await _save();
  }

  /// Updates both IP and port (used by QR scan and discovery).
  Future<void> updateAddress(String ip, String port, {String? token, bool clearToken = false}) async {
    state = state.copyWith(
      ip: ip.trim(),
      port: port.isEmpty ? '8000' : port,
      token: token,
      clearToken: clearToken,
    );
    await _save();
  }

  Future<bool> connect({String? port}) async {
    if (port != null && port.isNotEmpty) {
      state = state.copyWith(port: port);
    }
    state = state.copyWith(isLoading: true);
    _api.setBaseUrl(state.ip, port: state.port, token: state.token);

    final check = await _api.checkConnection();
    if (check.ok) await _save();

    state = state.copyWith(
      isConnected: check.ok,
      authRequired: check.authRequired,
      isLoading: false,
      error: check.ok ? null : check.error,
    );
    return check.ok;
  }

  /// Handles the laptop's QR code, e.g. http://192.168.43.12:8000/?token=abc
  /// (the ?token part only exists when the server requires one).
  Future<bool> pairFromQr(String raw) async {
    final uri = Uri.tryParse(raw.trim());
    final valid = uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
    if (!valid) {
      state = state.copyWith(error: 'That QR code is not a DropLink address.');
      return false;
    }

    final token = uri.queryParameters['token'];
    final hasToken = token != null && token.isNotEmpty;
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
    final check = await _api.checkConnection();
    if (check.ok != state.isConnected) {
      state = state.copyWith(
        isConnected: check.ok,
        authRequired: check.authRequired,
        error: check.ok ? null : check.error,
      );
    }
  }

  void disconnect() {
    state = state.copyWith(isConnected: false);
  }

  /// Attempt to auto-reconnect to the saved device when IP changes
  Future<bool> tryAutoReconnect() async {
    final repository = ref.read(repositoryProvider);
    final activeDevice = await repository.getActiveDevice();
    if (activeDevice == null) return false;

    // Try ping the saved IP
    _api.setBaseUrl(activeDevice.lastIp, port: activeDevice.lastPort, token: activeDevice.token);
    final check = await _api.checkConnection();

    if (check.ok) {
      state = state.copyWith(
        ip: activeDevice.lastIp,
        port: activeDevice.lastPort,
        token: activeDevice.token,
        isConnected: true,
        authRequired: check.authRequired,
      );
      await _save();
      return true;
    }

    // Try discovery to find the device by ID
    // This would need to be implemented in a discovery provider
    // For now, return false
    return false;
  }
}

final connectionProvider =
    NotifierProvider<ConnectionNotifier, LinkState>(
      ConnectionNotifier.new,
    );