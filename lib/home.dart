import 'package:flutter/material.dart';

import 'batch.dart';
import 'device.dart';
import 'main.dart';
import 'models.dart';
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

String hourLabel(BuildContext context, int h) =>
    MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay(hour: h, minute: 0));

enum Level { good, warn, bad, off }

Color levelColor(BuildContext context, Level l) => switch (l) {
      Level.good => const Color(0xFF2E9E5B),
      Level.warn => const Color(0xFFE09A1A),
      Level.bad => const Color(0xFFD64535),
      Level.off => Theme.of(context).colorScheme.outline,
    };

/// The one screen: is the incubator OK (temperature, humidity), then the batches of eggs.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: incubator, builder: _build);

  Widget _build(BuildContext context, Widget? _) {
    final inc = incubator;
    final active = inc.activeBatches;
    final ended = inc.endedBatches;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('app')),
        actions: [
          _LinkChip(inc.link),
          if (inc.isAdmin)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 6),
              child: Tooltip(message: tr('you_are_admin'), child: const Icon(Icons.verified_user_rounded, size: 20)),
            ),
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
            const SizedBox(height: 14),
            _OutputsRow(inc),
            if (inc.isAdmin && inc.outboxCount > 0) ...[
              const SizedBox(height: 10),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.cloud_upload_outlined, size: 16),
                const SizedBox(width: 6),
                Text(trf('queued', [inc.outboxCount]), style: Theme.of(context).textTheme.bodySmall),
              ]),
            ],
            if (turnDue(active, inc.turnTimes)) ...[const SizedBox(height: 14), _TurnCard(inc)],
            const SizedBox(height: 22),
            Row(children: [
              Text(tr('batches'), style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              const Spacer(),
              if (inc.isAdmin)
                TextButton.icon(
                  onPressed: () => openBatchEditor(context, null),
                  icon: const Icon(Icons.add),
                  label: Text(tr('add_batch')),
                ),
            ]),
            const SizedBox(height: 6),
            if (active.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(tr('no_batches'), textAlign: TextAlign.center),
              ),
            for (final b in active) ...[BatchCard(b), const SizedBox(height: 10)],
            if (ended.isNotEmpty)
              TextButton(
                onPressed: () =>
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const PastBatchesScreen())),
                child: Text(trf('history_batches', [ended.length])),
              ),
          ],
        ),
      ),
    );
  }
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

class _TurnCard extends StatelessWidget {
  const _TurnCard(this.inc);
  final Incubator inc;

  @override
  Widget build(BuildContext context) {
    final names = inc.activeBatches.where((b) => !b.inLockdown).map((b) => b.name).join('، ');
    return Card(
      color: Theme.of(context).colorScheme.tertiaryContainer,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: const Icon(Icons.sync_rounded),
        title: Text(tr('turn_eggs')),
        subtitle: Text(names),
        trailing: inc.isAdmin
            ? FilledButton.tonal(onPressed: inc.markTurned, child: Text(tr('done')))
            : null,
      ),
    );
  }
}

/// Lamp and fan: shown to everyone; the admin can tap to switch them.
class _OutputsRow extends StatelessWidget {
  const _OutputsRow(this.inc);
  final Incubator inc;

  @override
  Widget build(BuildContext context) {
    if (!inc.hasData) return const SizedBox.shrink();
    Widget chip(IconData icon, String which, String label, bool on) {
      final c = on ? const Color(0xFFE8833A) : Theme.of(context).colorScheme.outline;
      final mode = inc.settings[which] as String?;
      final child = Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 18, color: c),
        const SizedBox(width: 6),
        Text('$label: ${on ? tr('on') : tr('off')}', style: Theme.of(context).textTheme.bodyMedium),
        if (mode != null && mode != 'auto') ...[
          const SizedBox(width: 4),
          Text('(${modeLabel(mode, fan: which == 'fan')})', style: Theme.of(context).textTheme.bodySmall),
        ],
        if (inc.isAdmin) ...[const SizedBox(width: 2), const Icon(Icons.arrow_drop_down, size: 18)],
      ]);
      if (!inc.isAdmin) return child;
      return InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => pickMode(context, which),
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4), child: child),
      );
    }

    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 20,
      runSpacing: 8,
      children: [
        chip(Icons.light_mode_rounded, 'lamp', tr('lamp'), inc.lampOn),
        chip(Icons.air_rounded, 'fan', tr('fan'), inc.fanOn),
      ],
    );
  }
}
