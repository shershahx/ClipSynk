import 'dart:io';

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// System tray service for Windows.
/// Provides a tray icon with context menu to restore or quit the app.
class TrayService with TrayListener {
  TrayService._();

  static final TrayService _instance = TrayService._();
  static TrayService get instance => _instance;

  static bool _initialized = false;

  /// Initialize the system tray (Windows only).
  static Future<void> initialize() async {
    if (!Platform.isWindows) return;
    if (_initialized) return;

    await trayManager.setIcon('windows/runner/resources/app_icon.ico');
    await trayManager.setToolTip('ClipSync — Clipboard Sync');

    final menu = Menu(
      items: [
        MenuItem(
          key: 'restore',
          label: 'Restore ClipSync',
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'quit',
          label: 'Quit',
        ),
      ],
    );
    await trayManager.setContextMenu(menu);
    trayManager.addListener(_instance);

    _initialized = true;
  }

  /// Dispose of the tray.
  static Future<void> dispose() async {
    if (!Platform.isWindows) return;
    trayManager.removeListener(_instance);
    await trayManager.destroy();
    _initialized = false;
  }

  @override
  void onTrayIconMouseDown() {
    // Single click on tray icon → show window
    windowManager.show();
    windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'restore':
        windowManager.show();
        windowManager.focus();
        break;
      case 'quit':
        windowManager.destroy();
        exit(0);
      default:
        break;
    }
  }
}
