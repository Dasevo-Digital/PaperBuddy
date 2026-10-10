import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';
import 'package:qr/qr.dart';
import 'package:url_launcher/url_launcher.dart';

import 'dialogs.dart';
import '../l10n.dart';

/// Richtet die Zwei-Faktor-Anmeldung ein: QR-Code bzw. Schlüssel für die
/// Authenticator-App, Bestätigung mit dem ersten Code, danach die
/// Wiederherstellungscodes. Liefert `true`, wenn TOTP jetzt aktiv ist.
Future<bool> showTotpSetup(BuildContext context, PaperlessClient client) async {
  final setup = await guarded(context, client.totpSetup);
  if (setup == null || !context.mounted) return false;
  final codes = await showDialog<List<String>>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _TotpSetupDialog(client: client, setup: setup),
  );
  if (codes == null || !context.mounted) return false;
  await showRecoveryCodes(context, codes);
  return true;
}

class _TotpSetupDialog extends StatefulWidget {
  const _TotpSetupDialog({required this.client, required this.setup});
  final PaperlessClient client;
  final TotpSetup setup;

  @override
  State<_TotpSetupDialog> createState() => _TotpSetupDialogState();
}

class _TotpSetupDialogState extends State<_TotpSetupDialog> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  /// Auf dem Telefon lässt sich der eigene Bildschirm nicht scannen; dort
  /// öffnet der Link die Authenticator-App direkt.
  bool get _isPhone =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final code = _code.text.replaceAll(RegExp(r'\s'), '');
    if (code.length != 6) {
      setState(() => _error = tr.pleaseEnterTheSixDigit);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final codes = await widget.client.activateTotp(widget.setup.secret, code);
      if (mounted) Navigator.pop(context, codes);
    } on ApiException {
      if (mounted) {
        setState(() {
          _busy = false;
          _error =
              tr.theCodeDoesNotMatch;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final secret = widget.setup.secret;
    final grouped = [
      for (var i = 0; i < secret.length; i += 4)
        secret.substring(i, (i + 4).clamp(0, secret.length)),
    ].join(' ');
    return AlertDialog(
      title: Text(tr.setUpTwoFactorAuthentication),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: [
              Text(
                _isPhone
                    ? tr.totpStepOneOpen
                    : tr.totpStepOneScan,
              ),
              Center(
                child: Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(8),
                  child: SizedBox.square(
                    dimension: 200,
                    child: CustomPaint(painter: _QrPainter(widget.setup.url)),
                  ),
                ),
              ),
              if (_isPhone)
                OutlinedButton.icon(
                  onPressed: () => launchUrl(
                    Uri.parse(widget.setup.url),
                    mode: LaunchMode.externalApplication,
                  ),
                  icon: const Icon(LucideIcons.externalLink),
                  label: Text(tr.openInAuthenticatorApp),
                ),
              Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      grouped,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: tr.copyKey,
                    icon: const Icon(LucideIcons.copy),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: secret));
                      showInfo(context, tr.keyCopied);
                    },
                  ),
                ],
              ),
              Text(tr.totpStepTwo),
              TextField(
                controller: _code,
                autofocus: !_isPhone,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                autofillHints: const [AutofillHints.oneTimeCode],
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')),
                  LengthLimitingTextInputFormatter(7),
                ],
                onSubmitted: (_) => _confirm(),
                decoration: InputDecoration(
                  labelText: tr.code,
                  errorText: _error,
                  errorMaxLines: 3,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(tr.cancel),
        ),
        FilledButton(
          onPressed: _busy ? null : _confirm,
          child: Text(tr.activate),
        ),
      ],
    );
  }
}

/// Zeigt die Wiederherstellungscodes einmalig an.
Future<void> showRecoveryCodes(
  BuildContext context,
  List<String> codes,
) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (context) => AlertDialog(
    title: Text(tr.recoveryCodes),
    content: SizedBox(
      width: 400,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          Text(
            tr.twoFactorAuthenticationIsActive,
          ),
          SelectableText(
            codes.join('\n'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontFamily: 'monospace',
              height: 1.6,
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton.icon(
        onPressed: () {
          Clipboard.setData(ClipboardData(text: codes.join('\n')));
          showInfo(context, tr.codesCopied);
        },
        icon: const Icon(LucideIcons.copy),
        label: Text(tr.copy),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context),
        child: Text(tr.saved),
      ),
    ],
  ),
);

class _QrPainter extends CustomPainter {
  _QrPainter(this.data)
    : _qr = QrImage(
        QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M),
      );

  final String data;
  final QrImage _qr;

  @override
  void paint(Canvas canvas, Size size) {
    final n = _qr.moduleCount;
    final cell = size.shortestSide / n;
    final paint = Paint()..color = Colors.black;
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        if (_qr.isDark(y, x)) {
          canvas.drawRect(
            Rect.fromLTWH(x * cell, y * cell, cell + 0.5, cell + 0.5),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.data != data;
}
