import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../../app_state.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/text_menus.dart';
import '../../widgets/totp_setup.dart';
import '../../l10n.dart';

/// Eigenen Namen, E-Mail und Passwort ändern, Zwei-Faktor-Anmeldung.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _first = TextEditingController();
  final _last = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _repeat = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  bool _mfa = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    AppScope.read(context).client.profile().then(
      (p) {
        if (!mounted) return;
        setState(() {
          _first.text = p.firstName;
          _last.text = p.lastName;
          _email.text = p.email;
          _mfa = p.isMfaEnabled;
          _loading = false;
        });
      },
      onError: (Object e) {
        if (mounted) {
          setState(() => _error = e is ApiException ? e.message : '$e');
        }
      },
    );
  }

  @override
  void dispose() {
    for (final c in [_first, _last, _email, _password, _repeat]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_password.text.isNotEmpty && _password.text != _repeat.text) {
      setState(() => _error = tr.thePasswordsDoNotMatch);
      return;
    }
    if (_password.text.isNotEmpty && _password.text.length < 8) {
      setState(() => _error = tr.thePasswordNeedsAtLeast);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final ok = await guarded(
      context,
      () => AppScope.read(context).client.updateProfile({
        'first_name': _first.text.trim(),
        'last_name': _last.text.trim(),
        'email': _email.text.trim(),
        if (_password.text.isNotEmpty) 'password': _password.text,
      }),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok != null) {
      _password.clear();
      _repeat.clear();
      showInfo(context, tr.profileSaved);
    }
  }

  Future<void> _enableMfa() async {
    final ok = await showTotpSetup(context, AppScope.read(context).client);
    if (ok && mounted) setState(() => _mfa = true);
  }

  Future<void> _disableMfa() async {
    final client = AppScope.read(context).client;
    if (!await confirm(
      context,
      title: tr.turnOffTwoFactorAuthentication,
      message:
          tr.afterThatThePasswordAlone,
      action: tr.turnOff,
      destructive: true,
    )) {
      return;
    }
    if (!mounted) return;
    final ok = await guarded(context, () async {
      await client.deactivateTotp();
      return true;
    });
    if (ok == true && mounted) {
      setState(() => _mfa = false);
      showInfo(context, tr.twoFactorAuthenticationTurnedOff);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr.profile)),
      body: _loading && _error == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: 16,
                      children: [
                        if (_error != null)
                          Text(
                            _error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        TextField(
                          controller: _first,
                          decoration: InputDecoration(
                            labelText: tr.firstName,
                          ),
                        ),
                        TextField(
                          controller: _last,
                          decoration: InputDecoration(
                            labelText: tr.lastName,
                          ),
                        ),
                        TextField(
                          controller: _email,
                          keyboardType: TextInputType.emailAddress,
                          decoration: InputDecoration(
                            labelText: tr.email,
                          ),
                        ),
                        const Divider(),
                        TextField(
                          controller: _password,
                          obscureText: true,
                          contextMenuBuilder: passwordContextMenu,
                          decoration: InputDecoration(
                            labelText: tr.newPassword,
                            helperText: tr.leaveEmptyToKeepIt,
                          ),
                        ),
                        TextField(
                          controller: _repeat,
                          obscureText: true,
                          contextMenuBuilder: passwordContextMenu,
                          decoration: InputDecoration(
                            labelText: tr.repeatPassword,
                          ),
                        ),
                        FilledButton(
                          onPressed: _saving ? null : _save,
                          child: Text(tr.save),
                        ),
                        const Divider(),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            _mfa ? LucideIcons.shieldCheck : LucideIcons.shield,
                            color: _mfa
                                ? Theme.of(context).colorScheme.primary
                                : null,
                          ),
                          title: Text(tr.twoFactorAuthentication),
                          subtitle: Text(
                            _mfa
                                ? tr.activeSigningInAlsoRequires
                                : tr.offACodeFromAn,
                          ),
                        ),
                        if (_mfa)
                          OutlinedButton.icon(
                            onPressed: _disableMfa,
                            icon: const Icon(LucideIcons.shieldOff),
                            label: Text(tr.turnOff),
                          )
                        else
                          FilledButton.tonalIcon(
                            onPressed: _enableMfa,
                            icon: const Icon(LucideIcons.shieldPlus),
                            label: Text(tr.setUp),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
