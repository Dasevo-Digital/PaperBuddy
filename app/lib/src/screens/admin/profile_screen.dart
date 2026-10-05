import 'package:flutter/material.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../../app_state.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/text_menus.dart';

/// Eigenen Namen, E-Mail und Passwort ändern.
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
      setState(() => _error = 'Die Passwörter stimmen nicht überein');
      return;
    }
    if (_password.text.isNotEmpty && _password.text.length < 8) {
      setState(() => _error = 'Das Passwort braucht mindestens 8 Zeichen');
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
      showInfo(context, 'Profil gespeichert');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profil')),
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
                          decoration: const InputDecoration(
                            labelText: 'Vorname',
                          ),
                        ),
                        TextField(
                          controller: _last,
                          decoration: const InputDecoration(
                            labelText: 'Nachname',
                          ),
                        ),
                        TextField(
                          controller: _email,
                          keyboardType: TextInputType.emailAddress,
                          decoration: const InputDecoration(
                            labelText: 'E-Mail',
                          ),
                        ),
                        const Divider(),
                        TextField(
                          controller: _password,
                          obscureText: true,
                          contextMenuBuilder: passwordContextMenu,
                          decoration: const InputDecoration(
                            labelText: 'Neues Passwort',
                            helperText: 'Leer lassen, um es zu behalten',
                          ),
                        ),
                        TextField(
                          controller: _repeat,
                          obscureText: true,
                          contextMenuBuilder: passwordContextMenu,
                          decoration: const InputDecoration(
                            labelText: 'Passwort wiederholen',
                          ),
                        ),
                        FilledButton(
                          onPressed: _saving ? null : _save,
                          child: const Text('Speichern'),
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
