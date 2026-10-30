import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'alarms.dart';
import 'chart.dart';
import 'device.dart';
import 'home.dart';
import 'main.dart';
import 'strings.dart';

/// Sends a settings change to the incubator (admin) and says if it could not be delivered.
Future<void> sendSettings(BuildContext context, Map<String, dynamic> patch) async {
  final ok = await incubator.setSettings(patch);
  if (!context.mounted) return;
  final msg = !ok
      ? (incubator.isAdmin ? tr('not_reachable') : tr('pin_wrong'))
      : (incubator.link == Link.cloud ? tr('pending') : null);
  if (msg != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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

String modeLabel(String? m, {bool fan = false}) => switch (m) {
      'on' => tr('mode_always'),
      'off' => tr('mode_off'),
      _ => fan ? tr('mode_auto_fan') : tr('mode_auto'),
    };

Future<void> pickMode(BuildContext context, String which) async {
  final current = (incubator.settings[which] as String?) ?? (which == 'fan' ? 'on' : 'auto');
  final picked = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (final m in ['auto', 'on', 'off'])
          ListTile(
            title: Text(modeLabel(m, fan: which == 'fan')),
            trailing: m == current ? const Icon(Icons.check) : null,
            onTap: () => Navigator.pop(context, m),
          ),
      ]),
    ),
  );
  if (picked != null && picked != current && context.mounted) await sendSettings(context, {which: picked});
}

/// Asks for a 4-digit PIN. With [twice], asks again to confirm a new one.
Future<String?> askPin(BuildContext context, String title, {bool twice = false}) async {
  final a = TextEditingController(), b = TextEditingController();
  String? error;
  return showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        InputDecoration deco(String label) => InputDecoration(labelText: label, counterText: '');
        Widget field(TextEditingController c, String label) => TextField(
              controller: c,
              autofocus: c == a,
              obscureText: true,
              maxLength: 4,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              textDirection: TextDirection.ltr,
              decoration: deco(label),
            );
        return AlertDialog(
          title: Text(title),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            field(a, twice ? tr('new_pin') : tr('enter_pin')),
            if (twice) field(b, tr('repeat_pin')),
            if (error != null)
              Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('cancel'))),
            FilledButton(
              onPressed: () {
                if (a.text.length != 4) return;
                if (twice && a.text != b.text) {
                  setState(() => error = tr('pin_mismatch'));
                  return;
                }
                Navigator.pop(context, a.text);
              },
              child: Text(tr('save')),
            ),
          ],
        );
      },
    ),
  );
}

String adminErrorText(AdminError e) => switch (e.code) {
      'wrong' => tr('pin_wrong'),
      'locked' => tr('pin_locked'),
      'none' => tr('pin_none'),
      _ => tr('pin_offline'),
    };

/// Everything that is not needed at a glance, as one plain list.
class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: incubator, builder: _build);

  void _snack(BuildContext context, String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _admin(BuildContext context, Future<void> Function() action) async {
    try {
      await action();
    } on AdminError catch (e) {
      if (context.mounted) _snack(context, adminErrorText(e));
    }
  }

  Widget _build(BuildContext context, Widget? _) {
    final inc = incubator;
    final admin = inc.isAdmin;
    final s = inc.settings;
    final (hMin, hMax) = inc.humidityRange;
    final big = Theme.of(context).textTheme.titleMedium;

    return Scaffold(
      appBar: AppBar(title: Text(tr('more'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _Section(tr('admin')),
          ListTile(
            leading: Icon(admin ? Icons.verified_user_rounded : Icons.visibility_outlined),
            title: Text(admin ? tr('you_are_admin') : tr('viewer')),
            subtitle: Text(tr('admin_hint')),
          ),
          if (!admin && inc.hasAdmin)
            ListTile(
              leading: const Icon(Icons.login),
              title: Text(tr('admin_login')),
              onTap: () async {
                final p = await askPin(context, tr('admin_login'));
                if (p != null && context.mounted) await _admin(context, () => incubator.adminLogin(p));
              },
            ),
          if (!admin && !inc.hasAdmin)
            ListTile(
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: Text(tr('become_admin')),
              onTap: () async {
                final p = await askPin(context, tr('become_admin'), twice: true);
                if (p != null && context.mounted) await _admin(context, () => incubator.setPin(p));
              },
            ),
          if (admin) ...[
            ListTile(
              leading: const Icon(Icons.password),
              title: Text(tr('change_pin')),
              onTap: () async {
                final p = await askPin(context, tr('change_pin'), twice: true);
                if (p != null && context.mounted) {
                  await _admin(context, () async {
                    await incubator.setPin(p);
                    if (context.mounted) _snack(context, tr('save'));
                  });
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.logout),
              title: Text(tr('admin_logout')),
              onTap: incubator.adminLogout,
            ),
          ],
          _Section(tr('sec_targets')),
          ListTile(
            enabled: admin,
            leading: const Icon(Icons.thermostat_outlined),
            title: Text(tr('temp')),
            trailing: Text('${fmt1(inc.tTarget)}°', style: big),
            onTap: () => _editTemp(context),
          ),
          ListTile(
            enabled: admin,
            leading: const Icon(Icons.water_drop_outlined),
            title: Text(tr('humidity_range')),
            subtitle: Text(tr('hum_note')),
            trailing: Text('$hMin–$hMax%', style: big),
            onTap: () => _editHumidity(context),
          ),
          ListTile(
            enabled: admin,
            leading: const Icon(Icons.schedule),
            title: Text(tr('turn_times')),
            subtitle: Text(inc.turnTimes.map((h) => hourLabel(context, h)).join(' · ')),
            onTap: () => _editTurnTimes(context),
          ),
          _Section(tr('sec_controls')),
          ListTile(
            enabled: admin,
            leading: const Icon(Icons.light_mode_outlined),
            title: Text(tr('lamp')),
            subtitle: Text(tr('lamp_auto_hint')),
            trailing: Text(modeLabel(s['lamp'] as String?)),
            onTap: () => pickMode(context, 'lamp'),
          ),
          ListTile(
            enabled: admin,
            leading: const Icon(Icons.air),
            title: Text(tr('fan')),
            trailing: Text(modeLabel(s['fan'] as String?, fan: true)),
            onTap: () => pickMode(context, 'fan'),
          ),
          if (!admin)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(tr('viewer_note'), style: Theme.of(context).textTheme.bodySmall),
            ),
          _Section(tr('alarms')),
          ListTile(
            leading: const Icon(Icons.notifications_active_outlined),
            title: Text(tr('alarms')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AlarmsScreen())),
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
              _snack(context, tr('copied'));
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
    var range = RangeValues(((s['h_min'] as num?) ?? 50).toDouble(), ((s['h_max'] as num?) ?? 55).toDouble());
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

  Future<void> _editTurnTimes(BuildContext context) async {
    final hours = [...incubator.turnTimes];
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(tr('turn_times')),
          content: SizedBox(
            width: 320,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('turn_times_hint')),
              const SizedBox(height: 12),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (var h = 0; h < 24; h++)
                  FilterChip(
                    label: Text(hourLabel(context, h)),
                    selected: hours.contains(h),
                    showCheckmark: false,
                    onSelected: (on) => setState(() {
                      if (on) {
                        hours.add(h);
                      } else {
                        hours.remove(h);
                      }
                    }),
                  ),
              ]),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('save'))),
          ],
        ),
      ),
    );
    if (ok == true) incubator.setTurnTimes(hours);
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
