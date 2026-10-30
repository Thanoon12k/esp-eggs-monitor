import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

// Public values: the cloud project URL and its publishable key (same as the firmware's config.py).
const cloudUrl = 'https://axncazensmjdqpczvzwf.supabase.co';
const cloudKey = 'sb_publishable_7hGIGHFa1mcWPMI8mEZKGw_-wgkkSYT';

/// How the phone reaches the incubator right now.
enum Link { local, cloud, offline }

class Reading {
  final DateTime at;
  final double t, h;
  const Reading(this.at, this.t, this.h);
}

/// Thrown when the cloud refuses an admin action; [code] is 'wrong', 'locked', 'none' or 'offline'.
class AdminError implements Exception {
  AdminError(this.code);
  final String code;
}

Future<dynamic> rpc(String fn, Map<String, dynamic> body, {Duration timeout = const Duration(seconds: 8)}) async {
  final r = await http
      .post(Uri.parse('$cloudUrl/rest/v1/rpc/$fn'),
          headers: {'apikey': cloudKey, 'Content-Type': 'application/json'}, body: jsonEncode(body))
      .timeout(timeout);
  if (r.statusCode != 200) {
    final msg = r.body;
    if (msg.contains('wrong')) throw AdminError('wrong');
    if (msg.contains('locked')) throw AdminError('locked');
    if (msg.contains('no admin')) throw AdminError('none');
    throw HttpException('${r.statusCode} $msg');
  }
  return jsonDecode(r.body);
}

/// GET http://host/api/state; null when nothing answers.
Future<Map<String, dynamic>?> probe(String host, {Duration timeout = const Duration(seconds: 2)}) async {
  try {
    final r = await http.get(Uri.parse('http://$host/api/state')).timeout(timeout);
    if (r.statusCode != 200) return null;
    final j = jsonDecode(r.body);
    if (j is Map<String, dynamic> && j['key'] is String) return j;
  } catch (_) {}
  return null;
}

/// The incubator as the phone sees it: readings from the ESP32 (directly on the home Wi-Fi, or
/// through the cloud), plus batches and shared settings from the cloud. The admin's edits wait in
/// an outbox on the phone until the cloud can be reached.
class Incubator extends ChangeNotifier {
  SharedPreferences? _prefs;
  String key = '';
  String addr = '';
  Link link = Link.offline;
  Map<String, dynamic> state = {};
  DateTime? seenAt;
  bool pending = false;
  List<Reading> history = [];
  bool loaded = false;

  // Batches and shared settings (cloud), and this phone's admin PIN.
  Map<String, Batch> _cloudBatches = {};
  Map<String, dynamic> app = {};
  int appUpdated = 0;
  bool hasAdmin = false;
  String pin = '';
  bool cloudOk = false;
  Map<String, Map<String, dynamic>> _outbox = {}; // batch id -> {id, data, updated, deleted}
  Map<String, dynamic>? _outboxApp;

  Timer? _timer;
  int _ticks = 0;
  bool _busy = false;
  DateTime _historyAt = DateTime(2000);

  bool get paired => key.isNotEmpty;
  bool get isAdmin => pin.isNotEmpty;
  int get outboxCount => _outbox.length + (_outboxApp == null ? 0 : 1);
  Map<String, dynamic> get settings => Map<String, dynamic>.from((state['s'] as Map?) ?? const {});
  double? get t => (state['t'] as num?)?.toDouble();
  double? get h => (state['h'] as num?)?.toDouble();
  bool get sensorOk => state['ok'] == true;
  bool get lampOn => state['lamp'] == true;
  bool get fanOn => state['fan'] == true;
  bool get hasData => state.isNotEmpty;

  /// True when the last report is too old to trust.
  bool get stale => seenAt == null || DateTime.now().difference(seenAt!) > const Duration(seconds: 90);

  double get tTarget => (settings['t_target'] as num?)?.toDouble() ?? 37.5;

  /// All batches as this phone sees them: the cloud's copy with the admin's unsent edits on top.
  List<Batch> get batches {
    final m = Map<String, Batch>.from(_cloudBatches);
    for (final o in _outbox.values) {
      final id = o['id'] as String;
      if (o['deleted'] == true) {
        m.remove(id);
      } else {
        m[id] = Batch.fromJson(id, Map<String, dynamic>.from(o['data'] as Map));
      }
    }
    return m.values.toList()..sort((a, b) => a.start.compareTo(b.start));
  }

  List<Batch> get activeBatches => batches.where((b) => b.active).toList();
  List<Batch> get endedBatches => batches.where((b) => !b.active).toList().reversed.toList();

  Map<String, dynamic> get appSettings => {...app, ...?_outboxApp};
  List<int> get turnTimes =>
      ((appSettings['turn_times'] as List?) ?? const [8, 14, 20]).map((e) => (e as num).toInt()).toList()..sort();

  (int, int) get humidityRange => humidityRangeFor(
        batches,
        (settings['h_min'] as num?)?.round() ?? 50,
        (settings['h_max'] as num?)?.round() ?? 55,
      );

  // ---- Lifecycle ---------------------------------------------------------------

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    final p = _prefs!;
    key = p.getString('key') ?? '';
    addr = p.getString('addr') ?? '';
    pin = p.getString('pin') ?? '';
    hasAdmin = p.getBool('has_admin') ?? false;
    try {
      state = Map<String, dynamic>.from(jsonDecode(p.getString('state') ?? '{}') as Map);
      _setBatches(jsonDecode(p.getString('batches') ?? '[]'));
      app = Map<String, dynamic>.from(jsonDecode(p.getString('app') ?? '{}') as Map);
      final ob = jsonDecode(p.getString('outbox') ?? '{}') as Map;
      _outbox = {for (final e in ob.entries) e.key as String: Map<String, dynamic>.from(e.value as Map)};
      final oa = p.getString('outbox_app');
      _outboxApp = oa == null ? null : Map<String, dynamic>.from(jsonDecode(oa) as Map);
    } catch (_) {}
    loaded = true;
    notifyListeners();
    if (paired) start();
  }

  void start() {
    _timer?.cancel();
    _ticks = 0;
    refresh();
    // Every 3 s on the home Wi-Fi; every 12 s through the cloud.
    _timer = Timer.periodic(const Duration(seconds: 3), (_) {
      _ticks++;
      if (link == Link.local || _ticks % 4 == 0) refresh();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _save() {
    final p = _prefs;
    if (p == null) return;
    p.setString('key', key);
    p.setString('addr', addr);
    p.setString('state', jsonEncode(state));
    p.setString('pin', pin);
    p.setBool('has_admin', hasAdmin);
    p.setString('batches', jsonEncode([
      for (final b in _cloudBatches.values) {'id': b.id, 'data': b.toJson()}
    ]));
    p.setString('app', jsonEncode(app));
    p.setString('outbox', jsonEncode(_outbox));
    if (_outboxApp == null) {
      p.remove('outbox_app');
    } else {
      p.setString('outbox_app', jsonEncode(_outboxApp));
    }
  }

  Future<void> refresh() async {
    if (_busy || !paired) return;
    _busy = true;
    try {
      final local = addr.isNotEmpty && await _refreshLocal();
      // The cloud also carries batches, so ask it every few rounds even when the ESP32 answers.
      final cloud = (!local || _ticks % 10 == 0) && await _refreshCloud(updateState: !local);
      link = local ? Link.local : (cloud ? Link.cloud : Link.offline);
      if (cloud) await flush();
      if (DateTime.now().difference(_historyAt) > const Duration(minutes: 5)) await loadHistory();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  // ---- Local (home Wi-Fi) ---------------------------------------------------------

  Future<bool> _refreshLocal() async {
    final j = await probe(addr);
    if (j == null || j['key'] != key) return false;
    state = j;
    seenAt = DateTime.now();
    pending = false;
    _save();
    return true;
  }

  // ---- Cloud -------------------------------------------------------------------------

  Future<bool> _refreshCloud({bool updateState = true}) async {
    try {
      final j = await rpc('incubator_get', {'p_key': key});
      cloudOk = j is Map;
      if (j is! Map) return false;
      if (updateState) {
        state = Map<String, dynamic>.from(j['state'] as Map);
        // Age is measured on the server's clock so a wrong phone clock does not matter.
        final seen = DateTime.tryParse('${j['seen_at']}');
        final now = DateTime.tryParse('${j['now']}');
        seenAt = seen != null && now != null ? DateTime.now().subtract(now.difference(seen)) : null;
        pending = j['pending'] == true;
        _setHistory(j['history']);
      }
      hasAdmin = j['has_admin'] == true;
      _setBatches(j['batches']);
      app = Map<String, dynamic>.from((j['app'] as Map?) ?? const {});
      appUpdated = (j['app_updated'] as num?)?.toInt() ?? 0;
      final ip = state['ip'];
      if (ip is String && ip.isNotEmpty && ip != addr) addr = ip; // try it directly next time
      _save();
      return true;
    } catch (_) {
      cloudOk = false;
      return false;
    }
  }

  void _setBatches(Object? rows) {
    if (rows is! List) return;
    _cloudBatches = {
      for (final r in rows)
        if (r is Map && r['id'] is String && r['data'] is Map)
          r['id'] as String: Batch.fromJson(r['id'] as String, Map<String, dynamic>.from(r['data'] as Map)),
    };
  }

  void _setHistory(Object? rows) {
    if (rows is! List) return;
    history = [
      for (final r in rows)
        if (r is Map && r['t'] != null && r['h'] != null)
          Reading(DateTime.fromMillisecondsSinceEpoch((r['at'] as num).toInt() * 1000), (r['t'] as num).toDouble(),
              (r['h'] as num).toDouble()),
    ];
    _historyAt = DateTime.now();
  }

  /// 24 h chart data: the cloud keeps real timestamps; the ESP32 keeps its own copy for local-only use.
  Future<void> loadHistory() async {
    try {
      final j = await rpc('incubator_get', {'p_key': key});
      if (j is Map && (j['history'] as List?)?.isNotEmpty == true) {
        _setHistory(j['history']);
        return;
      }
    } catch (_) {}
    if (addr.isEmpty) return;
    try {
      final r = await http.get(Uri.parse('http://$addr/api/history')).timeout(const Duration(seconds: 3));
      final j = jsonDecode(r.body) as Map;
      final ts = (j['t'] as List).cast<num>(), hs = (j['h'] as List).cast<num>();
      final step = (j['step'] as num).toInt();
      final now = DateTime.now();
      history = [
        for (var i = 0; i < ts.length; i++)
          Reading(now.subtract(Duration(seconds: step * (ts.length - 1 - i))), ts[i].toDouble(), hs[i].toDouble()),
      ];
      _historyAt = now;
    } catch (_) {}
  }

  // ---- Admin -------------------------------------------------------------------------

  /// Checks a PIN with the cloud and remembers it on this phone.
  Future<void> adminLogin(String p) async {
    final String res;
    try {
      res = await rpc('incubator_check_pin', {'p_key': key, 'p_pin': p}) as String;
    } on AdminError {
      rethrow;
    } catch (_) {
      throw AdminError('offline');
    }
    if (res == 'none') {
      hasAdmin = false;
      throw AdminError('none');
    }
    if (res != 'ok') throw AdminError(res);
    pin = p;
    hasAdmin = true;
    _save();
    notifyListeners();
  }

  /// First admin (no PIN yet) or PIN change.
  Future<void> setPin(String newPin) async {
    final String res;
    try {
      res = await rpc('incubator_set_pin', {'p_key': key, 'p_old': pin, 'p_new': newPin}) as String;
    } catch (_) {
      throw AdminError('offline');
    }
    if (res != 'ok') throw AdminError(res);
    pin = newPin;
    hasAdmin = true;
    _save();
    notifyListeners();
  }

  void adminLogout() {
    pin = '';
    _save();
    notifyListeners();
  }

  void _dropAdmin() {
    pin = '';
    _save();
  }

  // ---- Changes (admin) ----------------------------------------------------------------

  /// Changes the ESP32's settings (lamp/fan mode, targets). Returns false when it cannot be reached.
  Future<bool> setSettings(Map<String, dynamic> patch) async {
    final before = Map<String, dynamic>.from(state);
    state = {...state, 's': {...settings, ...patch}};
    notifyListeners();
    try {
      if (link == Link.local) {
        final r = await http
            .post(Uri.parse('http://$addr/api/settings'),
                headers: {'Content-Type': 'application/json'}, body: jsonEncode(patch))
            .timeout(const Duration(seconds: 4));
        if (r.statusCode == 200) {
          state = jsonDecode(r.body) as Map<String, dynamic>;
          _save();
          notifyListeners();
          return true;
        }
      }
      await rpc('incubator_admin_command', {'p_key': key, 'p_pin': pin, 'p_patch': patch});
      pending = true;
      _save();
      notifyListeners();
      return true;
    } on AdminError {
      _dropAdmin();
      state = before;
      notifyListeners();
      return false;
    } catch (_) {
      state = before;
      notifyListeners();
      return false;
    }
  }

  /// Saves a batch (new or edited). It is shown right away and sent when the cloud is reachable.
  void saveBatch(Batch b) {
    _outbox[b.id] = {'id': b.id, 'data': b.toJson(), 'updated': nowMs(), 'deleted': false};
    _save();
    notifyListeners();
    flush();
  }

  void deleteBatch(String id) {
    _outbox[id] = {'id': id, 'data': <String, dynamic>{}, 'updated': nowMs(), 'deleted': true};
    _save();
    notifyListeners();
    flush();
  }

  /// "Eggs turned" for every running batch that is not in lockdown.
  void markTurned() {
    final now = nowSec();
    for (final b in activeBatches.where((b) => !b.inLockdown)) {
      saveBatch(b.copy()..turned = now);
    }
  }

  void setTurnTimes(List<int> hours) {
    _outboxApp = {...appSettings, 'turn_times': hours..sort()};
    _save();
    notifyListeners();
    flush();
  }

  bool _flushing = false;

  /// Sends the outbox to the cloud. Items edited again while sending stay queued.
  Future<void> flush() async {
    if (_flushing || outboxCount == 0 || !isAdmin) return;
    _flushing = true;
    final sent = Map<String, Map<String, dynamic>>.from(_outbox);
    final sentApp = _outboxApp;
    final appTime = nowMs();
    try {
      await rpc('incubator_sync', {
        'p_key': key,
        'p_pin': pin,
        'p_batches': sent.values.toList(),
        'p_app': sentApp,
        'p_app_updated': appTime,
      });
      for (final e in sent.entries) {
        final o = e.value;
        if (identical(_outbox[e.key], o)) {
          _outbox.remove(e.key);
          if (o['deleted'] == true) {
            _cloudBatches.remove(e.key);
          } else {
            _cloudBatches[e.key] = Batch.fromJson(e.key, Map<String, dynamic>.from(o['data'] as Map));
          }
        }
      }
      if (sentApp != null && identical(_outboxApp, sentApp)) {
        app = sentApp;
        appUpdated = appTime;
        _outboxApp = null;
      }
      _save();
    } on AdminError {
      _dropAdmin(); // PIN changed on another phone: log in again; the outbox is kept
    } catch (_) {
      // offline: try again on the next refresh
    } finally {
      _flushing = false;
      notifyListeners();
    }
  }

  // ---- Pairing ---------------------------------------------------------------------

  /// Looks for an incubator: its own setup Wi-Fi, its name on the network, the last known address,
  /// then every address on the phone's Wi-Fi network. Returns the host and its state.
  static Future<(String, Map<String, dynamic>)?> discover(String lastAddr) async {
    for (final host in ['192.168.4.1', 'incubator.local', if (lastAddr.isNotEmpty) lastAddr]) {
      final j = await probe(host, timeout: const Duration(seconds: 3));
      if (j != null) return (host, j);
    }
    final prefixes = <String>{};
    try {
      for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        for (final a in ni.addresses) {
          final p = a.address.split('.');
          if (!a.isLoopback && p.length == 4 && _isPrivate(p)) prefixes.add('${p[0]}.${p[1]}.${p[2]}');
        }
      }
    } catch (_) {}
    for (final prefix in prefixes) {
      for (var start = 1; start < 255; start += 64) {
        final batch = [for (var i = start; i < start + 64 && i < 255; i++) '$prefix.$i'];
        final results = await Future.wait(
            // The incubator can be busy for a few seconds while it reports to the cloud.
            batch.map((h) async => (h, await probe(h, timeout: const Duration(seconds: 4)))));
        for (final (h, j) in results) {
          if (j != null) return (h, j);
        }
      }
    }
    return null;
  }

  static bool _isPrivate(List<String> p) {
    final a = int.tryParse(p[0]) ?? 0, b = int.tryParse(p[1]) ?? 0;
    return a == 10 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31);
  }

  /// Tells an incubator in setup mode (its own Wi-Fi) which home Wi-Fi to join.
  static Future<bool> sendWifi(String host, String ssid, String pass) async {
    try {
      final r = await http
          .post(Uri.parse('http://$host/api/wifi'),
              headers: {'Content-Type': 'application/json'}, body: jsonEncode({'ssid': ssid, 'pass': pass}))
          .timeout(const Duration(seconds: 5));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  void pair(String newKey, {String host = '', Map<String, dynamic>? found}) {
    key = newKey.trim();
    addr = host == '192.168.4.1' ? '' : host; // the setup address goes away once it joins the home Wi-Fi
    state = found ?? {};
    seenAt = found != null ? DateTime.now() : null;
    history = [];
    _historyAt = DateTime(2000);
    _save();
    notifyListeners();
    start();
  }

  void forget() {
    _timer?.cancel();
    key = '';
    addr = '';
    state = {};
    history = [];
    seenAt = null;
    pin = '';
    hasAdmin = false;
    _cloudBatches = {};
    _outbox = {};
    _outboxApp = null;
    app = {};
    link = Link.offline;
    for (final k in ['key', 'addr', 'state', 'pin', 'has_admin', 'batches', 'app', 'outbox', 'outbox_app']) {
      _prefs?.remove(k);
    }
    notifyListeners();
  }
}
