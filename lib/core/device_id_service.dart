import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Manages a persistent, unique device identifier for this installation.
class DeviceIdService {
  DeviceIdService._();

  static const _key = 'clip_sync_device_id';
  static String? _cachedId;

  /// Returns the unique device ID for this device, creating one if needed.
  static Future<String> getDeviceId() async {
    if (_cachedId != null) return _cachedId!;

    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_key);

    if (id == null) {
      id = const Uuid().v4();
      await prefs.setString(_key, id);
    }

    _cachedId = id;
    return id;
  }

  /// Returns a short, human-readable form of the device ID.
  static Future<String> getShortDeviceId() async {
    final id = await getDeviceId();
    return '${_platformName()}-${id.substring(0, 8)}';
  }

  static String _platformName() {
    if (Platform.isAndroid) return 'Android';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isIOS) return 'iOS';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isLinux) return 'Linux';
    return 'Device';
  }
}

/// Validates clipboard content — only plain text is accepted.
class ClipboardValidator {
  ClipboardValidator._();

  /// Maximum content length (64 KB).
  static const int maxContentLength = 65536;

  /// Returns the clipboard text if it passes validation, or null otherwise.
  static Future<String?> getValidClipboardText() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data == null || data.text == null) return null;

      final text = data.text!;
      if (text.isEmpty) return null;
      if (text.length > maxContentLength) return null;

      // Reject anything that looks like a file path (basic heuristic)
      if (_looksLikeFilePath(text)) return null;

      return text;
    } catch (_) {
      return null;
    }
  }

  static bool _looksLikeFilePath(String text) {
    final trimmed = text.trim();
    // Windows absolute paths
    if (RegExp(r'^[A-Za-z]:\\').hasMatch(trimmed)) return true;
    // Unix absolute paths (but allow short ones that might be text)
    if (trimmed.startsWith('/') && trimmed.contains('/') && trimmed.length < 260) {
      // Only if it looks path-like (no spaces, or typical path chars)
      if (RegExp(r'^(/[\w.\-]+)+/?$').hasMatch(trimmed)) return true;
    }
    return false;
  }
}
