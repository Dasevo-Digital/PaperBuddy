import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../app_state.dart';
import '../environment.dart';
import '../widgets/text_menus.dart';
import 'offline_screen.dart';

/// Anmeldung an einem PaperBuddy- oder Paperless-ngx-Server.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _server;
  late final TextEditingController _username;
  final _password = TextEditingController();
  final _code = TextEditingController();
  final _codeFocus = FocusNode();

  /// Der Server hat einen zweiten Faktor verlangt.
  bool _needsCode = false;
  bool _busy = false;
  bool _showPassword = false;
  bool _hasSavedSession = false;

  /// Offline gespeicherte Dokumente vom letzten Server.
  int _offlineCount = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    final state = AppScope.read(context);
    _server = TextEditingController(text: state.store.lastServer ?? '');
    _username = TextEditingController(text: state.store.lastUsername ?? '');
    _error = state.restoreError;
    state.hasSavedSession.then((v) {
      if (mounted) setState(() => _hasSavedSession = v);
    });
    state.offlineCache().then((cache) async {
      final n = (await cache?.offlineDocuments())?.length ?? 0;
      if (mounted) setState(() => _offlineCount = n);
    });
  }

  @override
  void dispose() {
    _server.dispose();
    _username.dispose();
    _password.dispose();
    _code.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  /// Anderer Server oder Benutzer: wieder ohne Code anfangen.
  void _resetCode() {
    if (_needsCode) setState(() => _needsCode = false);
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AppScope.read(context).login(
        _server.text,
        _username.text.trim(),
        _password.text,
        code: _needsCode ? _code.text : null,
      );
    } on MfaRequiredException catch (e) {
      if (!mounted) return;
      final first = !_needsCode;
      setState(() {
        _needsCode = true;
        _error = first ? null : e.message;
      });
      _code.clear();
      _codeFocus.requestFocus();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: AutofillGroup(
                child: Form(
                  key: _form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(
                        LucideIcons.fileStack,
                        size: 56,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        AppEnv.appName,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Mit deinem PaperBuddy- oder Paperless-Server verbinden',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 32),
                      TextFormField(
                        controller: _server,
                        onChanged: (_) => _resetCode(),
                        enabled: !_busy,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.url],
                        decoration: const InputDecoration(
                          labelText: 'Server-Adresse',
                          hintText: 'z. B. nas.local:8000',
                          prefixIcon: Icon(LucideIcons.server),
                        ),
                        validator: (v) => (v ?? '').trim().isEmpty
                            ? 'Bitte Adresse angeben'
                            : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _username,
                        onChanged: (_) => _resetCode(),
                        enabled: !_busy,
                        autocorrect: false,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.username],
                        decoration: const InputDecoration(
                          labelText: 'Benutzername',
                          prefixIcon: Icon(LucideIcons.user),
                        ),
                        validator: (v) => (v ?? '').trim().isEmpty
                            ? 'Bitte Benutzernamen angeben'
                            : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _password,
                        enabled: !_busy,
                        obscureText: !_showPassword,
                        contextMenuBuilder: passwordContextMenu,
                        autofillHints: const [AutofillHints.password],
                        onFieldSubmitted: (_) => _submit(),
                        decoration: InputDecoration(
                          labelText: 'Passwort',
                          prefixIcon: const Icon(LucideIcons.keyRound),
                          suffixIcon: IconButton(
                            tooltip: _showPassword
                                ? 'Passwort verbergen'
                                : 'Passwort anzeigen',
                            icon: Icon(
                              _showPassword
                                  ? LucideIcons.eyeOff
                                  : LucideIcons.eye,
                            ),
                            onPressed: () =>
                                setState(() => _showPassword = !_showPassword),
                          ),
                        ),
                        validator: (v) =>
                            (v ?? '').isEmpty ? 'Bitte Passwort angeben' : null,
                      ),
                      if (_needsCode) ...[
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _code,
                          focusNode: _codeFocus,
                          enabled: !_busy,
                          autofillHints: const [AutofillHints.oneTimeCode],
                          keyboardType: TextInputType.visiblePassword,
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                              RegExp('[0-9A-Za-z -]'),
                            ),
                          ],
                          onFieldSubmitted: (_) => _submit(),
                          decoration: const InputDecoration(
                            labelText: 'Bestätigungscode',
                            helperText:
                                'Aus der Authenticator-App oder ein Wiederherstellungscode',
                            prefixIcon: Icon(LucideIcons.shieldCheck),
                          ),
                          validator: (v) => (v ?? '').trim().isEmpty
                              ? 'Bitte den Code eingeben'
                              : null,
                        ),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 16),
                        _ErrorBox(message: _error!),
                      ],
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: _busy ? null : _submit,
                        icon: _busy
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(LucideIcons.logIn),
                        label: const Text('Anmelden'),
                      ),
                      if (_offlineCount > 0 && !_busy) ...[
                        const SizedBox(height: 8),
                        TextButton.icon(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const OfflineScreen(),
                            ),
                          ),
                          icon: const Icon(LucideIcons.cloudCheck),
                          label: Text(
                            _offlineCount == 1
                                ? 'Offline-Dokument öffnen'
                                : '$_offlineCount Offline-Dokumente öffnen',
                          ),
                        ),
                      ],
                      if (_hasSavedSession && !_busy) ...[
                        const SizedBox(height: 8),
                        TextButton.icon(
                          onPressed: () =>
                              AppScope.read(context).retryRestore(),
                          icon: const Icon(LucideIcons.refreshCw),
                          label: const Text(
                            'Gespeicherte Anmeldung erneut versuchen',
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            LucideIcons.circleAlert,
            color: scheme.onErrorContainer,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}
