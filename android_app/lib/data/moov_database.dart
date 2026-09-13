import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../moov/moov_decoder.dart';

/// Local-only storage. Port of the desktop `backend/models.py`.
///
/// Everything lives in a private SQLite file on the device — no server, no
/// sync, no network. Losing the vendor's servers cannot affect this data.
class MoovDatabase {
  MoovDatabase._();
  static final MoovDatabase instance = MoovDatabase._();

  Database? _db;

  Future<Database> get _database async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'moov_fitness.db'),
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE workouts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            activity_type TEXT NOT NULL,
            start_time INTEGER NOT NULL,
            end_time INTEGER,
            duration_sec INTEGER DEFAULT 0,
            total_steps INTEGER DEFAULT 0,
            avg_cadence_rpm INTEGER DEFAULT 0,
            max_impact_g REAL DEFAULT 0.0,
            calories_burned REAL DEFAULT 0.0,
            distance_km REAL DEFAULT 0.0,
            notes TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE daily_stats (
            date TEXT PRIMARY KEY,
            total_steps INTEGER DEFAULT 0,
            active_minutes INTEGER DEFAULT 0,
            active_seconds REAL DEFAULT 0,
            calories_burned REAL DEFAULT 0.0,
            distance_km REAL DEFAULT 0.0,
            last_updated INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE telemetry_snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp INTEGER NOT NULL,
            workout_id INTEGER,
            accel_x REAL, accel_y REAL, accel_z REAL,
            impact_g REAL,
            activity TEXT
          )
        ''');
      },
    );
    return _db!;
  }

  // ---------------------------------------------------------------------------
  // Workouts
  // ---------------------------------------------------------------------------

  Future<int> createWorkout(String activityType) async {
    final db = await _database;
    return db.insert('workouts', {
      'activity_type': activityType,
      'start_time': DateTime.now().millisecondsSinceEpoch,
      'notes': 'Recorded on device',
    });
  }

  Future<void> finishWorkout({
    required int workoutId,
    required int durationSec,
    required int steps,
    required int avgCadence,
    required double maxImpact,
    required double calories,
    required double distanceKm,
  }) async {
    final db = await _database;
    await db.update(
      'workouts',
      {
        'end_time': DateTime.now().millisecondsSinceEpoch,
        'duration_sec': durationSec,
        'total_steps': steps,
        'avg_cadence_rpm': avgCadence,
        'max_impact_g': maxImpact,
        'calories_burned': calories,
        'distance_km': distanceKm,
      },
      where: 'id = ?',
      whereArgs: [workoutId],
    );
  }

  Future<List<Map<String, Object?>>> getWorkouts({int limit = 30}) async {
    final db = await _database;
    return db.query('workouts', orderBy: 'start_time DESC', limit: limit);
  }

  // ---------------------------------------------------------------------------
  // Daily totals
  // ---------------------------------------------------------------------------

  static String _todayKey() {
    final now = DateTime.now();
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return '${now.year}-$m-$d';
  }

  Future<Map<String, Object?>> getTodayStats() async {
    final db = await _database;
    final rows = await db.query(
      'daily_stats',
      where: 'date = ?',
      whereArgs: [_todayKey()],
      limit: 1,
    );
    if (rows.isEmpty) {
      return {
        'date': _todayKey(),
        'total_steps': 0,
        'active_minutes': 0,
        'active_seconds': 0.0,
        'calories_burned': 0.0,
        'distance_km': 0.0,
      };
    }
    return rows.first;
  }

  /// Adds to today's totals.
  ///
  /// Accumulates at full precision and rounds only for display. Rounding the
  /// running total here would discard each per-step increment (0.04 kcal,
  /// 0.0008 km) before it could ever add up, and the values would sit at zero
  /// forever — a bug that shipped in the desktop version.
  Future<void> addToToday({
    required int steps,
    required double activeSeconds,
    required double calories,
    required double distanceKm,
  }) async {
    final current = await getTodayStats();
    final date = _todayKey();

    final newSteps = (current['total_steps'] as int) + steps;
    final newActiveSec = (current['active_seconds'] as num).toDouble() + activeSeconds;
    final newCalories = (current['calories_burned'] as num).toDouble() + calories;
    final newDistance = (current['distance_km'] as num).toDouble() + distanceKm;

    final db = await _database;
    await db.insert(
      'daily_stats',
      {
        'date': date,
        'total_steps': newSteps,
        'active_minutes': newActiveSec ~/ 60,
        'active_seconds': newActiveSec,
        'calories_burned': newCalories,
        'distance_km': newDistance,
        'last_updated': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ---------------------------------------------------------------------------
  // Telemetry log
  // ---------------------------------------------------------------------------

  Future<void> logSnapshot(SensorFrame frame, {int? workoutId}) async {
    final db = await _database;
    await db.insert('telemetry_snapshots', {
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'workout_id': workoutId,
      'accel_x': frame.ax,
      'accel_y': frame.ay,
      'accel_z': frame.az,
      'impact_g': frame.magnitude,
      'activity': frame.activity,
    });
  }
}
