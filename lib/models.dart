import 'dart:math';

import 'species.dart';

int nowSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
int nowMs() => DateTime.now().millisecondsSinceEpoch;

DateTime? timeOf(Object? v) =>
    v is num && v > 0 ? DateTime.fromMillisecondsSinceEpoch(v.toInt() * 1000) : null;

String newId() {
  final r = Random.secure();
  return List.generate(12, (_) => r.nextInt(16).toRadixString(16)).join();
}

int _int(Object? v) => v is num ? v.toInt() : 0;

/// One group of eggs set together. Kept in the cloud; only the admin edits it.
class Batch {
  Batch({
    required this.id,
    required this.name,
    required this.species,
    required this.eggs,
    required this.start,
    this.place = '',
    this.turned = 0,
    this.hatched = 0,
    this.dead = 0,
    this.clear = 0,
    this.broken = 0,
    this.ended = 0,
  });

  final String id;
  String name;
  String species;
  int eggs;
  String place;
  int start; // unix seconds
  int turned; // unix seconds, last turning
  int hatched, dead, clear, broken;
  int ended; // unix seconds, 0 while running

  factory Batch.fromJson(String id, Map<String, dynamic> j) => Batch(
        id: id,
        name: (j['name'] as String?) ?? '',
        species: (j['species'] as String?) ?? 'chicken',
        eggs: _int(j['eggs']),
        place: (j['place'] as String?) ?? '',
        start: _int(j['start']),
        turned: _int(j['turned']),
        hatched: _int(j['hatched']),
        dead: _int(j['dead']),
        clear: _int(j['clear']),
        broken: _int(j['broken']),
        ended: _int(j['ended']),
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'species': species,
        'eggs': eggs,
        'place': place,
        'start': start,
        'turned': turned,
        'hatched': hatched,
        'dead': dead,
        'clear': clear,
        'broken': broken,
        'ended': ended,
      };

  Batch copy() => Batch.fromJson(id, toJson());

  Species get sp => speciesById(species);
  bool get active => ended == 0;
  DateTime get startedAt => DateTime.fromMillisecondsSinceEpoch(start * 1000);

  /// Incubation day, 1-based.
  int get day => DateTime.now().difference(startedAt).inDays + 1;
  bool get inLockdown => day >= sp.lockdownDay;
  int get lost => dead + clear + broken;
  int get remaining => max(0, eggs - hatched - lost);
  double get hatchRate => eggs == 0 ? 0 : hatched / eggs;
  DateTime dayDate(int d) => startedAt.add(Duration(days: d - 1));
}

/// Per-phone alarm settings. Each person sets their own.
class AlarmPrefs {
  bool enabled = true; // background monitoring + all alerts
  double tLow = 36.5, tHigh = 38.5;
  int minutes = 1; // how long the temperature must be out of range
  bool offline = true;
  int offlineMinutes = 5;
  bool humidity = true;
  bool sensor = true;
  bool turning = true;
  bool milestones = true;

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'tLow': tLow,
        'tHigh': tHigh,
        'minutes': minutes,
        'offline': offline,
        'offlineMinutes': offlineMinutes,
        'humidity': humidity,
        'sensor': sensor,
        'turning': turning,
        'milestones': milestones,
      };

  static AlarmPrefs fromJson(Map<String, dynamic> j) {
    final a = AlarmPrefs();
    a.enabled = j['enabled'] as bool? ?? a.enabled;
    a.tLow = (j['tLow'] as num?)?.toDouble() ?? a.tLow;
    a.tHigh = (j['tHigh'] as num?)?.toDouble() ?? a.tHigh;
    a.minutes = (j['minutes'] as num?)?.toInt() ?? a.minutes;
    a.offline = j['offline'] as bool? ?? a.offline;
    a.offlineMinutes = (j['offlineMinutes'] as num?)?.toInt() ?? a.offlineMinutes;
    a.humidity = j['humidity'] as bool? ?? a.humidity;
    a.sensor = j['sensor'] as bool? ?? a.sensor;
    a.turning = j['turning'] as bool? ?? a.turning;
    a.milestones = j['milestones'] as bool? ?? a.milestones;
    return a;
  }
}

/// Humidity range for the incubator right now: the lockdown range as soon as any running batch
/// is in lockdown, otherwise the configured range.
(int, int) humidityRangeFor(List<Batch> batches, int hMin, int hMax) {
  for (final b in batches) {
    if (b.active && b.inLockdown) return (b.sp.lockMin, b.sp.lockMax);
  }
  return (hMin, hMax);
}

/// Next turning time (hours of the day) after now, or null when no batch needs turning.
DateTime? nextTurn(List<Batch> batches, List<int> hours, [DateTime? now]) {
  now ??= DateTime.now();
  if (hours.isEmpty || !batches.any((b) => b.active && !b.inLockdown)) return null;
  final sorted = [...hours]..sort();
  for (var d = 0; d < 2; d++) {
    for (final h in sorted) {
      final t = DateTime(now.year, now.month, now.day + d, h);
      if (t.isAfter(now)) return t;
    }
  }
  return null;
}

/// True when a turning time has passed and the running batches were not turned since.
bool turnDue(List<Batch> batches, List<int> hours, [DateTime? now]) {
  now ??= DateTime.now();
  final due = batches.where((b) => b.active && !b.inLockdown).toList();
  if (due.isEmpty || hours.isEmpty) return false;
  DateTime? last;
  for (final h in hours) {
    for (final d in [0, -1]) {
      final t = DateTime(now.year, now.month, now.day + d, h);
      if (!t.isAfter(now) && (last == null || t.isAfter(last))) last = t;
    }
  }
  if (last == null) return false;
  // Turning up to an hour early counts.
  final since = last.subtract(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000;
  return due.any((b) => b.turned < since);
}
