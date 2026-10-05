// Modelle für Verwaltung, Freigaben und Automatisierung.

int? _int(Object? v) => v is int ? v : (v is String ? int.tryParse(v) : null);
List<int> _ints(Object? v) =>
    v is List ? [for (final e in v) ?_int(e)] : const [];
List<String> _strings(Object? v) =>
    v is List ? [for (final e in v) '$e'] : const [];

/// Art eines Labels, mit API-Pfad und Rechte-Modell.
enum LabelKind {
  tag('tags', 'tag', 'Tag', 'Tags'),
  correspondent(
    'correspondents',
    'correspondent',
    'Korrespondent',
    'Korrespondenten',
  ),
  documentType(
    'document_types',
    'documenttype',
    'Dokumenttyp',
    'Dokumenttypen',
  ),
  storagePath('storage_paths', 'storagepath', 'Speicherpfad', 'Speicherpfade');

  const LabelKind(this.path, this.model, this.singular, this.plural);
  final String path;
  final String model;
  final String singular;
  final String plural;
}

/// Zuordnungsalgorithmen (Werte wie in Paperless-ngx).
enum MatchingAlgorithm {
  none(0, 'Keine'),
  any(1, 'Eines der Wörter'),
  all(2, 'Alle Wörter'),
  literal(3, 'Genauer Ausdruck'),
  regex(4, 'Regulärer Ausdruck'),
  fuzzy(5, 'Ungefähr'),
  auto(6, 'Automatisch (lernend)');

  const MatchingAlgorithm(this.value, this.label);
  final int value;
  final String label;

  static MatchingAlgorithm of(int v) =>
      values.firstWhere((m) => m.value == v, orElse: () => none);
}

/// Freigaben eines Objekts.
class ObjectPermissions {
  ObjectPermissions({
    Set<int>? viewUsers,
    Set<int>? viewGroups,
    Set<int>? changeUsers,
    Set<int>? changeGroups,
  }) : viewUsers = viewUsers ?? {},
       viewGroups = viewGroups ?? {},
       changeUsers = changeUsers ?? {},
       changeGroups = changeGroups ?? {};

  final Set<int> viewUsers;
  final Set<int> viewGroups;
  final Set<int> changeUsers;
  final Set<int> changeGroups;

  bool get isEmpty =>
      viewUsers.isEmpty &&
      viewGroups.isEmpty &&
      changeUsers.isEmpty &&
      changeGroups.isEmpty;

  factory ObjectPermissions.fromJson(Map<String, dynamic>? j) {
    Map? bucket(String k) => j?[k] as Map?;
    return ObjectPermissions(
      viewUsers: _ints(bucket('view')?['users']).toSet(),
      viewGroups: _ints(bucket('view')?['groups']).toSet(),
      changeUsers: _ints(bucket('change')?['users']).toSet(),
      changeGroups: _ints(bucket('change')?['groups']).toSet(),
    );
  }

  Map<String, dynamic> toJson() => {
    'view': {'users': viewUsers.toList(), 'groups': viewGroups.toList()},
    'change': {'users': changeUsers.toList(), 'groups': changeGroups.toList()},
  };
}

class AppUser {
  const AppUser({
    required this.id,
    required this.username,
    this.email = '',
    this.firstName = '',
    this.lastName = '',
    this.isActive = true,
    this.isStaff = false,
    this.isSuperuser = false,
    this.groups = const [],
    this.permissions = const [],
    this.inheritedPermissions = const [],
  });

  final int id;
  final String username;
  final String email;
  final String firstName;
  final String lastName;
  final bool isActive;
  final bool isStaff;
  final bool isSuperuser;
  final List<int> groups;
  final List<String> permissions;
  final List<String> inheritedPermissions;

  String get displayName {
    final n = '$firstName $lastName'.trim();
    return n.isEmpty ? username : n;
  }

  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser(
    id: j['id'] as int,
    username: j['username'] as String? ?? '',
    email: j['email'] as String? ?? '',
    firstName: j['first_name'] as String? ?? '',
    lastName: j['last_name'] as String? ?? '',
    isActive: j['is_active'] as bool? ?? true,
    isStaff: j['is_staff'] as bool? ?? false,
    isSuperuser: j['is_superuser'] as bool? ?? false,
    groups: _ints(j['groups']),
    permissions: _strings(j['user_permissions']),
    inheritedPermissions: _strings(j['inherited_permissions']),
  );
}

class UserGroup {
  const UserGroup({
    required this.id,
    required this.name,
    this.permissions = const [],
  });
  final int id;
  final String name;
  final List<String> permissions;

  factory UserGroup.fromJson(Map<String, dynamic> j) => UserGroup(
    id: j['id'] as int,
    name: j['name'] as String? ?? '',
    permissions: _strings(j['permissions']),
  );
}

/// Datentypen der Custom Fields.
enum CustomFieldType {
  string('string', 'Text'),
  longtext('longtext', 'Langer Text'),
  url('url', 'Link'),
  date('date', 'Datum'),
  boolean('boolean', 'Ja/Nein'),
  integer('integer', 'Ganzzahl'),
  float('float', 'Zahl'),
  monetary('monetary', 'Geldbetrag'),
  documentlink('documentlink', 'Dokumentverweis'),
  select('select', 'Auswahl');

  const CustomFieldType(this.value, this.label);
  final String value;
  final String label;

  static CustomFieldType of(String v) =>
      values.firstWhere((t) => t.value == v, orElse: () => string);
}

class SelectOption {
  const SelectOption(this.id, this.label);
  final String id;
  final String label;
}

class CustomField {
  const CustomField({
    required this.id,
    required this.name,
    required this.type,
    this.options = const [],
    this.defaultCurrency,
    this.documentCount = 0,
  });

  final int id;
  final String name;
  final CustomFieldType type;
  final List<SelectOption> options;
  final String? defaultCurrency;
  final int documentCount;

  factory CustomField.fromJson(Map<String, dynamic> j) {
    final extra = (j['extra_data'] as Map?) ?? const {};
    final raw = extra['select_options'] as List? ?? const [];
    return CustomField(
      id: j['id'] as int,
      name: j['name'] as String? ?? '',
      type: CustomFieldType.of(j['data_type'] as String? ?? 'string'),
      options: [
        for (final (i, o) in raw.indexed)
          if (o is Map)
            SelectOption('${o['id']}', '${o['label']}')
          else
            SelectOption('$i', '$o'),
      ],
      defaultCurrency: extra['default_currency'] as String?,
      documentCount: j['document_count'] as int? ?? 0,
    );
  }
}

class FilterRule {
  const FilterRule(this.type, this.value);
  final int type;
  final String? value;

  Map<String, dynamic> toJson() => {'rule_type': type, 'value': value};
  factory FilterRule.fromJson(Map<String, dynamic> j) =>
      FilterRule(_int(j['rule_type']) ?? -1, j['value']?.toString());
}

class SavedView {
  const SavedView({
    required this.id,
    required this.name,
    this.showOnDashboard = false,
    this.showInSidebar = false,
    this.sortField,
    this.sortReverse = false,
    this.rules = const [],
    this.owner,
    this.userCanChange = true,
  });

  final int id;
  final String name;
  final bool showOnDashboard;
  final bool showInSidebar;
  final String? sortField;
  final bool sortReverse;
  final List<FilterRule> rules;
  final int? owner;
  final bool userCanChange;

  factory SavedView.fromJson(Map<String, dynamic> j) => SavedView(
    id: j['id'] as int,
    name: j['name'] as String? ?? '',
    showOnDashboard: j['show_on_dashboard'] as bool? ?? false,
    showInSidebar: j['show_in_sidebar'] as bool? ?? false,
    sortField: j['sort_field'] as String?,
    sortReverse: j['sort_reverse'] as bool? ?? false,
    rules: [
      for (final r in j['filter_rules'] as List? ?? const [])
        if (r is Map<String, dynamic>) FilterRule.fromJson(r),
    ],
    owner: _int(j['owner']),
    userCanChange: j['user_can_change'] as bool? ?? true,
  );
}

/// Workflow mit Auslösern und Aktionen im JSON der API; die App bearbeitet
/// die Felder direkt, damit nichts verloren geht, was sie nicht kennt.
class Workflow {
  Workflow({
    this.id,
    required this.name,
    this.order = 0,
    this.enabled = true,
    List<Map<String, dynamic>>? triggers,
    List<Map<String, dynamic>>? actions,
  }) : triggers = triggers ?? [],
       actions = actions ?? [];

  final int? id;
  String name;
  int order;
  bool enabled;
  final List<Map<String, dynamic>> triggers;
  final List<Map<String, dynamic>> actions;

  factory Workflow.fromJson(Map<String, dynamic> j) => Workflow(
    id: j['id'] as int?,
    name: j['name'] as String? ?? '',
    order: j['order'] as int? ?? 0,
    enabled: j['enabled'] as bool? ?? true,
    triggers: [
      for (final t in j['triggers'] as List? ?? const [])
        Map<String, dynamic>.from(t as Map),
    ],
    actions: [
      for (final a in j['actions'] as List? ?? const [])
        Map<String, dynamic>.from(a as Map),
    ],
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'order': order,
    'enabled': enabled,
    'triggers': triggers,
    'actions': actions,
  };
}

class MailAccount {
  const MailAccount({
    this.id,
    required this.name,
    required this.imapServer,
    this.imapPort,
    this.imapSecurity = 2,
    required this.username,
    this.characterSet = 'UTF-8',
  });

  final int? id;
  final String name;
  final String imapServer;
  final int? imapPort;

  /// 1 = keine, 2 = SSL, 3 = STARTTLS
  final int imapSecurity;
  final String username;
  final String characterSet;

  factory MailAccount.fromJson(Map<String, dynamic> j) => MailAccount(
    id: j['id'] as int?,
    name: j['name'] as String? ?? '',
    imapServer: j['imap_server'] as String? ?? '',
    imapPort: _int(j['imap_port']),
    imapSecurity: _int(j['imap_security']) ?? 2,
    username: j['username'] as String? ?? '',
    characterSet: j['character_set'] as String? ?? 'UTF-8',
  );

  Map<String, dynamic> toJson({String? password}) => {
    'name': name,
    'imap_server': imapServer,
    'imap_port': imapPort,
    'imap_security': imapSecurity,
    'username': username,
    'character_set': characterSet,
    'password': ?password,
  };
}

/// Mailregel als JSON (viele Felder, siehe Paperless-ngx).
class MailRule {
  MailRule(this.json);
  final Map<String, dynamic> json;

  int? get id => json['id'] as int?;
  String get name => json['name'] as String? ?? '';
  int? get account => _int(json['account']);
  bool get enabled => json['enabled'] as bool? ?? true;
}

class ScannerInfo {
  const ScannerInfo({
    required this.id,
    required this.name,
    required this.url,
    required this.discovered,
  });
  final String id;
  final String name;
  final String url;
  final bool discovered;

  factory ScannerInfo.fromJson(Map<String, dynamic> j) => ScannerInfo(
    id: '${j['id']}',
    name: '${j['name']}',
    url: '${j['url']}',
    discovered: j['source'] == 'discovered',
  );
}

class ScannerCapabilities {
  const ScannerCapabilities({
    this.makeAndModel = '',
    this.sources = const [],
    this.colorModes = const [],
    this.resolutions = const [],
    this.duplex = false,
  });

  final String makeAndModel;
  final List<String> sources;
  final List<String> colorModes;
  final List<int> resolutions;
  final bool duplex;

  factory ScannerCapabilities.fromJson(Map<String, dynamic> j) =>
      ScannerCapabilities(
        makeAndModel: j['make_and_model'] as String? ?? '',
        sources: _strings(j['sources']),
        colorModes: _strings(j['color_modes']),
        resolutions: _ints(j['resolutions']),
        duplex: j['duplex'] as bool? ?? false,
      );
}

class Profile {
  const Profile({
    this.email = '',
    this.firstName = '',
    this.lastName = '',
    this.hasUsablePassword = true,
  });
  final String email;
  final String firstName;
  final String lastName;
  final bool hasUsablePassword;

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
    email: j['email'] as String? ?? '',
    firstName: j['first_name'] as String? ?? '',
    lastName: j['last_name'] as String? ?? '',
    hasUsablePassword: j['has_usable_password'] as bool? ?? true,
  );
}
