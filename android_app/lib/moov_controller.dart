import 'dart:async';

import 'package:flutter/foundation.dart';

import 'data/moov_database.dart';
import 'moov/moov_ble_manager.dart';
import 'moov/moov_foreground.dart';
import 'moov/moov_decoder.dart';

/// Application state: owns the BLE link, the database, and the live session.
///
/// The UI reads only from here — it never touches BLE or SQLite directly.
class MoovController extends ChangeNotifier {
  MoovController({MoovBleManager? ble}) : _ble = ble ?? MoovBleManager();

  final MoovBleManager _ble;

  /// Exposed for the diagnostics panel only.
  MoovBleManager get ble => _ble;
  final MoovDatabase _db = MoovDatabase.instance;

  StreamSubscription<SensorFrame>? _frameSub;
  StreamSubscription<MoovConnectionState>? _stateSub;
  Timer? _flushTimer;

  // Live values
  SensorFrame? frame;
  MoovConnectionState connectionState = MoovConnectionState.idle;
  String deviceName = '—';

  // Today
  int todaySteps = 0;
  double todayCalories = 0;
  double todayDistanceKm = 0;
  int todayActiveMinutes = 0;

  // Current workout session
  int? activeWorkoutId;
  bool sessionActive = false;
  String activeActivity = 'Running';
  DateTime? sessionStart;
  int sessionSteps = 0;
  double sessionMaxImpact = 0;
  int sessionCadence = 0;

  // Pending totals, flushed to SQLite once a second rather than per frame —
  // the stream runs at 50–100 Hz and a write per frame would thrash the DB.
  int _pendingSteps = 0;
  double _pendingCalories = 0;
  double _pendingDistance = 0;
  double _pendingActiveSeconds = 0;
  DateTime? _lastFrameAt;
  DateTime? _lastSnapshotAt;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  /// Rebuild at most ~16x/sec. The sensor stream runs at 50-100 Hz and
  /// notifying on every frame rebuilds the whole widget tree that often,
  /// which starves the main thread and makes buttons feel unresponsive.
  void _notifyThrottled() {
    final now = DateTime.now();
    if (now.difference(_lastNotify).inMilliseconds >= 60) {
      _lastNotify = now;
      notifyListeners();
    }
  }

  Future<void> init() async {
    await _ble.ensurePermissions();

    _frameSub = _ble.frames.listen(_onFrame);
    _stateSub = _ble.state.listen((s) {
      connectionState = s;
      if (s == MoovConnectionState.connected) deviceName = _ble.deviceName;
      MoovForeground.start(
        text: s == MoovConnectionState.connected
            ? 'Tracking ${_ble.deviceName}'
            : 'Looking for your Moov…',
      );
      notifyListeners();
    });

    // Start listening before the notification and battery-optimisation
    // prompts. Those are modal system dialogs, and waiting on them meant the
    // app was not scanning yet when the user pressed the Moov button - the
    // advertisement lasts only a few seconds and was simply missed.
    await _ble.startAutoConnect();

    await MoovForeground.requestPermission();
    await MoovForeground.start(text: 'Looking for your Moov…');
    unawaited(MoovForeground.requestBatteryExemption());

    await refreshToday();
    _flushTimer = Timer.periodic(const Duration(seconds: 1), (_) => _flush());
    notifyListeners();
  }

  void _onFrame(SensorFrame f) {
    final now = DateTime.now();

    // Credit active time only for gaps that look continuous — a reconnect
    // after a long silence should not add phantom minutes.
    if (_lastFrameAt != null) {
      final dt = now.difference(_lastFrameAt!).inMilliseconds / 1000.0;
      if (dt > 0 && dt < 2.0) _pendingActiveSeconds += dt;
    }
    _lastFrameAt = now;

    frame = f;

    if (f.stepDetected) {
      _pendingSteps += 1;
      _pendingCalories += 0.04; // kcal per step
      _pendingDistance += 0.0008; // km per step
      sessionSteps += 1;
    }

    if (f.magnitude > sessionMaxImpact) sessionMaxImpact = f.magnitude;
    sessionCadence = sessionCadence == 0
        ? (f.activity == 'Idle' ? 0 : 60)
        : sessionCadence;

    // One telemetry snapshot per second while running.
    if (_lastSnapshotAt == null ||
        now.difference(_lastSnapshotAt!).inSeconds >= 1) {
      _lastSnapshotAt = now;
      unawaited(_db.logSnapshot(f, workoutId: activeWorkoutId));
    }

    _notifyThrottled();
  }

  Future<void> _flush() async {
    if (_pendingSteps == 0 && _pendingActiveSeconds == 0) return;
    final steps = _pendingSteps;
    final cals = _pendingCalories;
    final dist = _pendingDistance;
    final activeSec = _pendingActiveSeconds;
    _pendingSteps = 0;
    _pendingCalories = 0;
    _pendingDistance = 0;
    _pendingActiveSeconds = 0;

    await _db.addToToday(
      steps: steps,
      activeSeconds: activeSec,
      calories: cals,
      distanceKm: dist,
    );
    await refreshToday();
  }

  Future<void> refreshToday() async {
    final s = await _db.getTodayStats();
    todaySteps = (s['total_steps'] as num).toInt();
    todayCalories = (s['calories_burned'] as num).toDouble();
    todayDistanceKm = (s['distance_km'] as num).toDouble();
    todayActiveMinutes = (s['active_minutes'] as num).toInt();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Workout session
  // ---------------------------------------------------------------------------

  Future<void> startWorkout(String activity) async {
    activeActivity = activity;
    sessionSteps = 0;
    sessionMaxImpact = 0;
    sessionCadence = 0;
    sessionStart = DateTime.now();
    sessionActive = true;
    notifyListeners(); // instant feedback; persistence follows
    activeWorkoutId = await _db.createWorkout(activity);
  }

  Future<void> stopWorkout() async {
    final id = activeWorkoutId;
    final start = sessionStart;
    if (!sessionActive || start == null) return;

    final duration = DateTime.now().difference(start).inSeconds;
    final steps = sessionSteps;
    final cadence = sessionCadence;
    final impact = sessionMaxImpact;

    // Clear the UI first, persist after.
    sessionActive = false;
    sessionStart = null;
    activeWorkoutId = null;
    notifyListeners();

    if (id == null) return;
    await _db.finishWorkout(
      workoutId: id,
      durationSec: duration,
      steps: steps,
      avgCadence: cadence,
      maxImpact: impact,
      calories: steps * 0.045,
      distanceKm: steps * 0.0008,
    );
  }

  int get sessionDurationSec =>
      sessionStart == null ? 0 : DateTime.now().difference(sessionStart!).inSeconds;

  Future<List<Map<String, Object?>>> workouts() => _db.getWorkouts();

  /// Clears the remembered Moov address. Recovers from a bad entry without
  /// reinstalling the app.
  Future<void> forgetDevice() async {
    await _ble.forgetKnownDevice();
    notifyListeners();
  }

  @override
  void dispose() {
    MoovForeground.stop();
    _flushTimer?.cancel();
    _frameSub?.cancel();
    _stateSub?.cancel();
    _ble.dispose();
    super.dispose();
  }
}
