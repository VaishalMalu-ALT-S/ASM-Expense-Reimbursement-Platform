import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../app/theme/asm_theme.dart';
import '../../core/network/supabase_service.dart';
import '../../core/auth/auth_notifier.dart';
import '../models/employee.dart';
import 'notification_center.dart';

/// Enterprise Application Shell
/// Automatically detects screen width and presents:
/// - Desktop/Tablet: Dark Navy Top Utility Header + Left Vertical Navigation Sidebar + Main Content
/// - Mobile: Compact App Bar + Sticky Bottom Navigation with central add button
class EnterpriseShell extends StatefulWidget {
  final Widget child;
  final String currentRoute;

  const EnterpriseShell({
    super.key,
    required this.child,
    required this.currentRoute,
  });

  @override
  State<EnterpriseShell> createState() => _EnterpriseShellState();
}

class _EnterpriseShellState extends State<EnterpriseShell> {
  Employee? _currentEmployee;
  final _notifications = NotificationCounter();

  @override
  void initState() {
    super.initState();
    _currentEmployee = AuthNotifier().currentEmployee;
    AuthNotifier().addListener(_onAuthChanged);
    if (_currentEmployee == null) {
      _loadCurrentEmployee();
    }
    _notifications.refresh();
  }

  @override
  void didUpdateWidget(covariant EnterpriseShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentRoute != widget.currentRoute) _notifications.refresh();
  }

  void _onAuthChanged() {
    if (mounted) {
      setState(() {
        _currentEmployee = AuthNotifier().currentEmployee;
      });
    }
  }

  Future<void> _loadCurrentEmployee() async {
    try {
      final emp = await SupabaseService().getCurrentEmployee();
      if (mounted) {
        setState(() {
          _currentEmployee = emp;
        });
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    AuthNotifier().removeListener(_onAuthChanged);
    _notifications.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth >= 900;
        if (isDesktop) {
          return _buildDesktopLayout(context);
        } else {
          return _buildMobileLayout(context);
        }
      },
    );
  }

  Widget _buildDesktopLayout(BuildContext context) {
    return Scaffold(
      backgroundColor: AsmTheme.surfaceBackground,
      body: Column(
        children: [
          // 1. Top Enterprise Header (Reference Screenshot 1 & 2)
          Container(
            height: 54,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            color: AsmTheme.darkHeader,
            child: Row(
              children: [
                // Official ASM Logo
                Container(
                  height: 28,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Image.asset(
                    'assets/images/asmlogo.png',
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Text(
                      'ASM',
                      style: TextStyle(color: AsmTheme.primaryNavy, fontWeight: FontWeight.w900, fontSize: 13),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                const Text(
                  'EXPENSE',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    letterSpacing: 1.2,
                  ),
                ),
                const Spacer(),

                NotificationBell(counter: _notifications),
                const SizedBox(width: 4),

                // Quick Action Button
                IconButton(
                  tooltip: 'Record Expense',
                  icon: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: AsmTheme.brandBlue,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Icon(Icons.add, size: 16, color: Colors.white),
                  ),
                  onPressed: () => context.push('/expenses/new'),
                ),
                const SizedBox(width: 12),

                // User Organization & Profile Badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 12,
                        backgroundColor: AsmTheme.accentGold,
                        child: Text(
                          _currentEmployee != null && _currentEmployee!.fullName.isNotEmpty
                              ? _currentEmployee!.fullName[0].toUpperCase()
                              : 'U',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _currentEmployee?.fullName ?? 'Al Seer Marine',
                            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                          ),
                          if (_currentEmployee != null)
                            Text(
                              '${_currentEmployee!.employeeCode} • ${_currentEmployee!.roles.isNotEmpty ? _currentEmployee!.roles.first.displayName : 'Employee'}',
                              style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 10),
                            ),
                        ],
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Sign Out',
                        icon: const Icon(Icons.logout, size: 18, color: Colors.white70),
                        onPressed: () async {
                          await AuthNotifier().signOut();
                          if (context.mounted) context.go('/login');
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // 2. Body: Left Navigation Sidebar + Content Area
          Expanded(
            child: Row(
              children: [
                // Left Navigation Sidebar
                Container(
                  width: 220,
                  color: Colors.white,
                  child: Column(
                    children: [
                      const SizedBox(height: 12),
                      _buildNavItem(context, Icons.dashboard_outlined, 'Dashboard', '/dashboard'),
                      _buildNavItem(context, Icons.receipt_long_outlined, 'Expenses', '/expenses'),
                      _buildNavItem(context, Icons.document_scanner_outlined, 'Scan Receipt', '/receipts/scan'),
                      _buildNavItem(context, Icons.folder_outlined, 'Claims', '/claims'),
                      if (AuthNotifier().isManager)
                        _buildNavItem(context, Icons.approval_outlined, 'Approvals', '/approvals'),
                      if (AuthNotifier().isManagement)
                        _buildNavItem(context, Icons.verified_user_outlined, 'Management Review', '/approvals/management'),
                      if (AuthNotifier().isFinance)
                        _buildNavItem(context, Icons.payments_outlined, 'Reimbursements', '/finance/reimbursements'),
                      if (AuthNotifier().isManager)
                        _buildNavItem(context, Icons.bar_chart_outlined, 'Analytics & Reports', '/reports'),
                      if (AuthNotifier().isAdmin)
                        _buildNavItem(context, Icons.admin_panel_settings_outlined, 'Administration', '/admin'),
                      const Spacer(),
                      const Divider(),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            const Icon(Icons.shield_outlined, size: 16, color: AsmTheme.textMuted),
                            const SizedBox(width: 8),
                            Text(
                              'Internal v1.0',
                              style: TextStyle(fontSize: 11, color: AsmTheme.textMuted.withValues(alpha: 0.8)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),

                // Main Content
                Expanded(
                  child: widget.child,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavItem(BuildContext context, IconData icon, String title, String route) {
    final isActive = widget.currentRoute.startsWith(route);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: isActive ? AsmTheme.brandBlue.withValues(alpha: 0.1) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          dense: true,
          leading: Icon(
            icon,
            size: 18,
            color: isActive ? AsmTheme.brandBlue : AsmTheme.textBody,
          ),
          title: Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
              color: isActive ? AsmTheme.brandBlue : AsmTheme.textHeading,
            ),
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          onTap: () => context.go(route),
        ),
      ),
    );
  }

  Widget _buildMobileLayout(BuildContext context) {
    return Scaffold(
      body: widget.child,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _getMobileIndex(widget.currentRoute),
        selectedItemColor: AsmTheme.brandBlue,
        unselectedItemColor: AsmTheme.textMuted,
        type: BottomNavigationBarType.fixed,
        selectedLabelStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontSize: 11),
        onTap: (index) {
          switch (index) {
            case 0:
              context.go('/dashboard');
              break;
            case 1:
              if (AuthNotifier().isManager) {
                context.go('/approvals');
              } else {
                context.go('/receipts/scan');
              }
              break;
            case 2:
              context.go('/expenses');
              break;
            case 3:
              context.go('/claims');
              break;
            case 4:
              _showMoreSheet(context);
              break;
          }
        },
        items: [
          const BottomNavigationBarItem(icon: Icon(Icons.home_outlined), activeIcon: Icon(Icons.home), label: 'Home'),
          if (AuthNotifier().isManager)
            const BottomNavigationBarItem(icon: Icon(Icons.approval_outlined), activeIcon: Icon(Icons.approval), label: 'Approvals')
          else
            const BottomNavigationBarItem(icon: Icon(Icons.document_scanner_outlined), activeIcon: Icon(Icons.document_scanner), label: 'Scan'),
          const BottomNavigationBarItem(icon: Icon(Icons.receipt_long_outlined), activeIcon: Icon(Icons.receipt_long), label: 'Expenses'),
          const BottomNavigationBarItem(icon: Icon(Icons.folder_outlined), activeIcon: Icon(Icons.folder), label: 'Claims'),
          BottomNavigationBarItem(
            icon: ListenableBuilder(
              listenable: _notifications,
              builder: (_, __) => Badge(
                isLabelVisible: _notifications.unread > 0,
                label: Text('${_notifications.unread}'),
                backgroundColor: AsmTheme.statusRejected,
                child: const Icon(Icons.menu),
              ),
            ),
            label: 'More',
          ),
        ],
      ),
    );
  }

  /// Role-filtered destinations for small screens (the same set as the desktop sidebar).
  void _showMoreSheet(BuildContext context) {
    final auth = AuthNotifier();
    final entries = <(IconData, String, String)>[
      (Icons.add_circle_outline, 'Manual Expense (No Receipt)', '/expenses/new'),
      if (auth.isManager) (Icons.approval_outlined, 'Approvals', '/approvals'),
      if (auth.isManagement) (Icons.verified_user_outlined, 'Management Review', '/approvals/management'),
      if (auth.isFinance) (Icons.payments_outlined, 'Finance Settlement', '/finance/reimbursements'),
      if (auth.isManager) (Icons.bar_chart_outlined, 'Reports', '/reports'),
      if (auth.isAdmin) (Icons.admin_panel_settings_outlined, 'Administration & Controls', '/admin'),
    ];
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_currentEmployee != null)
                ListTile(
                  title: Text(_currentEmployee!.fullName, style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text('${_currentEmployee!.employeeCode}  |  ${_currentEmployee!.roles.map((r) => r.displayName).join(', ')}'),
                ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.notifications_none),
                title: const Text('Notifications'),
                trailing: _notifications.unread > 0
                    ? Badge(label: Text('${_notifications.unread} unread'), backgroundColor: AsmTheme.statusRejected)
                    : null,
                onTap: () {
                  Navigator.pop(sheet);
                  showNotificationPanel(context, _notifications);
                },
              ),
              for (final e in entries)
                ListTile(
                  leading: Icon(e.$1),
                  title: Text(e.$2),
                  onTap: () {
                    Navigator.pop(sheet);
                    context.go(e.$3);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.logout, color: AsmTheme.statusRejected),
                title: const Text('Sign out', style: TextStyle(color: AsmTheme.statusRejected)),
                onTap: () async {
                  Navigator.pop(sheet);
                  await AuthNotifier().signOut();
                  if (context.mounted) context.go('/login');
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  int _getMobileIndex(String route) {
    final isMgr = AuthNotifier().isManager;
    if (isMgr && route.startsWith('/approvals')) return 1;
    if (!isMgr && route.startsWith('/receipts/scan')) return 1;
    if (route.startsWith('/expenses')) return 2;
    if (route.startsWith('/claims')) return 3;
    if (route.startsWith('/approvals') ||
        route.startsWith('/advances') ||
        route.startsWith('/finance') ||
        route.startsWith('/reports') ||
        route.startsWith('/admin')) {
      return 4;
    }
    return 0;
  }
}
