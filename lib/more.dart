import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chart.dart';
import 'device.dart';
import 'home.dart';
import 'main.dart';
import 'species.dart';
import 'strings.dart';

/// Sends a settings change and tells the user if it could not be delivered or will apply later.
Future<void> sendSettings(BuildContext context, Map<String, dynamic> patch) async {
  final ok = await incubator.setSettings(patch);
  if (!context.mounted) return;
  final msg = !ok ? tr('not_reachable') : (incubator.link == Link.cloud ? tr('pending') : null);
  if (msg != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

/// Pick the egg type and start counting from today.
Future<void> startBatchDialog(BuildContext context) async {
  var chosen = incubator.species;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(tr('new_batch')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('new_batch_q')),
          const SizedBox(height: 12),
          for (final sp in allSpecies)
            RadioListTile<Species>(
              contentPadding: EdgeInsets.zero,
              value: sp,
              // ignore: deprecated_member_use
              groupValue: chosen,
              // ignore: deprecated_member_use
              onChanged: (v) => setState(() => chosen = v!),
              title: Text(tr(sp.id)),
              subtitle: Text('${trf('days', [sp.days])} · ${sp.temp}° · ${sp.hMin}–${sp.hMax}%'),
            ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('start'))),
        ],
      ),
    ),
  );
  if (ok != true || !context.mounted) return;
  await sendSettings(context, {
    'species': chosen.id,
    'start': Incubator.nowSec(),
    'turned': Incubator.nowSec(),
    't_target': chosen.temp,
    'h_min': chosen.hMin,
    'h_max': chosen.hMax,
  });
}

Future<bool> confirm(BuildContext context, String title, String body) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('save'))),
        ],
      ),
    ) ==
    true;

String _modeLabel(String? m, {bool fan = false}) => switch (m) {
      'on' => tr('mode_always'),
      'off' => tr('mode_off'),
      _ => fan ? tr('mode_auto_fan') : tr('mode_auto'),
    };

/// Everything that is not needed at a glance, as one plain list.
class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: incubator, builder: _build);

  Widget _build(BuildContext context, Widget? _) {
    final inc = incubator;
    final s = inc.settings;
    final started = inc.startedAt;
    final (hMin, hMax) = inc.humidityRange;
    final loc = MaterialLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(tr('more'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _Section(tr('sec_batch')),
          ListTile(
            leading: const Icon(Icons.egg_outlined),
            title: Text(tr('egg_type')),
            subtitle: Text(started == null ? tr('no_batch') : tr(inc.species.id)),
          ),
          if (started != null)
            ListTile(
              leading: const Icon(Icons.event_outlined),
              title: Text(tr('started')),
              subtitle: Text('${loc.formatMediumDate(started)} · ${trf('day_of', [inc.day!, inc.species.days])}'),
            ),
          ListTile(
            leading: const Icon(Icons.add_circle_outline),
            title: Text(tr('new_batch')),
            onTap: () => startBatchDialog(context),
          ),
          if (started != null)
            ListTile(
              leading: const Icon(Icons.stop_circle_outlined),
              title: Text(tr('end_batch')),
              onTap: () async {
                if (await confirm(context, tr('end_batch'), tr('end_batch_q')) && context.mounted) {
                  await sendSettings(context, {'start': 0});
                }
              },
            ),
          _Section(tr('sec_targets')),
          ListTile(
            leading: const Icon(Icons.thermostat_outlined),
            title: Text(tr('temp')),
            trailing: Text('${fmt1(inc.tTarget)}°', style: Theme.of(context).textTheme.titleMedium),
            onTap: () => _editTemp(context),
          ),
          ListTile(
            leading: const Icon(Icons.water_drop_outlined),
            title: Text(tr('humidity_range')),
            subtitle: Text(tr('hum_note')),
            trailing: Text('$hMin–$hMax%', style: Theme.of(context).textTheme.titleMedium),
            onTap: () => _editHumidity(context),
          ),
          _Section(tr('sec_controls')),
          ListTile(
            leading: const Icon(Icons.light_mode_outlined),
            title: Text(tr('lamp')),
            subtitle: Text(tr('lamp_auto_hint')),
            trailing: Text(_modeLabel(s['lamp'] as String?)),
            onTap: () => _pickMode(context, 'lamp'),
          ),
          ListTile(
            leading: const Icon(Icons.air),
            title: Text(tr('fan')),
            trailing: Text(_modeLabel(s['fan'] as String?, fan: true)),
            onTap: () => _pickMode(context, 'fan'),
          ),
          _Section(tr('sec_history')),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: inc.history.length < 2
                ? Text(tr('no_history'))
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('temp'), style: Theme.of(context).textTheme.labelLarge),
                    LineChart(
                      points: [for (final r in inc.history) (r.at, r.t)],
                      color: const Color(0xFFE8833A),
                      target: inc.tTarget,
                      unit: '°',
                    ),
                    const SizedBox(height: 16),
                    Text(tr('hum'), style: Theme.of(context).textTheme.labelLarge),
                    LineChart(
                      points: [for (final r in inc.history) (r.at, r.h)],
                      color: const Color(0xFF3B82C4),
                      unit: '%',
                    ),
                  ]),
          ),
          _Section(tr('sec_connection')),
          ListTile(
            leading: const Icon(Icons.wifi),
            title: Text(tr('status')),
            subtitle: Text([
              switch (inc.link) {
                Link.local => tr('link_local'),
                Link.cloud => tr('link_cloud'),
                Link.offline => tr('link_offline'),
              },
              if (inc.seenAt != null) trf('st_last_seen', [ago(inc.seenAt!)]),
            ].join(' · ')),
          ),
          ListTile(
            leading: const Icon(Icons.router_outlined),
            title: Text(tr('address')),
            subtitle: Text(inc.addr.isEmpty ? '—' : inc.addr),
          ),
          ListTile(
            leading: const Icon(Icons.key_outlined),
            title: Text(tr('device_key')),
            subtitle: Text('${inc.key}\n${tr('device_key_hint')}'),
            isThreeLine: true,
            trailing: const Icon(Icons.copy_rounded),
            onTap: () {
              Clipboard.setData(ClipboardData(text: inc.key));
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('copied'))));
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: Text(tr('forget')),
            onTap: () async {
              if (await confirm(context, tr('forget'), tr('forget_q')) && context.mounted) {
                Navigator.popUntil(context, (r) => r.isFirst);
                incubator.forget();
              }
            },
          ),
          _Section(tr('sec_app')),
          ListTile(
            leading: const Icon(Icons.language),
            title: Text(tr('language')),
            trailing: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'ar', label: Text('العربية')),
                ButtonSegment(value: 'en', label: Text('English')),
              ],
              selected: {lang.value},
              showSelectedIcon: false,
              onSelectionChanged: (v) => lang.value = v.first,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _editTemp(BuildContext context) async {
    var v = incubator.tTarget;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(tr('temp')),
          content: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton.filledTonal(
                onPressed: () => setState(() => v = (v - 0.1).clamp(30.0, 39.0)), icon: const Icon(Icons.remove)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text('${fmt1(v)}°', style: Theme.of(context).textTheme.headlineMedium),
            ),
            IconButton.filledTonal(
                onPressed: () => setState(() => v = (v + 0.1).clamp(30.0, 39.0)), icon: const Icon(Icons.add)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('save'))),
          ],
        ),
      ),
    );
    if (ok == true && context.mounted) await sendSettings(context, {'t_target': double.parse(fmt1(v))});
  }

  Future<void> _editHumidity(BuildContext context) async {
    final s = incubator.settings;
    var range = RangeValues(
      ((s['h_min'] as num?) ?? incubator.species.hMin).toDouble(),
      ((s['h_max'] as num?) ?? incubator.species.hMax).toDouble(),
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(tr('humidity_range')),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('${range.start.round()}–${range.end.round()}%', style: Theme.of(context).textTheme.headlineMedium),
            RangeSlider(
              values: range,
              min: 30,
              max: 85,
              divisions: 55,
              onChanged: (r) => setState(() => range = r),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('save'))),
          ],
        ),
      ),
    );
    if (ok == true && context.mounted) {
      await sendSettings(context, {'h_min': range.start.round(), 'h_max': range.end.round()});
    }
  }

  Future<void> _pickMode(BuildContext context, String which) async {
    final current = (incubator.settings[which] as String?) ?? (which == 'fan' ? 'on' : 'auto');
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final m in ['auto', 'on', 'off'])
            ListTile(
              title: Text(_modeLabel(m, fan: which == 'fan')),
              trailing: m == current ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(context, m),
            ),
        ]),
      ),
    );
    if (picked != null && picked != current && context.mounted) await sendSettings(context, {which: picked});
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}
