import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_state.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/label_pickers.dart';
import '../../widgets/text_menus.dart';
import '../../l10n.dart';

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
    if (!ok) return showError(context, tr.couldNotOpenTheBrowser);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr.signInInBrowser),
        content: Text(
          tr.signInInBrowserHint,
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr.done),
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
        n == 0 ? tr.noNewAttachments : tr.fileSImported(n),
      );
      AppScope.read(context).notifyDocumentsChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr.emailImport)),
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
                  title: Text(tr.accounts, style: theme.textTheme.titleMedium),
                  trailing: TextButton.icon(
                    onPressed: () => _editAccount(),
                    icon: const Icon(LucideIcons.plus),
                    label: Text(tr.account),
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
                            label: Text(tr.connectWithGoogle),
                          ),
                        if (_oauth?.outlook case final url?)
                          OutlinedButton.icon(
                            onPressed: () => _connect(url),
                            icon: const Icon(LucideIcons.mail),
                            label: Text(tr.connectWithMicrosoft),
                          ),
                      ],
                    ),
                  ),
                if (accounts.isEmpty)
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      tr.paperbuddyCanFetchAttachmentsFrom,
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
                      tooltip: tr.fetchNow,
                      icon: const Icon(LucideIcons.refreshCw),
                      onPressed: () => _process(a),
                    ),
                  ),
                const Divider(),
                ListTile(
                  title: Text(tr.rules, style: theme.textTheme.titleMedium),
                  trailing: TextButton.icon(
                    onPressed: accounts.isEmpty
                        ? null
                        : () => _editRule(accounts),
                    icon: const Icon(LucideIcons.plus),
                    label: Text(tr.rule),
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
                          tr.from(r.json['filter_from']),
                        if ('${r.json['filter_subject'] ?? ''}'.isNotEmpty)
                          tr.subjectQuoted(r.json['filter_subject']),
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
        _message = tr.connectionSuccessfulFolders(folders.join(', '));
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
      setState(() => _message = tr.nameServerAndUserAre);
      return;
    }
    if (widget.account == null && _password.text.isEmpty) {
      setState(() => _message = tr.pleaseEnterThePassword);
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
      title: tr.deleteAccount,
      message: tr.itsRulesWillBeDeleted,
      action: tr.delete,
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
          widget.account == null ? tr.createMailAccount : widget.account!.name,
        ),
        actions: [
          if (widget.account != null)
            IconButton(
              tooltip: tr.delete,
              icon: const Icon(LucideIcons.trash2),
              onPressed: _delete,
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _busy ? null : _save,
              child: Text(tr.save),
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
                    decoration: InputDecoration(
                      labelText: tr.name,
                      hintText: tr.personal,
                    ),
                  ),
                  TextField(
                    controller: _server,
                    decoration: InputDecoration(
                      labelText: tr.imapServer,
                      hintText: 'imap.example.org',
                    ),
                  ),
                  Row(
                    spacing: 12,
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          initialValue: _security,
                          decoration: InputDecoration(
                            labelText: tr.encryption,
                          ),
                          items: [
                            DropdownMenuItem(value: 2, child: Text('SSL/TLS')),
                            DropdownMenuItem(value: 3, child: Text('STARTTLS')),
                            DropdownMenuItem(value: 1, child: Text(tr.none)),
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
                            labelText: tr.port,
                            hintText: _security == 2 ? '993' : '143',
                          ),
                        ),
                      ),
                    ],
                  ),
                  TextField(
                    controller: _user,
                    decoration: InputDecoration(
                      labelText: tr.username,
                    ),
                  ),
                  if (widget.account?.isOAuth ?? false)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(LucideIcons.keyRound),
                      title: Text(tr.signedInViaOauth),
                      subtitle: Text(
                        tr.toRenewReconnectTheAccount,
                      ),
                    )
                  else
                    TextField(
                      controller: _password,
                      obscureText: true,
                      contextMenuBuilder: passwordContextMenu,
                      decoration: InputDecoration(
                        labelText: tr.password,
                        helperText: widget.account == null
                            ? tr.withManyProvidersAnApp
                            : tr.leaveEmptyToKeepIt,
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
                    label: Text(tr.testConnection),
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
      setState(() => _error = tr.pleaseEnterAName);
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
      title: tr.deleteRule,
      action: tr.delete,
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
          widget.rule == null ? tr.createMailRule : widget.rule!.name,
        ),
        actions: [
          if (widget.rule != null)
            IconButton(
              tooltip: tr.delete,
              icon: const Icon(LucideIcons.trash2),
              onPressed: _delete,
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(tr.save),
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
                  _field('name', tr.name),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(tr.active),
                    value: _r['enabled'] != false,
                    onChanged: (v) => _set('enabled', v),
                  ),
                  DropdownButtonFormField<int>(
                    initialValue: _r['account'] as int?,
                    decoration: InputDecoration(labelText: tr.account),
                    items: [
                      for (final a in widget.accounts)
                        DropdownMenuItem(value: a.id, child: Text(a.name)),
                    ],
                    onChanged: (v) => _set('account', v),
                  ),
                  _field('folder', tr.folder, hint: 'INBOX'),
                  Text(tr.filter, style: theme.textTheme.titleMedium),
                  _field('filter_from', tr.senderContains),
                  _field('filter_subject', tr.subjectContains),
                  _field('filter_body', tr.bodyContains),
                  _field(
                    'filter_attachment_filename_include',
                    tr.attachmentFileName,
                    hint: '*.pdf',
                  ),
                  _field(
                    'maximum_age',
                    tr.atMostDaysOld,
                    type: TextInputType.number,
                  ),
                  Text(tr.processing, style: theme.textTheme.titleMedium),
                  DropdownButtonFormField<int>(
                    initialValue: _r['consumption_scope'] as int? ?? 1,
                    decoration: InputDecoration(labelText: tr.mailConsume),
                    items: [
                      DropdownMenuItem(value: 1, child: Text(tr.attachmentsOnly)),
                      DropdownMenuItem(
                        value: 2,
                        child: Text(tr.onlyTheEmailItselfAs),
                      ),
                      DropdownMenuItem(
                        value: 3,
                        child: Text(tr.emailAndAttachments),
                      ),
                    ],
                    onChanged: (v) => _set('consumption_scope', v),
                  ),
                  DropdownButtonFormField<int>(
                    initialValue: _r['attachment_type'] as int? ?? 1,
                    decoration: InputDecoration(labelText: tr.attachments),
                    items: [
                      DropdownMenuItem(
                        value: 1,
                        child: Text(tr.realAttachmentsOnly),
                      ),
                      DropdownMenuItem(
                        value: 2,
                        child: Text(tr.embeddedFilesToo),
                      ),
                    ],
                    onChanged: (v) => _set('attachment_type', v),
                  ),
                  DropdownButtonFormField<int>(
                    initialValue: action,
                    decoration: InputDecoration(labelText: tr.afterwards),
                    items: [
                      DropdownMenuItem(
                        value: 3,
                        child: Text(tr.markAsRead),
                      ),
                      DropdownMenuItem(
                        value: 4,
                        child: Text(tr.flag),
                      ),
                      DropdownMenuItem(
                        value: 2,
                        child: Text(tr.moveToFolder),
                      ),
                      DropdownMenuItem(
                        value: 5,
                        child: Text(tr.setKeyword),
                      ),
                      DropdownMenuItem(value: 1, child: Text(tr.delete)),
                    ],
                    onChanged: (v) => _set('action', v),
                  ),
                  if (action == 2 || action == 5)
                    _field(
                      'action_parameter',
                      action == 2 ? tr.targetFolder : tr.keyword,
                      hint: action == 2 ? tr.archive : 'paperbuddy',
                    ),
                  Text(tr.assign, style: theme.textTheme.titleMedium),
                  DropdownButtonFormField<int>(
                    initialValue: _r['assign_title_from'] as int? ?? 1,
                    decoration: InputDecoration(labelText: tr.titleFrom),
                    items: [
                      DropdownMenuItem(value: 1, child: Text(tr.subject)),
                      DropdownMenuItem(value: 2, child: Text(tr.fileName)),
                      DropdownMenuItem(value: 3, child: Text(tr.automatic)),
                    ],
                    onChanged: (v) => _set('assign_title_from', v),
                  ),
                  DropdownButtonFormField<int>(
                    initialValue: _r['assign_correspondent_from'] as int? ?? 1,
                    decoration: InputDecoration(
                      labelText: tr.correspondent,
                    ),
                    items: [
                      DropdownMenuItem(value: 1, child: Text(tr.automatic)),
                      DropdownMenuItem(
                        value: 2,
                        child: Text(tr.senderAddress),
                      ),
                      DropdownMenuItem(value: 3, child: Text(tr.senderName)),
                      DropdownMenuItem(value: 4, child: Text(tr.fixed)),
                    ],
                    onChanged: (v) => _set('assign_correspondent_from', v),
                  ),
                  if (_r['assign_correspondent_from'] == 4)
                    LabelField<Correspondent>(
                      label: tr.correspondent,
                      icon: LucideIcons.user,
                      options: state.correspondents,
                      value: _r['assign_correspondent'] as int?,
                      onChanged: (v) => _set('assign_correspondent', v),
                    ),
                  LabelField<DocumentType>(
                    label: tr.documentType,
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
