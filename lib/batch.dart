import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'home.dart';
import 'main.dart';
import 'models.dart';
import 'species.dart';
import 'strings.dart';
import 'tray.dart';

/// Next milestone of a running batch, for the card.
String milestone(Batch b) {
  final d = b.day, sp = b.sp;
  if (d >= sp.days) return tr('hatch_today');
  if (b.inLockdown) return trf('hatch_in', [sp.days - d]);
  if (d == 7 || d == 14) return tr('ms_candle');
  return trf('lockdown_in', [sp.lockdownDay - d]);
}

class BatchCard extends StatelessWidget {
  const BatchCard(this.b, {super.key});
  final Batch b;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sp = b.sp;
    return Card(
      color: theme.colorScheme.surfaceContainerHigh,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: InkWell(
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BatchScreen(b.id))),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              DayRing(b),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(b.name,
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                      overflow: TextOverflow.ellipsis),
                  Text([tr(sp.id), if (b.place.isNotEmpty) b.place].join(' · '),
                      style: theme.textTheme.bodySmall, overflow: TextOverflow.ellipsis),
                ]),
              ),
            ]),
            const SizedBox(height: 12),
            EggTray(eggs: eggsOf(b), columns: 10, maxEggs: 30),
            EggLegend(b, compact: true),
            const SizedBox(height: 6),
            Row(children: [
              Icon(Icons.flag_rounded, size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Expanded(child: Text(milestone(b), style: theme.textTheme.bodyMedium)),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// Incubation day inside a progress ring.
class DayRing extends StatelessWidget {
  const DayRing(this.b, {super.key, this.size = 52});
  final Batch b;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final days = b.sp.days;
    final d = b.day.clamp(1, days);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(alignment: Alignment.center, children: [
        SizedBox.expand(
          child: CircularProgressIndicator(
            value: b.active ? d / days : 1,
            strokeWidth: size * 0.09,
            strokeCap: StrokeCap.round,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ),
        Column(mainAxisSize: MainAxisSize.min, children: [
          Text('$d', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, height: 1)),
          Text('/$days', style: theme.textTheme.labelSmall?.copyWith(height: 1)),
        ]),
      ]),
    );
  }
}

/// Counts per egg status, each with its egg. The admin can tap a count to change it.
class EggLegend extends StatelessWidget {
  const EggLegend(this.b, {super.key, this.compact = false, this.onTap});
  final Batch b;
  final bool compact;
  final void Function(String field, String label, int value)? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = [
      (EggStatus.incubating, tr('remaining'), b.remaining, ''),
      (EggStatus.hatched, tr('hatched'), b.hatched, 'hatched'),
      (EggStatus.dead, tr('dead'), b.dead, 'dead'),
      (EggStatus.clear, tr('clear'), b.clear, 'clear'),
      (EggStatus.broken, tr('broken'), b.broken, 'broken'),
    ];
    if (compact) {
      return Wrap(spacing: 12, runSpacing: 4, children: [
        for (final (st, label, n, _) in items)
          if (n > 0 || st == EggStatus.incubating)
            Row(mainAxisSize: MainAxisSize.min, children: [
              EggIcon(st, size: 12),
              const SizedBox(width: 4),
              Text('$n $label', style: theme.textTheme.labelMedium),
            ]),
      ]);
    }
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 1.25,
      children: [
        for (final (st, label, n, field) in [...items, (EggStatus.incubating, tr('eggs'), b.eggs, 'eggs')])
          Material(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: onTap != null && field.isNotEmpty ? () => onTap!(field, label, n) : null,
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                field == 'eggs'
                    ? Icon(Icons.inventory_2_outlined, size: 24, color: theme.colorScheme.primary)
                    : EggIcon(st, size: 20),
                const SizedBox(height: 4),
                Text('$n', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                Text(label, style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
              ]),
            ),
          ),
      ],
    );
  }
}

/// Everything about one batch: counts, losses, timeline. Only the admin can change it.
class BatchScreen extends StatelessWidget {
  const BatchScreen(this.id, {super.key});
  final String id;

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: incubator, builder: _build);

  Widget _build(BuildContext context, Widget? _) {
    final found = incubator.batches.where((b) => b.id == id);
    if (found.isEmpty) return Scaffold(appBar: AppBar());
    final b = found.first;
    final admin = incubator.isAdmin;
    final theme = Theme.of(context);
    final loc = MaterialLocalizations.of(context);
    final sp = b.sp;
    final next = b.active ? nextTurn([b], incubator.turnTimes) : null;

    final steps = [
      (1, tr('tl_start')),
      if (sp.days >= 14) (7, tr('tl_candle')),
      if (sp.days >= 18) (14, tr('tl_candle')),
      (sp.lockdownDay, tr('tl_lockdown')),
      (sp.days, tr('tl_hatch')),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(b.name),
        actions: [
          if (admin)
            PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'edit') openBatchEditor(context, b);
                if (v == 'end') incubator.saveBatch(b.copy()..ended = b.active ? nowSec() : 0);
                if (v == 'delete' && await _confirm(context, tr('delete_batch'), tr('delete_batch_q'))) {
                  incubator.deleteBatch(b.id);
                  if (context.mounted) Navigator.pop(context);
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'edit', child: Text(tr('edit'))),
                PopupMenuItem(value: 'end', child: Text(b.active ? tr('end_batch') : tr('start'))),
                PopupMenuItem(value: 'delete', child: Text(tr('delete_batch'))),
              ],
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          Text(
            [
              tr(sp.id),
              if (b.place.isNotEmpty) b.place,
              '${tr('started')}: ${loc.formatMediumDate(b.startedAt)}',
              if (!b.active) tr('ended'),
            ].join(' · '),
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          Row(children: [
            DayRing(b, size: 64),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(b.active ? trf('day_of', [b.day.clamp(1, sp.days), sp.days]) : tr('ended'),
                    style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                if (b.active) Text(milestone(b), style: theme.textTheme.bodyMedium),
              ]),
            ),
          ]),
          const SizedBox(height: 16),
          EggTray(eggs: eggsOf(b)),
          const SizedBox(height: 8),
          EggLegend(b, onTap: admin ? (f, label, v) => _editCount(context, b, f, label, v) : null),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr('lost')),
            trailing: Text('${b.lost}', style: theme.textTheme.titleMedium),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr('hatch_rate')),
            trailing: Text('${(b.hatchRate * 100).round()}%', style: theme.textTheme.titleMedium),
          ),
          if (b.active && !b.inLockdown)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.sync_rounded),
              title: Text(b.turned > 0 ? trf('last_turned', [ago(timeOf(b.turned)!)]) : tr('turn_never')),
              subtitle: next == null
                  ? null
                  : Text(trf('next_turn', ['${loc.formatShortDate(next)} ${hourLabel(context, next.hour)}'])),
              trailing: admin
                  ? FilledButton.tonal(
                      onPressed: () => incubator.saveBatch(b.copy()..turned = nowSec()), child: Text(tr('done')))
                  : null,
            ),
          if (!admin)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(tr('viewer_note'), style: theme.textTheme.bodySmall),
            ),
          const SizedBox(height: 16),
          Text(tr('timeline'), style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
          for (final (d, label) in steps)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(
                b.day > d || !b.active ? Icons.check_circle : (b.day == d ? Icons.radio_button_checked : Icons.circle_outlined),
                color: b.day >= d || !b.active ? theme.colorScheme.primary : theme.colorScheme.outline,
              ),
              title: Text(label),
              trailing: Text('${trf('day_of', [d, sp.days]).split(' ').take(2).join(' ')} · ${loc.formatShortDate(b.dayDate(d))}',
                  style: theme.textTheme.bodySmall),
            ),
        ],
      ),
    );
  }

  Future<void> _editCount(BuildContext context, Batch b, String field, String label, int value) async {
    var v = value;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(label),
          content: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton.filledTonal(
                onPressed: v > 0 ? () => setState(() => v--) : null, icon: const Icon(Icons.remove)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text('$v', style: Theme.of(context).textTheme.headlineMedium),
            ),
            IconButton.filledTonal(onPressed: () => setState(() => v++), icon: const Icon(Icons.add)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('save'))),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final c = b.copy();
    switch (field) {
      case 'eggs':
        c.eggs = v;
      case 'hatched':
        c.hatched = v;
      case 'dead':
        c.dead = v;
      case 'clear':
        c.clear = v;
      case 'broken':
        c.broken = v;
    }
    incubator.saveBatch(c);
  }
}

Future<bool> _confirm(BuildContext context, String title, String body) async =>
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

void openBatchEditor(BuildContext context, Batch? b) =>
    Navigator.push(context, MaterialPageRoute(builder: (_) => BatchEditScreen(batch: b)));

/// Add or edit a batch (admin).
class BatchEditScreen extends StatefulWidget {
  const BatchEditScreen({super.key, this.batch});
  final Batch? batch;

  @override
  State<BatchEditScreen> createState() => _BatchEditScreenState();
}

class _BatchEditScreenState extends State<BatchEditScreen> {
  late final TextEditingController _name, _eggs, _place;
  late String _species;
  late DateTime _start;

  @override
  void initState() {
    super.initState();
    final b = widget.batch;
    _name = TextEditingController(text: b?.name ?? trf('batch_default', [incubator.batches.length + 1]));
    _eggs = TextEditingController(text: b == null ? '' : '${b.eggs}');
    _place = TextEditingController(text: b?.place ?? '');
    _species = b?.species ?? 'chicken';
    _start = b?.startedAt ?? DateTime.now();
  }

  void _save() {
    final eggs = int.tryParse(_eggs.text.trim()) ?? 0;
    final name = _name.text.trim();
    if (name.isEmpty || eggs <= 0) return;
    final start = _start.millisecondsSinceEpoch ~/ 1000;
    final b = widget.batch?.copy() ?? Batch(id: newId(), name: name, species: _species, eggs: eggs, start: start, turned: nowSec());
    b
      ..name = name
      ..species = _species
      ..eggs = eggs
      ..place = _place.text.trim()
      ..start = start;
    incubator.saveBatch(b);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final loc = MaterialLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.batch == null ? tr('add_batch') : tr('edit'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(controller: _name, decoration: InputDecoration(labelText: tr('batch_name')), maxLength: 30),
          const SizedBox(height: 4),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final sp in allSpecies)
              ChoiceChip(
                label: Text(tr(sp.id)),
                selected: _species == sp.id,
                onSelected: (_) => setState(() => _species = sp.id),
              ),
          ]),
          const SizedBox(height: 16),
          TextField(
            controller: _eggs,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(labelText: tr('eggs_count')),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _place,
            maxLength: 40,
            decoration: InputDecoration(labelText: tr('place'), hintText: tr('place_hint')),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.event_outlined),
            title: Text(tr('start_date')),
            trailing: Text(loc.formatMediumDate(_start)),
            onTap: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: _start,
                firstDate: DateTime.now().subtract(const Duration(days: 60)),
                lastDate: DateTime.now(),
              );
              if (d != null) setState(() => _start = DateTime(d.year, d.month, d.day, DateTime.now().hour));
            },
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _save,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            child: Text(tr('save')),
          ),
        ],
      ),
    );
  }
}

class PastBatchesScreen extends StatelessWidget {
  const PastBatchesScreen({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: incubator,
        builder: (context, _) {
          final ended = incubator.endedBatches;
          final loc = MaterialLocalizations.of(context);
          return Scaffold(
            appBar: AppBar(title: Text(trf('history_batches', [ended.length]))),
            body: ListView(children: [
              for (final b in ended)
                ListTile(
                  leading: const EggIcon(EggStatus.hatched, size: 26),
                  title: Text(b.name),
                  subtitle: Text(
                      '${tr(b.sp.id)} · ${loc.formatMediumDate(b.startedAt)} · ${tr('hatched')} ${b.hatched}/${b.eggs} · ${tr('lost')} ${b.lost}'),
                  trailing: Text('${(b.hatchRate * 100).round()}%'),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BatchScreen(b.id))),
                ),
            ]),
          );
        },
      );
}
