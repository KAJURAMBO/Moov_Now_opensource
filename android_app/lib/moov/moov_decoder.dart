import 'dart:math' as math;
import 'dart:typed_data';

import 'moov_protocol.dart';

/// One decoded sensor frame.
class SensorFrame {
  final double ax, ay, az;
  final double magnitude; // |accel| in g — also used as impact force
  final double pitch; // degrees, ±90
  final double roll; // degrees, ±90
  final int sequence; // device sequence byte, 0–255 wrapping
  final bool stepDetected;
  final String activity;

  const SensorFrame({
    required this.ax,
    required this.ay,
    required this.az,
    required this.magnitude,
    required this.pitch,
    required this.roll,
    required this.sequence,
    required this.stepDetected,
    required this.activity,
  });
}

/// Decodes 20-byte Moov Now notification payloads.
///
/// Direct port of `ble_tools/decoder.py`. Frame layout (little-endian):
///
/// ```
/// [0:2]   header, 00 00
/// [2:8]   3 x int16 — not yet identified. Swings full-range even when
///         stationary, so it is NOT a clean rate gyro. Unused.
/// [8:12]  zeros
/// [12:18] ACCELEROMETER — 3 x int16 LE, 16384 LSB per g
/// [18]    sequence counter, 0-255 wrapping
/// [19]    zero
/// ```
///
/// Stateful: holds the step-detector arm flag between frames.
class MoovDecoder {
  bool _stepArmed = false;

  /// Step thresholds. A step is counted on the rising edge through
  /// [_stepHigh] and the detector re-arms once the signal falls below
  /// [_stepLow]. This yields one count per bounce at any sample rate —
  /// a plain threshold test fires on every frame while the stream runs at
  /// 50–100 Hz.
  static const double _stepHigh = 1.45;
  static const double _stepLow = 1.15;

  /// Returns null when the payload is too short to be a sensor frame.
  SensorFrame? decode(Uint8List data) {
    if (data.length < moovPacketLength) return null;

    final bd = ByteData.sublistView(data);

    // Accelerometer: bytes [12:18].
    final ax = bd.getInt16(12, Endian.little) / moovAccelLsbPerG;
    final ay = bd.getInt16(14, Endian.little) / moovAccelLsbPerG;
    final az = bd.getInt16(16, Endian.little) / moovAccelLsbPerG;

    final magnitude = math.sqrt(ax * ax + ay * ay + az * az);

    // Tilt from the gravity vector. Both angles are measured from -az, which
    // is the device's flat reference — using az directly flips roll to ±180°
    // whenever the device rests face-up.
    final pitch = math.atan2(-ax, math.sqrt(ay * ay + az * az)) * 180 / math.pi;
    final roll = math.atan2(ay, -az) * 180 / math.pi;

    // Edge-triggered step detection.
    var step = false;
    if (magnitude > _stepHigh && !_stepArmed) {
      _stepArmed = true;
      step = true;
    } else if (magnitude < _stepLow) {
      _stepArmed = false;
    }

    return SensorFrame(
      ax: ax,
      ay: ay,
      az: az,
      magnitude: magnitude,
      pitch: pitch,
      roll: roll,
      sequence: data[moovSeqOffset],
      stepDetected: step,
      activity: _classify(magnitude),
    );
  }

  /// Accelerometer-only classification. At rest the magnitude is ~1 g, so
  /// anything near gravity must read Idle rather than a sport.
  ///
  /// Cycling cannot be detected from the accelerometer alone — it needs the
  /// gyroscope, which is not decoded yet. Users pick it from the workout tabs.
  static String _classify(double magnitude) {
    if (magnitude > 2.60) return 'Boxing';
    if (magnitude > 1.75) return 'Running';
    if (magnitude > 1.15) return 'Walking';
    return 'Idle';
  }

  /// Reset detector state — call when a new connection starts.
  void reset() {
    _stepArmed = false;
  }
}
