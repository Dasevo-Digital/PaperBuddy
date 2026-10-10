import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/app.dart';
import 'src/app_state.dart';
import 'src/session_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting();
  final prefs = await SharedPreferences.getInstance();
  final state = AppState(SessionStore(prefs));
  runApp(PaperBuddyApp(state: state));
  await state.restore();
}
