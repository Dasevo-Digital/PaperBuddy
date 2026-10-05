import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:paperbuddy_api/paperbuddy_api.dart';

import 'session_store.dart';
import 'thumbnail_cache.dart';
import 'upload_queue.dart';

enum SessionStatus { starting, signedOut, signedIn }

/// Sitzung und Stammdaten (Tags, Korrespondenten, Dokumenttypen).
/// Screens erreichen sie über [AppScope].
class AppState extends ChangeNotifier {
  AppState(this._store, {this._httpClient});

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

  /// Wird erhöht, wenn sich Dokumente geändert haben (z. B. nach einem
  /// Upload), damit Listen neu laden.
  final documentsChanged = ValueNotifier(0);

  final thumbnails = ThumbnailCache();
  late final uploads = UploadQueue(
    onDocumentAdded: () {
      notifyDocumentsChanged();
      refreshLabels().ignore();
    },
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

  Future<void> login(String server, String username, String password) async {
    final client = await PaperlessClient.login(
      server,
      username,
      password,
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
    await refreshLabels();
    status = SessionStatus.signedIn;
    notifyListeners();
  }

  Future<void> logout() async {
    await _store.clear();
    _client?.close();
    _client = null;
    thumbnails.clear();
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
  }

  Future<void> refreshLabels() async {
    final c = _client;
    if (c == null) return;
    final (t, co, dt, sp) = await (
      c.tags(),
      c.correspondents(),
      c.documentTypes(),
      c.storagePaths(),
    ).wait;
    tags = {for (final x in t) x.id: x};
    correspondents = {for (final x in co) x.id: x};
    documentTypes = {for (final x in dt) x.id: x};
    storagePaths = {for (final x in sp) x.id: x};
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
        // Ältere Server kennen manche Endpunkte nicht.
        return empty;
      }
    }

    final (cf, sv, us, gr) = await (
      optional(
        user.can('view', 'customfield'),
        c.customFields,
        <CustomField>[],
      ),
      optional(user.can('view', 'savedview'), c.savedViews, <SavedView>[]),
      optional(user.can('view', 'user'), c.users, <AppUser>[]),
      optional(user.can('view', 'group'), c.groups, <UserGroup>[]),
    ).wait;
    customFields = {for (final x in cf) x.id: x};
    savedViews = sv;
    users = {for (final x in us) x.id: x};
    groups = {for (final x in gr) x.id: x};
    notifyListeners();
  }

  void notifyDocumentsChanged() => documentsChanged.value++;

  @override
  void dispose() {
    _client?.close();
    documentsChanged.dispose();
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
