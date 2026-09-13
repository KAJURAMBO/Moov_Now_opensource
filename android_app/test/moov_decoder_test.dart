import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:moovnow/moov/moov_decoder.dart';

/// Builds a 20-byte sensor frame with the given accelerometer counts.
/// Accelerometer occupies bytes [12:18]; everything else mirrors a real frame.
Uint8List frameWithAccel(int ax, int ay, int az, {int seq = 0}) {
  final b = ByteData(20);
  b.setInt16(12, ax, Endian.little);
  b.setInt16(14, ay, Endian.little);
  b.setInt16(16, az, Endian.little);
  b.setUint8(18, seq);
  return b.buffer.asUint8List();
}

void main() {
  group('MoovDecoder', () {
    test('decodes gravity as ~1 g with a flat device', () {
      // Device resting flat reports -1 g on Z — the reference captured from
      // real hardware.
      final f = MoovDecoder().decode(frameWithAccel(0, 0, -16384))!;
      expect(f.magnitude, closeTo(1.0, 0.01));
      expect(f.ax, closeTo(0.0, 0.001));
      expect(f.az, closeTo(-1.0, 0.001));
    });

    test('pitch and roll are zero when flat, and stay within ±90', () {
      final d = MoovDecoder();
      final flat = d.decode(frameWithAccel(0, 0, -16384))!;
      expect(flat.pitch, closeTo(0.0, 0.5));
      expect(flat.roll, closeTo(0.0, 0.5));

      // Tilted onto its side: roll must not flip to ±180 (the bug this
      // reference-frame choice avoids).
      final tilted = d.decode(frameWithAccel(0, 8192, -14189))!;
      expect(tilted.roll.abs(), lessThan(90));
      expect(tilted.roll, closeTo(30.0, 1.0));
    });

    test('classifies a resting device as Idle, not a sport', () {
      final f = MoovDecoder().decode(frameWithAccel(0, 0, -16384))!;
      expect(f.activity, 'Idle');
    });

    test('classifies increasing magnitudes as walking then running', () {
      final d = MoovDecoder();
      // ~1.5 g
      expect(d.decode(frameWithAccel(0, 0, -24576))!.activity, 'Walking');
      // ~2.0 g
      expect(d.decode(frameWithAccel(0, 0, -32768))!.activity, 'Running');
    });

    test('counts one step per bounce, not one per frame', () {
      final d = MoovDecoder();

      // Sustained high magnitude: the detector must fire once on the rising
      // edge and not again while the signal stays high.
      var steps = 0;
      for (var i = 0; i < 50; i++) {
        if (d.decode(frameWithAccel(0, 0, -32768))!.stepDetected) steps++;
      }
      expect(steps, 1, reason: 'sustained high magnitude is one step, not 50');

      // Fall back below the re-arm threshold, then rise again -> a second step.
      for (var i = 0; i < 10; i++) {
        expect(d.decode(frameWithAccel(0, 0, -16384))!.stepDetected, isFalse);
      }
      expect(d.decode(frameWithAccel(0, 0, -32768))!.stepDetected, isTrue);
    });

    test('reads the sequence counter from byte 18', () {
      final f = MoovDecoder().decode(frameWithAccel(0, 0, -16384, seq: 200))!;
      expect(f.sequence, 200);
    });

    test('returns null for short payloads', () {
      expect(MoovDecoder().decode(Uint8List(10)), isNull);
    });
  });
}
