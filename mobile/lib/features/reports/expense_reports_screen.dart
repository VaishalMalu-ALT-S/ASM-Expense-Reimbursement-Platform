import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../core/network/supabase_service.dart';
import '../../core/utils/money_utils.dart';
import '../../core/utils/file_exporter.dart';
import '../../shared/models/expense_claim.dart';
import '../../shared/widgets/async_states.dart';
import '../../shared/widgets/status_badge.dart';
import '../../app/theme/asm_theme.dart';

/// Professional Executive Expense & Financial Intelligence Reports.
/// Powered by live corporate telemetry from Supabase.
class ExpenseReportsScreen extends StatefulWidget {
  const ExpenseReportsScreen({super.key});

  @override
  State<ExpenseReportsScreen> createState() => _ExpenseReportsScreenState();
}

class _ExpenseReportsScreenState extends State<ExpenseReportsScreen> {
  static const _limit = 250;
  static const _statusGroups = <String, List<String>?>{
    'All statuses': null,
    'In approval': ['SUBMITTED', 'LINE_MANAGER_REVIEW', 'HOD_REVIEW', 'SIVA_REVIEW', 'FINANCE_REVIEW'],
    'Needs correction': ['CORRECTION_REQUIRED'],
    'Awaiting payment': ['APPROVED', 'REIMBURSEMENT_PROCESSING'],
    'Paid / settled': ['PAID', 'SETTLED'],
    'Rejected / cancelled': ['REJECTED', 'CANCELLED'],
  };
  static const _periods = <String, int?>{
    'Last 30 days': 30,
    'Last 90 days': 90,
    'Last 12 months': 365,
    'All time': null,
  };

  List<Map<String, dynamic>> _claims = [];
  List<Map<String, dynamic>> _departments = [];
  String _status = 'All statuses';
  String _period = 'Last 90 days';
  String? _departmentId;
  String _searchQuery = '';
  bool _isLoading = true;
  String? _error;
  bool _isExporting = false;

  @override
  void initState() {
    super.initState();
    _loadDepartments();
    _load();
  }

  Future<void> _loadDepartments() async {
    try {
      final res = await SupabaseService().client
          .from('departments')
          .select('id, name')
          .eq('is_active', true)
          .order('name');
      if (mounted) {
        setState(() => _departments = List<Map<String, dynamic>>.from(res as List));
      }
    } catch (_) {
      // Graceful fallback if department table is inaccessible
    }
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      var q = SupabaseService().client.from('expense_claims').select(
          'id, claim_number, title, purpose, status, claim_date, total_expense_minor, net_reimbursement_minor, '
          'employees!inner(full_name, employee_code, department_id, departments!employees_department_id_fkey(name))');

      final statuses = _statusGroups[_status];
      if (statuses != null) q = q.inFilter('status', statuses);

      final days = _periods[_period];
      if (days != null) {
        final threshold = DateTime.now().subtract(Duration(days: days)).toIso8601String().split('T')[0];
        q = q.gte('claim_date', threshold);
      }

      if (_departmentId != null) q = q.eq('employees.department_id', _departmentId!);

      final res = await q.order('claim_date', ascending: false).limit(_limit);
      if (mounted) {
        setState(() {
          _claims = List<Map<String, dynamic>>.from(res as List);
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Report telemetry could not be loaded from server. Check your connection and try again.';
          _isLoading = false;
        });
      }
    }
  }

  int _sum(Iterable<Map<String, dynamic>> rows, String col) =>
      rows.fold<int>(0, (s, r) => s + ((r[col] as num?)?.toInt() ?? 0));

  List<Map<String, dynamic>> get _filteredClaims {
    if (_searchQuery.trim().isEmpty) return _claims;
    final q = _searchQuery.toLowerCase().trim();
    return _claims.where((c) {
      final numStr = (c['claim_number'] as String? ?? '').toLowerCase();
      final title = (c['title'] as String? ?? '').toLowerCase();
      final emp = c['employees'] as Map<String, dynamic>?;
      final empName = (emp?['full_name'] as String? ?? '').toLowerCase();
      final dept = (emp?['departments'] as Map<String, dynamic>?)?['name'] as String? ?? '';
      return numStr.contains(q) || title.contains(q) || empName.contains(q) || dept.toLowerCase().contains(q);
    }).toList();
  }

  String _generateCsvContent(List<Map<String, dynamic>> items) {
    final buffer = StringBuffer();
    // CSV Header
    buffer.writeln('Claim Number,Title,Employee,Employee Code,Department,Claim Date,Total Expense (AED),Net Reimbursement (AED),Status');

    for (final c in items) {
      final emp = c['employees'] as Map<String, dynamic>?;
      final dept = (emp?['departments'] as Map<String, dynamic>?)?['name'] as String? ?? 'N/A';
      final empName = ((emp?['full_name'] as String? ?? 'Employee')).replaceAll(RegExp(r'\s*\([^)]*\)'), '').trim();
      final empCode = emp?['employee_code'] as String? ?? '';
      final totalAed = MoneyUtils.formatAmount((c['total_expense_minor'] as num?)?.toInt() ?? 0);
      final netAed = MoneyUtils.formatAmount((c['net_reimbursement_minor'] as num?)?.toInt() ?? 0);
      final status = ClaimStatus.fromString(c['status'] as String? ?? '').displayName;

      String escape(String val) => '"${val.replaceAll('"', '""')}"';

      buffer.writeln([
        escape(c['claim_number'] as String? ?? ''),
        escape(c['title'] as String? ?? ''),
        escape(empName),
        escape(empCode),
        escape(dept),
        escape(c['claim_date'] as String? ?? ''),
        escape(totalAed),
        escape(netAed),
        escape(status),
      ].join(','));
    }

    return buffer.toString();
  }

  Future<void> _exportReport() async {
    final items = _filteredClaims;
    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No data available to download for the current filters.')),
      );
      return;
    }

    setState(() => _isExporting = true);
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.')[0];
    final filename = 'ASM_Expense_Report_$timestamp.csv';
    final csvContent = _generateCsvContent(items);

    final success = await downloadReportFile(filename: filename, content: csvContent);
    if (!mounted) return;
    setState(() => _isExporting = false);

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.check_circle_outline, color: AsmTheme.statusApproved, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Expense Report Ready', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
                      Text('${items.length} records exported • $filename', style: const TextStyle(fontSize: 12, color: AsmTheme.textMuted)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              'Your official CSV report has been triggered for download and formatted according to corporate financial accounting specifications.',
              style: TextStyle(fontSize: 13, color: AsmTheme.textBody),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Copy CSV Data'),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: csvContent));
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('CSV report copied to clipboard.')),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AsmTheme.primaryNavy,
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.download, size: 16),
                    label: const Text('Re-download'),
                    onPressed: () {
                      downloadReportFile(filename: filename, content: csvContent);
                      Navigator.pop(ctx);
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Exported ${items.length} claims to $filename'),
          backgroundColor: AsmTheme.statusApproved,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final claims = _filteredClaims;
    final totalSpendMinor = _sum(claims, 'total_expense_minor');
    final paidMinor = _sum(claims.where((c) => c['status'] == 'PAID' || c['status'] == 'SETTLED'), 'net_reimbursement_minor');
    final pendingMinor = _sum(claims.where((c) => c['status'] == 'APPROVED' || c['status'] == 'REIMBURSEMENT_PROCESSING' || c['status'] == 'FINANCE_REVIEW'), 'total_expense_minor');

    final distribution = <String, int>{};
    for (final c in claims) {
      final s = ClaimStatus.fromString(c['status'] as String? ?? '').displayName;
      distribution[s] = (distribution[s] ?? 0) + 1;
    }
    final maxCount = distribution.values.fold<int>(0, (m, v) => v > m ? v : m);

    return Scaffold(
      backgroundColor: AsmTheme.surfaceBackground,
      appBar: AppBar(
        title: const Text('Expense Reports & Intelligence'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload Telemetry',
            onPressed: _load,
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: _isExporting
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.white)),
                  )
                : TextButton.icon(
                    style: TextButton.styleFrom(foregroundColor: Colors.white),
                    icon: const Icon(Icons.download_rounded, size: 20),
                    label: const Text('Export CSV', style: TextStyle(fontWeight: FontWeight.w600)),
                    onPressed: _exportReport,
                  ),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= 900;
          final isTablet = constraints.maxWidth >= 600 && constraints.maxWidth < 900;

          return RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: EdgeInsets.symmetric(horizontal: isWide ? 32 : 16, vertical: 20),
              children: [
                // Top Executive Title Bar
                _buildHeader(isWide),
                const SizedBox(height: 20),

                // Filters Card
                _buildFiltersCard(isWide),
                const SizedBox(height: 20),

                if (_isLoading)
                  const SizedBox(height: 380, child: SkeletonList(rows: 5))
                else if (_error != null)
                  StateMessage.error(message: _error!, onAction: _load)
                else ...[
                  // 4 KPI Summary Cards
                  _buildKpiMetrics(
                    isWide: isWide,
                    isTablet: isTablet,
                    totalCount: claims.length,
                    totalSpendMinor: totalSpendMinor,
                    paidMinor: paidMinor,
                    pendingMinor: pendingMinor,
                  ),
                  const SizedBox(height: 20),

                  // Analytics Distribution + Status Breakdown
                  if (claims.isNotEmpty) ...[
                    _buildStatusDistributionCard(distribution, maxCount, claims.length),
                    const SizedBox(height: 20),
                  ],

                  // Table / List Header
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Audit Records (${claims.length} claims)',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: AsmTheme.primaryNavy),
                      ),
                      if (claims.isNotEmpty)
                        TextButton.icon(
                          icon: const Icon(Icons.file_download_outlined, size: 16),
                          label: const Text('Download CSV'),
                          onPressed: _exportReport,
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  if (claims.isEmpty)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: StateMessage(
                          icon: Icons.insights_outlined,
                          title: 'No Claims Match Active Filter',
                          message: 'Adjust your search keyword, date period, or status criteria to inspect corporate records.',
                        ),
                      ),
                    )
                  else
                    for (int i = 0; i < claims.length; i++)
                      _buildClaimRow(claims[i]),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildHeader(bool isWide) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AsmTheme.primaryNavy,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.analytics_outlined, color: AsmTheme.accentGold, size: 28),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  'Corporate Expense Analytics & Audit Report',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
                ),
                SizedBox(height: 4),
                Text(
                  'Real-time financial status, audit compliance, and department expenditure breakdown',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ),
          if (isWide)
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AsmTheme.accentGold,
                foregroundColor: AsmTheme.primaryNavy,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              icon: const Icon(Icons.download, size: 18),
              label: const Text('Download CSV', style: TextStyle(fontWeight: FontWeight.bold)),
              onPressed: _exportReport,
            ),
        ],
      ),
    );
  }

  Widget _buildFiltersCard(bool isWide) {
    return Card(
      elevation: 1,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Search Input
            TextField(
              decoration: InputDecoration(
                hintText: 'Search by claim #, title, employee name, or department...',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                filled: true,
                fillColor: AsmTheme.surfaceBackground,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
              ),
              onChanged: (val) => setState(() => _searchQuery = val),
            ),
            const SizedBox(height: 14),

            // Dropdown Filters Row
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _buildDropdown<String>(
                  label: 'Workflow Stage',
                  value: _status,
                  items: {for (final k in _statusGroups.keys) k: k},
                  onChanged: (v) {
                    if (v != null) {
                      setState(() => _status = v);
                      _load();
                    }
                  },
                ),
                _buildDropdown<String>(
                  label: 'Reporting Period',
                  value: _period,
                  items: {for (final k in _periods.keys) k: k},
                  onChanged: (v) {
                    if (v != null) {
                      setState(() => _period = v);
                      _load();
                    }
                  },
                ),
                if (_departments.isNotEmpty)
                  _buildDropdown<String?>(
                    label: 'Department',
                    value: _departmentId,
                    items: {
                      null: 'All Departments',
                      for (final d in _departments) d['id'] as String: d['name'] as String,
                    },
                    onChanged: (v) {
                      setState(() => _departmentId = v);
                      _load();
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDropdown<T>({
    required String label,
    required T value,
    required Map<T, String> items,
    required ValueChanged<T?> onChanged,
  }) {
    return SizedBox(
      width: 220,
      child: DropdownButtonFormField<T>(
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
        items: items.entries
            .map((e) => DropdownMenuItem<T>(
                  value: e.key,
                  child: Text(e.value, style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis),
                ))
            .toList(),
        onChanged: onChanged,
      ),
    );
  }

  Widget _buildKpiMetrics({
    required bool isWide,
    required bool isTablet,
    required int totalCount,
    required int totalSpendMinor,
    required int paidMinor,
    required int pendingMinor,
  }) {
    final cards = [
      _kpiCard(
        title: 'Total Claims',
        value: '$totalCount',
        subtitle: 'In current filter period',
        icon: Icons.receipt_long_outlined,
        color: AsmTheme.brandBlue,
      ),
      _kpiCard(
        title: 'Total Expenditure',
        value: MoneyUtils.format(totalSpendMinor),
        subtitle: 'Gross audited expenses',
        icon: Icons.account_balance_wallet_outlined,
        color: AsmTheme.primaryNavy,
      ),
      _kpiCard(
        title: 'Settled & Paid',
        value: MoneyUtils.format(paidMinor),
        subtitle: 'Completed payouts',
        icon: Icons.verified_outlined,
        color: AsmTheme.statusApproved,
      ),
      _kpiCard(
        title: 'Pending Pipeline',
        value: MoneyUtils.format(pendingMinor),
        subtitle: 'Awaiting approvals & payment',
        icon: Icons.hourglass_bottom_outlined,
        color: AsmTheme.statusPending,
      ),
    ];

    if (isWide) {
      return Row(
        children: cards.map((c) => Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: c))).toList(),
      );
    } else if (isTablet) {
      return Column(
        children: [
          Row(children: [Expanded(child: cards[0]), const SizedBox(width: 8), Expanded(child: cards[1])]),
          const SizedBox(height: 8),
          Row(children: [Expanded(child: cards[2]), const SizedBox(width: 8), Expanded(child: cards[3])]),
        ],
      );
    } else {
      return Column(
        children: cards.map((c) => Padding(padding: const EdgeInsets.only(bottom: 8), child: c)).toList(),
      );
    }
  }

  Widget _kpiCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color color,
  }) {
    return Card(
      elevation: 1,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 12, color: AsmTheme.textMuted)),
                  const SizedBox(height: 2),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      value,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AsmTheme.textHeading),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(subtitle, style: const TextStyle(fontSize: 11, color: AsmTheme.textSecondary)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusDistributionCard(Map<String, int> distribution, int maxCount, int totalClaims) {
    final sortedEntries = distribution.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

    return Card(
      elevation: 1,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Workflow Status Breakdown', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                Text('$totalClaims total claims', style: const TextStyle(fontSize: 12, color: AsmTheme.textMuted)),
              ],
            ),
            const SizedBox(height: 16),
            for (final e in sortedEntries) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(e.key, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                        Text(
                          '${e.value} (${(e.value / totalClaims * 100).toStringAsFixed(1)}%)',
                          style: const TextStyle(fontSize: 12, color: AsmTheme.textSecondary),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: maxCount == 0 ? 0 : e.value / maxCount,
                        minHeight: 8,
                        backgroundColor: AsmTheme.surfaceBackground,
                        color: StatusBadge.styleFor(e.key).fg,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildClaimRow(Map<String, dynamic> claim) {
    final emp = claim['employees'] as Map<String, dynamic>?;
    final dept = emp?['departments'] as Map<String, dynamic>?;
    final empName = ((emp?['full_name'] as String? ?? 'Employee')).replaceAll(RegExp(r'\s*\([^)]*\)'), '').trim();
    final status = ClaimStatus.fromString(claim['status'] as String? ?? '').displayName;
    final totalMinor = (claim['total_expense_minor'] as num?)?.toInt() ?? 0;

    return Card(
      elevation: 0.5,
      color: Colors.white,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        onTap: () => context.push('/claims/${claim['id']}'),
        leading: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: AsmTheme.primaryNavy.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(Icons.receipt_outlined, color: AsmTheme.primaryNavy, size: 22),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                claim['title'] as String? ?? 'Claim',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              MoneyUtils.format(totalMinor),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AsmTheme.primaryNavy),
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '#${claim['claim_number']} • $empName • ${dept?['name'] ?? 'Department'} • ${claim['claim_date'] ?? ''}',
                  style: const TextStyle(fontSize: 12, color: AsmTheme.textMuted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              StatusBadge(status: status),
            ],
          ),
        ),
      ),
    );
  }
}
