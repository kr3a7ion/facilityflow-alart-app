import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'api.dart';
import 'config.dart';

/// One scan, and the phone is somebody's.
///
/// The square carries the host address and the identity together, because the step that
/// loses people is typing `http://192.168.1.50:4700` into a phone keyboard. Manual entry
/// is kept as the fallback for a cracked camera or a scan that will not take, not as the
/// main road.
class PairScreen extends StatefulWidget {
  const PairScreen({super.key, required this.onPaired});

  final void Function(Config config) onPaired;

  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> {
  bool _manual = false;
  bool _busy = false;
  String? _error;
  final _codeField = TextEditingController();
  final _urlField = TextEditingController(text: 'http://');

  @override
  void dispose() {
    _codeField.dispose();
    _urlField.dispose();
    super.dispose();
  }

  Future<void> _submit(String baseUrl, String code) async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      final name = '${Platform.operatingSystem} phone';
      final result = await Api.pair(
        baseUrl: baseUrl.replaceAll(RegExp(r'/+$'), ''),
        code: code,
        deviceName: name,
      );
      final user = result['user'] as Map<String, dynamic>;
      final property = result['property'] as Map<String, dynamic>;
      final config = Config(
        baseUrl: baseUrl.replaceAll(RegExp(r'/+$'), ''),
        token: result['token'] as String,
        displayName: user['displayName'] as String? ?? '',
        roleName: user['roleName'] as String? ?? '',
        propertyName: property['shortName'] as String? ?? '',
        deviceId: result['deviceId'] as String? ?? '',
      );
      await config.save();
      if (mounted) widget.onPaired(config);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceFirst('Exception: ', '');
          _busy = false;
        });
      }
    }
  }

  void _onScan(BarcodeCapture capture) {
    if (_busy) return;
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null) return;
    try {
      final payload = jsonDecode(raw) as Map<String, dynamic>;
      final url = payload['url'] as String?;
      final code = payload['code'] as String?;
      if (url == null || code == null) return;
      _submit(url, code);
    } catch (_) {
      // Some other QR code happened to be in shot. Keep scanning rather than shouting.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Set up alerts')),
      body: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Sign in to FacilityFlow on a computer or in your browser, open '
              '"Ring my phone", and scan the square it shows you.',
              style: TextStyle(fontSize: 15, height: 1.45),
            ),
            const SizedBox(height: 16),
            if (_error != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0x22D32F2F),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_error!, style: const TextStyle(height: 1.4)),
              ),
              const SizedBox(height: 14),
            ],
            if (!_manual)
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: MobileScanner(
                    onDetect: _onScan,
                    // A camera that will not start should say so, not sit there black.
                    errorBuilder: (context, error) => Container(
                      color: Colors.black,
                      alignment: Alignment.center,
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        error.errorCode == MobileScannerErrorCode.permissionDenied
                            ? 'Camera permission is off. Allow it in Settings → Apps → '
                                'FacilityFlow Alerts, or type the code instead.'
                            : 'The camera would not start (${error.errorCode.name}). '
                                'Type the code instead.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white, height: 1.4),
                      ),
                    ),
                  ),
                ),
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _urlField,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Host address',
                      helperText: 'The address on the notice board, e.g. http://192.168.1.50:4700',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _codeField,
                    textCapitalization: TextCapitalization.characters,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Pairing code',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 14),
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _submit(_urlField.text.trim(), _codeField.text.trim()),
                    child: Text(_busy ? 'Pairing…' : 'Pair this phone'),
                  ),
                ],
              ),
            const SizedBox(height: 14),
            TextButton(
              onPressed: _busy ? null : () => setState(() => _manual = !_manual),
              child: Text(_manual ? 'Scan the square instead' : 'Type the code instead'),
            ),
          ],
        ),
      ),
    );
  }
}
