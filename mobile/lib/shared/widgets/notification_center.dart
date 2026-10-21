import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../app/theme/asm_theme.dart';
import '../../core/network/supabase_service.dart';
import '../models/app_notification.dart';
import 'async_states.dart';

/// Unread notification count, refreshed whenever [refresh] is called.
class NotificationCounter extends ChangeNotifier {
  int _unread = 0;
  int get unread => _unread;

  Future<void> refresh() async {
    try {
      final n = await SupabaseService().getUnreadNotificationCount();
      if (n != _unread) {
        _unread = n;
        notifyListeners();
      }
    } catch (_) {
      // Count is advisory; the panel shows load errors explicitly.
    }
  }
}

/// Header bell with unread badge that opens the notification panel.
class NotificationBell extends StatelessWidget {
  final NotificationCounter counter;
  final Color color;

  const NotificationBell({super.key, required this.counter, this.color = Colors.white70});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: counter,
      builder: (context, _) {
        final n = counter.unread;
        return IconButton(
          tooltip: n > 0 ? 'Notifications, $n unread' : 'Notifications',
          onPressed: () => showNotificationPanel(context, counter),
          icon: Badge(
            isLabelVisible: n > 0,
            label: Text(n > 99 ? '99+' : '$n'),
            backgroundColor: AsmTheme.statusRejected,
            child: Icon(n > 0 ? Icons.notifications : Icons.notifications_none, color: color, size: 20),
          ),
        );
      },
    );
  }
}

Future<void> showNotificationPanel(BuildContext context, NotificationCounter counter) async {
  final router = GoRouter.of(context);
  final route = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (_) => const _NotificationPanel(),
  );
  await counter.refresh();
  if (route != null) router.go(route);
}

class _NotificationPanel extends StatefulWidget {
  const _NotificationPanel();

  @override
  State<_NotificationPanel> createState() => _NotificationPanelState();
}

class _NotificationPanelState extends State<_NotificationPanel> {
  List<AppNotification>? _items;
  String? _error;
  bool _marking = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final items = await SupabaseService().getNotifications();
      if (mounted) setState(() => _items = items);
    } catch (_) {
      if (mounted) setState(() => _error = 'Notifications could not be loaded. Check your connection and try again.');
    }
  }

  Future<void> _markAllRead() async {
    final unread = _items?.where((n) => !n.isRead).map((n) => n.id).toList() ?? const [];
    if (unread.isEmpty) return;
    setState(() => _marking = true);
    try {
      await SupabaseService().markNotificationsRead(unread);
      await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not mark notifications as read. Please retry.')),
        );
      }
    } finally {
      if (mounted) setState(() => _marking = false);
    }
  }

  Future<void> _open(AppNotification n) async {
    if (!n.isRead) {
      try {
        await SupabaseService().markNotificationsRead([n.id]);
      } catch (_) {}
    }
    if (mounted) Navigator.pop(context, n.route);
  }

  String _age(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'Just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    if (d.inDays < 7) return '${d.inDays} d ago';
    return '${t.day.toString().padLeft(2, '0')}/${t.month.toString().padLeft(2, '0')}/${t.year}';
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final hasUnread = items?.any((n) => !n.isRead) ?? false;
    Widget body;
    if (_error != null) {
      body = StateMessage.error(message: _error!, onAction: _load);
    } else if (items == null) {
      body = const SkeletonList(rows: 4, rowHeight: 64);
    } else if (items.isEmpty) {
      body = const StateMessage(
        icon: Icons.notifications_none,
        title: 'No notifications yet',
        message: 'Approval requests and decisions on your claims and advances will appear here.',
      );
    } else {
      body = ListView.separated(
        shrinkWrap: true,
        itemCount: items.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final n = items[i];
          return ListTile(
            onTap: () => _open(n),
            leading: Icon(
              n.isRead ? Icons.notifications_none : Icons.circle,
              size: n.isRead ? 20 : 10,
              color: n.isRead ? AsmTheme.textMuted : AsmTheme.brandBlue,
              semanticLabel: n.isRead ? 'Read' : 'Unread',
            ),
            title: Text(n.title,
                style: TextStyle(fontSize: 13, fontWeight: n.isRead ? FontWeight.w500 : FontWeight.w700)),
            subtitle: Text('${n.body}\n${_age(n.createdAt)}',
                style: const TextStyle(fontSize: 12, color: AsmTheme.textSecondary, height: 1.35)),
            isThreeLine: true,
            trailing: n.route != null ? const Icon(Icons.chevron_right, size: 18) : null,
          );
        },
      );
    }

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
              child: Row(children: [
                const Expanded(
                  child: Text('Notifications',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AsmTheme.textHeading)),
                ),
                if (hasUnread)
                  TextButton(
                    onPressed: _marking ? null : _markAllRead,
                    child: const Text('Mark all as read'),
                  ),
              ]),
            ),
            const Divider(height: 1),
            Flexible(child: StateSwitcher(child: KeyedSubtree(key: ValueKey(items?.length ?? -1), child: body))),
          ],
        ),
      ),
    );
  }
}
