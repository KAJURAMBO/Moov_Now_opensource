import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'moov_decoder.dart';
import 'moov_protocol.dart';

enum MoovConnectionState { idle, scanning, connecting, connected, waitingForDevice }

/// Owns the BLE link to the Moov Now.
///
/// This is the Android equivalent of `backend/ble_bridge.py`: it scans, picks
/// the device, subscribes to the data characteristic, enables the stream, and
/// keeps it alive. Exposes a plain [Stream] of decoded frames so the UI layer
/// never touches BLE directly.
///
/// Everything is local — no network access anywhere in this class.
class MoovBleManager {
  MoovBleManager();

  final MoovDecoder _decoder = MoovDecoder();
  final _frameController = StreamController<SensorFrame>.broadcast();
  final _stateController = StreamController<MoovConnectionState>.broadcast();

  BluetoothDevice? _device;
  BluetoothCharacteristic? _enableChar;
  StreamSubscription<List<int>>? _valueSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  Timer? _keepAliveTimer;
  DateTime? _lastFrameAt;
  bool _autoConnectRunning = false;
  bool _enablingStream = false;

  BluetoothDevice? get device => _device;
  String get deviceName => _device?.platformName.isNotEmpty == true
      ? _device!.platformName
      : (_device?.remoteId.str ?? '—');

  /// Decoded sensor frames.
  Stream<SensorFrame> get frames => _frameController.stream;

  /// Connection state for the UI.
  Stream<MoovConnectionState> get state => _stateController.stream;

  MoovConnectionState _state = MoovConnectionState.idle;
  MoovConnectionState get currentState => _state;

  void _setState(MoovConnectionState s) {
    if (_state == s) return;
    _state = s;
    if (!_stateController.isClosed) _stateController.add(s);
  }

  // ---------------------------------------------------------------------------
  // Permissions
  // ---------------------------------------------------------------------------

  /// Android 12+ needs BLUETOOTH_SCAN / BLUETOOTH_CONNECT; older versions need
  /// location permission before the OS will return scan results at all.
  Future<bool> ensurePermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    final scanOk = statuses[Permission.bluetoothScan]?.isGranted ?? false;
    final connectOk = statuses[Permission.bluetoothConnect]?.isGranted ?? false;
    // Location may be permanently denied on newer Android without blocking BLE,
    // so treat only the bluetooth permissions as mandatory.
    return scanOk && connectOk;
  }

  // ---------------------------------------------------------------------------
  // Auto-connect
  // ---------------------------------------------------------------------------

  /// Starts the always-on connect loop: scan, connect, stream, recover.
  /// Safe to call repeatedly.
  Future<void> startAutoConnect() async {
    if (_autoConnectRunning) return;
    _autoConnectRunning = true;
    unawaited(_autoConnectLoop());
  }

  Future<void> _autoConnectLoop() async {
    while (_autoConnectRunning) {
      if (_device != null && _isConnected) {
        await Future.delayed(const Duration(seconds: 2));
        continue;
      }
      try {
        _setState(MoovConnectionState.scanning);
        final candidate = await _findMoov(timeout: const Duration(seconds: 8));
        if (candidate == null) {
          _setState(MoovConnectionState.waitingForDevice);
          continue;
        }
        _setState(MoovConnectionState.connecting);
        await _connect(candidate);
      } catch (_) {
        _setState(MoovConnectionState.waitingForDevice);
        await Future.delayed(const Duration(seconds: 2));
      }
    }
  }

  bool get _isConnected => _device?.isConnected ?? false;

  /// Scans and returns the first plausible Moov.
  ///
  /// The device usually advertises as "Unknown Device" with no service UUIDs,
  /// so a name match or a Moov service UUID wins immediately, and a strong
  /// unnamed signal is accepted as a fallback — the same tiering used on the
  /// desktop bridge.
  Future<BluetoothDevice?> _findMoov({required Duration timeout}) async {
    BluetoothDevice? named;
    BluetoothDevice? fallback;

    final sub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final name = r.device.platformName.toLowerCase();
        final advName = r.advertisementData.advName.toLowerCase();
        final rssi = r.rssi;

        final nameMatch = moovNameHints.any((h) => name.contains(h) || advName.contains(h));
        final svcUuids = r.advertisementData.serviceUuids.map((g) => g.str.toLowerCase());
        final uuidMatch = svcUuids.any(
          (u) => moovAdvUuids.any((frag) => u.contains(frag)),
        );

        if (nameMatch || uuidMatch) {
          named ??= r.device;
        } else if (rssi > -75) {
          fallback ??= r.device;
        }
      }
    });

    try {
      await FlutterBluePlus.startScan(timeout: timeout, continuousUpdates: true);
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        if (named != null) return named;
        await Future.delayed(const Duration(milliseconds: 200));
      }
      return named ?? fallback;
    } finally {
      await sub.cancel();
      await FlutterBluePlus.stopScan();
    }
  }

  Future<void> _connect(BluetoothDevice device) async {
    await device.connect(timeout: const Duration(seconds: 12));
    _device = device;

    // Recover automatically when the link drops (the firmware sleeps the
    // stream regularly, and the link occasionally follows).
    await _connSub?.cancel();
    _connSub = device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected) {
        _onDisconnected();
      }
    });

    final services = await device.discoverServices();
    final service = services.firstWhere(
      (s) => s.uuid.str.toLowerCase() == moovServiceUuid,
      orElse: () => throw StateError('Moov sensor service not found'),
    );

    // 1. Subscribe to the data characteristic only.
    final dataChar = service.characteristics.firstWhere(
      (c) => c.uuid.str.toLowerCase() == moovDataCharUuid,
    );
    await dataChar.setNotifyValue(true);
    _valueSub = dataChar.onValueReceived.listen(_onPacket);

    // 2. Enable the stream. Only cd52 — writing cd53/cd54 drops the link.
    _enableChar = service.characteristics.firstWhere(
      (c) => c.uuid.str.toLowerCase() == moovEnableCharUuid,
    );
    await _writeEnable();

    _decoder.reset();
    _lastFrameAt = DateTime.now();
    _setState(MoovConnectionState.connected);
    _startKeepAlive();
  }

  Future<void> _writeEnable() async {
    final char = _enableChar;
    if (char == null || _enablingStream) return;
    _enablingStream = true;
    try {
      await char.write([moovEnableOn], withoutResponse: true);
    } catch (_) {
      // Link went away mid-write; the connection listener will recover it.
    } finally {
      _enablingStream = false;
    }
  }

  void _onPacket(List<int> value) {
    _lastFrameAt = DateTime.now();
    final frame = _decoder.decode(Uint8List.fromList(value));
    if (frame != null && !_frameController.isClosed) {
      _frameController.add(frame);
    }
  }

  // ---------------------------------------------------------------------------
  // Keep-alive
  // ---------------------------------------------------------------------------

  /// The device's firmware sleeps the stream after ~10–20 s. Re-writing the
  /// enable byte after a few silent seconds resumes it without user action.
  void _startKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final last = _lastFrameAt;
      if (last == null || !_isConnected) return;
      if (DateTime.now().difference(last) > moovKeepAliveAfter) {
        _lastFrameAt = DateTime.now(); // avoid firing repeatedly while it wakes
        _writeEnable();
      }
    });
  }

  void _onDisconnected() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    _valueSub?.cancel();
    _valueSub = null;
    _enableChar = null;
    _device = null;
    _setState(MoovConnectionState.waitingForDevice);
    // The auto-connect loop observes the cleared device and rescans.
  }

  // ---------------------------------------------------------------------------
  // Teardown
  // ---------------------------------------------------------------------------

  Future<void> disconnect() async {
    _keepAliveTimer?.cancel();
    await _valueSub?.cancel();
    await _connSub?.cancel();
    try {
      await _device?.disconnect();
    } catch (_) {}
    _device = null;
    _enableChar = null;
    _setState(MoovConnectionState.idle);
  }

  Future<void> dispose() async {
    _autoConnectRunning = false;
    await disconnect();
    await _frameController.close();
    await _stateController.close();
  }
}
