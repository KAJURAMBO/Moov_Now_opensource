/// Moov Now BLE protocol constants.
///
/// Reverse-engineered from the device and the official app; the verified
/// reference lives in `ble_tools/protocol_notes.md` at the repository root.
library;

/// Sensor ("gyroscope") service — the primary data and control service.
const String moovServiceUuid = 'f000cd50-0451-4000-b000-000000000000';

/// Data characteristic. Subscribe here; the 20-byte sensor frames arrive as
/// notifications.
const String moovDataCharUuid = 'f000cd51-0451-4000-b000-000000000000';

/// Enable characteristic. Writing `0x01` starts the stream.
const String moovEnableCharUuid = 'f000cd52-0451-4000-b000-000000000000';

/// Interval characteristic. Writing this makes the device drop the link.
/// Kept for documentation only — never write to it.
const String moovIntervalCharUuid = 'f000cd53-0451-4000-b000-000000000000';

/// Command characteristic. Same caveat as the interval — never write to it.
const String moovCommandCharUuid = 'f000cd54-0451-4000-b000-000000000000';

/// Payload written to [moovEnableCharUuid] to start (or resume) the stream.
/// Verified idempotent in the app's native code: `turn_on()` writes 1,
/// `turn_off()` writes 0, so re-sending 1 does not stop the stream.
const int moovEnableOn = 0x01;

/// Length of a sensor frame in bytes.
const int moovPacketLength = 20;

/// Accelerometer scale: 16384 LSB per g (±2 g range).
/// Verified against a flat, stationary device — gravity reads 1.0 g.
const double moovAccelLsbPerG = 16384.0;

/// Sequence counter byte offset within a sensor frame.
const int moovSeqOffset = 18;

/// Device firmware sleeps the stream after roughly 10–20 s. If no frame has
/// arrived for this long, re-write [moovEnableOn] to resume.
const Duration moovKeepAliveAfter = Duration(seconds: 3);

/// Advertising names / identifiers used to recognise a Moov while scanning.
/// The device frequently advertises as "Unknown Device" with no service UUIDs,
/// so a strong unnamed signal is also accepted (see the BLE manager).
const List<String> moovNameHints = ['moov'];

/// Advertised service UUID fragments that identify Moov hardware.
const List<String> moovAdvUuids = [
  '9a3f68e0',
  'f000cd50',
  '9fa480e0',
  'd0611e78',
  '2b00',
  '2b01',
];
