import 'package:flutter/material.dart';

import 'device.dart';
import 'main.dart';
import 'strings.dart';

/// First run: find the incubator on the Wi-Fi (or its own setup Wi-Fi), or type its key.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  bool _searching = false;
  String? _message;
  // Set when the phone is on the incubator's own Wi-Fi: it still needs the home Wi-Fi.
  (String, Map<String, dynamic>)? _setupDevice;
  final _ssid = TextEditingController();
  final _pass = TextEditingController();

  Future<void> _find() async {
    setState(() {
      _searching = true;
      _message = null;
    });
    final found = await Incubator.discover(incubator.addr);
    if (!mounted) return;
    setState(() => _searching = false);
    if (found == null) {
      setState(() => _message = tr('not_found'));
      return;
    }
    final (host, state) = found;
    if (host == '192.168.4.1' && (state['ip'] as String? ?? '').isEmpty) {
      setState(() => _setupDevice = found);
    } else {
      incubator.pair(state['key'] as String, host: host, found: state);
    }
  }

  Future<void> _sendWifi() async {
    final (host, state) = _setupDevice!;
    if (_ssid.text.trim().isEmpty) return;
    setState(() => _searching = true);
    final ok = await Incubator.sendWifi(host, _ssid.text.trim(), _pass.text);
    if (!mounted) return;
    setState(() => _searching = false);
    if (ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('wifi_sent')), duration: const Duration(seconds: 8)));
      // The key is all we need; the address comes from the cloud once it is online.
      incubator.pair(state['key'] as String);
    } else {
      setState(() => _message = tr('not_reachable'));
    }
  }

  Future<void> _ask(String title, void Function(String) onDone) async {
    final c = TextEditingController();
    final v = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(controller: c, autofocus: true, textDirection: TextDirection.ltr),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, c.text.trim()), child: Text(tr('connect'))),
        ],
      ),
    );
    if (v != null && v.isNotEmpty) onDone(v);
  }

  Future<void> _byAddress(String host) async {
    setState(() => _searching = true);
    final found = await Incubator.discover(host);
    if (!mounted) return;
    setState(() => _searching = false);
    if (found == null) {
      setState(() => _message = tr('not_found'));
    } else {
      incubator.pair(found.$2['key'] as String, host: found.$1, found: found.$2);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(actions: [
        TextButton(
          onPressed: () => lang.value = lang.isAr ? 'en' : 'ar',
          child: Text(lang.isAr ? 'English' : 'العربية'),
        ),
      ]),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
        children: [
          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: const Image(image: AssetImage('assets/icon.png'), width: 112, height: 112),
            ),
          ),
          const SizedBox(height: 20),
          Text(tr('setup_title'), textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
          const SizedBox(height: 24),
          if (_setupDevice == null) ...[
            _Step(1, tr('setup_step1')),
            _Step(2, tr('setup_step2')),
            _Step(3, tr('setup_step3')),
            const SizedBox(height: 8),
            Text(tr('setup_mobile_data'), style: theme.textTheme.bodySmall),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _searching ? null : _find,
              icon: _searching
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.search),
              label: Text(_searching ? tr('searching') : tr('find')),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            ),
          ] else ...[
            Text(tr('wifi_found_ap'), style: theme.textTheme.bodyLarge),
            const SizedBox(height: 16),
            TextField(controller: _ssid, decoration: InputDecoration(labelText: tr('wifi_name'))),
            const SizedBox(height: 12),
            TextField(
                controller: _pass, obscureText: true, decoration: InputDecoration(labelText: tr('wifi_pass'))),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _searching ? null : _sendWifi,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              child: Text(tr('connect')),
            ),
          ],
          if (_message != null) ...[
            const SizedBox(height: 16),
            Text(_message!, textAlign: TextAlign.center, style: TextStyle(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: 24),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            TextButton(
                onPressed: _searching ? null : () => _ask(tr('enter_addr'), _byAddress), child: Text(tr('enter_addr'))),
            TextButton(
              onPressed: () => _ask(tr('enter_key'), (k) {
                if (k.length >= 16) incubator.pair(k);
              }),
              child: Text(tr('enter_key')),
            ),
          ]),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step(this.n, this.text);
  final int n;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          CircleAvatar(radius: 13, child: Text('$n', style: const TextStyle(fontSize: 13))),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyLarge)),
        ]),
      );
}
