import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'moov/moov_ble_manager.dart';
import 'moov/moov_foreground.dart';
import 'moov_controller.dart';

void main() => runApp(const MoovApp());

class MoovApp extends StatefulWidget {
  const MoovApp({super.key});
  @override
  State<MoovApp> createState() => _MoovAppState();
}

class _MoovAppState extends State<MoovApp> {
  late final MoovController controller;

  @override
  void initState() {
    super.initState();
    controller = MoovController();
    controller.init();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Moov Now',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00B8D4),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: HomeShell(controller: controller),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.controller});
  final MoovController controller;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    // Only the visible page is constructed. Building all four on every
    // rebuild made each notify far more expensive than it needed to be.
    Widget currentPage() {
      switch (_index) {
        case 0:
          return DashboardScreen(controller: widget.controller);
        case 1:
          return LiveScreen(controller: widget.controller);
        case 2:
          return WorkoutScreen(controller: widget.controller);
        default:
          return HistoryScreen(key: const ValueKey('history'), controller: widget.controller);
      }
    }

    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('Moov Now'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(child: _StatusChip(state: widget.controller.connectionState)),
            ),
          ],
        ),
        body: currentPage(),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.dashboard_outlined), label: 'Today'),
            NavigationDestination(icon: Icon(Icons.sensors), label: 'Live'),
            NavigationDestination(icon: Icon(Icons.play_circle_outline), label: 'Workout'),
            NavigationDestination(icon: Icon(Icons.history), label: 'History'),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.state});
  final MoovConnectionState state;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (state) {
      MoovConnectionState.connected => ('Connected', Colors.greenAccent),
      MoovConnectionState.connecting => ('Connecting…', Colors.amberAccent),
      MoovConnectionState.scanning => ('Scanning…', Colors.amberAccent),
      MoovConnectionState.waitingForDevice => ('Press Moov', Colors.orangeAccent),
      MoovConnectionState.idle => ('Idle', Colors.grey),
    };
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.circle, size: 10, color: color),
      const SizedBox(width: 6),
      Text(label, style: const TextStyle(fontSize: 12)),
    ]);
  }
}

// -----------------------------------------------------------------------------
// Dashboard
// -----------------------------------------------------------------------------

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key, required this.controller});
  final MoovController controller;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(children: [
          Expanded(child: _StatCard(
            label: 'STEPS',
            value: NumberFormat.decimalPattern().format(controller.todaySteps),
            goal: 'Goal 10,000',
            progress: (controller.todaySteps / 10000).clamp(0.0, 1.0),
          )),
          const SizedBox(width: 12),
          Expanded(child: _StatCard(
            label: 'ACTIVE MIN',
            value: '${controller.todayActiveMinutes}',
            goal: 'Goal 60 min',
            progress: (controller.todayActiveMinutes / 60).clamp(0.0, 1.0),
          )),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: _StatCard(
            label: 'CALORIES',
            value: controller.todayCalories.toStringAsFixed(1),
            goal: 'kcal',
            progress: (controller.todayCalories / 500).clamp(0.0, 1.0),
          )),
          const SizedBox(width: 12),
          Expanded(child: _StatCard(
            label: 'DISTANCE',
            value: controller.todayDistanceKm.toStringAsFixed(2),
            goal: 'km',
            progress: (controller.todayDistanceKm / 8).clamp(0.0, 1.0),
          )),
        ]),
        const SizedBox(height: 24),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Device', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(controller.deviceName),
              const SizedBox(height: 4),
              Text(
                'Press the Moov button when the app says "Press Moov". '
                'The device only advertises for a few seconds after a press.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ]),
          ),
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    required this.goal,
    required this.progress,
  });
  final String label, value, goal;
  final double progress;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 6),
          Text(value, style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: progress, minHeight: 5),
          const SizedBox(height: 4),
          Text(goal, style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Live
// -----------------------------------------------------------------------------

class LiveScreen extends StatelessWidget {
  const LiveScreen({super.key, required this.controller});
  final MoovController controller;

  @override
  Widget build(BuildContext context) {
    final f = controller.frame;
    final ble = controller.ble;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (f == null)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Text('Waiting for sensor data...'),
            ),
          )
        else ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(children: [
                Text(f.activity, style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 12),
                Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                  _Metric(label: 'PITCH', value: '${f.pitch.toStringAsFixed(1)} deg'),
                  _Metric(label: 'ROLL', value: '${f.roll.toStringAsFixed(1)} deg'),
                  _Metric(label: 'IMPACT', value: '${f.magnitude.toStringAsFixed(2)}g'),
                ]),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Accelerometer (g)', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                _AxisBar(label: 'X', value: f.ax),
                _AxisBar(label: 'Y', value: f.ay),
                _AxisBar(label: 'Z', value: f.az),
              ]),
            ),
          ),
        ],

        // Field diagnostics. If the app says "Connected" but shows no data, this
        // says which step of the handshake failed.
        const SizedBox(height: 12),
        Card(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Diagnostics', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              _DiagRow('state', ble.currentState.name),
              _DiagRow('device', controller.deviceName),
              _DiagRow('services found', '${ble.servicesFound}'),
              _DiagRow('sensor service', ble.serviceUuids.contains(
                      'f000cd50-0451-4000-b000-000000000000') ? 'present' : 'MISSING'),
              _DiagRow('data char (cd51)', ble.dataCharFound ? 'found' : 'not found'),
              _DiagRow('notify subscribed', ble.notifySubscribed ? 'yes' : 'no'),
              _DiagRow('enable char (cd52)', ble.enableCharFound ? 'found' : 'not found'),
              _DiagRow('enable write', ble.enableWriteResult),
              _DiagRow('write attempts', '${ble.writeAttempts}'),
              _DiagRow('packets received', '${ble.packetsReceived}'),
              _DiagRow('last packet', ble.lastPacketHex.isEmpty ? '-' : ble.lastPacketHex),
              _DiagRow('remembered MAC', ble.knownMoovAddr.isEmpty ? '(none yet)' : ble.knownMoovAddr),
              _DiagRow('scan mode', ble.usingKnownAddress
                  ? 'broad (remembered MAC prioritised)'
                  : 'broad (nothing remembered yet)'),
              _DiagRow('matched by', ble.lastMatchKind.isEmpty ? '-' : ble.lastMatchKind),
              _DiagRow('name / fallback', '${ble.nameMatches} / ${ble.fallbackMatches}'),
              _DiagRow('adv name', ble.lastCandidateAdvName.isEmpty ? '(empty)' : ble.lastCandidateAdvName),
              _DiagRow('candidate', ble.lastCandidate.isEmpty ? '-' : ble.lastCandidate),
              _DiagRow('blacklisted', '${ble.blacklistSize}'),
              _DiagRow('scan starts', '${ble.scanStarts}'),
              _DiagRow('bg service', MoovForeground.running ? 'running' : 'NOT running'),
              _DiagRow('battery exempt', MoovForeground.batteryExempt ? 'yes' : 'no'),
              _DiagRow('service error', MoovForeground.lastError.isEmpty ? '-' : MoovForeground.lastError),
              _DiagRow('last error', ble.lastError.isEmpty ? '-' : ble.lastError),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => controller.forgetDevice(),
                child: const Text('Forget remembered device'),
              ),
              const SizedBox(height: 8),
              Text('services: ${ble.serviceUuids.join(", ")}',
                  style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
        ),
      ],
    );
  }
}

class _DiagRow extends StatelessWidget {
  const _DiagRow(this.label, this.value);
  final String label, value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 130,
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        Expanded(
          child: Text(value,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ),
      ]),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => Column(children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: 4),
        Text(value, style: Theme.of(context).textTheme.titleLarge),
      ]);
}

/// Horizontal bar showing one accelerometer axis on a ±4 g scale.
class _AxisBar extends StatelessWidget {
  const _AxisBar({required this.label, required this.value});
  final String label;
  final double value;

  @override
  Widget build(BuildContext context) {
    const range = 4.0;
    final norm = (value / range).clamp(-1.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(width: 18, child: Text(label)),
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) {
              final half = c.maxWidth / 2;
              return Stack(children: [
                Container(height: 10, color: Colors.white12),
                Positioned(
                  left: norm >= 0 ? half : half + norm * half,
                  child: Container(
                    height: 10,
                    width: (norm.abs() * half).clamp(1.0, half),
                    color: Colors.cyanAccent,
                  ),
                ),
                Positioned(left: half, child: Container(width: 1, height: 10, color: Colors.white38)),
              ]);
            },
          ),
        ),
        SizedBox(width: 52, child: Text(value.toStringAsFixed(2), textAlign: TextAlign.right)),
      ]),
    );
  }
}

// -----------------------------------------------------------------------------
// Workout
// -----------------------------------------------------------------------------

class WorkoutScreen extends StatelessWidget {
  const WorkoutScreen({super.key, required this.controller});
  final MoovController controller;

  static const activities = ['Run', 'Cycle', 'Swim', 'Box', 'Walk'];

  @override
  Widget build(BuildContext context) {
    final active = controller.sessionActive;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 8,
          children: activities
              .map((a) => ChoiceChip(
                    label: Text(a),
                    selected: controller.activeActivity == a,
                    onSelected: active
                        ? null
                        : (_) => controller.activeActivity = a,
                  ))
              .toList(),
        ),
        const SizedBox(height: 24),
        Center(
          child: Text(
            _fmt(controller.sessionDurationSec),
            style: Theme.of(context).textTheme.displayMedium,
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(active ? 'Recording ${controller.activeActivity}…' : 'No active session'),
        ),
        const SizedBox(height: 24),
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          _Metric(label: 'STEPS', value: '${controller.sessionSteps}'),
          _Metric(label: 'CADENCE', value: '${controller.sessionCadence} RPM'),
          _Metric(
            label: 'MAX IMPACT',
            value: '${controller.sessionMaxImpact.toStringAsFixed(1)}g',
          ),
        ]),
        const SizedBox(height: 32),
        FilledButton.icon(
          onPressed: () async {
            if (active) {
              await controller.stopWorkout();
            } else {
              await controller.startWorkout(controller.activeActivity);
            }
          },
          icon: Icon(active ? Icons.stop : Icons.play_arrow),
          label: Text(active ? 'Stop Workout Session' : 'Start Workout Session'),
        ),
      ],
    );
  }

  static String _fmt(int sec) {
    final h = (sec ~/ 3600).toString().padLeft(2, '0');
    final m = ((sec % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (sec % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}

// -----------------------------------------------------------------------------
// History
// -----------------------------------------------------------------------------

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.controller});
  final MoovController controller;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<Map<String, Object?>> rows = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await widget.controller.workouts();
    if (mounted) setState(() => rows = r);
  }

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return const Center(child: Text('No workouts yet'));
    }
    final fmt = DateFormat('MMM d, h:mm a');
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: rows.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final w = rows[i];
          final start = DateTime.fromMillisecondsSinceEpoch(
            (w['start_time'] as num).toInt(),
          );
          final dur = (w['duration_sec'] as num).toInt();
          return ListTile(
            title: Text('${w['activity_type']}  ·  ${fmt.format(start)}'),
            subtitle: Text(
              '${dur ~/ 60}m ${dur % 60}s   ·   ${w['total_steps']} steps   ·   '
              '${(w['calories_burned'] as num).toStringAsFixed(1)} kcal',
            ),
            trailing: Text('${(w['distance_km'] as num).toStringAsFixed(2)} km'),
          );
        },
      ),
    );
  }
}
