import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io';

import 'package:clip_sync/core/device_id_service.dart';
import 'package:clip_sync/core/supabase_config.dart';
import 'package:clip_sync/models/clipboard_item.dart';
import 'package:clip_sync/services/media_clipboard_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:open_filex/open_filex.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

/// Core clipboard sync engine.
///
/// Handles:
/// - Local clipboard polling & change detection
/// - Pushing new local clipboard text to Supabase
/// - Receiving remote clipboard items via Supabase Realtime **and** a
///   periodic pull (Realtime alone can silently miss events)
/// - Re-syncing immediately when the app returns to the foreground
/// - Writing remote clipboard items to the local OS clipboard
/// - Infinite-loop prevention via device_id + last-received tracking
class SyncEngine with WidgetsBindingObserver {
  SyncEngine({
    required this.deviceId,
    required this.userId,
    this.onItemsChanged,
    this.onSyncStatusChanged,
    this.onError,
  });

  final String deviceId;
  final String userId;
  final void Function(List<ClipboardItem> items)? onItemsChanged;
  final void Function(bool isConnected)? onSyncStatusChanged;
  final void Function(String message)? onError;

  /// Private Supabase Storage bucket holding images and files.
  static const String _bucket = 'clipboard-files';

  /// Signature of the last image/file we saw on the local clipboard.
  String? _lastMediaSignature;

  /// After we write a remote image/file to the clipboard, the next media read
  /// is our own write (possibly re-encoded) and must not be uploaded again.
  DateTime? _adoptMediaUntil;

  /// Last Windows clipboard sequence number for which media was read.
  int? _lastMediaSeq;
  DateTime _lastMediaCheck = DateTime.fromMillisecondsSinceEpoch(0);

  /// Downloaded image/file bytes by item id (small LRU, for thumbnails/copy).
  final Map<String, Uint8List> _bytesCache = {};
  static const int _maxCachedItems = 12;

  final SupabaseClient _supabase = Supabase.instance.client;

  /// The last text we received from the cloud and wrote to the local clipboard.
  /// Used to prevent echo: when the local watcher sees this text, it won't push it back.
  String? _lastReceivedFromCloud;

  /// The last text we read from the local clipboard.
  String? _lastLocalClipboardText;

  /// In-memory clipboard history, newest first (capped at 20 items).
  final List<ClipboardItem> _items = [];
  static const int _maxItemsInMemory = 20;

  /// Newest `created_at` we have seen so far; used to pull only newer rows.
  DateTime? _latestSeen;

  /// Polling timer for local clipboard changes.
  Timer? _clipboardPollTimer;

  /// Periodic pull of remote items (safety net for missed Realtime events).
  Timer? _remotePullTimer;
  bool _pulling = false;
  bool _pollingClipboard = false;

  /// Supabase Realtime channel.
  RealtimeChannel? _realtimeChannel;

  /// Whether the sync engine is currently active.
  bool _isActive = false;
  bool get isActive => _isActive;

  /// Whether realtime is connected.
  bool _isConnected = false;
  bool get isConnected => _isConnected;

  bool _disposed = false;

  // ── Lifecycle ───────────────────────────────────────────────────

  /// Start the sync engine: load history, start polling, subscribe to Realtime.
  Future<void> start() async {
    if (_isActive) {
      dev.log('start() called but already active, skipping', name: 'SyncEngine');
      return;
    }

    dev.log('Starting sync engine for user=$userId device=$deviceId',
        name: 'SyncEngine');

    // Mark active up-front so a concurrent start() can't double-start and
    // so pause() during startup is honoured.
    _isActive = true;

    try {
      if (_latestSeen == null) {
        await _loadInitialHistory();
      } else {
        // Resuming after a pause: fetch whatever we missed and apply it.
        await _pullRemote();
      }
      if (!_isActive) return; // paused while loading

      _startClipboardPolling();
      _startRemotePulling();
      _subscribeToRealtime();
      WidgetsBinding.instance.addObserver(this);
      unawaited(_purgeExpiredMedia());
    } catch (_) {
      pause();
      rethrow;
    }

    dev.log('Sync engine is now active', name: 'SyncEngine');
  }

  /// Pause the sync engine: stop polling and unsubscribe from Realtime.
  void pause() {
    _isActive = false;
    _stopClipboardPolling();
    _stopRemotePulling();
    _unsubscribeFromRealtime();
    WidgetsBinding.instance.removeObserver(this);
    _isConnected = false;
    if (!_disposed) onSyncStatusChanged?.call(false);
    dev.log('Sync engine paused', name: 'SyncEngine');
  }

  /// Dispose of all resources.
  void dispose() {
    _disposed = true;
    pause();
    _items.clear();
  }

  /// When the app returns to the foreground, sync right away. On Android the
  /// clipboard can only be read while the app is focused, so this is when
  /// anything copied in other apps is picked up.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _adoptNativeSession().whenComplete(syncNow);
    }
  }

  /// The Android Quick Settings tile can refresh the Supabase session natively
  /// (rotating the refresh token) while this isolate is asleep. Re-read the
  /// persisted session so we don't keep using a stale refresh token.
  Future<void> _adoptNativeSession() async {
    if (!Platform.isAndroid) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final host = Uri.parse(SupabaseConfig.url).host.split('.').first;
      final stored = prefs.getString('sb-$host-auth-token');
      if (stored == null) return;
      final storedRefresh =
          (jsonDecode(stored) as Map<String, dynamic>)['refresh_token'];
      final current = _supabase.auth.currentSession?.refreshToken;
      if (storedRefresh != null && storedRefresh != current) {
        await _supabase.auth.recoverSession(stored);
        dev.log('Adopted session refreshed by native tile',
            name: 'SyncEngine');
      }
    } catch (e) {
      dev.log('Could not adopt native session: $e', name: 'SyncEngine');
    }
  }

  /// Immediately pull remote changes and push the current local clipboard.
  Future<void> syncNow() async {
    if (!_isActive) return;
    await _pullRemote();
    // The clipboard may not be readable the instant the window regains focus.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _lastMediaCheck = DateTime.fromMillisecondsSinceEpoch(0); // allow media read
    await _pollClipboard();
  }

  // ── Initial History Load ────────────────────────────────────────

  Future<void> _loadInitialHistory() async {
    try {
      dev.log('Loading initial clipboard history...', name: 'SyncEngine');
      final response = await _supabase
          .from('clipboard_items')
          .select()
          .eq('user_id', userId)
          .order('created_at', ascending: false)
          .limit(_maxItemsInMemory);

      _items.clear();
      for (final row in response) {
        _items.add(ClipboardItem.fromJson(row));
      }
      if (_items.isNotEmpty) _latestSeen = _items.first.createdAt;
      // Mark as loaded even when the history is empty so a later resume uses
      // the incremental pull path.
      _latestSeen ??= DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      _notifyItems();
      dev.log('Loaded ${_items.length} clipboard items', name: 'SyncEngine');
    } catch (e, stack) {
      dev.log('Failed to load clipboard history: $e',
          name: 'SyncEngine', error: e, stackTrace: stack);
      // Don't rethrow — engine should still start polling & realtime
    }
  }

  // ── Remote Pull (fallback for Realtime) ─────────────────────────

  void _startRemotePulling() {
    _remotePullTimer?.cancel();
    _remotePullTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _pullRemote(),
    );
  }

  void _stopRemotePulling() {
    _remotePullTimer?.cancel();
    _remotePullTimer = null;
  }

  /// Fetch rows newer than the newest one we know about and ingest them.
  Future<void> _pullRemote() async {
    if (!_isActive || _pulling) return;
    _pulling = true;
    try {
      if (_latestSeen == null) {
        // History never loaded (e.g. offline at start). Load it without
        // treating old remote rows as "new" clipboard content.
        await _loadInitialHistory();
        return;
      }
      var query = _supabase.from('clipboard_items').select().eq('user_id', userId);
      query = query.gte('created_at', _latestSeen!.toUtc().toIso8601String());
      final rows =
          await query.order('created_at', ascending: false).limit(_maxItemsInMemory);
      if (!_isActive) return;
      _ingest([for (final row in rows) ClipboardItem.fromJson(row)]);
    } catch (e) {
      dev.log('Remote pull failed: $e', name: 'SyncEngine');
    } finally {
      _pulling = false;
    }
  }

  /// Add unseen items to the history (deduplicated by id). If any of them came
  /// from another device, the newest one is written to the local clipboard.
  void _ingest(List<ClipboardItem> incoming) {
    final known = _items.map((i) => i.id).toSet();
    final fresh = incoming.where((i) => !known.contains(i.id)).toList();
    if (fresh.isEmpty) return;

    _items.addAll(fresh);
    _items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (_items.length > _maxItemsInMemory) {
      _items.removeRange(_maxItemsInMemory, _items.length);
    }
    if (_latestSeen == null || _items.first.createdAt.isAfter(_latestSeen!)) {
      _latestSeen = _items.first.createdAt;
    }
    _notifyItems();

    final newestRemote = fresh
        .where((i) => i.deviceId != deviceId)
        .fold<ClipboardItem?>(
          null,
          (best, i) =>
              best == null || i.createdAt.isAfter(best.createdAt) ? i : best,
        );
    if (newestRemote != null) {
      if (newestRemote.isMedia) {
        _applyRemoteMedia(newestRemote);
      } else {
        _writeRemoteToLocalClipboard(newestRemote);
      }
    } else {
      // An item from this device that we didn't push ourselves (e.g. sent by
      // the Android Quick Settings tile). Remember it so the clipboard poll
      // doesn't upload the same text a second time.
      final newestOwn = fresh.first;
      if (newestOwn.deviceId == deviceId && !newestOwn.isMedia) {
        _lastLocalClipboardText = newestOwn.content;
      }
    }
  }

  void _writeRemoteToLocalClipboard(ClipboardItem item) {
    _lastReceivedFromCloud = item.content;
    _lastLocalClipboardText = item.content;
    Clipboard.setData(ClipboardData(text: item.content));
    dev.log(
        'Wrote remote clipboard to local: ${item.content.length} chars from ${item.deviceId}',
        name: 'SyncEngine');
  }

  void _notifyItems() {
    if (_disposed) return;
    onItemsChanged?.call(List.unmodifiable(_items));
  }

  // ── Local Clipboard Polling (Push Logic) ────────────────────────

  void _startClipboardPolling() {
    _clipboardPollTimer?.cancel();
    _clipboardPollTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _pollClipboard(),
    );
    dev.log('Clipboard polling started (1s interval)', name: 'SyncEngine');
  }

  void _stopClipboardPolling() {
    _clipboardPollTimer?.cancel();
    _clipboardPollTimer = null;
  }

  Future<void> _pollClipboard() async {
    if (!_isActive || _pollingClipboard) return;
    _pollingClipboard = true;
    try {
      final text = await ClipboardValidator.getValidClipboardText();
      if (text == null) {
        // No text on the clipboard: it may hold an image or a copied file.
        await _pollMedia();
        return;
      }

      // No change from what we already know
      if (text == _lastLocalClipboardText) return;

      _lastLocalClipboardText = text;
      _lastMediaSignature = null; // re-copying the same image should sync again

      // If this text is what we just received from the cloud, don't push it back
      if (text == _lastReceivedFromCloud) return;

      // New local clipboard content → push to Supabase
      await _pushToSupabase(text);
    } finally {
      _pollingClipboard = false;
    }
  }

  Future<void> _pushToSupabase(String text) async {
    try {
      final item = ClipboardItem(
        id: '', // will be generated by DB
        userId: userId,
        deviceId: deviceId,
        content: text,
        createdAt: DateTime.now(),
      );

      // Read the inserted row back so it shows up in the history immediately,
      // without waiting for Realtime or the next pull.
      final row = await _supabase
          .from('clipboard_items')
          .insert(item.toInsertJson())
          .select()
          .single();
      dev.log('Pushed clipboard to cloud: ${text.length} chars',
          name: 'SyncEngine');
      _ingest([ClipboardItem.fromJson(row)]);
    } catch (e) {
      dev.log('Failed to push clipboard: $e', name: 'SyncEngine');
    }
  }

  // ── Images & Files ──────────────────────────────────────────────

  void _reportError(String message) {
    dev.log(message, name: 'SyncEngine');
    if (!_disposed) onError?.call(message);
  }

  /// Look for an image/file on the local clipboard and upload it if it's new.
  Future<void> _pollMedia({bool force = false}) async {
    final seq = MediaClipboardService.clipboardSequence();
    if (seq != null) {
      // Windows: only read the (large) image/file data when the clipboard changed.
      if (!force && seq == _lastMediaSeq) return;
      _lastMediaSeq = seq;
    } else {
      // Android: no change counter, so throttle the heavier read.
      final now = DateTime.now();
      if (!force && now.difference(_lastMediaCheck) < const Duration(seconds: 3)) {
        return;
      }
      _lastMediaCheck = now;
    }

    MediaClip? clip;
    try {
      clip = await MediaClipboardService.readFromClipboard();
    } catch (e) {
      _lastMediaSeq = null; // clipboard was busy; try again next poll
      dev.log('Reading media from clipboard failed: $e', name: 'SyncEngine');
      return;
    }
    if (clip == null) return;

    final adoptUntil = _adoptMediaUntil;
    if (adoptUntil != null) {
      _adoptMediaUntil = null;
      if (DateTime.now().isBefore(adoptUntil)) {
        // This is the image/file we just wrote ourselves; don't echo it back.
        _lastMediaSignature = clip.signature;
        return;
      }
    }
    if (clip.signature == _lastMediaSignature) return;

    _lastMediaSignature = clip.signature;
    _lastLocalClipboardText = null; // re-copying the same text should sync again
    await _pushMedia(clip);
  }

  /// Upload an image/file chosen by the user (file picker).
  /// Returns an error message, or null on success.
  Future<String?> sendFile(String fileName, Uint8List bytes) async {
    final error = MediaClipboardService.validate(fileName, bytes.length);
    if (error != null) return error;
    final clip = MediaClipboardService.fromBytes(fileName, bytes);
    if (clip == null) return 'Unsupported file';
    // Don't let the clipboard poll re-upload this later.
    return _pushMedia(clip, reportErrors: false);
  }

  /// Upload to Storage, then insert the metadata row.
  Future<String?> _pushMedia(MediaClip clip, {bool reportErrors = true}) async {
    final ext = MediaClipboardService.extensionOf(clip.fileName);
    final path = '$userId/${const Uuid().v4()}${ext.isEmpty ? '' : '.$ext'}';
    var uploaded = false;
    try {
      await _supabase.storage.from(_bucket).uploadBinary(
            path,
            clip.bytes,
            fileOptions: FileOptions(contentType: clip.mimeType, upsert: false),
          );
      uploaded = true;

      final item = ClipboardItem(
        id: '',
        userId: userId,
        deviceId: deviceId,
        content: clip.fileName,
        createdAt: DateTime.now(),
        kind: clip.kind,
        fileName: clip.fileName,
        mimeType: clip.mimeType,
        sizeBytes: clip.bytes.length,
        storagePath: path,
      );
      final row = await _supabase
          .from('clipboard_items')
          .insert(item.toInsertJson())
          .select()
          .single();
      final saved = ClipboardItem.fromJson(row);
      _cacheBytes(saved.id, clip.bytes);
      dev.log('Pushed ${clip.kind.name} to cloud: ${clip.fileName} '
          '(${clip.bytes.length} bytes)', name: 'SyncEngine');
      _ingest([saved]);
      return null;
    } catch (e) {
      if (uploaded) {
        // Don't leave an orphan file behind if the row insert failed.
        _supabase.storage.from(_bucket).remove([path]).catchError((Object _) => <FileObject>[]);
      }
      final message = _describeMediaError(e);
      if (reportErrors) _reportError(message);
      return message;
    }
  }

  String _describeMediaError(Object e) {
    final text = e.toString();
    if (text.contains('Bucket not found') || text.contains('bucket')) {
      return 'Image/file sync is not set up: create the "$_bucket" storage '
          'bucket (run supabase_media_migration.sql).';
    }
    if (text.contains('kind') ||
        text.contains('storage_path') ||
        text.contains('PGRST204')) {
      return 'Image/file sync needs a database update: run '
          'supabase_media_migration.sql in Supabase.';
    }
    return 'Failed to upload image/file: $text';
  }

  void _cacheBytes(String itemId, Uint8List bytes) {
    _bytesCache.remove(itemId);
    _bytesCache[itemId] = bytes;
    while (_bytesCache.length > _maxCachedItems) {
      _bytesCache.remove(_bytesCache.keys.first);
    }
  }

  /// Download (or return cached) bytes for an image/file item.
  Future<Uint8List> fetchBytes(ClipboardItem item) async {
    final cached = _bytesCache[item.id];
    if (cached != null) return cached;
    final path = item.storagePath;
    if (path == null) throw StateError('Item has no stored file');
    final bytes = await _supabase.storage.from(_bucket).download(path);
    _cacheBytes(item.id, bytes);
    return bytes;
  }

  /// A remote image/file arrived: put it on this device's clipboard.
  Future<void> _applyRemoteMedia(ClipboardItem item) async {
    if ((item.sizeBytes ?? 0) > MediaClipboardService.maxBytes) return;
    try {
      final bytes = await fetchBytes(item);
      await _putMediaOnClipboard(item, bytes);
      dev.log('Wrote remote ${item.kind.name} to local clipboard: '
          '${item.fileName} from ${item.deviceId}', name: 'SyncEngine');
    } catch (e) {
      _reportError('Could not receive ${item.fileName ?? 'file'}: $e');
    }
  }

  /// Returns true if the item is now on the clipboard.
  Future<bool> _putMediaOnClipboard(ClipboardItem item, Uint8List bytes) async {
    _adoptMediaUntil = DateTime.now().add(const Duration(seconds: 10));
    _lastReceivedFromCloud = null;
    _lastLocalClipboardText = null;

    if (item.isImage) {
      try {
        await MediaClipboardService.writeImage(bytes);
        return true;
      } catch (e) {
        // e.g. WebP isn't decodable by Windows; fall back to a file.
        dev.log('writeImage failed ($e), falling back to file',
            name: 'SyncEngine');
      }
    }

    final path = await MediaClipboardService.saveToTemp(
        item.id, item.fileName ?? item.content, bytes);
    final ok = await MediaClipboardService.writeFile(path);
    if (!ok) _adoptMediaUntil = null; // nothing was written (e.g. Android)
    return ok;
  }

  /// Put an item from the history back on the clipboard (manual action).
  /// Returns a short message for the user.
  Future<String> copyItem(ClipboardItem item) async {
    if (!item.isMedia) {
      await copyToClipboard(item.content);
      return 'Copied to clipboard';
    }
    try {
      final bytes = await fetchBytes(item);
      final ok = await _putMediaOnClipboard(item, bytes);
      return ok
          ? (item.isImage ? 'Image copied to clipboard' : 'File copied to clipboard')
          : 'This device can\'t paste files - use Open instead';
    } catch (e) {
      return 'Copy failed: $e';
    }
  }

  /// Download an image/file and open it with the system's default app.
  Future<String?> openItem(ClipboardItem item) async {
    try {
      final bytes = await fetchBytes(item);
      final path = await MediaClipboardService.saveToTemp(
          item.id, item.fileName ?? item.content, bytes);
      final result = await OpenFilex.open(path);
      if (result.type != ResultType.done) return result.message;
      return null;
    } catch (e) {
      return 'Open failed: $e';
    }
  }

  // ── Supabase Realtime (Pull Logic) ──────────────────────────────

  void _subscribeToRealtime() {
    _unsubscribeFromRealtime();

    dev.log('Subscribing to realtime for user=$userId', name: 'SyncEngine');

    // Unique topic per subscription so a late unsubscribe of the previous
    // channel can't tear down the new one.
    final topic =
        'clipboard_${deviceId}_${DateTime.now().microsecondsSinceEpoch}';

    _realtimeChannel = _supabase
        .channel(topic)
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'clipboard_items',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (payload) => _handleRealtimeInsert(payload),
        )
        .subscribe((status, [error]) {
      if (_disposed || !_isActive) return;
      final connected = status == RealtimeSubscribeStatus.subscribed;
      _isConnected = connected;
      onSyncStatusChanged?.call(connected);
      dev.log(
          'Realtime status: $status${error != null ? ' error=$error' : ''}',
          name: 'SyncEngine');
    });
  }

  void _unsubscribeFromRealtime() {
    final channel = _realtimeChannel;
    _realtimeChannel = null;
    if (channel != null) {
      _supabase.removeChannel(channel).catchError((Object e) {
        dev.log('Failed to remove realtime channel: $e', name: 'SyncEngine');
        return '';
      });
    }
  }

  void _handleRealtimeInsert(PostgresChangePayload payload) {
    if (!_isActive) return;
    try {
      _ingest([ClipboardItem.fromJson(payload.newRecord)]);
    } catch (e) {
      dev.log('Error handling realtime insert: $e', name: 'SyncEngine');
    }
  }

  // ── Manual Actions ──────────────────────────────────────────────

  /// Delete a clipboard item by ID (and its stored file, if any).
  Future<void> deleteItem(String itemId) async {
    try {
      final match = _items.where((item) => item.id == itemId);
      final storagePath = match.isEmpty ? null : match.first.storagePath;
      if (storagePath != null) {
        await _supabase.storage.from(_bucket).remove([storagePath]);
      }
      await _supabase.from('clipboard_items').delete().eq('id', itemId);
      _bytesCache.remove(itemId);
      _items.removeWhere((item) => item.id == itemId);
      _notifyItems();
    } catch (e) {
      dev.log('Failed to delete item: $e', name: 'SyncEngine');
    }
  }

  /// Clear all clipboard items for this user.
  Future<void> clearAll() async {
    try {
      await _removeAllStoredFiles();
      await _supabase.from('clipboard_items').delete().eq('user_id', userId);
      _bytesCache.clear();
      _items.clear();
      _notifyItems();
    } catch (e) {
      dev.log('Failed to clear items: $e', name: 'SyncEngine');
    }
  }

  /// Images/files expire after 48 hours like text does. The database cleanup
  /// job skips them (it can't delete stored files), so the app removes them.
  Future<void> _purgeExpiredMedia() async {
    try {
      final cutoff =
          DateTime.now().toUtc().subtract(const Duration(hours: 48));
      final rows = await _supabase
          .from('clipboard_items')
          .select('id, storage_path')
          .eq('user_id', userId)
          .not('storage_path', 'is', null)
          .lt('created_at', cutoff.toIso8601String());
      if (rows.isEmpty) return;

      await _supabase.storage.from(_bucket).remove([
        for (final row in rows) row['storage_path'] as String,
      ]);
      await _supabase
          .from('clipboard_items')
          .delete()
          .inFilter('id', [for (final row in rows) row['id'] as String]);
      dev.log('Purged ${rows.length} expired image/file items',
          name: 'SyncEngine');
    } catch (e) {
      // Columns may not exist yet (database not migrated); nothing to purge.
      dev.log('Expired media purge skipped: $e', name: 'SyncEngine');
    }
  }

  Future<void> _removeAllStoredFiles() async {
    try {
      final rows = await _supabase
          .from('clipboard_items')
          .select('storage_path')
          .eq('user_id', userId)
          .not('storage_path', 'is', null);
      final paths = [
        for (final row in rows) row['storage_path'] as String,
      ];
      if (paths.isNotEmpty) {
        await _supabase.storage.from(_bucket).remove(paths);
      }
    } catch (e) {
      // Column may not exist yet (database not migrated) - nothing to remove.
      dev.log('Could not remove stored files: $e', name: 'SyncEngine');
    }
  }

  /// Copy text to the local clipboard (manual action from history).
  Future<void> copyToClipboard(String text) async {
    _lastReceivedFromCloud = text;
    _lastLocalClipboardText = text;
    await Clipboard.setData(ClipboardData(text: text));
  }
}
