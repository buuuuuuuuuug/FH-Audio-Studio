import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/app_info.dart';
import '../state/studio_state.dart';
import '../state/router.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';
import 'nav_item.dart';
import '../widgets/rm_button.dart';
import '../widgets/rm_icon.dart';
import '../tweaks/tweaks_panel.dart';
import '../state/editor_options.dart';
import '../state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

double _navigationWidth(double width) =>
    width < 136 ? 56 : width.clamp(136, 360);

class SidebarLayout extends StateNotifier<double> {
  SidebarLayout(this.ref)
    : _prefs = ref.read(sharedPreferencesProvider),
      super(
        _navigationWidth(
          ref.read(sharedPreferencesProvider).getDouble('navigation.width') ??
              220,
        ),
      ) {
    _expandedWidth =
        _prefs.getDouble('navigation.expandedWidth') ??
        (state >= 136 ? state : 220);
  }
  final Ref ref;
  final SharedPreferences _prefs;
  Timer? _timer;
  double _expandedWidth = 220;
  void toggle() => resize(state < 136 ? _expandedWidth : 56);
  void resize(double value) {
    if (state >= 136) _expandedWidth = state;
    state = _navigationWidth(value);
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 180), _persist);
    if (state < 208) ref.read(settingsExpandedProvider.notifier).state = false;
  }

  void _persist() {
    _prefs.setDouble('navigation.width', state);
    _prefs.setDouble('navigation.expandedWidth', _expandedWidth);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _persist();
    super.dispose();
  }
}

final sidebarLayoutProvider = StateNotifierProvider<SidebarLayout, double>(
  (ref) => SidebarLayout(ref),
);

/// 左侧 220px 导航栏
class Sidebar extends ConsumerStatefulWidget {
  const Sidebar({super.key, required this.activeId});

  final String activeId;

  @override
  ConsumerState<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends ConsumerState<Sidebar> {
  ({double x, double width})? _drag;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final cli = ref.watch(studioProvider);
    final appInfo = ref.watch(appInfoProvider).valueOrNull ?? AppInfo.fallback;
    final toolchainLocked = cli.toolchainWorkflowLocked;
    final lockMessage = cli.toolchainWorkflowLockMessage;
    final targetWidth = ref.watch(sidebarLayoutProvider);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: targetWidth),
      duration: _drag == null
          ? const Duration(milliseconds: 180)
          : Duration.zero,
      curve: Curves.easeOutCubic,
      builder: (context, width, _) {
        final compact = width < 136;

        String? lastGroup;
        final children = <Widget>[];
        for (final spec in kNavItems) {
          if (spec.id == 'speech' &&
              !ref.watch(editorOptionsProvider).speechEnabled) {
            continue;
          }
          if (spec.id == 'siren' &&
              !ref.watch(editorOptionsProvider).sirenEnabled) {
            continue;
          }
          if (spec.group != null && spec.group != lastGroup) {
            children.add(
              SizedBox(
                height: 34,
                child: compact
                    ? Divider(
                        height: 1,
                        indent: 8,
                        endIndent: 8,
                        color: rm.border,
                      )
                    : Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 10),
                          child: Text(
                            spec.group!.toUpperCase(),
                            style: RmText.mono(
                              10.5,
                              color: rm.fg4,
                              letterSpacing: 1.26,
                            ),
                          ),
                        ),
                      ),
              ),
            );
            lastGroup = spec.group;
          }
          final enabled =
              !toolchainLocked || _toolchainLockAllowsNavItem(spec.id);
          children.add(
            NavItem(
              spec: spec,
              active: spec.id == widget.activeId,
              compact: compact,
              enabled: enabled,
              tooltip: enabled ? null : lockMessage,
              trailing: spec.id == 'dashboard'
                  ? SizedBox(
                      width: compact ? 20 : 26,
                      child: RmButton(
                        key: const ValueKey('sidebar-toggle'),
                        size: RmButtonSize.sm,
                        leading: RmIcon(
                          compact ? 'chevron-right' : 'chevron-left',
                          size: compact ? 10 : 12,
                        ),
                        horizontalPadding: compact ? 3 : 6,
                        tooltip: compact ? '展开导航栏' : '收起导航栏',
                        onPressed: () =>
                            ref.read(sidebarLayoutProvider.notifier).toggle(),
                      ),
                    )
                  : null,
              onTap: enabled ? () => context.go(_pathFor(spec.id)) : null,
            ),
          );
          children.add(const SizedBox(height: 4));
        }

        final panel = Container(
          width: width - 4,
          decoration: BoxDecoration(
            border: Border(right: BorderSide(color: rm.border)),
          ),
          padding: EdgeInsets.fromLTRB(
            compact ? 6 : 12,
            10,
            compact ? 6 : 12,
            12,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: ListView(children: children)),
              AnimatedSize(
                duration: const Duration(milliseconds: 160),
                alignment: Alignment.bottomCenter,
                child: width >= 208 && ref.watch(settingsExpandedProvider)
                    ? const TweaksPanel(embedded: true)
                    : const SizedBox.shrink(),
              ),
              NavItem(
                spec: const NavSpec(
                  id: 'settings',
                  label: '设置',
                  icon: 'settings',
                ),
                active: ref.watch(settingsExpandedProvider),
                compact: compact,
                onTap: () {
                  if (width < 208) {
                    ref.read(sidebarLayoutProvider.notifier).resize(220);
                  }
                  ref.read(settingsExpandedProvider.notifier).state = !ref.read(
                    settingsExpandedProvider,
                  );
                },
              ),
              const SizedBox(height: 4),
              if (!compact)
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final line in appInfo.sidebarLines)
                        Text(line, style: RmText.mono(10.5, color: rm.fg4)),
                    ],
                  ),
                ),
            ],
          ),
        );
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            panel,
            MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                key: const ValueKey('sidebar-resizer'),
                dragStartBehavior: DragStartBehavior.down,
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: (d) =>
                    _drag = (x: d.globalPosition.dx, width: width),
                onHorizontalDragUpdate: (d) {
                  final start = _drag;
                  if (start != null) {
                    ref
                        .read(sidebarLayoutProvider.notifier)
                        .resize(start.width + d.globalPosition.dx - start.x);
                  }
                },
                onHorizontalDragEnd: (_) {
                  ref
                      .read(sidebarLayoutProvider.notifier)
                      .resize(ref.read(sidebarLayoutProvider));
                  _drag = null;
                },
                onDoubleTap: () =>
                    ref.read(sidebarLayoutProvider.notifier).resize(220),
                child: SizedBox(width: 4, height: double.infinity),
              ),
            ),
          ],
        );
      },
    );
  }

  String _pathFor(String id) {
    switch (id) {
      case 'dashboard':
        return RmRoutes.dashboard;
      case 'pool':
        return RmRoutes.pool;
      case 'siren':
        return RmRoutes.siren;
      case 'settings':
        return RmRoutes.settings;
      case 'playlist':
        return RmRoutes.playlist;
      case 'voices':
        return RmRoutes.voices;
      case 'speech':
        return RmRoutes.speech;
      case 'stingers':
        return RmRoutes.stingers;
    }
    return RmRoutes.dashboard;
  }
}

/// 顶部 tab 模式
class TabsBar extends ConsumerWidget {
  const TabsBar({super.key, required this.activeId});

  final String activeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rm = context.rm;
    final cli = ref.watch(studioProvider);
    final toolchainLocked = cli.toolchainWorkflowLocked;
    final lockMessage = cli.toolchainWorkflowLockMessage;
    return Container(
      height: RmTokens.tabsBarHeight,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: rm.border)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final spec in [
              ...kNavItems,
              const NavSpec(id: 'settings', label: '设置', icon: 'settings'),
            ])
              Builder(
                builder: (context) {
                  if (spec.id == 'speech' &&
                      !ref.watch(editorOptionsProvider).speechEnabled) {
                    return const SizedBox.shrink();
                  }
                  if (spec.id == 'siren' &&
                      !ref.watch(editorOptionsProvider).sirenEnabled) {
                    return const SizedBox.shrink();
                  }
                  final enabled =
                      !toolchainLocked || _toolchainLockAllowsNavItem(spec.id);
                  return TabItem(
                    spec: spec,
                    active: spec.id == 'settings'
                        ? ref.watch(settingsExpandedProvider)
                        : spec.id == activeId,
                    enabled: enabled,
                    tooltip: enabled ? null : lockMessage,
                    onTap: enabled
                        ? () {
                            if (spec.id == 'settings') {
                              ref
                                  .read(settingsExpandedProvider.notifier)
                                  .state = !ref.read(
                                settingsExpandedProvider,
                              );
                            } else {
                              context.go(_pathFor(spec.id));
                            }
                          }
                        : null,
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  String _pathFor(String id) {
    switch (id) {
      case 'dashboard':
        return RmRoutes.dashboard;
      case 'pool':
        return RmRoutes.pool;
      case 'siren':
        return RmRoutes.siren;
      case 'settings':
        return RmRoutes.settings;
      case 'playlist':
        return RmRoutes.playlist;
      case 'voices':
        return RmRoutes.voices;
      case 'speech':
        return RmRoutes.speech;
      case 'stingers':
        return RmRoutes.stingers;
    }
    return RmRoutes.dashboard;
  }
}

bool _toolchainLockAllowsNavItem(String id) {
  return id == 'dashboard' || id == 'siren';
}
