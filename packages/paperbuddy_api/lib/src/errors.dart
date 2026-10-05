/// Fehler vom Server oder bei der Verbindung.
class ApiException implements Exception {
  ApiException(this.message, {this.statusCode, this.fieldErrors = const {}});

  final String message;
  final int? statusCode;

  /// Validierungsfehler je Feld, z. B. `{"name": ["… already exists."]}`.
  final Map<String, List<String>> fieldErrors;

  bool get isUnauthorized => statusCode == 401 || statusCode == 403;
  bool get isNotFound => statusCode == 404;

  /// Aus einer DRF-Fehlerantwort (`{"detail": …}` oder Feldfehler).
  factory ApiException.fromBody(int status, Object? body) {
    if (body is Map) {
      final detail = body['detail'];
      if (detail is String) return ApiException(detail, statusCode: status);
      final fields = <String, List<String>>{
        for (final e in body.entries)
          '${e.key}': e.value is List
              ? [for (final v in e.value as List) '$v']
              : ['${e.value}'],
      };
      final first = fields.values.expand((v) => v).firstOrNull;
      return ApiException(
        first ?? 'Fehler $status',
        statusCode: status,
        fieldErrors: fields,
      );
    }
    return ApiException('Fehler $status', statusCode: status);
  }

  @override
  String toString() => statusCode == null ? message : '$message ($statusCode)';
}

/// Der Server verlangt einen zweiten Faktor (TOTP- oder
/// Wiederherstellungscode); [invalid] = der mitgeschickte Code war falsch.
class MfaRequiredException extends ApiException {
  MfaRequiredException({this.invalid = false, String? message})
    : super(
        message ??
            (invalid
                ? 'Der Code ist falsch oder abgelaufen.'
                : 'Bitte den Code aus der Authenticator-App eingeben.'),
        statusCode: 400,
      );

  final bool invalid;
}
