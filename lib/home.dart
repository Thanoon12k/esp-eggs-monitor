import 'package:flutter/material.dart';

import 'device.dart';
import 'main.dart';
import 'more.dart';
import 'strings.dart';

String ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return tr('ago_now');
  if (d.inHours < 1) return trf('ago_min', [d.inMinutes]);
  if (d.inDays < 1) return trf('ago_hour', [d.inHours]);
  return trf('ago_day', [d.inDays]);
}

String fmt1(double v) => v.toStringAsFixed(1);

enum Level { good, warn, bad, off }

Color levelColor(BuildContext context, Level l) => switch (l) {
      Level.good => const Color(0xFF2E9E5B),
      Level.warn => const Color(0xFFE09A1A),
      Level.bad => const Color(0xFFD64535),
      Level.off => Theme.of(context).colorScheme.outline,
    };

/// The one screen that matters: is the incubator OK, how warm, how humid, which day.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: incubator, builder: _build);

  Widget _build(BuildContext context, Widget? _) {
    final inc = incubator;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('app')),
        actions: [
          _LinkChip(inc.link),
          IconButton(
            tooltip: tr('more'),
            icon: const Icon(Icons.menu_rounded),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MoreScreen())),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: inc.refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            _StatusBanner(inc),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _TempCard(inc)),
                const SizedBox(width: 12),
                Expanded(child: _HumCard(inc)),
              ],
            ),
            const SizedBox(height: 12),
            _DayCard(inc),
            if (_turnDue(inc)) ...[const SizedBox(height: 12), _TurnCard(inc)],
            const SizedBox(height: 20),
            _OutputsRow(inc),
          ],
        ),
      ),
    );
  }
}

bool _turnDue(Incubator inc) {
  final day = inc.day;
  if (day == null || inc.inLockdown) return false;
  final last = inc.turnedAt;
  return last == null || DateTime.now().difference(last) > const Duration(hours: 8);
}

class _LinkChip extends StatelessWidget {
  const _LinkChip(this.link);
  final Link link;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (link) {
      Link.local => (tr('link_local'), levelColor(context, Level.good)),
      Link.cloud => (tr('link_cloud'), const Color(0xFF3B82C4)),
      Link.offline => (tr('link_offline'), levelColor(context, Level.off)),
    };
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 6),
      Text(label, style: Theme.of(context).textTheme.labelMedium),
      const SizedBox(width: 4),
    ]);
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner(this.inc);
  final Incubator inc;

  (Level, IconData, String, String?) _status() {
    if (!inc.hasData || inc.stale) {
      return (
        Level.off,
        Icons.wifi_off_rounded,
        tr('st_offline'),
        inc.seenAt != null ? trf('st_last_seen', [ago(inc.seenAt!)]) : null
      );
    }
    if (!inc.sensorOk) return (Level.bad, Icons.sensors_off_rounded, tr('st_sensor'), null);
    final t = inc.t!, target = inc.tTarget;
    final (hMin, hMax) = inc.humidityRange;
    final h = inc.h!;
    final humMsg = h < hMin - 3 ? tr('hum_low') : (h > hMax + 3 ? tr('hum_high') : null);
    if (t >= target + 1.0) return (Level.bad, Icons.local_fire_department_rounded, tr('st_hot'), humMsg);
    if (t <= target - 1.0) return (Level.warn, Icons.ac_unit_rounded, tr('st_cold'), humMsg);
    if (t <= target - 0.5) return (Level.warn, Icons.trending_up_rounded, tr('st_warming'), humMsg);
    if (t >= target + 0.5) return (Level.warn, Icons.thermostat_rounded, tr('st_warm'), humMsg);
    if (humMsg != null) return (Level.warn, Icons.water_drop_rounded, humMsg, null);
    return (Level.good, Icons.check_circle_rounded, tr('ok_all'), null);
  }

  @override
  Widget build(BuildContext context) {
    final (level, icon, title, sub) = _status();
    final c = levelColor(context, level);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Row(children: [
        Icon(icon, color: c, size: 32),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            if (sub != null) Text(sub, style: Theme.of(context).textTheme.bodyMedium),
          ]),
        ),
      ]),
    );
  }
}

class _BigNumber extends StatelessWidget {
  const _BigNumber({required this.label, required this.value, required this.unit, required this.sub, required this.level});
  final String label, value, unit, sub;
  final Level level;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = levelColor(context, level);
    return Card(
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: value, style: theme.textTheme.displayMedium?.copyWith(fontWeight: FontWeight.w600, color: c)),
                TextSpan(text: unit, style: theme.textTheme.titleLarge?.copyWith(color: c)),
              ]),
              textDirection: TextDirection.ltr,
            ),
          ),
          Text(sub, style: theme.textTheme.bodySmall),
        ]),
      ),
    );
  }
}

class _TempCard extends StatelessWidget {
  const _TempCard(this.inc);
  final Incubator inc;

  @override
  Widget build(BuildContext context) {
    final t = inc.sensorOk ? inc.t : null;
    final target = inc.tTarget;
    final level = t == null || inc.stale
        ? Level.off
        : (t - target).abs() >= 1.0
            ? Level.bad
            : (t - target).abs() >= 0.5
                ? Level.warn
                : Level.good;
    return _BigNumber(
      label: tr('temp'),
      value: t == null ? '--' : fmt1(t),
      unit: '°',
      sub: trf('target', ['${fmt1(target)}°']),
      level: level,
    );
  }
}

class _HumCard extends StatelessWidget {
  const _HumCard(this.inc);
  final Incubator inc;

  @override
  Widget build(BuildContext context) {
    final h = inc.sensorOk ? inc.h : null;
    final (lo, hi) = inc.humidityRange;
    final level = h == null || inc.stale
        ? Level.off
        : (h < lo - 3 || h > hi + 3)
            ? Level.warn
            : Level.good;
    return _BigNumber(
      label: tr('hum'),
      value: h == null ? '--' : h.round().toString(),
      unit: '%',
      sub: trf('target', ['$lo–$hi%']),
      level: level,
    );
  }
}

class _DayCard extends StatelessWidget {
  const _DayCard(this.inc);
  final Incubator inc;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final day = inc.day;
    final sp = inc.species;
    if (day == null) {
      return Card(
        color: theme.colorScheme.surfaceContainerHigh,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          leading: const Icon(Icons.egg_outlined),
          title: Text(tr('no_batch')),
          trailing: FilledButton(onPressed: () => startBatchDialog(context), child: Text(tr('start_batch'))),
        ),
      );
    }
    final String note;
    if (day >= sp.days) {
      note = tr('hatch_today');
    } else if (inc.inLockdown) {
      note = '${tr('lockdown_now')} · ${trf('hatch_in', [sp.days - day + 1])}';
    } else {
      note = trf('lockdown_in', [sp.lockdownDay - day]);
    }
    return Card(
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.egg_rounded, size: 20),
            const SizedBox(width: 8),
            Text(trf('day_of', [day.clamp(1, sp.days), sp.days]),
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const Spacer(),
            Text(tr(sp.id), style: theme.textTheme.labelLarge),
          ]),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(value: (day / sp.days).clamp(0.0, 1.0), minHeight: 10),
          ),
          const SizedBox(height: 8),
          Text(note, style: theme.textTheme.bodyMedium),
        ]),
      ),
    );
  }
}

class _TurnCard extends StatelessWidget {
  const _TurnCard(this.inc);
  final Incubator inc;

  @override
  Widget build(BuildContext context) {
    final last = inc.turnedAt;
    return Card(
      color: Theme.of(context).colorScheme.tertiaryContainer,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: const Icon(Icons.sync_rounded),
        title: Text(tr('turn_eggs')),
        subtitle: Text(last == null ? tr('turn_never') : trf('turn_last', [ago(last)])),
        trailing: FilledButton.tonal(
          onPressed: () => sendSettings(context, {'turned': Incubator.nowSec()}),
          child: Text(tr('done')),
        ),
      ),
    );
  }
}

class _OutputsRow extends StatelessWidget {
  const _OutputsRow(this.inc);
  final Incubator inc;

  @override
  Widget build(BuildContext context) {
    Widget chip(IconData icon, String label, bool on) {
      final c = on ? const Color(0xFFE8833A) : Theme.of(context).colorScheme.outline;
      return Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 18, color: c),
        const SizedBox(width: 6),
        Text('$label: ${on ? tr('on') : tr('off')}', style: Theme.of(context).textTheme.bodyMedium),
      ]);
    }

    if (!inc.hasData) return const SizedBox.shrink();
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 24,
      runSpacing: 8,
      children: [
        chip(Icons.light_mode_rounded, tr('lamp'), inc.lampOn),
        chip(Icons.air_rounded, tr('fan'), inc.fanOn),
      ],
    );
  }
}
