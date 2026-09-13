import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'moov_decoder.dart';
import 'moov_foreground.dart';
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

  // ---- diagnostics (surfaced in the UI so a field failure is visible without logcat)
  int packetsReceived = 0;
  String lastPacketHex = '';
  String enableWriteResult = 'not attempted';
  bool dataCharFound = false;
  bool enableCharFound = false;
  bool notifySubscribed = false;
  int servicesFound = 0;
  List<String> serviceUuids = [];
  int writeAttempts = 0;
  int scanStarts = 0;
  String lastError = '';
  String lastMatchKind = '';     // name | uuid | fallback
  String lastCandidateAdvName = '';
  int nameMatches = 0;
  int fallbackMatches = 0;
  String lastCandidate = '';
  String _lastCandidateAddr = '';
  final Set<String> _blacklist = {};
  int get blacklistSize => _blacklist.length;

  StreamSubscription<List<int>>? _valueSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<ScanResult>>? _scanSub;
  Timer? _keepAliveTimer;
  DateTime? _lastFrameAt;
  bool _autoConnectRunning = false;
  bool _enablingStream = false;
  bool _connectInProgress = false;
  BluetoothDevice? _fallbackCandidate;
  final Map<String, int> _sightings = {};
  static const int _sightingsNeeded = 3;   // seen on 3 separate scan emissions
  static const int _fallbackRssi = -65;    // and genuinely close

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

  /// Starts the always-on connect engine. Safe to call repeatedly.
  Future<void> startAutoConnect() async {
    if (_autoConnectRunning) return;
    _autoConnectRunning = true;
    _scanSub ??= FlutterBluePlus.scanResults.listen(_onScanResults);
    unawaited(_scanLoop());
  }

  /// Keeps one long scan running while disconnected.
  ///
  /// Android throttles apps to 5 scan *starts* per 30 seconds. The previous
  /// scan / stop / scan cycle every 8 s sat right on that limit, so the OS
  /// delayed the scans and connecting felt slow. A single long scan with a
  /// periodic restart stays well under it.
  Future<void> _scanLoop() async {
    while (_autoConnectRunning) {
      if (_connectInProgress || (_device != null && _isConnected)) {
        await Future.delayed(const Duration(milliseconds: 500));
        continue;
      }
      _setState(MoovConnectionState.scanning);
      try {
        scanStarts++;
        await FlutterBluePlus.startScan(
          timeout: const Duration(seconds: 25),
          continuousUpdates: true,
        );
      } catch (e) {
        lastError = 'scan: $e';
        await Future.delayed(const Duration(seconds: 2));
      }
    }
  }

  void _onScanResults(List<ScanResult> results) {
    if (_connectInProgress) return;
    if (_device != null && _isConnected) return;

    for (final r in results) {
      if (_blacklist.contains(r.device.remoteId.str)) continue;

      final name = r.device.platformName.toLowerCase();
      final advName = r.advertisementData.advName.toLowerCase();
      final nameMatch =
          moovNameHints.any((h) => name.contains(h) || advName.contains(h));
      final svcUuids =
          r.advertisementData.serviceUuids.map((g) => g.str.toLowerCase());
      final uuidMatch =
          svcUuids.any((u) => moovAdvUuids.any((frag) => u.contains(frag)));

      if (nameMatch || uuidMatch) {
        // Recorded so the Diagnostics panel shows whether Android is actually
        // reporting an advertised name. If it never matches here, every
        // connection is going through the slow fallback path.
        lastMatchKind = nameMatch ? 'name' : 'uuid';
        nameMatches++;
        lastCandidateAdvName = r.advertisementData.advName;
        _beginConnect(r.device);
        return;
      }

      // The Moov normally advertises as an unnamed device with no service
      // UUIDs, so signal strength is the only remaining clue.
      //
      // This used to connect to the first strong device it saw, which meant
      // burning a 15 s connect timeout on a nearby non-Moov while the user
      // was pressing their actual device. The fallback now has to be seen on
      // several separate scan emissions and be genuinely close, so a device
      // that merely drifts past is ignored.
      final addr = r.device.remoteId.str;
      if (r.rssi > _fallbackRssi) {
        _sightings[addr] = (_sightings[addr] ?? 0) + 1;
        if (_sightings[addr]! >= _sightingsNeeded) {
          _fallbackCandidate ??= r.device;
        }
      }
    }

    final fb = _fallbackCandidate;
    if (fb != null && !_blacklist.contains(fb.remoteId.str)) {
      lastMatchKind = 'fallback';
      fallbackMatches++;
      _fallbackCandidate = null;
      _beginConnect(fb);
    }
  }

  void _beginConnect(BluetoothDevice d) {
    if (_connectInProgress) return;
    if (_device != null && _isConnected) return;
    _connectInProgress = true;

    _lastCandidateAddr = d.remoteId.str;
    lastCandidate = "${d.platformName.isEmpty ? "(no name)" : d.platformName} "
        "$_lastCandidateAddr";

    unawaited(() async {
      try {
        await FlutterBluePlus.stopScan();
        _setState(MoovConnectionState.connecting);
        await _connect(d);
      } catch (e) {
        lastError = e.toString();
        if (_lastCandidateAddr.isNotEmpty) _blacklist.add(_lastCandidateAddr);
        _setState(MoovConnectionState.waitingForDevice);
      } finally {
        _connectInProgress = false;
      }
    }());
  }

  bool get _isConnected => _device?.isConnected ?? false;

  Future<void> _connect(BluetoothDevice device) async {
    // Short timeout: the Moov answers immediately when awake, and a wrong
    // device should fail fast rather than block the queue.
    await device.connect(timeout: const Duration(seconds: 8));
    _device = device;

    // Recover automatically when the link drops (the firmware sleeps the
    // stream regularly, and the link occasionally follows).
    await _connSub?.cancel();
    _connSub = device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected) _onDisconnected();
    });

    final services = await device.discoverServices();
    servicesFound = services.length;
    serviceUuids = services.map((x) => x.uuid.str.toLowerCase()).toList();

    final service = services.firstWhere(
      (s) => s.uuid.str.toLowerCase() == moovServiceUuid,
      orElse: () => throw StateError(
          'not a Moov: no f000cd50 among ${services.length} services'),
    );

    // 1. Subscribe to the data characteristic only.
    final dataChar = service.characteristics.firstWhere(
      (c) => c.uuid.str.toLowerCase() == moovDataCharUuid,
      orElse: () => throw StateError('data char not found'),
    );
    dataCharFound = true;
    await dataChar.setNotifyValue(true);
    notifySubscribed = true;
    _valueSub = dataChar.onValueReceived.listen(_onPacket);

    // Let the CCCD write settle before issuing the enable write. Android can
    // drop a characteristic write issued in the same breath as setNotifyValue.
    await Future.delayed(const Duration(milliseconds: 300));

    // 2. Enable the stream. Only cd52 — writing cd53/cd54 drops the link.
    _enableChar = service.characteristics.firstWhere(
      (c) => c.uuid.str.toLowerCase() == moovEnableCharUuid,
      orElse: () => throw StateError('enable char not found'),
    );
    enableCharFound = true;
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
      writeAttempts++;
      // f000cd52 declares 'write' but NOT 'write-without-response'. Bleak on
      // Windows tolerates a no-response write anyway; Android does not, and
      // rejects it with GATT_WRITE_NOT_PERMITTED. Match the declared property.
      final noResp = char.properties.writeWithoutResponse && !char.properties.write;
      await char.write([moovEnableOn], withoutResponse: noResp);
      enableWriteResult = 'ok (attempt $writeAttempts, '
          '${noResp ? "no-response" : "with-response"})';
    } catch (e) {
      // Record it rather than swallow it: a failed enable write is exactly why
      // the app would sit on "Connected" with no data.
      enableWriteResult = 'FAILED: $e';
    } finally {
      _enablingStream = false;
    }
  }

  void _onPacket(List<int> value) {
    _lastFrameAt = DateTime.now();
    packetsReceived++;
    lastPacketHex = value.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
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
    // The scan loop observes the cleared device and resumes scanning.
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
    await _scanSub?.cancel();
    await MoovForeground.stop();
    await disconnect();
    await _frameController.close();
    await _stateController.close();
  }
}
