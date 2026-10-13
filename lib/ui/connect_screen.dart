import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'common.dart';

class ConnectScreen extends StatefulWidget {
  /// When true the screen was opened from settings to change the site.
  final bool fromSettings;
  const ConnectScreen({super.key, this.fromSettings = false});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  late final TextEditingController _url;
  late final TextEditingController _token;
  bool _apiSecret = false;
  bool _mmol = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: app.settings.str('nsUrl'));
    _token = TextEditingController(text: app.settings.str('nsToken'));
    _apiSecret = app.settings.flag('apiSecret');
    _mmol = app.settings.mmol;
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (_url.text.trim().isEmpty) {
      setState(() => _error = 'Enter your Nightscout address');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final name = await app.connect(_url.text, _token.text, _apiSecret, _mmol);
      if (!mounted) return;
      toast(context, 'Connected to $name');
      if (widget.fromSettings) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.fromSettings ? AppBar(title: const Text('Nightscout site')) : null,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
          children: [
            if (!widget.fromSettings) ...[
              Container(
                width: 56,
                height: 56,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: const Color(0xFF12303D), borderRadius: BorderRadius.circular(16)),
                child: const Icon(Icons.water_drop_outlined, color: kAccent, size: 30),
              ),
              const SizedBox(height: 16),
              const Text('Connect your data', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              const Text(
                'Enter the address of your Nightscout site. The app reads glucose, treatments and loop status from it.',
                style: TextStyle(color: kMuted, height: 1.45),
              ),
              const SizedBox(height: 24),
            ],
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Site address', hintText: 'https://my-site.example.com'),
            ),
            const SizedBox(height: 16),
            Seg(
              options: const ['Access token', 'API secret'],
              index: _apiSecret ? 1 : 0,
              onChanged: (i) => setState(() => _apiSecret = i == 1),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _token,
              autocorrect: false,
              obscureText: true,
              decoration: InputDecoration(
                labelText: _apiSecret ? 'API secret' : 'Access token',
                helperText: _apiSecret
                    ? 'Full access. A token with the careportal role is safer.'
                    : 'In Nightscout: Admin tools › Subjects. Use "readable", or "careportal" to log treatments.',
                helperMaxLines: 3,
              ),
            ),
            const SizedBox(height: 20),
            const Text('Units', style: TextStyle(color: kMuted, fontSize: 13)),
            const SizedBox(height: 8),
            Seg(options: const ['mmol/L', 'mg/dL'], index: _mmol ? 0 : 1, onChanged: (i) => setState(() => _mmol = i == 0)),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, style: const TextStyle(color: Color(0xFFFF6B76))),
            ],
            const SizedBox(height: 28),
            const Text(
              'For information only. Do not make treatment decisions from this app without checking your meter or sensor.',
              style: TextStyle(color: kMuted, fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 52,
              child: FilledButton(
                onPressed: _busy ? null : _connect,
                child: _busy
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Test and connect', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
