import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'home.dart';
import 'main.dart';
import 'models.dart';
import 'species.dart';
import 'strings.dart';

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
      child: InkWell(
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BatchScreen(b.id))),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.egg_rounded, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(b.name,
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis),
              ),
              Text(trf('day_of', [b.day.clamp(1, sp.days), sp.days]), style: theme.textTheme.labelLarge),
            ]),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(value: (b.day / sp.days).clamp(0.0, 1.0), minHeight: 8),
            ),
            const SizedBox(height: 8),
            Text(
              [
                tr(sp.id),
                '${b.remaining} ${tr('eggs')}',
                if (b.hatched > 0) '${tr('hatched')} ${b.hatched}',
                if (b.lost > 0) '${tr('lost')} ${b.lost}',
                if (b.place.isNotEmpty) b.place,
              ].join(' · '),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 2),
            Text(milestone(b), style: theme.textTheme.bodyMedium),
          ]),
        ),
      ),
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

    Widget count(String label, int value, String field, Color? color) => Expanded(
          child: Card(
            color: theme.colorScheme.surfaceContainerHigh,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: admin && field.isNotEmpty ? () => _editCount(context, b, field, label, value) : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                child: Column(children: [
                  Text('$value',
                      style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600, color: color)),
                  Text(label, style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
                ]),
              ),
            ),
          ),
        );

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
          if (b.active) ...[
            Text(trf('day_of', [b.day.clamp(1, sp.days), sp.days]),
                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(value: (b.day / sp.days).clamp(0.0, 1.0), minHeight: 10),
            ),
            const SizedBox(height: 6),
            Text(milestone(b)),
            const SizedBox(height: 16),
          ],
          Row(children: [
            count(tr('eggs'), b.eggs, 'eggs', null),
            count(tr('remaining'), b.remaining, '', null),
            count(tr('hatched'), b.hatched, 'hatched', const Color(0xFF2E9E5B)),
          ]),
          Row(children: [
            count(tr('dead'), b.dead, 'dead', const Color(0xFFD64535)),
            count(tr('clear'), b.clear, 'clear', const Color(0xFFE09A1A)),
            count(tr('broken'), b.broken, 'broken', const Color(0xFFE09A1A)),
          ]),
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
                  leading: const Icon(Icons.egg_outlined),
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
