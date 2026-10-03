# ClipSync

**Clipboard sync between Android and Windows — text, images and files.**

Copy something on your phone and paste it on your PC, and the other way round. ClipSync keeps your clipboard in sync across all the devices you sign in to, backed by your own free Supabase project.

---

## Features

- **Text, images and files** — plain text, images (PNG, JPG, GIF, WebP, BMP) and documents (PDF, TXT, CSV, RTF, Word, PowerPoint, Excel), up to 10 MB each
- **Real-time sync** — Supabase Realtime pushes new clips instantly, with a 3-second pull as a safety net so a dropped connection never leaves you stale
- **Automatic on Windows** — copy text, an image, or a file in Explorer; it shows up on your other devices
- **Send file button** — pick a file on any device and send it to the rest
- **Android Quick Settings tile** — Android only lets the focused app read the clipboard, so tap the "Send clipboard" tile after copying in any app to send it
- **Sync now button** — pulls remote clips and pushes whatever is on the clipboard right now
- **Loop-proof engine** — device ID plus last-received tracking prevents echo loops
- **48-hour auto-cleanup** — old clips are removed automatically (text by a database job, images/files by the app)
- **Material 3 UI** — light and dark themes, image thumbnails, file-type icons
- **Email/password or magic-link sign-in**

### What works where

| | Windows | Android |
|---|---|---|
| Text | Automatic | Automatic while the app is open; use the tile otherwise |
| Images | Automatic, both directions | Received images go on the clipboard; copied images are sent while the app is open |
| Files | Copy in Explorer to send; received files go on the clipboard for pasting | Use **Send file** to send; use **Open** on a received file |

Android 10 and later block background clipboard reading. This is an Android rule, not something the app can bypass.

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Framework | Flutter |
| State management | Riverpod with code generation |
| Backend | Supabase (Auth, Postgres, Realtime, Storage) |
| Routing | GoRouter |
| Clipboard images/files | `pasteboard` |
| File picking / opening | `file_picker`, `open_filex` |
| Windows window and tray | `window_manager`, `tray_manager` |

---

## Getting Started

### Prerequisites

- Flutter SDK (stable)
- A free [Supabase](https://supabase.com) project
- Android SDK for Android builds, and/or Visual Studio with the "Desktop development with C++" workload for Windows builds

### 1. Clone and install

```bash
git clone https://github.com/shershahx/ClipSync.git
cd ClipSync
flutter pub get
```

### 2. Create your Supabase config file (required)

The file holding your project URL and key is **not** included in this repository, so the app will not compile until you create it.

Create this file:

```
lib/core/supabase_config.dart
```

with exactly this code, replacing the two values:

```dart
class SupabaseConfig {
  SupabaseConfig._();

  /// Your Supabase project URL.
  static const String url = 'https://YOUR_PROJECT_REF.supabase.co';

  /// Your Supabase publishable (anon) key.
  static const String anonKey = 'YOUR_PUBLISHABLE_KEY';
}
```

Find both values in the Supabase dashboard under **Project Settings → API**: the **Project URL**, and the **publishable** key (or the legacy **anon** key).

> Never put the `service_role` or secret key in this file. It would ship inside the app. The file is listed in `.gitignore`, so it won't be committed. Don't remove it from there.

### 3. Set up the database

In the Supabase dashboard, open **SQL Editor** and run these two scripts in order:

1. `supabase_migration.sql` — creates the `clipboard_items` table, row-level security, the Realtime publication and the 48-hour cleanup job
2. `supabase_media_migration.sql` — adds image/file support: extra columns, the private `clipboard-files` storage bucket and its access rules

Text sync works after the first script. Images and files need the second one; without it the app shows a banner telling you to run it.

Also check:
- **Realtime**: Database → Replication → enabled for `clipboard_items` (the first script does this, but verify)
- **pg_cron**: Database → Extensions → `pg_cron` enabled

If you use email sign-up, either confirm the email address or turn off "Confirm email" under Authentication → Providers → Email.

### 4. Generate Riverpod code

```bash
dart run build_runner build
```

### 5. Run

```bash
# Windows
flutter run -d windows

# Android
flutter run -d <device_id>
```

Sign in on each device with the **same account**. Clips only sync between devices signed in to the same account.

---

## Building for release

### Android

```bash
flutter build apk --release
```

The APK is in `build/app/outputs/flutter-apk/app-release.apk`. For the Play Store, use `flutter build appbundle --release` and configure your own signing key (the project currently signs release builds with the debug key).

After installing, add the **Send clipboard** tile: open Quick Settings, tap the edit (pencil) icon, and drag it into your tiles. Open the app once after installing so the tile has what it needs to upload.

### Windows

```bash
flutter build windows --release
```

The runnable app is the whole folder `build/windows/x64/runner/Release/` — zip it to share it as a portable app.

To make a proper installer, install [Inno Setup](https://jrsoftware.org/isinfo.php) and run:

```bash
iscc windows\installer\clipsync.iss
```

The installer is written to `build/installer/ClipSync-Setup-<version>.exe`. It installs per user (no admin prompt), adds Start menu and optional desktop shortcuts, and can start ClipSync when you sign in to Windows. Keep `MyAppVersion` in `windows/installer/clipsync.iss` in step with `version:` in `pubspec.yaml`.

Unsigned installers trigger Windows SmartScreen ("Windows protected your PC"). Click **More info → Run anyway**, or sign the installer with a code-signing certificate.

---

## Project Structure

```
lib/
├── main.dart                         # Entry point (Supabase + window init)
├── app.dart                          # Root MaterialApp and theming
├── router.dart                       # GoRouter with auth redirects
├── core/
│   ├── supabase_config.dart          # YOUR URL + key (you create this, not in git)
│   ├── theme.dart                    # Material 3 themes
│   └── device_id_service.dart        # Device ID + text clipboard validation
├── models/
│   └── clipboard_item.dart           # Clip model (text / image / file)
├── providers/
│   └── providers.dart                # Riverpod providers
├── services/
│   ├── sync_engine.dart              # Sync logic, upload/download, loop prevention
│   ├── media_clipboard_service.dart  # Image/file clipboard access and validation
│   └── tray_service.dart             # Windows system tray
└── screens/
    ├── splash_screen.dart
    ├── auth_screen.dart
    └── dashboard_screen.dart         # Status, toggle, history, Send file

android/app/src/main/kotlin/com/clipsync/clip_sync/
├── ClipboardTileService.kt           # Quick Settings tile
├── SendClipboardActivity.kt          # Invisible screen that reads the clipboard
└── ClipboardUploader.kt              # Uploads without needing the app running

windows/installer/clipsync.iss        # Inno Setup installer script
supabase_migration.sql                # Table, RLS, Realtime, cleanup job
supabase_media_migration.sql          # Image/file columns, storage bucket, policies
```

---

## How Sync Works

```
Device A (Windows)                  Supabase                  Device B (Android)
copy "Hello"
  │ clipboard poll (1s)
  ▼
INSERT row (device_id = A) ───────▶ clipboard_items
                                       │ Realtime event (+ 3s pull as backup)
                                       ▼
                                    device_id ≠ B ─────────▶ write to clipboard
```

For images and files, the bytes are uploaded to the private `clipboard-files` storage bucket under `<user id>/`, and only the metadata goes in the table. The receiving device downloads the file and puts it on its clipboard.

**Loop prevention**
1. A device that receives a clip writes it to its clipboard and remembers it, so its own poll doesn't send it back.
2. A device ignores clips whose `device_id` is its own.
3. After writing a received image or file, the next clipboard read is treated as the device's own write, even if the OS re-encoded it.

**Cleanup:** text rows older than 48 hours are deleted hourly by `pg_cron`. Stored images and files are deleted by the app (on startup, on delete, and on Clear History), because Supabase doesn't allow deleting stored files with plain SQL.

---

## Database Schema

```sql
clipboard_items (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  device_id    TEXT        NOT NULL,
  content      TEXT        NOT NULL,      -- the text, or the file name for images/files
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  kind         TEXT        NOT NULL DEFAULT 'text',   -- 'text' | 'image' | 'file'
  file_name    TEXT,
  mime_type    TEXT,
  size_bytes   BIGINT,
  storage_path TEXT
)
```

Row-level security means each user can only read, insert and delete their own rows, and only touch files under their own folder in the storage bucket.

---

## Troubleshooting

| Problem | Likely cause |
|---|---|
| Build fails with `supabase_config.dart` not found | You haven't created the config file (step 2) |
| Red banner: "Image/file sync needs a database update" | Run `supabase_media_migration.sql` |
| Red banner: "Image/file sync is not set up" | The `clipboard-files` bucket is missing; run `supabase_media_migration.sql` |
| Clips don't arrive on the other device | Both devices must be signed in to the same account and have sync turned on |
| Android doesn't pick up a copy | The app must be in the foreground; use the Quick Settings tile or **Sync now** |
| Status stuck on "Connecting..." | Realtime isn't enabled for `clipboard_items`. Clips still arrive via the 3-second pull |

---

## License

This project is provided as-is for personal use. Add your preferred license as needed.
