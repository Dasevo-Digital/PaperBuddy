import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_state.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/label_pickers.dart';
import '../../widgets/text_menus.dart';

class MailScreen extends StatefulWidget {
  const MailScreen({super.key});

  @override
  State<MailScreen> createState() => _MailScreenState();
}

class _MailScreenState extends State<MailScreen> {
  late Future<(List<MailAccount>, List<MailRule>)> _data;
  ({String? gmail, String? outlook})? _oauth;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final c = AppScope.read(context).client;
    _data = (c.mailAccounts(), c.mailRules()).wait;
    c.mailOAuthUrls().then((u) {
      if (mounted) setState(() => _oauth = u);
    }, onError: (_) {});
  }

  /// OAuth-Anmeldung im Browser; danach Liste neu laden.
  Future<void> _connect(String url) async {
    final ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!mounted) return;
    if (!ok) return showError(context, 'Browser konnte nicht geöffnet werden');
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Im Browser anmelden'),
        content: const Text(
          'Melde dich im Browser an und erlaube den Zugriff. Danach hier auf „Fertig“ tippen.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Fertig'),
          ),
        ],
      ),
    );
    if (mounted) setState(_reload);
  }

  Future<void> _editAccount([MailAccount? a]) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => MailAccountScreen(account: a)),
    );
    if (saved == true && mounted) setState(_reload);
  }

  Future<void> _editRule(List<MailAccount> accounts, [MailRule? r]) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => MailRuleScreen(rule: r, accounts: accounts),
      ),
    );
    if (saved == true && mounted) setState(_reload);
  }

  Future<void> _process(MailAccount a) async {
    final n = await guarded(
      context,
      () => AppScope.read(context).client.processMailAccount(a.id!),
    );
    if (n != null && mounted) {
      showInfo(
        context,
        n == 0 ? 'Keine neuen Anhänge' : '$n Datei(en) übernommen',
      );
      AppScope.read(context).notifyDocumentsChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('E-Mail-Abruf')),
      body: FutureBuilder<(List<MailAccount>, List<MailRule>)>(
        future: _data,
        builder: (context, snap) {
          if (snap.hasError) {
            return EmptyHint(icon: LucideIcons.cloudOff, text: '${snap.error}');
          }
          final data = snap.data;
          if (data == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final (accounts, rules) = data;
          return RefreshIndicator(
            onRefresh: () async => setState(_reload),
            child: ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                ListTile(
                  title: Text('Konten', style: theme.textTheme.titleMedium),
                  trailing: TextButton.icon(
                    onPressed: () => _editAccount(),
                    icon: const Icon(LucideIcons.plus),
                    label: const Text('Konto'),
                  ),
                ),
                if (_oauth?.gmail != null || _oauth?.outlook != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (_oauth?.gmail case final url?)
                          OutlinedButton.icon(
                            onPressed: () => _connect(url),
                            icon: const Icon(LucideIcons.mail),
                            label: const Text('Mit Google verbinden'),
                          ),
                        if (_oauth?.outlook case final url?)
                          OutlinedButton.icon(
                            onPressed: () => _connect(url),
                            icon: const Icon(LucideIcons.mail),
                            label: const Text('Mit Microsoft verbinden'),
                          ),
                      ],
                    ),
                  ),
                if (accounts.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'PaperBuddy kann Anhänge aus einem Postfach abholen, z. B. Rechnungen, die per Mail kommen.',
                    ),
                  ),
                for (final a in accounts)
                  ListTile(
                    leading: const Icon(LucideIcons.mail),
                    title: Text(a.name),
                    subtitle: Text(
                      a.isOAuth
                          ? '${a.username} · ${a.accountType == 2 ? 'Google' : 'Microsoft'} (OAuth)'
                          : '${a.username} @ ${a.imapServer}',
                    ),
                    onTap: () => _editAccount(a),
                    trailing: IconButton(
                      tooltip: 'Jetzt abrufen',
                      icon: const Icon(LucideIcons.refreshCw),
                      onPressed: () => _process(a),
                    ),
                  ),
                const Divider(),
                ListTile(
                  title: Text('Regeln', style: theme.textTheme.titleMedium),
                  trailing: TextButton.icon(
                    onPressed: accounts.isEmpty
                        ? null
                        : () => _editRule(accounts),
                    icon: const Icon(LucideIcons.plus),
                    label: const Text('Regel'),
                  ),
                ),
                for (final r in rules)
                  ListTile(
                    leading: Icon(
                      r.enabled ? LucideIcons.filter : LucideIcons.filterX,
                    ),
                    title: Text(r.name),
                    subtitle: Text(
                      [
                        accounts
                                .where((a) => a.id == r.account)
                                .firstOrNull
                                ?.name ??
                            '',
                        '${r.json['folder'] ?? 'INBOX'}',
                        if ('${r.json['filter_from'] ?? ''}'.isNotEmpty)
                          'von ${r.json['filter_from']}',
                        if ('${r.json['filter_subject'] ?? ''}'.isNotEmpty)
                          'Betreff „${r.json['filter_subject']}“',
                      ].where((s) => s.isNotEmpty).join(' · '),
                    ),
                    onTap: () => _editRule(accounts, r),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class MailAccountScreen extends StatefulWidget {
  const MailAccountScreen({super.key, this.account});
  final MailAccount? account;

  @override
  State<MailAccountScreen> createState() => _MailAccountScreenState();
}

class _MailAccountScreenState extends State<MailAccountScreen> {
  late final _name = TextEditingController(text: widget.account?.name ?? '');
  late final _server = TextEditingController(
    text: widget.account?.imapServer ?? '',
  );
  late final _port = TextEditingController(
    text: widget.account?.imapPort?.toString() ?? '',
  );
  late final _user = TextEditingController(
    text: widget.account?.username ?? '',
  );
  final _password = TextEditingController();
  late int _security = widget.account?.imapSecurity ?? 2;
  bool _busy = false;
  String? _message;
  bool _ok = false;

  @override
  void dispose() {
    for (final c in [_name, _server, _port, _user, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  MailAccount get _account => MailAccount(
    id: widget.account?.id,
    name: _name.text.trim(),
    imapServer: _server.text.trim(),
    imapPort: int.tryParse(_port.text.trim()),
    imapSecurity: _security,
    username: _user.text.trim(),
  );

  String? get _passwordOrNull => _password.text.isEmpty ? null : _password.text;

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final folders = await AppScope.read(
        context,
      ).client.testMailAccount(_account, password: _passwordOrNull);
      setState(() {
        _ok = true;
        _message = 'Verbindung erfolgreich. Ordner: ${folders.join(', ')}';
      });
    } on ApiException catch (e) {
      setState(() {
        _ok = false;
        _message = e.message;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty ||
        _server.text.trim().isEmpty ||
        _user.text.trim().isEmpty) {
      setState(() => _message = 'Name, Server und Benutzer sind nötig');
      return;
    }
    if (widget.account == null && _password.text.isEmpty) {
      setState(() => _message = 'Bitte das Passwort angeben');
      return;
    }
    setState(() => _busy = true);
    final saved = await guarded(
      context,
      () => AppScope.read(
        context,
      ).client.saveMailAccount(_account, password: _passwordOrNull),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (saved != null) Navigator.pop(context, true);
  }

  Future<void> _delete() async {
    final ok = await confirm(
      context,
      title: 'Konto löschen?',
      message: 'Zugehörige Regeln werden ebenfalls gelöscht.',
      action: 'Löschen',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final done = await guarded(
      context,
      () => AppScope.read(
        context,
      ).client.deleteMailAccount(widget.account!.id!).then((_) => true),
    );
    if (done == true && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.account == null ? 'Mailkonto anlegen' : widget.account!.name,
        ),
        actions: [
          if (widget.account != null)
            IconButton(
              tooltip: 'Löschen',
              icon: const Icon(LucideIcons.trash2),
              onPressed: _delete,
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _busy ? null : _save,
              child: const Text('Speichern'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 16,
                children: [
                  TextField(
                    controller: _name,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      hintText: 'Privat',
                    ),
                  ),
                  TextField(
                    controller: _server,
                    decoration: const InputDecoration(
                      labelText: 'IMAP-Server',
                      hintText: 'imap.example.org',
                    ),
                  ),
                  Row(
                    spacing: 12,
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          initialValue: _security,
                          decoration: const InputDecoration(
                            labelText: 'Verschlüsselung',
                          ),
                          items: const [
                            DropdownMenuItem(value: 2, child: Text('SSL/TLS')),
                            DropdownMenuItem(value: 3, child: Text('STARTTLS')),
                            DropdownMenuItem(value: 1, child: Text('Keine')),
                          ],
                          onChanged: (v) => setState(() => _security = v ?? 2),
                        ),
                      ),
                      SizedBox(
                        width: 120,
                        child: TextField(
                          controller: _port,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: 'Port',
                            hintText: _security == 2 ? '993' : '143',
                          ),
                        ),
                      ),
                    ],
                  ),
                  TextField(
                    controller: _user,
                    decoration: const InputDecoration(
                      labelText: 'Benutzername',
                    ),
                  ),
                  if (widget.account?.isOAuth ?? false)
                    const ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(LucideIcons.keyRound),
                      title: Text('Angemeldet über OAuth'),
                      subtitle: Text(
                        'Zum Erneuern das Konto über „Mit Google/Microsoft verbinden“ neu verbinden.',
                      ),
                    )
                  else
                    TextField(
                      controller: _password,
                      obscureText: true,
                      contextMenuBuilder: passwordContextMenu,
                      decoration: InputDecoration(
                        labelText: 'Passwort',
                        helperText: widget.account == null
                            ? 'Bei vielen Anbietern ein App-Passwort'
                            : 'Leer lassen, um es zu behalten',
                      ),
                    ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _test,
                    icon: _busy
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(LucideIcons.plugZap),
                    label: const Text('Verbindung testen'),
                  ),
                  if (_message != null)
                    Text(
                      _message!,
                      style: TextStyle(
                        color: _ok ? scheme.primary : scheme.error,
                      ),
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

class MailRuleScreen extends StatefulWidget {
  const MailRuleScreen({super.key, this.rule, required this.accounts});
  final MailRule? rule;
  final List<MailAccount> accounts;

  @override
  State<MailRuleScreen> createState() => _MailRuleScreenState();
}

class _MailRuleScreenState extends State<MailRuleScreen> {
  late final Map<String, dynamic> _r = {
    'name': '',
    'account': widget.accounts.first.id,
    'folder': 'INBOX',
    'maximum_age': 30,
    'action': 3,
    'assign_title_from': 1,
    'assign_correspondent_from': 1,
    'attachment_type': 1,
    'consumption_scope': 1,
    'assign_tags': <int>[],
    'enabled': true,
    ...?widget.rule?.json,
  };
  bool _saving = false;
  String? _error;

  void _set(String key, Object? value) => setState(() => _r[key] = value);

  Widget _field(
    String key,
    String label, {
    String? hint,
    TextInputType? type,
  }) => TextFormField(
    initialValue: _r[key]?.toString() ?? '',
    keyboardType: type,
    decoration: InputDecoration(labelText: label, hintText: hint),
    onChanged: (v) => _r[key] = type == TextInputType.number
        ? int.tryParse(v)
        : (v.isEmpty ? null : v),
  );

  Future<void> _save() async {
    if ('${_r['name'] ?? ''}'.trim().isEmpty) {
      setState(() => _error = 'Bitte einen Namen angeben');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await AppScope.read(context).client.saveMailRule(MailRule(_r));
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final ok = await confirm(
      context,
      title: 'Regel löschen?',
      action: 'Löschen',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final done = await guarded(
      context,
      () => AppScope.read(
        context,
      ).client.deleteMailRule(widget.rule!.id!).then((_) => true),
    );
    if (done == true && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final action = _r['action'] as int? ?? 3;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.rule == null ? 'Mailregel anlegen' : widget.rule!.name,
        ),
        actions: [
          if (widget.rule != null)
            IconButton(
              tooltip: 'Löschen',
              icon: const Icon(LucideIcons.trash2),
              onPressed: _delete,
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: const Text('Speichern'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 16,
                children: [
                  if (_error != null)
                    Text(
                      _error!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  _field('name', 'Name'),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Aktiv'),
                    value: _r['enabled'] != false,
                    onChanged: (v) => _set('enabled', v),
                  ),
                  DropdownButtonFormField<int>(
                    initialValue: _r['account'] as int?,
                    decoration: const InputDecoration(labelText: 'Konto'),
                    items: [
                      for (final a in widget.accounts)
                        DropdownMenuItem(value: a.id, child: Text(a.name)),
                    ],
                    onChanged: (v) => _set('account', v),
                  ),
                  _field('folder', 'Ordner', hint: 'INBOX'),
                  Text('Filter', style: theme.textTheme.titleMedium),
                  _field('filter_from', 'Absender enthält'),
                  _field('filter_subject', 'Betreff enthält'),
                  _field('filter_body', 'Text enthält'),
                  _field(
                    'filter_attachment_filename_include',
                    'Anhang-Dateiname',
                    hint: '*.pdf',
                  ),
                  _field(
                    'maximum_age',
                    'Höchstens … Tage alt',
                    type: TextInputType.number,
                  ),
                  Text('Verarbeitung', style: theme.textTheme.titleMedium),
                  DropdownButtonFormField<int>(
                    initialValue: _r['consumption_scope'] as int? ?? 1,
                    decoration: const InputDecoration(labelText: 'Übernehmen'),
                    items: const [
                      DropdownMenuItem(value: 1, child: Text('Nur Anhänge')),
                      DropdownMenuItem(
                        value: 2,
                        child: Text('Nur die Mail selbst (als Text)'),
                      ),
                      DropdownMenuItem(
                        value: 3,
                        child: Text('Mail und Anhänge'),
                      ),
                    ],
                    onChanged: (v) => _set('consumption_scope', v),
                  ),
                  DropdownButtonFormField<int>(
                    initialValue: _r['attachment_type'] as int? ?? 1,
                    decoration: const InputDecoration(labelText: 'Anhänge'),
                    items: const [
                      DropdownMenuItem(
                        value: 1,
                        child: Text('Nur echte Anhänge'),
                      ),
                      DropdownMenuItem(
                        value: 2,
                        child: Text('Auch eingebettete Dateien'),
                      ),
                    ],
                    onChanged: (v) => _set('attachment_type', v),
                  ),
                  DropdownButtonFormField<int>(
                    initialValue: action,
                    decoration: const InputDecoration(labelText: 'Danach'),
                    items: const [
                      DropdownMenuItem(
                        value: 3,
                        child: Text('Als gelesen markieren'),
                      ),
                      DropdownMenuItem(
                        value: 4,
                        child: Text('Markieren (Flagge)'),
                      ),
                      DropdownMenuItem(
                        value: 2,
                        child: Text('In Ordner verschieben'),
                      ),
                      DropdownMenuItem(
                        value: 5,
                        child: Text('Schlagwort setzen'),
                      ),
                      DropdownMenuItem(value: 1, child: Text('Löschen')),
                    ],
                    onChanged: (v) => _set('action', v),
                  ),
                  if (action == 2 || action == 5)
                    _field(
                      'action_parameter',
                      action == 2 ? 'Zielordner' : 'Schlagwort',
                      hint: action == 2 ? 'Archiv' : 'paperbuddy',
                    ),
                  Text('Zuweisen', style: theme.textTheme.titleMedium),
                  DropdownButtonFormField<int>(
                    initialValue: _r['assign_title_from'] as int? ?? 1,
                    decoration: const InputDecoration(labelText: 'Titel aus'),
                    items: const [
                      DropdownMenuItem(value: 1, child: Text('Betreff')),
                      DropdownMenuItem(value: 2, child: Text('Dateiname')),
                      DropdownMenuItem(value: 3, child: Text('Automatisch')),
                    ],
                    onChanged: (v) => _set('assign_title_from', v),
                  ),
                  DropdownButtonFormField<int>(
                    initialValue: _r['assign_correspondent_from'] as int? ?? 1,
                    decoration: const InputDecoration(
                      labelText: 'Korrespondent',
                    ),
                    items: const [
                      DropdownMenuItem(value: 1, child: Text('Automatisch')),
                      DropdownMenuItem(
                        value: 2,
                        child: Text('Absenderadresse'),
                      ),
                      DropdownMenuItem(value: 3, child: Text('Absendername')),
                      DropdownMenuItem(value: 4, child: Text('Fest gewählt')),
                    ],
                    onChanged: (v) => _set('assign_correspondent_from', v),
                  ),
                  if (_r['assign_correspondent_from'] == 4)
                    LabelField<Correspondent>(
                      label: 'Korrespondent',
                      icon: LucideIcons.user,
                      options: state.correspondents,
                      value: _r['assign_correspondent'] as int?,
                      onChanged: (v) => _set('assign_correspondent', v),
                    ),
                  LabelField<DocumentType>(
                    label: 'Dokumenttyp',
                    icon: LucideIcons.fileType,
                    options: state.documentTypes,
                    value: _r['assign_document_type'] as int?,
                    onChanged: (v) => _set('assign_document_type', v),
                  ),
                  TagsField(
                    tags: state.tags,
                    selected: {
                      for (final t in (_r['assign_tags'] as List? ?? const []))
                        t as int,
                    },
                    onChanged: (v) => _set('assign_tags', v.toList()),
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
