import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:nsd/nsd.dart';
import '../data/repository.dart';
import '../data/database.dart';

class DiscoveredDevice {
  final String deviceId;
  final String name;
  final String ip;
  final int port;
  final bool authRequired;
  final String via; // 'mdns' or 'scan'
  final bool isPaired;
  final bool hasToken;

  DiscoveredDevice({
    required this.deviceId,
    required this.name,
    required this.ip,
    required this.port,
    required this.authRequired,
    required this.via,
    this.isPaired = false,
    this.hasToken = false,
  });

  String get key => '$deviceId:$ip:$port';
}

class DiscoveryService {
  final Repository repository;
  final Dio _dio = Dio();

  DiscoveryService(this.repository);

  Stream<DiscoveredDevice> discover({
    Duration timeout = const Duration(seconds: 6),
    String configuredPort = '8000',
  }) async* {
    final knownDevices = <String>{};
    final controller = StreamController<DiscoveredDevice>();

    // Start both mDNS and scan in parallel
    final mdnsStream = _discoverMDns(timeout, controller, knownDevices);
    final scanStream = _discoverSubnet(
      timeout,
      controller,
      knownDevices,
      configuredPort,
    );

    // Merge streams
    await Future.wait([mdnsStream, scanStream]);

    await controller.close();
  }

  Future<void> _discoverMDns(
    Duration timeout,
    StreamController<DiscoveredDevice> controller,
    Set<String> knownDevices,
  ) async {
    try {
      final service = Service(
        type: '_droplink._tcp',
        port: 0,
        name: '',
      );

      final discovery = Discovery.start(
        service,
        timeout: timeout,
      );

      await for (final result in discovery) {
        if (result.status == DiscoveryStatus.found) {
          final service = result.service;
          final host = service.host?.host;
          final port = service.port;

          if (host != null && port != null) {
            final key = '$host:$port';
            if (knownDevices.contains(key)) continue;
            knownDevices.add(key);

            // Verify with /ping
            final device = await _verifyDevice(host, port, 'mdns');
            if (device != null) {
              controller.add(device);
            }
          }
        }
      }
    } catch (e) {
      // mDNS may fail on some devices, continue with scan
    }
  }

  Future<void> _discoverSubnet(
    Duration timeout,
    StreamController<DiscoveredDevice> controller,
    Set<String> knownDevices,
    String configuredPort,
  ) async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );

      final ownAddresses = <String>{};
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (!addr.isLoopback) {
            ownAddresses.add(addr.address);
          }
        }
      }

      final port = int.tryParse(configuredPort) ?? 8000;
      final futures = <Future<void>>[];

      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (addr.isLoopback) continue;

          final parts = addr.address.split('.');
          if (parts.length != 4) continue;

          final base = '${parts[0]}.${parts[1]}.${parts[2]}';

          // Scan hosts 1-254 with concurrency
          for (int i = 1; i <= 254; i++) {
            final host = '$base.$i';
            if (ownAddresses.contains(host)) continue;

            final key = '$host:$port';
            if (knownDevices.contains(key)) continue;

            futures.add(_probeHost(host, port, controller, knownDevices));

            // Limit concurrency
            if (futures.length >= 48) {
              await Future.wait(futures, eagerError: false);
              futures.clear();
            }
          }
        }
      }

      // Wait for remaining
      if (futures.isNotEmpty) {
        await Future.wait(futures, eagerError: false);
      }
    } catch (e) {
      // Scan may fail, that's ok
    }
  }

  Future<void> _probeHost(
    String host,
    int port,
    StreamController<DiscoveredDevice> controller,
    Set<String> knownDevices,
  ) async {
    try {
      final device = await _verifyDevice(host, port, 'scan');
      if (device != null) {
        final key = device.key;
        if (!knownDevices.contains(key)) {
          knownDevices.add(key);
          controller.add(device);
        }
      }
    } catch (e) {
      // Host not reachable or not a DropLink server
    }
  }

  Future<DiscoveredDevice?> _verifyDevice(
    String host,
    int port,
    String via,
  ) async {
    try {
      final dio = Dio();
      dio.options.connectTimeout = const Duration(milliseconds: 400);
      dio.options.receiveTimeout = const Duration(milliseconds: 400);

      final response = await dio.get('http://$host:$port/ping');
      final data = response.data;

      if (data is! Map || data['ping'] != 'pong' || data['app'] != 'DropLink') {
        return null;
      }

      final deviceId = data['device_id'] as String?;
      final deviceName = data['device_name'] as String?;
      final authRequired = data['auth_required'] == true;

      if (deviceId == null) return null;

      // Check if paired
      final device = await repository.getDevice(deviceId);
      final isPaired = device != null;
      final hasToken = device?.token != null;

      return DiscoveredDevice(
        deviceId: deviceId,
        name: deviceName ?? 'Laptop',
        ip: host,
        port: port,
        authRequired: authRequired,
        via: via,
        isPaired: isPaired,
        hasToken: hasToken,
      );
    } catch (e) {
      return null;
    }
  }
}
