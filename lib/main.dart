import 'dart:io';

import 'package:clip_sync/app.dart';
import 'package:clip_sync/core/device_id_service.dart';
import 'package:clip_sync/core/supabase_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Supabase
  await Supabase.initialize(
    url: SupabaseConfig.url,
    publishableKey: SupabaseConfig.anonKey,
  );

  // Expose config to native Android code (Quick Settings tile uploader).
  if (Platform.isAndroid) {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('clip_sync_supabase_url', SupabaseConfig.url);
    await prefs.setString('clip_sync_supabase_anon_key', SupabaseConfig.anonKey);
    await DeviceIdService.getDeviceId();
  }

  // Initialize window manager for desktop
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    const windowOptions = WindowOptions(
      size: Size(420, 720),
      minimumSize: Size(360, 600),
      center: true,
      title: 'ClipSync',
      titleBarStyle: TitleBarStyle.normal,
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(
    const ProviderScope(
      child: ClipSyncApp(),
    ),
  );
}
