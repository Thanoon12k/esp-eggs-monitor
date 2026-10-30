import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'home.dart';
import 'models.dart';
import 'monitor.dart';
import 'strings.dart';

/// This phone's alarm settings. Everyone (admin or viewer) sets their own.
class AlarmsScreen extends StatefulWidget {
  const AlarmsScreen({super.key});

  @override
  State<AlarmsScreen> createState() => _AlarmsScreenState();
}

class _AlarmsScreenState extends State<AlarmsScreen> {
  AlarmPrefs? _a;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) => setState(() => _a = loadAlarmPrefs(p)));
  }

  Future<void> _set(void Function(AlarmPrefs a) change) async {
    final a = _a!;
    setState(() => change(a));
    await saveAlarmPrefs(a);
    await syncMonitorService(askPermissions: a.enabled);
  }

  @override
  Widget build(BuildContext context) {
    final a = _a;
    if (a == null) return Scaffold(appBar: AppBar(title: Text(tr('alarms'))));
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr('alarms'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.notifications_active_outlined),
            title: Text(tr('alarm_enabled')),
            subtitle: Text(tr('alarm_enabled_hint')),
            value: a.enabled,
            onChanged: (v) => _set((a) => a.enabled = v),
          ),
          if (a.enabled) ...[
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(tr('alarm_temp_range'), style: theme.textTheme.titleSmall),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Column(children: [
                Text('${fmt1(a.tLow)}° – ${fmt1(a.tHigh)}°', style: theme.textTheme.headlineSmall),
                RangeSlider(
                  values: RangeValues(a.tLow, a.tHigh),
                  min: 20,
                  max: 42,
                  divisions: 220,
                  onChanged: (r) => setState(() {
                    a.tLow = double.parse(fmt1(r.start));
                    a.tHigh = double.parse(fmt1(r.end));
                  }),
                  onChangeEnd: (_) => _set((_) {}),
                ),
              ]),
            ),
            _Stepper(
              label: trf('alarm_minutes', [a.minutes]),
              onMinus: a.minutes > 1 ? () => _set((a) => a.minutes--) : null,
              onPlus: a.minutes < 60 ? () => _set((a) => a.minutes++) : null,
            ),
            const Divider(),
            SwitchListTile(
              secondary: const Icon(Icons.wifi_off_rounded),
              title: Text(tr('alarm_offline')),
              subtitle: Text(trf('alarm_offline_min', [a.offlineMinutes])),
              value: a.offline,
              onChanged: (v) => _set((a) => a.offline = v),
            ),
            if (a.offline)
              _Stepper(
                label: trf('alarm_offline_min', [a.offlineMinutes]),
                onMinus: a.offlineMinutes > 2 ? () => _set((a) => a.offlineMinutes--) : null,
                onPlus: a.offlineMinutes < 120 ? () => _set((a) => a.offlineMinutes++) : null,
              ),
            SwitchListTile(
              secondary: const Icon(Icons.sensors_off_rounded),
              title: Text(tr('alarm_sensor')),
              value: a.sensor,
              onChanged: (v) => _set((a) => a.sensor = v),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.water_drop_outlined),
              title: Text(tr('alarm_humidity')),
              value: a.humidity,
              onChanged: (v) => _set((a) => a.humidity = v),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.sync_rounded),
              title: Text(tr('alarm_turning')),
              value: a.turning,
              onChanged: (v) => _set((a) => a.turning = v),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.egg_outlined),
              title: Text(tr('alarm_milestones')),
              value: a.milestones,
              onChanged: (v) => _set((a) => a.milestones = v),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: OutlinedButton.icon(
                onPressed: testAlarm,
                icon: const Icon(Icons.volume_up_rounded),
                label: Text(tr('alarm_test')),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.label, this.onMinus, this.onPlus});
  final String label;
  final VoidCallback? onMinus, onPlus;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          Expanded(child: Text(label)),
          IconButton.filledTonal(onPressed: onMinus, icon: const Icon(Icons.remove)),
          const SizedBox(width: 8),
          IconButton.filledTonal(onPressed: onPlus, icon: const Icon(Icons.add)),
        ]),
      );
}
