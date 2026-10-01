# ClipSync

**Real-time clipboard synchronization across Android and Windows.**

Copy text on your phone — it's instantly available on your desktop, and vice versa. ClipSync keeps your clipboard in sync across all your authenticated devices with zero manual effort.

---

## ✨ Features

- **Real-time sync** — Clipboard changes propagate instantly via Supabase Realtime (WebSockets)
- **Loop-proof engine** — Dual-guard system (device ID + last-received tracking) prevents infinite echo loops
- **Plain text only** — Automatically rejects file paths, images, and binary clipboard formats
- **System tray (Windows)** — Close minimizes to tray; sync keeps running in the background
- **Background service (Android)** — Clipboard monitoring survives app minimization and device reboot
- **48-hour auto-cleanup** — Old items are automatically purged server-side via `pg_cron`
- **Memory-efficient** — Only 20 items held in memory; older history paginated from Supabase
- **Material 3 UI** — Polished dark/light theme with adaptive system colors, Google Fonts (Inter), and micro-animations
- **Magic link auth** — Sign in with email/password or passwordless magic link

---

## 📸 Screens

| Splash | Auth | Dashboard |
|--------|------|-----------|
| Sequential init with progress | Email/password + magic link | Live status, toggle, history |

---

## 🛠️ Tech Stack

| Layer | Technology |
|-------|-----------|
| Framework | Flutter (latest stable) |
| State Management | Riverpod 3.x/4.x with Code Generation |
| Backend | Supabase (Auth, Postgres, Realtime) |
| Routing | GoRouter |
| Windows Tray | `tray_manager` + `window_manager` |
| Android Background | `flutter_background_service` |

---

## 🚀 Getting Started

### Prerequisites

- Flutter SDK (latest stable)
- A [Supabase](https://supabase.com) project (free tier works fine)
- Android SDK and/or Visual Studio (for Windows desktop builds)

### 1. Clone & Install

```bash
git clone https://github.com/YOUR_USERNAME/ClipSync.git
cd ClipSync
flutter pub get
```

### 2. Configure Supabase

Edit `lib/core/supabase_config.dart` with your project credentials:

```dart
static const String url = 'https://YOUR_PROJECT.supabase.co';
static const String anonKey = 'YOUR_PUBLISHABLE_KEY';
```

### 3. Run the Database Migration

Open your Supabase Dashboard → **SQL Editor** → paste and run `supabase_migration.sql`.

This sets up:
- `clipboard_items` table
- Row Level Security (users can only access their own rows)
- Realtime publication
- Hourly cleanup of items older than 48 hours (`pg_cron`)

### 4. Enable Realtime & pg_cron

- **Realtime**: Dashboard → Database → Replication → enable for `clipboard_items`
- **pg_cron**: Dashboard → Database → Extensions → enable `pg_cron`

### 5. Generate Riverpod Code

```bash
dart run build_runner build
```

### 6. Run

```bash
# Windows
flutter run -d windows

# Android
flutter run -d <device_id>
```

---

## 📂 Project Structure

```
lib/
├── main.dart                    # Entry point (Supabase + WindowManager init)
├── app.dart                     # Root MaterialApp with M3 theming
├── router.dart                  # GoRouter with auth-based redirects
├── core/
│   ├── supabase_config.dart     # Supabase URL + key (edit this!)
│   ├── theme.dart               # Material 3 dark/light themes
│   └── device_id_service.dart   # Persistent device UUID + clipboard validator
├── models/
│   └── clipboard_item.dart      # Data model with JSON serialization
├── providers/
│   └── providers.dart           # Riverpod providers (code-gen annotations)
├── services/
│   ├── sync_engine.dart         # Core sync logic with loop prevention
│   └── tray_service.dart        # Windows system tray integration
└── screens/
    ├── splash_screen.dart       # Sequential async init with progress UI
    ├── auth_screen.dart         # Email/password + magic link auth
    └── dashboard_screen.dart    # Status indicator, sync toggle, clipboard history
```

---

## 🔄 How Sync Works

```
┌─────────────────┐                    ┌─────────────────┐
│   Device A      │                    │   Device B      │
│   (Windows)     │                    │   (Android)     │
├─────────────────┤                    ├─────────────────┤
│ Copy "Hello"    │                    │                 │
│       │         │                    │                 │
│       ▼         │                    │                 │
│ Poll detects    │   ┌──────────┐    │                 │
│ new text        │──▶│ Supabase │    │                 │
│ Push to cloud   │   │ INSERT   │    │                 │
│ (device_id: A)  │   │          │──▶ │ Realtime event  │
│                 │   └──────────┘    │ device_id ≠ B   │
│                 │                    │ → Write to      │
│                 │                    │   clipboard     │
│                 │                    │ → "Hello" ready │
└─────────────────┘                    └─────────────────┘
```

**Loop prevention:**
1. Device B receives "Hello" from cloud → writes to local clipboard → records it as `lastReceivedFromCloud`
2. Device B's clipboard poller sees "Hello" → matches `lastReceivedFromCloud` → **skips** (no re-push)
3. Device A receives its own insert via Realtime → `device_id` matches → **ignores**

---

## 🗃️ Database Schema

```sql
CREATE TABLE clipboard_items (
  id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  device_id  TEXT        NOT NULL,
  content    TEXT        NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

RLS ensures each user can only read, insert, and delete their own rows.

---

## 📄 License

This project is provided as-is for personal use. Add your preferred license as needed.
