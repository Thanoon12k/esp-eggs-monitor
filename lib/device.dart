import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'species.dart';

// Public values: the cloud project URL and its publishable key (same as the firmware's config.h).
const cloudUrl = 'https://axncazensmjdqpczvzwf.supabase.co';
const cloudKey = 'sb_publishable_7hGIGHFa1mcWPMI8mEZKGw_-wgkkSYT';

/// How the phone reaches the incubator right now.
enum Link { local, cloud, offline }

class Reading {
  final DateTime at;
  final double t, h;
  const Reading(this.at, this.t, this.h);
}

/// The incubator as the phone sees it: talks to the ESP32 directly on the home Wi-Fi,
/// or through the cloud when away.
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

  Timer? _timer;
  int _ticks = 0;
  bool _busy = false;
  DateTime _historyAt = DateTime(2000);

  bool get paired => key.isNotEmpty;
  Map<String, dynamic> get settings => Map<String, dynamic>.from((state['s'] as Map?) ?? const {});
  double? get t => (state['t'] as num?)?.toDouble();
  double? get h => (state['h'] as num?)?.toDouble();
  bool get sensorOk => state['ok'] == true;
  bool get lampOn => state['lamp'] == true;
  bool get fanOn => state['fan'] == true;
  bool get hasData => state.isNotEmpty;

  /// True when the last report is too old to trust.
  bool get stale => seenAt == null || DateTime.now().difference(seenAt!) > const Duration(seconds: 90);

  Species get species => speciesById(settings['species'] as String?);
  double get tTarget => (settings['t_target'] as num?)?.toDouble() ?? species.temp;
  DateTime? get startedAt => _time(settings['start']);
  DateTime? get turnedAt => _time(settings['turned']);

  /// Incubation day, 1-based; null when no batch is running.
  int? get day {
    final s = startedAt;
    if (s == null) return null;
    return DateTime.now().difference(s).inDays + 1;
  }

  bool get inLockdown => (day ?? 0) >= species.lockdownDay;

  (int, int) get humidityRange {
    if (inLockdown) return (species.lockMin, species.lockMax);
    return (
      (settings['h_min'] as num?)?.round() ?? species.hMin,
      (settings['h_max'] as num?)?.round() ?? species.hMax,
    );
  }

  static DateTime? _time(Object? v) =>
      v is num && v > 0 ? DateTime.fromMillisecondsSinceEpoch(v.toInt() * 1000) : null;

  static int nowSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  // ---- Lifecycle ---------------------------------------------------------------

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    key = _prefs!.getString('key') ?? '';
    addr = _prefs!.getString('addr') ?? '';
    try {
      state = Map<String, dynamic>.from(jsonDecode(_prefs!.getString('state') ?? '{}') as Map);
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
    _prefs?.setString('key', key);
    _prefs?.setString('addr', addr);
    _prefs?.setString('state', jsonEncode(state));
  }

  Future<void> refresh() async {
    if (_busy || !paired) return;
    _busy = true;
    try {
      if (addr.isNotEmpty && await _refreshLocal()) {
        link = Link.local;
      } else if (await _refreshCloud()) {
        link = Link.cloud;
      } else {
        link = Link.offline;
      }
      if (DateTime.now().difference(_historyAt) > const Duration(minutes: 5)) await loadHistory();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  // ---- Local (home Wi-Fi) ---------------------------------------------------------

  static Future<Map<String, dynamic>?> _probe(String host, {Duration timeout = const Duration(seconds: 2)}) async {
    try {
      final r = await http.get(Uri.parse('http://$host/api/state')).timeout(timeout);
      if (r.statusCode != 200) return null;
      final j = jsonDecode(r.body);
      if (j is Map<String, dynamic> && j['key'] is String) return j;
    } catch (_) {}
    return null;
  }

  Future<bool> _refreshLocal() async {
    final j = await _probe(addr);
    if (j == null || j['key'] != key) return false;
    state = j;
    seenAt = DateTime.now();
    pending = false;
    _save();
    return true;
  }

  // ---- Cloud -------------------------------------------------------------------------

  static Future<dynamic> _rpc(String fn, Map<String, dynamic> body) async {
    final r = await http
        .post(Uri.parse('$cloudUrl/rest/v1/rpc/$fn'),
            headers: {'apikey': cloudKey, 'Content-Type': 'application/json'}, body: jsonEncode(body))
        .timeout(const Duration(seconds: 8));
    if (r.statusCode != 200) throw HttpException('${r.statusCode} ${r.body}');
    return jsonDecode(r.body);
  }

  Future<bool> _refreshCloud() async {
    try {
      final j = await _rpc('incubator_get', {'p_key': key});
      if (j is! Map) return false;
      state = Map<String, dynamic>.from(j['state'] as Map);
      // Age is measured on the server's clock so a wrong phone clock does not matter.
      final seen = DateTime.tryParse('${j['seen_at']}');
      final now = DateTime.tryParse('${j['now']}');
      seenAt = seen != null && now != null ? DateTime.now().subtract(now.difference(seen)) : null;
      pending = j['pending'] == true;
      _setHistory(j['history']);
      final ip = state['ip'];
      if (ip is String && ip.isNotEmpty && ip != addr) addr = ip; // try it directly next time
      _save();
      return true;
    } catch (_) {
      return false;
    }
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
    if (link == Link.cloud) return; // already came with the cloud refresh
    try {
      final j = await _rpc('incubator_get', {'p_key': key});
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

  // ---- Changes ---------------------------------------------------------------------

  /// Sends a settings change. Returns false when the incubator cannot be reached at all.
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
      await _rpc('incubator_command', {'p_key': key, 'p_patch': patch});
      pending = true;
      _save();
      notifyListeners();
      return true;
    } catch (_) {
      state = before;
      notifyListeners();
      return false;
    }
  }

  // ---- Pairing ---------------------------------------------------------------------

  /// Looks for an incubator: its own setup Wi-Fi, the last known address, then every
  /// address on the phone's Wi-Fi network. Returns the host and its state.
  static Future<(String, Map<String, dynamic>)?> discover(String lastAddr) async {
    for (final host in ['192.168.4.1', if (lastAddr.isNotEmpty) lastAddr]) {
      final j = await _probe(host);
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
            batch.map((h) async => (h, await _probe(h, timeout: const Duration(milliseconds: 1500)))));
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
    link = Link.offline;
    _prefs?.remove('key');
    _prefs?.remove('addr');
    _prefs?.remove('state');
    notifyListeners();
  }
}
