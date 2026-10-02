import 'dart:async';
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
///
/// The camera **stops the moment a code is read**. It used to keep reading the same square
/// many times a second: while the host was being dialled nothing on screen changed, and
/// when that failed the next frame started another attempt and wiped the error before
/// anybody could read it — so a scan looked like it did nothing at all.
class PairScreen extends StatefulWidget {
  const PairScreen({super.key, required this.onPaired});

  final void Function(Config config) onPaired;

  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> {
  final _scanner = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  bool _manual = false;
  bool _busy = false;
  /// Set once a square has been read, until it succeeds or the person asks to scan again.
  bool _scanned = false;
  String? _trying;
  String? _error;
  final _codeField = TextEditingController();
  final _urlField = TextEditingController(text: 'http://');

  @override
  void dispose() {
    unawaited(_scanner.dispose());
    _codeField.dispose();
    _urlField.dispose();
    super.dispose();
  }

  /// `http://localhost:4700` reaches this phone, not the host PC.
  static bool _pointsAtItself(Uri uri) {
    final h = uri.host.toLowerCase();
    return h == 'localhost' || h == '::1' || h.startsWith('127.');
  }

  Future<void> _submit(String rawUrl, String code) async {
    if (_busy) return;
    final baseUrl = rawUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(baseUrl);

    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      setState(() => _error = 'That is not a host address. It should look like http://192.168.1.50:4700.');
      return;
    }
    if (_pointsAtItself(uri)) {
      setState(() => _error =
          'This code points at "${uri.host}", which on a phone means the phone itself. '
          'On the host PC, open FacilityFlow using its network address — Admin → Host PC '
          'shows it — and make a fresh pairing code there. Or type the address here instead.');
      return;
    }

    setState(() { _busy = true; _error = null; _trying = baseUrl; });
    try {
      final name = '${Platform.operatingSystem} phone';
      final result = await Api.pair(baseUrl: baseUrl, code: code, deviceName: name);
      final user = result['user'] as Map<String, dynamic>;
      final property = result['property'] as Map<String, dynamic>;
      final config = Config(
        baseUrl: baseUrl,
        token: result['token'] as String,
        displayName: user['displayName'] as String? ?? '',
        roleName: user['roleName'] as String? ?? '',
        propertyName: property['shortName'] as String? ?? '',
        deviceId: result['deviceId'] as String? ?? '',
        userId: user['id'] as String? ?? '',
      );
      await config.save();
      if (mounted) widget.onPaired(config);
    } on TimeoutException {
      _fail('Could not reach $baseUrl. Is this phone on the property wifi — the same '
          'network as the host PC? Mobile data cannot reach it.');
    } on SocketException {
      _fail('Could not reach $baseUrl. Is this phone on the property wifi, and is the '
          'host PC switched on?');
    } catch (e) {
      _fail(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() { _error = message; _busy = false; _trying = null; });
  }

  void _onScan(BarcodeCapture capture) {
    if (_busy || _scanned) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;
      Map<String, dynamic> payload;
      try {
        payload = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        // Some other QR code happened to be in shot. Keep scanning rather than shouting.
        continue;
      }
      final url = payload['url'] as String?;
      final code = payload['code'] as String?;
      if (url == null || code == null) continue;

      // Got one. Stop the camera so it cannot start a second attempt over the first.
      setState(() => _scanned = true);
      unawaited(_scanner.stop());
      // Fill the manual fields too, so a failure can be corrected by hand rather than
      // starting over.
      _urlField.text = url;
      _codeField.text = code;
      unawaited(_submit(url, code));
      return;
    }
  }

  Future<void> _scanAgain() async {
    setState(() { _scanned = false; _error = null; });
    await _scanner.start();
  }

  Widget _scannerView() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _scanner,
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
          if (_scanned)
            Container(
              color: Colors.black.withValues(alpha: 0.78),
              alignment: Alignment.center,
              padding: const EdgeInsets.all(22),
              child: _busy
                  ? Column(mainAxisSize: MainAxisSize.min, children: [
                      const CircularProgressIndicator(color: Colors.white),
                      const SizedBox(height: 16),
                      const Text('Code read. Pairing…',
                          style: TextStyle(color: Colors.white, fontSize: 16,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      Text(_trying ?? '',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70)),
                    ])
                  : Column(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.error_outline, color: Colors.white, size: 40),
                      const SizedBox(height: 12),
                      const Text('That did not pair.',
                          style: TextStyle(color: Colors.white, fontSize: 16,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      const Text('The reason is above.',
                          style: TextStyle(color: Colors.white70)),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _scanAgain,
                        icon: const Icon(Icons.qr_code_scanner),
                        label: const Text('Scan again'),
                      ),
                    ]),
            ),
          if (!_scanned)
            // A frame to aim at. Without one people hold the phone at arm's length and
            // the square is too small to read.
            Center(
              child: Container(
                width: 230,
                height: 230,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white, width: 3),
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
        ],
      ),
    );
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
              'Sign in to FacilityFlow in a browser, open "Ring my phone", and scan the '
              'square it shows you. Use the PC\'s network address, not "localhost".',
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
              Expanded(child: _scannerView())
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
                        : () => _submit(_urlField.text, _codeField.text.trim()),
                    child: Text(_busy ? 'Pairing…' : 'Pair this phone'),
                  ),
                ],
              ),
            const SizedBox(height: 14),
            TextButton(
              onPressed: _busy
                  ? null
                  // The scanner widget starts the camera when it appears and stops it
                  // when it goes, so switching modes only has to swap the widget.
                  : () => setState(() {
                        _manual = !_manual;
                        _scanned = false;
                        _error = null;
                      }),
              child: Text(_manual ? 'Scan the square instead' : 'Type the code instead'),
            ),
          ],
        ),
      ),
    );
  }
}
