import 'dart:io';

import 'package:clip_sync/core/device_id_service.dart';
import 'package:clip_sync/models/clipboard_item.dart';
import 'package:clip_sync/providers/providers.dart';
import 'package:clip_sync/core/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:timeago/timeago.dart' as timeago;
import 'package:window_manager/window_manager.dart';

/// Main dashboard showing sync status, toggle, device info, and clipboard history.
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen>
    with WindowListener {
  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      windowManager.addListener(this);
    }
    // Auto-start sync engine if authenticated but not yet active
    _ensureSyncStarted();
  }

  @override
  void dispose() {
    if (Platform.isWindows) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  /// On Windows, intercept the close button to minimize to tray instead.
  @override
  void onWindowClose() async {
    if (Platform.isWindows) {
      await windowManager.hide();
    }
  }

  /// Ensure the sync engine is running when the dashboard mounts.
  Future<void> _ensureSyncStarted() async {
    if (Platform.isAndroid) {
      await Permission.notification.request();
      await Permission.ignoreBatteryOptimizations.request();
    }

    // Small delay to ensure Supabase auth session is fully hydrated
    await Future.delayed(const Duration(milliseconds: 300));

    final syncState = ref.read(syncEngineProvider);
    if (!syncState.isActive) {
      final user = Supabase.instance.client.auth.currentUser;
      if (user != null) {
        final deviceId = await DeviceIdService.getDeviceId();
        await ref.read(syncEngineProvider.notifier).initialize(
              deviceId: deviceId,
              userId: user.id,
            );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final syncState = ref.watch(syncEngineProvider);
    final shortDeviceIdAsync = ref.watch(shortDeviceIdProvider);

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // ── App Bar ──────────────────────────────────────────────
          SliverAppBar(
            pinned: true,
            title: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.asset(
                    'assets/icon.png',
                    width: 32,
                    height: 32,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  'ClipSync',
                  style: GoogleFonts.inter(
                    fontWeight: FontWeight.w800,
                    fontSize: 20,
                  ),
                ),
              ],
            ),
            actions: [
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert_rounded,
                    color: colorScheme.onSurfaceVariant),
                onSelected: (value) async {
                  if (value == 'clear') {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Clear History'),
                        content: const Text(
                            'Delete all synced clipboard items? This cannot be undone.'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Clear All'),
                          ),
                        ],
                      ),
                    );
                    if (confirm == true) {
                      ref
                          .read(syncEngineProvider.notifier)
                          .clearAll();
                    }
                  } else if (value == 'signout') {
                    await ref.read(authProvider.notifier).signOut();
                    if (context.mounted) context.go('/auth');
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'clear',
                    child: Row(
                      children: [
                        Icon(Icons.delete_sweep_outlined, size: 20),
                        SizedBox(width: 10),
                        Text('Clear History'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'signout',
                    child: Row(
                      children: [
                        Icon(Icons.logout_rounded, size: 20),
                        SizedBox(width: 10),
                        Text('Sign Out'),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 4),
            ],
          ),

          // ── Status Card ──────────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: _StatusCard(
                isActive: syncState.isActive,
                isConnected: syncState.isConnected,
                onToggle: () => ref
                    .read(syncEngineProvider.notifier)
                    .toggleSync(),
              ),
            ),
          ),

          // ── Error Banner (if any) ─────────────────────────────────
          if (syncState.error != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Card(
                  color: colorScheme.error.withValues(alpha: 0.1),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline_rounded,
                            size: 20, color: colorScheme.error),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            syncState.error!,
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color: colorScheme.error,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // ── Device Info ──────────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: shortDeviceIdAsync.when(
                data: (shortId) => _DeviceInfoChip(deviceId: shortId),
                loading: () => const SizedBox.shrink(),
                error: (_, _) => const SizedBox.shrink(),
              ),
            ),
          ),

          // ── Section Header ───────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Row(
                children: [
                  Icon(Icons.history_rounded,
                      size: 18, color: colorScheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Text(
                    'Recent Clips',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurfaceVariant,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${syncState.items.length} items',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Clipboard History ────────────────────────────────────
          if (syncState.items.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyState(colorScheme: colorScheme),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(0, 4, 0, 24),
              sliver: SliverList.builder(
                itemCount: syncState.items.length,
                itemBuilder: (context, index) {
                  final item = syncState.items[index];
                  return _ClipboardItemCard(
                    item: item,
                    onCopy: () {
                      ref
                          .read(syncEngineProvider.notifier)
                          .copyToClipboard(item.content);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: const Text('Copied to clipboard'),
                          duration: const Duration(seconds: 1),
                          action: SnackBarAction(
                            label: 'OK',
                            onPressed: () {},
                          ),
                        ),
                      );
                    },
                    onDelete: () {
                      ref
                          .read(syncEngineProvider.notifier)
                          .deleteItem(item.id);
                    },
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

// ── Status Card Widget ──────────────────────────────────────────────

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.isActive,
    required this.isConnected,
    required this.onToggle,
  });

  final bool isActive;
  final bool isConnected;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final statusColor = isActive && isConnected
        ? AppTheme.syncActiveColor
        : isActive
            ? AppTheme.warningColor
            : AppTheme.syncInactiveColor;

    final statusText = isActive && isConnected
        ? 'Live Sync'
        : isActive
            ? 'Connecting...'
            : 'Sync Paused';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            // Animated pulse dot
            _AnimatedPulseDot(color: statusColor, isActive: isActive),
            const SizedBox(width: 14),

            // Status text
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    statusText,
                    style: GoogleFonts.inter(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    isActive
                        ? 'Clipboard changes will sync across devices'
                        : 'Toggle to resume clipboard syncing',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),

            // Toggle
            Switch.adaptive(
              value: isActive,
              onChanged: (_) => onToggle(),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Animated Pulse Dot ──────────────────────────────────────────────

class _AnimatedPulseDot extends StatefulWidget {
  const _AnimatedPulseDot({
    required this.color,
    required this.isActive,
  });

  final Color color;
  final bool isActive;

  @override
  State<_AnimatedPulseDot> createState() => _AnimatedPulseDotState();
}

class _AnimatedPulseDotState extends State<_AnimatedPulseDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _animation = Tween<double>(begin: 1.0, end: 2.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    if (widget.isActive) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(_AnimatedPulseDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.isActive && _controller.isAnimating) {
      _controller.stop();
      _controller.reset();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 32,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (widget.isActive)
            AnimatedBuilder(
              animation: _animation,
              builder: (context, child) {
                return Container(
                  width: 12 * _animation.value,
                  height: 12 * _animation.value,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.color
                        .withValues(alpha: 0.3 * (2.0 - _animation.value)),
                  ),
                );
              },
            ),
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.color,
              boxShadow: [
                BoxShadow(
                  color: widget.color.withValues(alpha: 0.4),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Device Info Chip ────────────────────────────────────────────────

class _DeviceInfoChip extends StatelessWidget {
  const _DeviceInfoChip({required this.deviceId});

  final String deviceId;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(
              Platform.isWindows
                  ? Icons.desktop_windows_rounded
                  : Icons.phone_android_rounded,
              size: 20,
              color: colorScheme.primary,
            ),
            const SizedBox(width: 10),
            Text(
              'This Device',
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                deviceId,
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: colorScheme.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Clipboard Item Card ─────────────────────────────────────────────

class _ClipboardItemCard extends StatelessWidget {
  const _ClipboardItemCard({
    required this.item,
    required this.onCopy,
    required this.onDelete,
  });

  final ClipboardItem item;
  final VoidCallback onCopy;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      child: InkWell(
        onTap: onCopy,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Content preview
              Text(
                item.content,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  color: colorScheme.onSurface,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 12),
              // Footer: timestamp, device, actions
              Row(
                children: [
                  Icon(
                    Icons.access_time_rounded,
                    size: 14,
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    timeago.format(item.createdAt),
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      color:
                          colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Icon(
                    Icons.devices_rounded,
                    size: 14,
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    item.deviceId.length > 16
                        ? '${item.deviceId.substring(0, 16)}...'
                        : item.deviceId,
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      color:
                          colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                    ),
                  ),
                  const Spacer(),
                  // Copy button
                  _SmallIconButton(
                    icon: Icons.copy_rounded,
                    tooltip: 'Copy',
                    color: colorScheme.primary,
                    onPressed: onCopy,
                  ),
                  const SizedBox(width: 4),
                  // Delete button
                  _SmallIconButton(
                    icon: Icons.delete_outline_rounded,
                    tooltip: 'Delete',
                    color: colorScheme.error,
                    onPressed: onDelete,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Small Icon Button ───────────────────────────────────────────────

class _SmallIconButton extends StatelessWidget {
  const _SmallIconButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: Tooltip(
          message: tooltip,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(icon, size: 18, color: color),
          ),
        ),
      ),
    );
  }
}

// ── Empty State ─────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.colorScheme});

  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(48),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer.withValues(alpha: 0.4),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.content_paste_off_rounded,
                size: 36,
                color: colorScheme.primary.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'No clips yet',
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Copy something to your clipboard and it will\nappear here, synced across all your devices.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 13,
                color: colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
