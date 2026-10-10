import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../l10n/app_localizations.dart';

export '../l10n/app_localizations.dart';

/// Die Sprachen der App in der Reihenfolge des Menüs, mit eigenem Namen.
const appLanguages = {'de': 'Deutsch', 'en': 'English'};

/// Sprache des Geräts. Tests legen sie fest, weil sie deutsche Texte lesen
/// und der Testrechner Englisch spricht.
String Function() deviceLanguage = () => PlatformDispatcher.instance.locale.languageCode;

/// Sprache zur Einstellung [choice]: eine aus [appLanguages], bei „System“
/// (und Unbekanntem) die des Geräts, wenn die App sie spricht, sonst Englisch.
String resolveLanguage(String? choice) {
  if (appLanguages.containsKey(choice)) return choice!;
  final device = deviceLanguage();
  return appLanguages.containsKey(device) ? device : 'en';
}

var _language = 'de';
L10n _texts = lookupL10n(const Locale('de'));

/// Sprache der App ('de' oder 'en'); Datumsangaben folgen ihr.
String get appLanguage => _language;

/// Die Texte in der Sprache der App, auch dort, wo es keinen BuildContext
/// gibt (Benachrichtigungen, Zustand). Beim Sprachwechsel wird die App
/// komplett neu aufgebaut, Widgets behalten also keine alten Texte.
L10n get tr => _texts;

void useLanguage(String code) {
  _language = code;
  _texts = lookupL10n(Locale(code));
  Intl.defaultLocale = code;
  PaperlessClient.language = code;
}

/// `context.l10n.settingsLanguage`: die Texte in der gewählten Sprache.
extension L10nContext on BuildContext {
  L10n get l10n => L10n.of(this);
}
