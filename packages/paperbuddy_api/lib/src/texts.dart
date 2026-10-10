/// Meldungen und Bezeichnungen des Clients in der Sprache der App
/// (`PaperlessClient.language`, Standard Deutsch).
abstract final class ApiTexts {
  static String language = 'de';

  /// Deutscher oder englischer Text je nach [language].
  static String pick(String de, String en) => language == 'en' ? en : de;

  static String get serverRequired =>
      pick('Bitte eine Server-Adresse angeben.', 'Please enter a server address.');
  static String invalidServer(String input) =>
      pick('Ungültige Server-Adresse: $input', 'Invalid server address: $input');

  /// Login-Bremse; [seconds] aus `Retry-After`.
  static String tooManyAttempts(int? seconds) {
    if (seconds == null) {
      return pick('Zu viele Fehlversuche. Bitte später erneut versuchen.', 'Too many failed attempts. Please try again later.');
    }
    if (seconds < 120) {
      return pick(
        'Zu viele Fehlversuche. Bitte in $seconds Sekunden erneut versuchen.',
        'Too many failed attempts. Please try again in $seconds seconds.',
      );
    }
    final minutes = (seconds / 60).ceil();
    return pick(
      'Zu viele Fehlversuche. Bitte in $minutes Minuten erneut versuchen.',
      'Too many failed attempts. Please try again in $minutes minutes.',
    );
  }

  static String get tooManyCodes => pick(
    'Zu viele falsche Codes. Bitte in einigen Minuten erneut versuchen.',
    'Too many wrong codes. Please try again in a few minutes.',
  );
  static String get wrongCredentials =>
      pick('Benutzername oder Passwort ist falsch.', 'Wrong username or password.');
  static String get noServer => pick(
    'Unter dieser Adresse läuft kein PaperBuddy- oder Paperless-Server.',
    'There is no PaperBuddy or Paperless server at this address.',
  );
  static String get noResponse => pick('Der Server antwortet nicht.', 'The server does not respond.');
  static String unreachable(String reason) =>
      pick('Server nicht erreichbar: $reason', 'Server not reachable: $reason');
  static String get sessionExpired =>
      pick('Anmeldung abgelaufen oder ungültig.', 'Session expired or invalid.');
  static String get processingSlow =>
      pick('Die Verarbeitung dauert ungewöhnlich lange.', 'Processing is taking unusually long.');
  static String error(int status) => pick('Fehler $status', 'Error $status');
  static String get wrongCode => pick('Der Code ist falsch oder abgelaufen.', 'The code is wrong or has expired.');
  static String get enterCode =>
      pick('Bitte den Code aus der Authenticator-App eingeben.', 'Please enter the code from your authenticator app.');
}
