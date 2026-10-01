import 'dart:async';

import 'package:clip_sync/screens/auth_screen.dart';
import 'package:clip_sync/screens/dashboard_screen.dart';
import 'package:clip_sync/screens/splash_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

part 'router.g.dart';

/// Listens to Supabase auth state changes and notifies GoRouter to
/// re-evaluate its redirect logic. This avoids recreating the GoRouter
/// instance on every auth change (which would reset navigation state).
class _AuthChangeNotifier extends ChangeNotifier {
  late final StreamSubscription<AuthState> _sub;

  _AuthChangeNotifier() {
    _sub = Supabase.instance.client.auth.onAuthStateChange.listen((_) {
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

@Riverpod(keepAlive: true)
GoRouter router(Ref ref) {
  final authChangeNotifier = _AuthChangeNotifier();
  ref.onDispose(() => authChangeNotifier.dispose());

  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: authChangeNotifier,
    redirect: (context, state) {
      final currentPath = state.uri.path;

      // Always allow splash to run its init sequence
      if (currentPath == '/splash') return null;

      // Check auth directly from Supabase (not via a watched provider)
      final user = Supabase.instance.client.auth.currentUser;
      final isAuthenticated = user != null;
      final isOnAuth = currentPath == '/auth';

      // Not authenticated → force to auth
      if (!isAuthenticated && !isOnAuth) return '/auth';
      // Authenticated but still on auth → go to dashboard
      if (isAuthenticated && isOnAuth) return '/dashboard';

      return null;
    },
    routes: [
      GoRoute(
        path: '/splash',
        builder: (context, state) => const SplashScreen(),
      ),
      GoRoute(
        path: '/auth',
        builder: (context, state) => const AuthScreen(),
      ),
      GoRoute(
        path: '/dashboard',
        builder: (context, state) => const DashboardScreen(),
      ),
    ],
  );
}
