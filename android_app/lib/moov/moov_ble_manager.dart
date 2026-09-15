import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'moov_decoder.dart';
import 'moov_foreground.dart';
import 'moov_protocol.dart';

enum MoovConnectionState { idle, scanning, connecting, connected, waitingForDevice }

/// One device seen during a scan, with the decision made about it.
class ScannedDevice {
  final String address;
  final String name;
  final int rssi;
  final String verdict; // known | name-match | candidate | ignored | blacklisted
  const ScannedDevice(this.address, this.name, this.rssi, this.verdict);
}

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
  final _scanListController = StreamController<List<ScannedDevice>>.broadcast();
  List<ScannedDevice> scanList = [];

  /// Everything the scanner is currently seeing, and what it decided.
  Stream<List<ScannedDevice>> get scanListStream => _scanListController.stream;

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
  final Map<String, int> _failCounts = {};
  static const int maxStrikes = 3;
  int get blacklistSize => _blacklist.length;

  StreamSubscription<List<int>>? _valueSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<ScanResult>>? _scanSub;
  Timer? _keepAliveTimer;
  DateTime? _lastFrameAt;
  bool _autoConnectRunning = false;
  bool _enablingStream = false;
  bool _connectInProgress = false;

  /// MAC of a device already confirmed as the Moov. Persisted, so once the
  /// app has connected even once it can scan for that exact address and skip
  /// the name/fallback guesswork entirely - the way a watch reconnects.
  static const String _prefsKey = 'moov_known_addr';
  String knownMoovAddr = '';
  bool usingKnownAddress = false;

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
    await _loadKnownAddress();
    unawaited(_scanLoop());
  }

  Future<void> _loadKnownAddress() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      knownMoovAddr = prefs.getString(_prefsKey) ?? '';
    } catch (_) {
      knownMoovAddr = '';
    }
  }

  Future<void> _saveKnownAddress(String addr) async {
    if (addr.isEmpty || addr == knownMoovAddr) return;
    knownMoovAddr = addr;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, addr);
    } catch (_) {}
  }

  /// Forgets the remembered device - useful if the Moov is replaced.
  Future<void> forgetKnownDevice() async {
    knownMoovAddr = '';
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsKey);
    } catch (_) {}
  }

  /// Keeps one long scan running while disconnected.
  ///
  /// Android throttles apps to 5 scan *starts* per 30 seconds. The previous
  /// scan / stop / scan cycle every 8 s sat right on that limit, so the OS
  /// delayed the scans and connecting felt slow. A single long scan with a
  /// periodic restart stays well under it.
  /// Common non-Moov electronic device name fragments to exclude from signal sniping.
  static const List<String> _excludedDeviceKeywords = [
    'iphone', 'watch', 'apple', 'versa', 'livsmt', 'washer', 'tv', 'galaxy',
    'pixel', 'airpods', 'buds', 'headset', 'macbook', 'desktop', 'audio', 'soundbar'
  ];

  Future<void> _scanLoop() async {
    while (_autoConnectRunning) {
      if (_connectInProgress || (_device != null && _isConnected)) {
        await Future.delayed(const Duration(milliseconds: 500));
        continue;
      }
      _setState(MoovConnectionState.scanning);
      try {
        scanStarts++;
        usingKnownAddress = knownMoovAddr.isNotEmpty;
        // Always run open scanning so any active Moov button press signal burst
        // is sniped instantly.
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
    _publishScanList(results);

    if (_connectInProgress) return;
    if (_device != null && _isConnected) return;

    for (final r in results) {
      final addr0 = r.device.remoteId.str;
      if (_blacklist.contains(addr0)) continue;

      // Priority 1: An address already confirmed to be the Moov.
      if (knownMoovAddr.isNotEmpty &&
          addr0.toLowerCase() == knownMoovAddr.toLowerCase()) {
        lastMatchKind = 'known';
        nameMatches++;
        _beginConnect(r.device);
        return;
      }

      final name = r.device.platformName.toLowerCase();
      final advName = r.advertisementData.advName.toLowerCase();
      final rawName = advName.isNotEmpty ? advName : name;

      // Exclude common nearby consumer electronics (phones, watches, TVs)
      final isExcluded = _excludedDeviceKeywords.any((ex) => rawName.contains(ex));
      if (isExcluded) continue;

      final nameMatch =
          moovNameHints.any((h) => name.contains(h) || advName.contains(h));
      final svcUuids =
          r.advertisementData.serviceUuids.map((g) => g.str.toLowerCase());
      final uuidMatch =
          svcUuids.any((u) => moovAdvUuids.any((frag) => u.contains(frag)));

      // Priority 2: Explicit Moov name hint or service UUID match.
      if (nameMatch || uuidMatch) {
        lastMatchKind = nameMatch ? 'name' : 'uuid';
        nameMatches++;
        lastCandidateAdvName = r.advertisementData.advName;
        _beginConnect(r.device);
        return;
      }

      // Priority 3: Dynamic Sniper — Strong active signal burst (> -75 dBm) from
      // an unnamed/non-excluded device right when the user presses the button.
      if (r.rssi > -75) {
        lastMatchKind = 'signal-sniper';
        fallbackMatches++;
        _beginConnect(r.device);
        return;
      }
    }
  }

  /// Snapshot of the current scan, for the Diagnostics panel. Lets you see
  /// whether the Moov is being seen at all, and which verdict it got.
  void _publishScanList(List<ScanResult> results) {
    if (_scanListController.isClosed) return;
    final out = <ScannedDevice>[];
    for (final r in results) {
      final addr = r.device.remoteId.str;
      final nm = r.advertisementData.advName.isNotEmpty
          ? r.advertisementData.advName
          : (r.device.platformName.isEmpty ? '(no name)' : r.device.platformName);
      final lname = nm.toLowerCase();

      String verdict;
      if (_blacklist.contains(addr)) {
        verdict = 'blacklisted';
      } else if (knownMoovAddr.isNotEmpty &&
          addr.toLowerCase() == knownMoovAddr.toLowerCase()) {
        verdict = 'known';
      } else if (moovNameHints.any((h) => lname.contains(h)) ||
          r.advertisementData.serviceUuids.any((g) =>
              moovAdvUuids.any((f) => g.str.toLowerCase().contains(f)))) {
        verdict = 'name-match';
      } else if (r.rssi > -75) {
        verdict = 'candidate';
      } else {
        verdict = 'ignored';
      }
      out.add(ScannedDevice(addr, nm, r.rssi, verdict));
    }
    out.sort((a, b) => b.rssi.compareTo(a.rssi));
    scanList = out;
    _scanListController.add(out);
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
        // Success — clear any prior failure count for this address.
        _failCounts.remove(_lastCandidateAddr);
      } catch (e) {
        lastError = e.toString();
        // 3-strike blacklist, matching the Python ble_bridge.py. The Moov
        // often fails once due to timing but succeeds on retry; a 1-strike
        // ban permanently locked out the real device.
        if (_lastCandidateAddr.isNotEmpty) {
          final strikes = (_failCounts[_lastCandidateAddr] ?? 0) + 1;
          _failCounts[_lastCandidateAddr] = strikes;
          if (strikes >= maxStrikes) {
            _blacklist.add(_lastCandidateAddr);
          }
        }
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

    // Proven Moov. Overwrites any previously remembered address, so a bad
    // entry from an earlier version self-corrects on the next good connection.
    await _saveKnownAddress(device.remoteId.str);

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
    // Force-restart scanning. The scanLoop may be awaiting the previous
    // startScan's timeout; stopping it ensures a fresh scan starts immediately
    // so the device can be caught on its next advertisement burst.
    unawaited(() async {
      try { await FlutterBluePlus.stopScan(); } catch (_) {}
    }());
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
    await _scanListController.close();
  }
}
