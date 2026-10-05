part of 'client.dart';

/// Verwaltung, Freigaben, Papierkorb und Automatisierung.
extension PaperlessAdmin on PaperlessClient {
  Future<Map<String, dynamic>> _json(
    String method,
    String path, [
    Object? body,
  ]) async => (await _send(method, path, json: body)) as Map<String, dynamic>;

  // Labels --------------------------------------------------------------------

  Label _label(LabelKind kind, Map<String, dynamic> j) => switch (kind) {
    LabelKind.tag => Tag.fromJson(j),
    LabelKind.correspondent => Correspondent.fromJson(j),
    LabelKind.documentType => DocumentType.fromJson(j),
    LabelKind.storagePath => StoragePath.fromJson(j),
  };

  Future<List<Label>> labels(LabelKind kind) =>
      _all('/api/${kind.path}/', (j) => _label(kind, j));

  Future<Label> createLabel(LabelKind kind, Map<String, Object?> data) async =>
      _label(kind, await _json('POST', '/api/${kind.path}/', data));

  Future<Label> updateLabel(
    LabelKind kind,
    int id,
    Map<String, Object?> data,
  ) async => _label(kind, await _json('PATCH', '/api/${kind.path}/$id/', data));

  Future<void> deleteLabel(LabelKind kind, int id) =>
      _send('DELETE', '/api/${kind.path}/$id/');

  // Freigaben -----------------------------------------------------------------

  Future<ObjectPermissions> documentPermissions(int id) async {
    final j = await _getMap('/api/documents/$id/', {
      'full_perms': 'true',
      'fields': 'id,owner,permissions',
    });
    return ObjectPermissions.fromJson(
      j['permissions'] as Map<String, dynamic>?,
    );
  }

  /// Setzt Eigentümer und Freigaben eines Dokuments.
  Future<Document> setDocumentPermissions(
    int id,
    ObjectPermissions permissions, {
    int? owner,
    bool setOwner = false,
  }) async => Document.fromJson(
    await _json('PATCH', '/api/documents/$id/', {
      'set_permissions': permissions.toJson(),
      if (setOwner) 'owner': owner,
    }),
  );

  // Papierkorb ----------------------------------------------------------------

  Future<PageResult<Document>> trash({
    int page = 1,
    int pageSize = 100,
  }) async => PageResult.fromJson(
    await _getMap('/api/trash/', {'page': '$page', 'page_size': '$pageSize'}),
    Document.fromJson,
  );

  Future<void> restoreFromTrash(List<int> ids) => _send(
    'POST',
    '/api/trash/',
    json: {'documents': ids, 'action': 'restore'},
  );

  /// Ohne [ids] wird der ganze Papierkorb geleert.
  Future<void> emptyTrash([List<int> ids = const []]) =>
      _send('POST', '/api/trash/', json: {'documents': ids, 'action': 'empty'});

  // Benutzer und Gruppen ------------------------------------------------------

  Future<List<AppUser>> users() => _all('/api/users/', AppUser.fromJson);
  Future<AppUser> createUser(Map<String, Object?> data) async =>
      AppUser.fromJson(await _json('POST', '/api/users/', data));
  Future<AppUser> updateUser(int id, Map<String, Object?> data) async =>
      AppUser.fromJson(await _json('PATCH', '/api/users/$id/', data));
  Future<void> deleteUser(int id) => _send('DELETE', '/api/users/$id/');

  Future<List<UserGroup>> groups() => _all('/api/groups/', UserGroup.fromJson);
  Future<UserGroup> createGroup(String name, List<String> permissions) async =>
      UserGroup.fromJson(
        await _json('POST', '/api/groups/', {
          'name': name,
          'permissions': permissions,
        }),
      );
  Future<UserGroup> updateGroup(
    int id, {
    String? name,
    List<String>? permissions,
  }) async => UserGroup.fromJson(
    await _json('PATCH', '/api/groups/$id/', {
      'name': ?name,
      'permissions': ?permissions,
    }),
  );
  Future<void> deleteGroup(int id) => _send('DELETE', '/api/groups/$id/');

  Future<Profile> profile() async =>
      Profile.fromJson(await _getMap('/api/profile/'));
  Future<Profile> updateProfile(Map<String, Object?> data) async =>
      Profile.fromJson(await _json('PATCH', '/api/profile/', data));

  // Zwei-Faktor-Anmeldung -----------------------------------------------------

  /// Neuer Schlüssel; aktiv erst nach [activateTotp] mit einem passenden Code.
  Future<TotpSetup> totpSetup() async =>
      TotpSetup.fromJson(await _getMap('/api/profile/totp/'));

  /// Schaltet TOTP ein und liefert die Wiederherstellungscodes.
  Future<List<String>> activateTotp(String secret, String code) async {
    final r = await _json('POST', '/api/profile/totp/', {
      'secret': secret,
      'code': code.replaceAll(' ', ''),
    });
    return [for (final c in (r['recovery_codes'] as List? ?? [])) '$c'];
  }

  Future<void> deactivateTotp() => _send('DELETE', '/api/profile/totp/');

  /// Für Administratoren: TOTP eines anderen Benutzers zurücksetzen.
  Future<void> deactivateUserTotp(int userId) =>
      _send('POST', '/api/users/$userId/deactivate_totp/');

  // Custom Fields -------------------------------------------------------------

  Future<List<CustomField>> customFields() =>
      _all('/api/custom_fields/', CustomField.fromJson);

  Future<CustomField> createCustomField(
    String name,
    CustomFieldType type, {
    List<String> options = const [],
    String? defaultCurrency,
  }) async => CustomField.fromJson(
    await _json('POST', '/api/custom_fields/', {
      'name': name,
      'data_type': type.value,
      'extra_data': {
        if (type == CustomFieldType.select)
          'select_options': [
            for (final o in options) {'label': o},
          ],
        if (type == CustomFieldType.monetary)
          'default_currency': defaultCurrency,
      },
    }),
  );

  Future<CustomField> updateCustomField(
    int id, {
    String? name,
    List<SelectOption>? options,
  }) async => CustomField.fromJson(
    await _json('PATCH', '/api/custom_fields/$id/', {
      'name': ?name,
      if (options != null)
        'extra_data': {
          'select_options': [
            for (final o in options)
              {if (o.id.isNotEmpty) 'id': o.id, 'label': o.label},
          ],
        },
    }),
  );

  Future<void> deleteCustomField(int id) =>
      _send('DELETE', '/api/custom_fields/$id/');

  // Gespeicherte Ansichten ----------------------------------------------------

  Future<List<SavedView>> savedViews() =>
      _all('/api/saved_views/', SavedView.fromJson);

  Future<SavedView> createSavedView(
    String name,
    DocumentFilter filter, {
    bool showInSidebar = true,
  }) async => SavedView.fromJson(
    await _json('POST', '/api/saved_views/', {
      'name': name,
      'show_in_sidebar': showInSidebar,
      'show_on_dashboard': false,
      'sort_field': filter.ordering.apiValue.replaceFirst('-', ''),
      'sort_reverse': filter.ordering.apiValue.startsWith('-'),
      'filter_rules': [for (final r in filter.toFilterRules()) r.toJson()],
    }),
  );

  Future<void> deleteSavedView(int id) =>
      _send('DELETE', '/api/saved_views/$id/');

  // Workflows -----------------------------------------------------------------

  Future<List<Workflow>> workflows() =>
      _all('/api/workflows/', Workflow.fromJson);
  Future<Workflow> saveWorkflow(Workflow w) async => Workflow.fromJson(
    w.id == null
        ? await _json('POST', '/api/workflows/', w.toJson())
        : await _json('PUT', '/api/workflows/${w.id}/', w.toJson()),
  );
  Future<void> deleteWorkflow(int id) => _send('DELETE', '/api/workflows/$id/');

  // Mail ----------------------------------------------------------------------

  Future<List<MailAccount>> mailAccounts() =>
      _all('/api/mail_accounts/', MailAccount.fromJson);

  Future<MailAccount> saveMailAccount(
    MailAccount a, {
    String? password,
  }) async => MailAccount.fromJson(
    a.id == null
        ? await _json(
            'POST',
            '/api/mail_accounts/',
            a.toJson(password: password),
          )
        : await _json(
            'PATCH',
            '/api/mail_accounts/${a.id}/',
            a.toJson(password: password),
          ),
  );

  /// Anmelde-Links für Gmail/Outlook, falls auf dem Server eingerichtet.
  Future<({String? gmail, String? outlook})> mailOAuthUrls() async {
    final settings =
        (await _getMap('/api/ui_settings/'))['settings'] as Map? ?? const {};
    return (
      gmail: settings['gmail_oauth_url'] as String?,
      outlook: settings['outlook_oauth_url'] as String?,
    );
  }

  Future<void> deleteMailAccount(int id) =>
      _send('DELETE', '/api/mail_accounts/$id/');

  /// Prüft die Anmeldung und liefert die Ordner des Postfachs.
  Future<List<String>> testMailAccount(
    MailAccount a, {
    String? password,
  }) async {
    final j = await _json('POST', '/api/mail_accounts/test/', {
      ...a.toJson(password: password ?? '**********'),
      'id': a.id,
    });
    return [for (final f in j['folders'] as List? ?? const []) '$f'];
  }

  Future<int> processMailAccount(int id) async =>
      (await _json('POST', '/api/mail_accounts/$id/process/'))['consumed']
          as int? ??
      0;

  Future<List<MailRule>> mailRules() => _all('/api/mail_rules/', MailRule.new);
  Future<MailRule> saveMailRule(MailRule r) async => MailRule(
    r.id == null
        ? await _json('POST', '/api/mail_rules/', r.json)
        : await _json('PATCH', '/api/mail_rules/${r.id}/', r.json),
  );
  Future<void> deleteMailRule(int id) =>
      _send('DELETE', '/api/mail_rules/$id/');

  // Verlauf und Versionen -----------------------------------------------------

  Future<List<HistoryEntry>> history(int documentId) async => [
    for (final h
        in (await _send('GET', '/api/documents/$documentId/history/')) as List)
      HistoryEntry.fromJson(h as Map<String, dynamic>),
  ];

  /// Neue Fassung hochladen; liefert die Task-ID.
  Future<String> uploadVersion(
    int documentId,
    List<int> bytes,
    String filename, {
    String? label,
  }) async {
    final request =
        http.MultipartRequest(
            'POST',
            PaperlessClient._resolve(
              baseUrl,
              '/api/documents/$documentId/update_version/',
              null,
            ),
          )
          ..headers.addAll(_headers)
          ..files.add(
            http.MultipartFile.fromBytes('document', bytes, filename: filename),
          );
    if (label != null && label.isNotEmpty) {
      request.files.add(http.MultipartFile.fromString('version_label', label));
    }
    final response = await PaperlessClient._guard(
      () async => http.Response.fromStream(
        await _http.send(request).timeout(PaperlessClient._uploadTimeout),
      ),
    );
    final body = PaperlessClient._decode(response);
    if (response.statusCode != 200 || body is! String) {
      throw PaperlessClient._error(response, body);
    }
    return body;
  }

  Future<void> deleteVersion(int documentId, int versionId) =>
      _send('DELETE', '/api/documents/$documentId/versions/$versionId/');

  // Freigabelinks -------------------------------------------------------------

  Future<List<ShareLink>> shareLinks(int documentId) async => [
    for (final l
        in (await _send('GET', '/api/documents/$documentId/share_links/'))
            as List)
      ShareLink.fromJson(l as Map<String, dynamic>),
  ];

  Future<ShareLink> createShareLink(
    int documentId, {
    DateTime? expiration,
    bool original = false,
  }) async => ShareLink.fromJson(
    await _json('POST', '/api/share_links/', {
      'document': documentId,
      'expiration': expiration?.toUtc().toIso8601String(),
      'file_version': original ? 'original' : 'archive',
    }),
  );

  Future<void> deleteShareLink(int id) =>
      _send('DELETE', '/api/share_links/$id/');

  /// Öffentliche Adresse eines Freigabelinks.
  Uri shareLinkUrl(ShareLink link) =>
      baseUrl.replace(path: '${baseUrl.path}/share/${link.slug}');

  // Netzwerkscanner -----------------------------------------------------------

  Future<List<ScannerInfo>> scanners({bool refresh = false}) async => [
    for (final s
        in (await _send(
              'GET',
              '/api/scanners/',
              query: {if (refresh) 'refresh': 'true'},
            ))
            as List)
      ScannerInfo.fromJson(s as Map<String, dynamic>),
  ];

  Future<ScannerCapabilities> scannerCapabilities(String id) async =>
      ScannerCapabilities.fromJson(
        await _getMap('/api/scanners/$id/capabilities/'),
      );

  /// Startet einen Scan; liefert die Task-ID wie ein Upload.
  Future<String> scan(
    String id, {
    String source = 'Platen',
    String colorMode = 'RGB24',
    int resolution = 300,
    bool duplex = false,
    String? title,
    List<int> tags = const [],
    int? correspondent,
    int? documentType,
  }) async =>
      (await _send(
            'POST',
            '/api/scanners/$id/scan/',
            json: {
              'source': source,
              'color_mode': colorMode,
              'resolution': resolution,
              'duplex': duplex,
              'title': ?title,
              'tags': tags,
              'correspondent': ?correspondent,
              'document_type': ?documentType,
            },
          ))
          as String;
}
