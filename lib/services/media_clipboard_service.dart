import 'dart:developer' as dev;
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:clip_sync/models/clipboard_item.dart';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// An image or file read from (or destined for) the clipboard.
class MediaClip {
  const MediaClip({
    required this.kind,
    required this.fileName,
    required this.mimeType,
    required this.bytes,
    required this.signature,
  });

  final ClipKind kind;
  final String fileName;
  final String mimeType;
  final Uint8List bytes;

  /// Cheap identity used to detect "same thing as last time".
  final String signature;
}

/// Reads and writes images/files on the system clipboard and validates what
/// is allowed to sync.
class MediaClipboardService {
  MediaClipboardService._();

  /// Maximum size of a synced image/file (Supabase free tier friendly).
  static const int maxBytes = 10 * 1024 * 1024;

  static const Set<String> imageExtensions = {
    'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp',
  };

  static const Set<String> documentExtensions = {
    'pdf', 'txt', 'csv', 'rtf',
    'doc', 'docx', 'ppt', 'pptx', 'xls', 'xlsx',
  };

  static Set<String> get allowedExtensions =>
      {...imageExtensions, ...documentExtensions};

  static const Map<String, String> _mimeByExtension = {
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'bmp': 'image/bmp',
    'pdf': 'application/pdf',
    'txt': 'text/plain',
    'csv': 'text/csv',
    'rtf': 'application/rtf',
    'doc': 'application/msword',
    'docx':
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'ppt': 'application/vnd.ms-powerpoint',
    'pptx':
        'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'xls': 'application/vnd.ms-excel',
    'xlsx':
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  };

  static String extensionOf(String fileName) =>
      p.extension(fileName).replaceFirst('.', '').toLowerCase();

  static String mimeForFileName(String fileName) =>
      _mimeByExtension[extensionOf(fileName)] ?? 'application/octet-stream';

  /// Returns an error message if the file may not be synced, otherwise null.
  static String? validate(String fileName, int sizeBytes) {
    final ext = extensionOf(fileName);
    if (!allowedExtensions.contains(ext)) {
      return '.$ext files are not supported';
    }
    if (sizeBytes <= 0) return 'File is empty';
    if (sizeBytes > maxBytes) {
      return 'File is larger than ${maxBytes ~/ (1024 * 1024)} MB';
    }
    return null;
  }

  /// Builds a [MediaClip] from raw bytes (e.g. from a file picker).
  static MediaClip? fromBytes(String fileName, Uint8List bytes) {
    if (validate(fileName, bytes.length) != null) return null;
    final isImage = imageExtensions.contains(extensionOf(fileName));
    return MediaClip(
      kind: isImage ? ClipKind.image : ClipKind.file,
      fileName: fileName,
      mimeType: mimeForFileName(fileName),
      bytes: bytes,
      signature: 'bytes:${sha1.convert(bytes)}',
    );
  }

  // ── Windows clipboard change counter ────────────────────────────

  static int Function()? _sequenceFn;

  /// Windows increments this number on every clipboard change, so we can skip
  /// expensive image/file reads when nothing changed. Null on other platforms.
  static int? clipboardSequence() {
    if (!Platform.isWindows) return null;
    try {
      _sequenceFn ??= DynamicLibrary.open('user32.dll')
          .lookupFunction<Uint32 Function(), int Function()>(
              'GetClipboardSequenceNumber');
      return _sequenceFn!();
    } catch (_) {
      return null;
    }
  }

  // ── Reading ─────────────────────────────────────────────────────

  /// Reads a copied file (Windows) or image from the clipboard.
  /// Returns null when there is nothing syncable.
  static Future<MediaClip?> readFromClipboard() async {
    if (Platform.isWindows) {
      final files = await Pasteboard.files();
      if (files.isNotEmpty) return _readFile(files.first);
    }

    final raw = await Pasteboard.image;
    if (raw == null || raw.isEmpty) return null;

    final png = await _toPng(raw);
    if (png == null) return null;
    if (png.length > maxBytes) {
      dev.log('Clipboard image too large (${png.length} bytes), skipping',
          name: 'MediaClipboard');
      return null;
    }

    final name =
        'image_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.png';
    return MediaClip(
      kind: ClipKind.image,
      fileName: name,
      mimeType: 'image/png',
      bytes: png,
      signature: 'image:${sha1.convert(png)}',
    );
  }

  static Future<MediaClip?> _readFile(String path) async {
    final file = File(path);
    final name = p.basename(path);
    try {
      if (!await file.exists()) return null; // e.g. a folder
      final stat = await file.stat();
      final error = validate(name, stat.size);
      if (error != null) {
        dev.log('Skipping clipboard file "$name": $error',
            name: 'MediaClipboard');
        return null;
      }
      final isImage = imageExtensions.contains(extensionOf(name));
      return MediaClip(
        kind: isImage ? ClipKind.image : ClipKind.file,
        fileName: name,
        mimeType: mimeForFileName(name),
        bytes: await file.readAsBytes(),
        signature: 'file:$path:${stat.size}:${stat.modified.millisecondsSinceEpoch}',
      );
    } catch (e) {
      dev.log('Could not read clipboard file: $e', name: 'MediaClipboard');
      return null;
    }
  }

  /// Windows hands images over as uncompressed BMP; convert to PNG so they are
  /// small enough to upload. Other formats pass through unchanged.
  static Future<Uint8List?> _toPng(Uint8List raw) async {
    final isBmp = raw.length > 2 && raw[0] == 0x42 && raw[1] == 0x4D;
    if (!isBmp) return raw;
    try {
      return await Isolate.run(() {
        final decoded = img.decodeBmp(raw);
        if (decoded == null) return null;
        // The clipboard bitmap's alpha byte is unreliable (often 0), so drop it.
        final opaque = decoded.convert(numChannels: 3);
        return Uint8List.fromList(img.encodePng(opaque));
      });
    } catch (e) {
      dev.log('BMP to PNG conversion failed: $e', name: 'MediaClipboard');
      return null;
    }
  }

  // ── Writing ─────────────────────────────────────────────────────

  static Future<void> writeImage(Uint8List bytes) =>
      Pasteboard.writeImage(bytes);

  /// Puts a file on the clipboard so it can be pasted into Explorer, Word,
  /// chat apps etc. Only supported on desktop.
  static Future<bool> writeFile(String path) async {
    if (!Platform.isWindows) return false;
    return Pasteboard.writeFiles([path]);
  }

  /// Saves bytes under a per-item temp folder, keeping the original file name
  /// so pasting/opening shows the right name.
  static Future<String> saveToTemp(
      String itemId, String fileName, Uint8List bytes) async {
    final base = await getTemporaryDirectory();
    final dir = Directory(p.join(base.path, 'ClipSync', itemId));
    await dir.create(recursive: true);
    final safeName = fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final file = File(p.join(dir.path, safeName));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }
}
