import 'package:egg_incubator/models.dart';
import 'package:egg_incubator/monitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 11, 1, 12);
  Snapshot snap({double t = 37.5, double h = 52, bool ok = true, DateTime? seen}) =>
      Snapshot(t: t, h: h, ok: ok, seenAt: seen ?? t0, hRange: (50, 55));

  test('temperature rings only after it stays out of range', () {
    final a = AlarmPrefs()..minutes = 1;
    final tr = AlarmTracker();
    expect(tr.update(snap(t: 25), a, t0).$1, isEmpty);
    expect(tr.update(snap(t: 25, seen: t0.add(const Duration(seconds: 30))), a, t0.add(const Duration(seconds: 30))).$1,
        isEmpty);
    final now = t0.add(const Duration(seconds: 61));
    expect(tr.update(snap(t: 25, seen: now), a, now).$1, [AlarmKind.temp]);
    // rings once per episode
    expect(tr.update(snap(t: 25, seen: now), a, now.add(const Duration(seconds: 20))).$1, isEmpty);
    // back to normal clears it
    final later = now.add(const Duration(minutes: 1));
    expect(tr.update(snap(seen: later), a, later).$2, [AlarmKind.temp]);
  });

  test('a short dip does not ring', () {
    final a = AlarmPrefs();
    final tr = AlarmTracker();
    tr.update(snap(t: 36), a, t0);
    final t1 = t0.add(const Duration(seconds: 40));
    tr.update(snap(seen: t1), a, t1);
    final t2 = t0.add(const Duration(seconds: 80));
    expect(tr.update(snap(t: 36, seen: t2), a, t2).$1, isEmpty);
  });

  test('offline rings after the set minutes', () {
    final a = AlarmPrefs()..offlineMinutes = 5;
    final tr = AlarmTracker();
    expect(tr.update(snap(), a, t0.add(const Duration(minutes: 4))).$1, isEmpty);
    expect(tr.update(snap(), a, t0.add(const Duration(minutes: 6))).$1, [AlarmKind.offline]);
  });

  test('switched-off alarms stay quiet', () {
    final a = AlarmPrefs()
      ..offline = false
      ..sensor = false;
    final tr = AlarmTracker();
    expect(tr.update(snap(), a, t0.add(const Duration(hours: 1))).$1, isEmpty);
    expect(tr.update(snap(ok: false), a, t0.add(const Duration(minutes: 5))).$1, isEmpty);
  });

  Batch batch({int daysAgo = 3, int turnedHoursAgo = 10, String species = 'chicken'}) {
    final now = DateTime.now();
    return Batch(
      id: 'x',
      name: 'A',
      species: species,
      eggs: 30,
      start: now.subtract(Duration(days: daysAgo)).millisecondsSinceEpoch ~/ 1000,
      turned: now.subtract(Duration(hours: turnedHoursAgo)).millisecondsSinceEpoch ~/ 1000,
    );
  }

  test('turning is due when a turning time passed since the last turn', () {
    final now = DateTime.now();
    final all = List.generate(24, (h) => h); // every hour: always a recent slot
    expect(turnDue([batch(turnedHoursAgo: 5)], all, now), isTrue);
    expect(turnDue([batch(turnedHoursAgo: 0)], all, now), isFalse);
    expect(turnDue([batch(daysAgo: 19, turnedHoursAgo: 5)], all, now), isFalse); // lockdown: no turning
  });

  test('humidity target follows lockdown', () {
    expect(humidityRangeFor([batch()], 50, 55), (50, 55));
    expect(humidityRangeFor([batch(daysAgo: 18)], 50, 55), (65, 70));
  });

  test('batch counts', () {
    final b = batch()
      ..hatched = 20
      ..dead = 3
      ..clear = 4
      ..broken = 1;
    expect(b.lost, 8);
    expect(b.remaining, 2);
    expect(b.hatchRate, closeTo(0.667, 0.01));
  });
}
