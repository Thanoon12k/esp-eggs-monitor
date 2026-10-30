import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'device.dart';
import 'models.dart';
import 'strings.dart';

// Notification ids
const _idTemp = 10, _idOffline = 11, _idSensor = 12, _idHum = 13, _idTurn = 20;

final notifications = FlutterLocalNotificationsPlugin();

Future<void> initNotifications() async {
  await notifications.initialize(
    settings: const InitializationSettings(android: AndroidInitializationSettings('ic_notification')),
  );
}

/// Loud, repeating alarm sound (like an alarm clock) until the notification is dismissed.
NotificationDetails get alarmDetails => NotificationDetails(
      android: AndroidNotificationDetails(
        'incubator_alarm',
        tr('ch_alarm'),
        channelDescription: tr('ch_alarm_desc'),
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.alarm,
        audioAttributesUsage: AudioAttributesUsage.alarm,
        sound: const UriAndroidNotificationSound('content://settings/system/alarm_alert'),
        fullScreenIntent: true,
        visibility: NotificationVisibility.public,
        enableVibration: true,
        vibrationPattern: Int64List.fromList([0, 800, 400, 800, 400, 800]),
        additionalFlags: Int32List.fromList([4]), // FLAG_INSISTENT: keep ringing
      ),
    );

NotificationDetails get eventDetails => NotificationDetails(
      android: AndroidNotificationDetails(
        'incubator_events',
        tr('ch_events'),
        channelDescription: tr('ch_events_desc'),
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.reminder,
      ),
    );

Future<void> testAlarm() => notifications.show(
    id: 99, title: tr('alarm_test_title'), body: tr('alarm_test_body'), notificationDetails: alarmDetails);

// ---- Starting / stopping the service from the app -----------------------------------------

void initMonitorService() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'incubator_monitor',
      channelName: tr('ch_monitor'),
      channelDescription: tr('ch_monitor_desc'),
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(showNotification: false, playSound: false),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(20000),
      autoRunOnBoot: true,
      autoRunOnMyPackageReplaced: true,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
}

/// Starts or stops background monitoring to match this phone's alarm settings.
Future<void> syncMonitorService({bool askPermissions = false}) async {
  if (!Platform.isAndroid) return;
  final prefs = await SharedPreferences.getInstance();
  final paired = (prefs.getString('key') ?? '').isNotEmpty;
  final enabled = loadAlarmPrefs(prefs).enabled;
  final running = await FlutterForegroundTask.isRunningService;
  if (!paired || !enabled) {
    if (running) await FlutterForegroundTask.stopService();
    return;
  }
  if (askPermissions) {
    if (await FlutterForegroundTask.checkNotificationPermission() != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
  }
  if (running) return;
  await FlutterForegroundTask.startService(
    serviceId: 300,
    serviceTypes: [ForegroundServiceTypes.specialUse],
    notificationTitle: tr('monitor_title'),
    notificationText: tr('monitor_starting'),
    notificationIcon: const NotificationIcon(metaDataName: 'com.thanoon.egg_incubator.MONITOR_ICON'),
    callback: startMonitor,
  );
}

AlarmPrefs loadAlarmPrefs(SharedPreferences p) {
  try {
    return AlarmPrefs.fromJson(Map<String, dynamic>.from(jsonDecode(p.getString('alarm') ?? '{}') as Map));
  } catch (_) {
    return AlarmPrefs();
  }
}

Future<void> saveAlarmPrefs(AlarmPrefs a) async {
  final p = await SharedPreferences.getInstance();
  await p.setString('alarm', jsonEncode(a.toJson()));
  FlutterForegroundTask.sendDataToTask('reload');
}

@pragma('vm:entry-point')
void startMonitor() {
  FlutterForegroundTask.setTaskHandler(MonitorHandler());
}

// ---- Alarm rules (pure, so they can be tested) ----------------------------------------------

enum AlarmKind { temp, offline, sensor, humidity }

class Snapshot {
  Snapshot({this.t, this.h, required this.ok, this.seenAt, required this.hRange});
  final double? t, h;
  final bool ok;
  final DateTime? seenAt;
  final (int, int) hRange;
}

/// Remembers since when each problem has been going on and whether it already rang.
class AlarmTracker {
  final Map<AlarmKind, DateTime> _since = {};
  final Set<AlarmKind> fired = {};

  /// Returns (problems that should start ringing now, problems that cleared).
  (List<AlarmKind>, List<AlarmKind>) update(Snapshot s, AlarmPrefs a, DateTime now) {
    final online = s.seenAt != null && now.difference(s.seenAt!) < Duration(minutes: a.offlineMinutes);
    final active = <AlarmKind, Duration>{
      if (a.offline && s.seenAt != null && !online) AlarmKind.offline: Duration.zero,
      if (online && a.sensor && !s.ok) AlarmKind.sensor: const Duration(minutes: 1),
      if (online && s.ok && s.t != null && (s.t! < a.tLow || s.t! > a.tHigh))
        AlarmKind.temp: Duration(minutes: a.minutes),
      if (online && a.humidity && s.ok && s.h != null && (s.h! < s.hRange.$1 - 3 || s.h! > s.hRange.$2 + 3))
        AlarmKind.humidity: const Duration(minutes: 10),
    };
    final start = <AlarmKind>[], cleared = <AlarmKind>[];
    for (final k in AlarmKind.values) {
      final wait = active[k];
      if (wait == null) {
        _since.remove(k);
        if (fired.remove(k)) cleared.add(k);
        continue;
      }
      final since = _since.putIfAbsent(k, () => now);
      if (!fired.contains(k) && now.difference(since) >= wait) {
        fired.add(k);
        start.add(k);
      }
    }
    return (start, cleared);
  }
}

// ---- The background task ----------------------------------------------------------------------

class MonitorHandler extends TaskHandler {
  SharedPreferences? _prefs;
  final _tracker = AlarmTracker();
  bool _busy = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _prefs = await SharedPreferences.getInstance();
    lang.value = _prefs!.getString('lang') ?? 'ar';
    await initNotifications();
    await _tick();
  }

  @override
  void onRepeatEvent(DateTime timestamp) => _tick();

  @override
  void onReceiveData(Object data) => _tick();

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onNotificationPressed() => FlutterForegroundTask.launchApp();

  Future<void> _tick() async {
    if (_busy || _prefs == null) return;
    _busy = true;
    try {
      final p = _prefs!;
      await p.reload();
      lang.value = p.getString('lang') ?? lang.value;
      final key = p.getString('key') ?? '';
      if (key.isEmpty) return;
      final a = loadAlarmPrefs(p);
      if (!a.enabled) {
        await FlutterForegroundTask.stopService();
        return;
      }
      final addr = p.getString('addr') ?? '';

      // Readings: the ESP32 directly, else the cloud.
      Map<String, dynamic>? state;
      DateTime? seenAt;
      List<Batch> batches = _cachedBatches(p);
      var turnTimes = _cachedTurnTimes(p);
      if (addr.isNotEmpty) {
        final j = await probe(addr, timeout: const Duration(seconds: 4));
        if (j != null && j['key'] == key) {
          state = j;
          seenAt = DateTime.now();
        }
      }
      try {
        final j = await rpc('incubator_get', {'p_key': key});
        if (j is Map) {
          if (state == null) {
            state = Map<String, dynamic>.from(j['state'] as Map);
            final seen = DateTime.tryParse('${j['seen_at']}');
            final now = DateTime.tryParse('${j['now']}');
            if (seen != null && now != null) seenAt = DateTime.now().subtract(now.difference(seen));
          }
          batches = [
            for (final r in (j['batches'] as List? ?? const []))
              if (r is Map && r['data'] is Map)
                Batch.fromJson('${r['id']}', Map<String, dynamic>.from(r['data'] as Map)),
          ];
          final tt = (j['app'] as Map?)?['turn_times'];
          if (tt is List) turnTimes = tt.map((e) => (e as num).toInt()).toList();
        }
      } catch (_) {}
      if (state == null && seenAt == null) {
        // Neither the ESP32 nor the cloud answered: the phone itself is offline. Use the last report.
        seenAt = DateTime.tryParse(p.getString('mon_seen') ?? '');
      } else if (seenAt != null) {
        p.setString('mon_seen', seenAt.toIso8601String());
      }

      final s = state ?? const <String, dynamic>{};
      final settings = (s['s'] as Map?) ?? const {};
      final snap = Snapshot(
        t: (s['t'] as num?)?.toDouble(),
        h: (s['h'] as num?)?.toDouble(),
        ok: s['ok'] == true,
        seenAt: seenAt,
        hRange: humidityRangeFor(batches, (settings['h_min'] as num?)?.round() ?? 50,
            (settings['h_max'] as num?)?.round() ?? 55),
      );
      final now = DateTime.now();
      final (start, cleared) = _tracker.update(snap, a, now);
      for (final k in cleared) {
        await notifications.cancel(id: _idFor(k));
      }
      for (final k in start) {
        await _ring(k, snap);
      }

      FlutterForegroundTask.updateService(
        notificationTitle: tr('monitor_title'),
        notificationText: snap.t == null
            ? tr('st_offline')
            : '${snap.t!.toStringAsFixed(1)}° · ${snap.h?.round() ?? '--'}% · ${tr('lamp')}: ${s['lamp'] == true ? tr('on') : tr('off')}',
      );

      if (a.turning) await _turnReminder(p, batches, turnTimes, now);
      if (a.milestones) await _milestones(p, batches);
    } catch (_) {
      // keep the service alive; try again next round
    } finally {
      _busy = false;
    }
  }

  int _idFor(AlarmKind k) => switch (k) {
        AlarmKind.temp => _idTemp,
        AlarmKind.offline => _idOffline,
        AlarmKind.sensor => _idSensor,
        AlarmKind.humidity => _idHum,
      };

  Future<void> _ring(AlarmKind k, Snapshot s) async {
    final (title, body, loud) = switch (k) {
      AlarmKind.temp => (
          s.t! < 37 ? tr('al_cold') : tr('al_hot'),
          trf('al_temp_body', ['${s.t!.toStringAsFixed(1)}°']),
          true
        ),
      AlarmKind.offline => (tr('al_offline'), tr('al_offline_body'), true),
      AlarmKind.sensor => (tr('al_sensor'), tr('st_sensor'), true),
      AlarmKind.humidity => (
          s.h! < s.hRange.$1 ? tr('hum_low') : tr('hum_high'),
          trf('al_hum_body', ['${s.h!.round()}%', '${s.hRange.$1}–${s.hRange.$2}%']),
          false
        ),
    };
    await notifications.show(
        id: _idFor(k), title: title, body: body, notificationDetails: loud ? alarmDetails : eventDetails);
  }

  List<Batch> _cachedBatches(SharedPreferences p) {
    try {
      return [
        for (final r in jsonDecode(p.getString('batches') ?? '[]') as List)
          Batch.fromJson('${r['id']}', Map<String, dynamic>.from(r['data'] as Map)),
      ];
    } catch (_) {
      return [];
    }
  }

  List<int> _cachedTurnTimes(SharedPreferences p) {
    try {
      final tt = (jsonDecode(p.getString('app') ?? '{}') as Map)['turn_times'];
      if (tt is List) return tt.map((e) => (e as num).toInt()).toList();
    } catch (_) {}
    return [8, 14, 20];
  }

  /// One reminder per turning time while it is still due.
  Future<void> _turnReminder(SharedPreferences p, List<Batch> batches, List<int> hours, DateTime now) async {
    if (!turnDue(batches, hours, now)) return;
    final passed = hours.where((h) => h <= now.hour);
    final hour = passed.isEmpty ? null : passed.reduce((a, b) => a > b ? a : b);
    final slot = '${now.year}-${now.month}-${now.day}-${hour ?? 'y'}';
    if (p.getString('mon_turn_slot') == slot) return;
    await p.setString('mon_turn_slot', slot);
    final names = batches.where((b) => b.active && !b.inLockdown).map((b) => b.name).join('، ');
    await notifications.show(id: _idTurn, title: tr('turn_eggs'), body: names, notificationDetails: eventDetails);
  }

  /// Candling (day 7 and 14), lockdown and hatch day: once per batch, from 8 am.
  Future<void> _milestones(SharedPreferences p, List<Batch> batches) async {
    if (DateTime.now().hour < 8) return;
    final done = (p.getStringList('mon_milestones') ?? []).toSet();
    for (final b in batches.where((b) => b.active)) {
      final d = b.day;
      final String? kind = d == 7 || d == 14
          ? 'candle$d'
          : d == b.sp.lockdownDay
              ? 'lockdown'
              : d == b.sp.days
                  ? 'hatch'
                  : null;
      if (kind == null || done.contains('${b.id}-$kind')) continue;
      done.add('${b.id}-$kind');
      final text = switch (kind) {
        'lockdown' => tr('ms_lockdown'),
        'hatch' => tr('ms_hatch'),
        _ => tr('ms_candle'),
      };
      await notifications.show(
          id: 100 + (b.id.hashCode % 800).abs(),
          title: '${b.name} · ${trf('day_of', [d, b.sp.days])}',
          body: text,
          notificationDetails: eventDetails);
    }
    await p.setStringList('mon_milestones', done.toList());
  }
}
