import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:paperbuddy_api/paperbuddy_api.dart';

import 'app_lock.dart';
import 'file_cache.dart';
import 'notifications.dart';
import 'session_store.dart';
import 'thumbnail_cache.dart';
import 'upload_queue.dart';

enum SessionStatus { starting, signedOut, signedIn }

/// Sitzung und Stammdaten (Tags, Korrespondenten, Dokumenttypen).
/// Screens erreichen sie über [AppScope].
class AppState extends ChangeNotifier {
  AppState(this._store, {this._httpClient, this.authenticator});

  final SessionStore _store;

  /// Für Tests; sonst erzeugt der API-Client seinen eigenen.
  final http.Client Function()? _httpClient;
  SessionStore get store => _store;

  SessionStatus status = SessionStatus.starting;
  PaperlessClient? _client;

  /// Nur gültig, solange [status] == [SessionStatus.signedIn].
  PaperlessClient get client => _client!;

  /// Fehler beim automatischen Wiederverbinden, wird auf dem Anmeldebildschirm gezeigt.
  String? restoreError;

  Map<int, Tag> tags = {};
  Map<int, Correspondent> correspondents = {};
  Map<int, DocumentType> documentTypes = {};
  Map<int, StoragePath> storagePaths = {};
  Map<int, CustomField> customFields = {};
  List<SavedView> savedViews = [];

  /// Benutzer und Gruppen für Freigaben; bei fehlendem Recht leer.
  Map<int, AppUser> users = {};
  Map<int, UserGroup> groups = {};

  /// App-Sperre (Face ID, Touch ID, Fingerabdruck, Geräte-Code).
  late final lock = AppLock(
    enabled: _store.appLock,
    saveEnabled: _store.setAppLock,
    authenticate: authenticator,
  );

  /// Für Tests austauschbar; `null` = Gerät fragen.
  final Future<bool> Function(String reason)? authenticator;

  /// Darstellung (System, hell, dunkel); gilt sofort und bleibt gespeichert.
  late final themeMode = ValueNotifier<ThemeMode>(
    ThemeMode.values.firstWhere(
      (m) => m.name == _store.themeMode,
      orElse: () => ThemeMode.system,
    ),
  );

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode.value = mode;
    await _store.setThemeMode(mode.name);
  }

  /// Wird erhöht, wenn sich Dokumente geändert haben (z. B. nach einem
  /// Upload), damit Listen neu laden.
  final documentsChanged = ValueNotifier(0);

  /// Wird erhöht, wenn Fristen angelegt, abgehakt oder gelöscht wurden.
  final remindersChanged = ValueNotifier(0);

  final thumbnails = ThumbnailCache();

  /// Zwischenspeicher auf dem Gerät (im Web `null`).
  FileCache? files;

  /// Datei eines Dokuments: aus dem Zwischenspeicher, wenn sie zur
  /// aktuellen Fassung passt, sonst vom Server (und dann gespeichert).
  /// Ist der Server nicht erreichbar, wird auch eine ältere gespeicherte
  /// Fassung genommen.
  Future<DownloadedFile> download(
    Document doc, {
    bool original = false,
    int? version,
  }) async {
    final cache = files;
    if (version != null || cache == null) {
      return client.downloadFile(doc.id, original: original, version: version);
    }
    final hit = await cache.document(
      doc.id,
      original: original,
      modified: doc.modified,
    );
    if (hit != null) return hit;
    try {
      final file = await client.downloadFile(doc.id, original: original);
      cache
          .storeDocument(
            doc.id,
            file,
            original: original,
            modified: doc.modified,
          )
          .ignore();
      return file;
    } on ApiException catch (e) {
      // Netzwerkfehler (kein Statuscode): gespeicherte Fassung nehmen.
      if (e.statusCode != null) rethrow;
      final old = await cache.document(
        doc.id,
        original: original,
        anyVersion: true,
      );
      if (old == null) rethrow;
      return old;
    }
  }

  /// Zwischenspeicher auch ohne Anmeldung (Server nicht erreichbar), für
  /// den zuletzt benutzten Server und Benutzer.
  Future<FileCache?> offlineCache() async {
    if (files != null) return files;
    final server = _store.lastServer;
    final user = _store.lastUsername;
    if (server == null || user == null || server.isEmpty) return null;
    try {
      files = await FileCache.open(
        PaperlessClient.normalizeBaseUrl(server),
        user,
      );
    } on ApiException {
      return null;
    }
    return files;
  }

  /// Dokument für unterwegs dauerhaft auf dem Gerät halten.
  Future<void> keepOffline(Document doc) async {
    final cache = files;
    if (cache == null) return;
    final file = await client.downloadFile(doc.id);
    await cache.keepOffline(doc, file);
  }

  late final uploads = UploadQueue(onDocumentAdded: documentsArrived);

  /// Benachrichtigungszentrale für Uploads und Importe auf dem Server.
  late final notifications = NotificationCenter(
    uploads: uploads,
    onDocumentAdded: documentsArrived,
    loadSeen: () => _store.noticesSeen,
    saveSeen: _store.setNoticesSeen,
  );

  Future<void> restore() async {
    final saved = await _store.load();
    if (saved == null) {
      status = SessionStatus.signedOut;
      notifyListeners();
      return;
    }
    try {
      await _signIn(
        await PaperlessClient.connect(
          saved.server,
          saved.token,
          httpClient: _httpClient?.call(),
        ),
      );
    } on ApiException catch (e) {
      // Bei abgelaufenem Token neu anmelden; sonst (Server gerade nicht
      // erreichbar) den Token behalten und es später erneut versuchen.
      if (e.isUnauthorized) await _store.clear();
      restoreError = e.message;
      status = SessionStatus.signedOut;
      notifyListeners();
    }
  }

  /// Wirft [MfaRequiredException], wenn der Server einen zweiten Faktor
  /// verlangt; dann mit [code] erneut aufrufen.
  Future<void> login(
    String server,
    String username,
    String password, {
    String? code,
  }) async {
    final client = await PaperlessClient.login(
      server,
      username,
      password,
      code: code,
      httpClient: _httpClient?.call(),
    );
    await _store.save(SavedSession(client.baseUrl.toString(), client.token));
    await _store.rememberLogin(server.trim(), username.trim());
    restoreError = null;
    await _signIn(client);
  }

  /// Erneuter Versuch mit dem gespeicherten Token.
  Future<void> retryRestore() async {
    restoreError = null;
    status = SessionStatus.starting;
    notifyListeners();
    await restore();
  }

  Future<bool> get hasSavedSession async => await _store.load() != null;

  Future<void> _signIn(PaperlessClient client) async {
    _client?.close();
    _client = client;
    files = await FileCache.open(client.baseUrl, client.user.username);
    thumbnails.disk = files;
    await refreshLabels();
    status = SessionStatus.signedIn;
    notifications.start(client);
    notifyListeners();
  }

  /// So lange blendet die Oberfläche beim Abmelden über (siehe `_Root`).
  static const signOutTransition = Duration(milliseconds: 250);

  Future<void> logout() async {
    await _store.clear();
    final old = _client;
    thumbnails.clear();
    // Abmelden entfernt auch alle Dokumente vom Gerät.
    await files?.clearAll();
    files = null;
    thumbnails.disk = null;
    notifications.stop();
    uploads.clearFinished();
    tags = {};
    correspondents = {};
    documentTypes = {};
    storagePaths = {};
    customFields = {};
    savedViews = [];
    users = {};
    groups = {};
    status = SessionStatus.signedOut;
    notifyListeners();
    // Die bisherige Oberfläche blendet noch aus und baut dabei neu; sie
    // liest den Client. Erst danach freigeben.
    await Future<void>.delayed(signOutTransition * 2);
    if (identical(_client, old)) _client = null;
    old?.close();
  }

  /// Neu anlegen und gleich in die Listen übernehmen, damit Auswahlfelder
  /// den Namen statt einer Nummer zeigen.
  Future<Correspondent> createCorrespondent(String name) async {
    final created = await client.createCorrespondent(name);
    await refreshLabels();
    return created;
  }

  Future<DocumentType> createDocumentType(String name) async {
    final created = await client.createDocumentType(name);
    await refreshLabels();
    return created;
  }

  Future<void> refreshLabels() async {
    final c = _client;
    if (c == null) return;
    final user = c.user;
    Future<T> optional<T>(
      bool allowed,
      Future<T> Function() load,
      T empty,
    ) async {
      if (!allowed) return empty;
      try {
        return await load();
      } on ApiException {
        // Fehlendes Recht oder älterer Server: Liste bleibt leer.
        return empty;
      }
    }

    final (t, co, dt, sp, cf, sv, us, gr) = await (
      optional(user.can('view', 'tag'), c.tags, <Tag>[]),
      optional(
        user.can('view', 'correspondent'),
        c.correspondents,
        <Correspondent>[],
      ),
      optional(
        user.can('view', 'documenttype'),
        c.documentTypes,
        <DocumentType>[],
      ),
      optional(
        user.can('view', 'storagepath'),
        c.storagePaths,
        <StoragePath>[],
      ),
      optional(
        user.can('view', 'customfield'),
        c.customFields,
        <CustomField>[],
      ),
      optional(user.can('view', 'savedview'), c.savedViews, <SavedView>[]),
      optional(user.can('view', 'user'), c.users, <AppUser>[]),
      optional(user.can('view', 'group'), c.groups, <UserGroup>[]),
    ).wait;
    tags = {for (final x in t) x.id: x};
    correspondents = {for (final x in co) x.id: x};
    documentTypes = {for (final x in dt) x.id: x};
    storagePaths = {for (final x in sp) x.id: x};
    customFields = {for (final x in cf) x.id: x};
    savedViews = sv;
    users = {for (final x in us) x.id: x};
    groups = {for (final x in gr) x.id: x};
    notifyListeners();
  }

  void notifyDocumentsChanged() => documentsChanged.value++;

  DateTime? _backgroundSince;

  /// App geht in den Hintergrund: Abfragen pausieren.
  void appPaused() {
    lock.paused();
    _backgroundSince ??= DateTime.now();
    notifications.pause();
  }

  /// App kommt zurück: Benachrichtigungen sofort abgleichen, nach längerer
  /// Pause auch Listen und Labels neu laden.
  void appResumed() {
    lock.resumed();
    final since = _backgroundSince;
    _backgroundSince = null;
    if (status != SessionStatus.signedIn) return;
    notifications.resume();
    if (since != null &&
        DateTime.now().difference(since) > const Duration(seconds: 30)) {
      notifyDocumentsChanged();
      refreshLabels().ignore();
    }
  }

  Timer? _arrivedTimer;

  /// Neue Dokumente vom Server (Uploads, Importe). Mehrere kurz
  /// hintereinander lösen nur ein Neuladen der Listen und Labels aus,
  /// statt eines je Dokument.
  void documentsArrived() {
    _arrivedTimer?.cancel();
    _arrivedTimer = Timer(arrivalDelay, () {
      notifyDocumentsChanged();
      refreshLabels().ignore();
    });
  }

  /// Wartezeit zum Bündeln von [documentsArrived].
  static Duration arrivalDelay = const Duration(milliseconds: 800);

  @override
  void dispose() {
    _client?.close();
    _arrivedTimer?.cancel();
    documentsChanged.dispose();
    remindersChanged.dispose();
    themeMode.dispose();
    lock.dispose();
    notifications.dispose();
    uploads.dispose();
    super.dispose();
  }
}

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
    : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  /// Ohne Abhängigkeit, z. B. in Callbacks.
  static AppState read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
