import 'dart:async';
import 'dart:developer' as dev;

import 'package:clip_sync/core/device_id_service.dart';
import 'package:clip_sync/models/clipboard_item.dart';
import 'package:clip_sync/services/sync_engine.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

part 'providers.g.dart';

// ── Auth State Provider ───────────────────────────────────────────

@riverpod
Stream<AuthState> authState(Ref ref) {
  return Supabase.instance.client.auth.onAuthStateChange;
}

@riverpod
User? currentUser(Ref ref) {
  return Supabase.instance.client.auth.currentUser;
}

// ── Device ID Provider ────────────────────────────────────────────

@riverpod
Future<String> deviceId(Ref ref) async {
  return DeviceIdService.getDeviceId();
}

@riverpod
Future<String> shortDeviceId(Ref ref) async {
  return DeviceIdService.getShortDeviceId();
}

// ── Sync Engine Provider ──────────────────────────────────────────

@Riverpod(keepAlive: true)
class SyncEngineNotifier extends _$SyncEngineNotifier {
  SyncEngine? _engine;

  @override
  SyncEngineState build() {
    ref.onDispose(() {
      _engine?.dispose();
      _engine = null;
    });
    return const SyncEngineState(
      items: [],
      isActive: false,
      isConnected: false,
      error: null,
    );
  }

  /// Initialize and start the sync engine.
  Future<void> initialize({
    required String deviceId,
    required String userId,
  }) async {
    try {
      dev.log('Initializing sync engine for user=$userId device=$deviceId',
          name: 'SyncEngineNotifier');

      _engine?.dispose();

      _engine = SyncEngine(
        deviceId: deviceId,
        userId: userId,
        onItemsChanged: (items) {
          state = state.copyWith(items: items);
        },
        onSyncStatusChanged: (isConnected) {
          dev.log('Sync connection status changed: $isConnected',
              name: 'SyncEngineNotifier');
          state = state.copyWith(isConnected: isConnected);
        },
      );

      await _engine!.start();
      state = state.copyWith(isActive: true, error: null);
      dev.log('Sync engine started successfully', name: 'SyncEngineNotifier');
    } catch (e, stack) {
      dev.log('Failed to initialize sync engine: $e',
          name: 'SyncEngineNotifier', error: e, stackTrace: stack);
      state = state.copyWith(
        isActive: false,
        isConnected: false,
        error: 'Failed to start sync: $e',
      );
    }
  }

  /// Toggle sync on/off.
  Future<void> toggleSync() async {
    dev.log(
        'toggleSync called — engine=${_engine != null}, isActive=${state.isActive}',
        name: 'SyncEngineNotifier');

    if (_engine == null) {
      // Engine not initialized yet — lazy-init it
      final user = Supabase.instance.client.auth.currentUser;
      dev.log('toggleSync: currentUser=${user?.id}',
          name: 'SyncEngineNotifier');
      if (user != null) {
        final deviceId = await DeviceIdService.getDeviceId();
        await initialize(deviceId: deviceId, userId: user.id);
      } else {
        dev.log('toggleSync: No authenticated user, cannot start sync',
            name: 'SyncEngineNotifier');
        state = state.copyWith(
          error: 'Not signed in. Please sign in first.',
        );
      }
      return;
    }

    if (state.isActive) {
      _engine!.pause();
      state = state.copyWith(isActive: false, isConnected: false, error: null);
      dev.log('Sync paused', name: 'SyncEngineNotifier');
    } else {
      try {
        await _engine!.start();
        state = state.copyWith(isActive: true, error: null);
        dev.log('Sync resumed', name: 'SyncEngineNotifier');
      } catch (e) {
        dev.log('Failed to resume sync: $e', name: 'SyncEngineNotifier');
        state = state.copyWith(error: 'Failed to resume: $e');
      }
    }
  }

  /// Delete a clipboard item.
  Future<void> deleteItem(String itemId) async {
    await _engine?.deleteItem(itemId);
  }

  /// Clear all clipboard items.
  Future<void> clearAll() async {
    await _engine?.clearAll();
  }

  /// Copy an item to the local clipboard.
  Future<void> copyToClipboard(String text) async {
    await _engine?.copyToClipboard(text);
  }
}

// ── Sync Engine State ─────────────────────────────────────────────

class SyncEngineState {
  final List<ClipboardItem> items;
  final bool isActive;
  final bool isConnected;
  final String? error;

  const SyncEngineState({
    required this.items,
    required this.isActive,
    required this.isConnected,
    this.error,
  });

  SyncEngineState copyWith({
    List<ClipboardItem>? items,
    bool? isActive,
    bool? isConnected,
    String? error,
  }) {
    return SyncEngineState(
      items: items ?? this.items,
      isActive: isActive ?? this.isActive,
      isConnected: isConnected ?? this.isConnected,
      error: error,
    );
  }
}

// ── Auth Service Provider ─────────────────────────────────────────

@Riverpod(keepAlive: true)
class AuthNotifier extends _$AuthNotifier {
  @override
  AuthStatus build() {
    final user = Supabase.instance.client.auth.currentUser;
    final status =
        user != null ? AuthStatus.authenticated : AuthStatus.unauthenticated;
    dev.log('AuthNotifier.build: user=${user?.id}, status=$status',
        name: 'AuthNotifier');
    return status;
  }

  Future<String?> signInWithEmail(String email, String password) async {
    try {
      state = AuthStatus.loading;
      dev.log('Signing in with email: $email', name: 'AuthNotifier');
      await Supabase.instance.client.auth.signInWithPassword(
        email: email,
        password: password,
      );
      state = AuthStatus.authenticated;
      dev.log('Sign in successful', name: 'AuthNotifier');
      return null;
    } on AuthException catch (e) {
      dev.log('Sign in AuthException: ${e.message}', name: 'AuthNotifier');
      state = AuthStatus.unauthenticated;
      return e.message;
    } catch (e) {
      dev.log('Sign in error: $e', name: 'AuthNotifier');
      state = AuthStatus.unauthenticated;
      return e.toString();
    }
  }

  Future<String?> signUpWithEmail(String email, String password) async {
    try {
      state = AuthStatus.loading;
      dev.log('Signing up with email: $email', name: 'AuthNotifier');
      final response = await Supabase.instance.client.auth.signUp(
        email: email,
        password: password,
      );
      // Check if email confirmation is required
      if (response.user != null &&
          response.user!.identities != null &&
          response.user!.identities!.isEmpty) {
        dev.log('Sign up: user already registered', name: 'AuthNotifier');
        state = AuthStatus.unauthenticated;
        return 'An account with this email already exists. Please sign in instead.';
      }
      if (response.session != null) {
        state = AuthStatus.authenticated;
        dev.log('Sign up successful with immediate session',
            name: 'AuthNotifier');
      } else {
        // Email confirmation required
        state = AuthStatus.unauthenticated;
        dev.log('Sign up: email confirmation required', name: 'AuthNotifier');
        return 'Please check your email to confirm your account before signing in.';
      }
      return null;
    } on AuthException catch (e) {
      dev.log('Sign up AuthException: ${e.message}', name: 'AuthNotifier');
      state = AuthStatus.unauthenticated;
      return e.message;
    } catch (e) {
      dev.log('Sign up error: $e', name: 'AuthNotifier');
      state = AuthStatus.unauthenticated;
      return e.toString();
    }
  }

  Future<String?> sendMagicLink(String email) async {
    try {
      state = AuthStatus.loading;
      await Supabase.instance.client.auth.signInWithOtp(email: email);
      state = AuthStatus.unauthenticated;
      return null;
    } on AuthException catch (e) {
      state = AuthStatus.unauthenticated;
      return e.message;
    } catch (e) {
      state = AuthStatus.unauthenticated;
      return e.toString();
    }
  }

  Future<void> signOut() async {
    await Supabase.instance.client.auth.signOut();
    state = AuthStatus.unauthenticated;
    // Reset sync engine
    ref.read(syncEngineProvider.notifier).build();
  }
}

enum AuthStatus { loading, authenticated, unauthenticated }
