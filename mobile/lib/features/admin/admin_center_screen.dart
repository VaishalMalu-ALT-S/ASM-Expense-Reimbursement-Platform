import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../app/theme/asm_theme.dart';
import '../../core/network/supabase_service.dart';
import '../../shared/models/employee.dart';

class AdminCenterScreen extends StatefulWidget {
  const AdminCenterScreen({super.key});

  @override
  State<AdminCenterScreen> createState() => _AdminCenterScreenState();
}

class _AdminCenterScreenState extends State<AdminCenterScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _supabase = SupabaseService();

  bool _isLoading = true;
  String? _errorMessage;

  // Data state
  List<Employee> _employees = [];
  List<Map<String, dynamic>> _auditLogs = [];
  List<Map<String, dynamic>> _pendingClaims = [];
  List<Map<String, dynamic>> _pendingAdvances = [];
  List<Map<String, dynamic>> _categories = [];
  List<Map<String, dynamic>> _policies = [];

  // Filter state for employees
  String _employeeSearchQuery = '';
  AppRole? _selectedRoleFilter;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _loadAllData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadAllData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final results = await Future.wait([
        _supabase.getAllEmployeesWithRoles(),
        _supabase.getAuditLogs(limit: 50),
        _supabase.getAllPendingClaimsCompanyWide(),
        _supabase.getAllPendingAdvancesCompanyWide(),
        _supabase.client.from('expense_categories').select().order('name'),
        _supabase.getAllPolicyRules(),
      ]);

      if (mounted) {
        setState(() {
          _employees = results[0] as List<Employee>;
          _auditLogs = results[1] as List<Map<String, dynamic>>;
          _pendingClaims = results[2] as List<Map<String, dynamic>>;
          _pendingAdvances = results[3] as List<Map<String, dynamic>>;
          _categories = (results[4] as List).map((c) => Map<String, dynamic>.from(c as Map)).toList();
          _policies = results[5] as List<Map<String, dynamic>>;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to load administration telemetry: $e';
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AsmTheme.surfaceBackground,
      appBar: AppBar(
        title: const Text('Admin Center & Governance'),
        backgroundColor: AsmTheme.primaryNavy,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Refresh All Telemetry',
            icon: const Icon(Icons.refresh),
            onPressed: _loadAllData,
          ),
          const SizedBox(width: 8),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AsmTheme.accentGold,
          indicatorWeight: 3,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          isScrollable: true,
          tabs: [
            Tab(
              icon: const Icon(Icons.people_alt_outlined, size: 20),
              text: 'Employees (${_employees.length})',
            ),
            Tab(
              icon: const Icon(Icons.gavel_outlined, size: 20),
              text: 'Pending Approvals (${_pendingClaims.length + _pendingAdvances.length})',
            ),
            Tab(
              icon: const Icon(Icons.history_outlined, size: 20),
              text: 'Audit Trail (${_auditLogs.length})',
            ),
            Tab(
              icon: const Icon(Icons.tune_outlined, size: 20),
              text: 'Categories & Policy (${_categories.length})',
            ),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: AsmTheme.primaryNavy),
                  SizedBox(height: 16),
                  Text('Securing corporate administrative telemetry...', style: TextStyle(color: AsmTheme.textMuted)),
                ],
              ),
            )
          : _errorMessage != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline, size: 48, color: AsmTheme.statusRejected),
                        const SizedBox(height: 16),
                        Text(_errorMessage!, textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          onPressed: _loadAllData,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                )
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _buildEmployeesTab(),
                    _buildCompanyApprovalsTab(),
                    _buildAuditLogsTab(),
                    _buildPoliciesTab(),
                  ],
                ),
    );
  }

  // ==========================================================================
  // TAB 1: EMPLOYEES & ROLES
  // ==========================================================================
  Widget _buildEmployeesTab() {
    final filtered = _employees.where((e) {
      final matchesQuery = _employeeSearchQuery.isEmpty ||
          e.fullName.toLowerCase().contains(_employeeSearchQuery.toLowerCase()) ||
          e.employeeCode.toLowerCase().contains(_employeeSearchQuery.toLowerCase()) ||
          e.email.toLowerCase().contains(_employeeSearchQuery.toLowerCase()) ||
          (e.departmentName?.toLowerCase().contains(_employeeSearchQuery.toLowerCase()) ?? false);

      final matchesRole = _selectedRoleFilter == null || e.roles.contains(_selectedRoleFilter);

      return matchesQuery && matchesRole;
    }).toList();

    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth >= 900;

        return Column(
          children: [
            // Controls header
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.search, size: 20),
                            hintText: 'Search employees by name, code, email, or department...',
                            isDense: true,
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                            filled: true,
                            fillColor: AsmTheme.surfaceBackground,
                          ),
                          onChanged: (val) => setState(() => _employeeSearchQuery = val),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        FilterChip(
                          label: const Text('All Roles'),
                          selected: _selectedRoleFilter == null,
                          onSelected: (_) => setState(() => _selectedRoleFilter = null),
                        ),
                        const SizedBox(width: 8),
                        for (final role in AppRole.values) ...[
                          FilterChip(
                            label: Text(role.displayName),
                            selected: _selectedRoleFilter == role,
                            onSelected: (selected) {
                              setState(() {
                                _selectedRoleFilter = selected ? role : null;
                              });
                            },
                          ),
                          const SizedBox(width: 8),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // Employee List (Responsive)
            Expanded(
              child: filtered.isEmpty
                  ? const Center(
                      child: Text('No employees found matching filter criteria.', style: TextStyle(color: AsmTheme.textMuted)),
                    )
                  : isDesktop
                      ? _buildDesktopEmployeeTable(filtered)
                      : _buildMobileEmployeeList(filtered),
            ),
          ],
        );
      },
    );
  }

  Widget _buildDesktopEmployeeTable(List<Employee> list) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Card(
        elevation: 1,
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        child: DataTable(
          headingRowColor: WidgetStateProperty.all(AsmTheme.surfaceBackground),
          columns: const [
            DataColumn(label: Text('Code', style: TextStyle(fontWeight: FontWeight.bold))),
            DataColumn(label: Text('Name', style: TextStyle(fontWeight: FontWeight.bold))),
            DataColumn(label: Text('Department', style: TextStyle(fontWeight: FontWeight.bold))),
            DataColumn(label: Text('Designation', style: TextStyle(fontWeight: FontWeight.bold))),
            DataColumn(label: Text('Assigned Roles', style: TextStyle(fontWeight: FontWeight.bold))),
            DataColumn(label: Text('Status', style: TextStyle(fontWeight: FontWeight.bold))),
            DataColumn(label: Text('Actions', style: TextStyle(fontWeight: FontWeight.bold))),
          ],
          rows: list.map((emp) {
            return DataRow(
              cells: [
                DataCell(Text(emp.employeeCode, style: const TextStyle(fontWeight: FontWeight.w600))),
                DataCell(
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(emp.fullName, style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text(emp.email, style: const TextStyle(fontSize: 11, color: AsmTheme.textMuted)),
                    ],
                  ),
                ),
                DataCell(Text(emp.departmentName ?? '—')),
                DataCell(Text(emp.designationTitle ?? '—')),
                DataCell(
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: emp.roles.map((r) => _buildRoleBadge(r)).toList(),
                  ),
                ),
                DataCell(
                  Switch(
                    value: emp.isActive,
                    activeColor: AsmTheme.statusApproved,
                    onChanged: (val) => _toggleEmployeeStatus(emp, val),
                  ),
                ),
                DataCell(
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AsmTheme.primaryNavy,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    ),
                    icon: const Icon(Icons.manage_accounts, size: 16),
                    label: const Text('Manage Roles', style: TextStyle(fontSize: 12)),
                    onPressed: () => _openRoleEditor(emp),
                  ),
                ),
              ],
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildMobileEmployeeList(List<Employee> list) {
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: list.length,
      itemBuilder: (context, index) {
        final emp = list[index];
        return Card(
          elevation: 1,
          color: Colors.white,
          margin: const EdgeInsets.only(bottom: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: AsmTheme.borderLight),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      backgroundColor: AsmTheme.accentGold,
                      radius: 18,
                      child: Text(
                        emp.fullName.isNotEmpty ? emp.fullName[0].toUpperCase() : 'U',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(emp.fullName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                          Text('${emp.employeeCode} • ${emp.email}',
                              style: const TextStyle(fontSize: 12, color: AsmTheme.textMuted)),
                        ],
                      ),
                    ),
                    Switch(
                      value: emp.isActive,
                      activeColor: AsmTheme.statusApproved,
                      onChanged: (val) => _toggleEmployeeStatus(emp, val),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (emp.departmentName != null || emp.designationTitle != null) ...[
                  Text(
                    '${emp.departmentName ?? 'General'} • ${emp.designationTitle ?? 'Staff'}',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AsmTheme.textHeading),
                  ),
                  const SizedBox(height: 10),
                ],
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: emp.roles.map((r) => _buildRoleBadge(r)).toList(),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.manage_accounts, size: 16),
                    label: const Text('Assign / Modify Roles'),
                    onPressed: () => _openRoleEditor(emp),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildRoleBadge(AppRole role) {
    Color bg;
    Color fg;
    switch (role) {
      case AppRole.admin:
        bg = Colors.purple.shade50;
        fg = Colors.purple.shade800;
        break;
      case AppRole.management:
        bg = Colors.amber.shade50;
        fg = Colors.amber.shade900;
        break;
      case AppRole.finance:
        bg = Colors.green.shade50;
        fg = Colors.green.shade800;
        break;
      case AppRole.departmentManager:
        bg = Colors.indigo.shade50;
        fg = Colors.indigo.shade800;
        break;
      case AppRole.lineManager:
        bg = Colors.blue.shade50;
        fg = Colors.blue.shade800;
        break;
      case AppRole.employee:
        bg = Colors.grey.shade100;
        fg = Colors.grey.shade800;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
      child: Text(
        role.displayName,
        style: TextStyle(color: fg, fontSize: 10, fontWeight: FontWeight.bold),
      ),
    );
  }

  Future<void> _toggleEmployeeStatus(Employee emp, bool newStatus) async {
    final success = await _supabase.toggleEmployeeActive(emp.id, newStatus);
    if (success) {
      setState(() {
        final idx = _employees.indexWhere((e) => e.id == emp.id);
        if (idx != -1) {
          final updated = Employee(
            id: emp.id,
            employeeCode: emp.employeeCode,
            fullName: emp.fullName,
            email: emp.email,
            phone: emp.phone,
            departmentId: emp.departmentId,
            departmentName: emp.departmentName,
            designationTitle: emp.designationTitle,
            lineManagerId: emp.lineManagerId,
            hodId: emp.hodId,
            isActive: newStatus,
            roles: emp.roles,
          );
          _employees[idx] = updated;
        }
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${emp.fullName} is now ${newStatus ? 'Active' : 'Inactive'}')),
        );
      }
    }
  }

  void _openRoleEditor(Employee emp) {
    final selectedRoles = Set<AppRole>.from(emp.roles);

    showDialog<void>(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text('Manage Roles: ${emp.fullName}'),
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Employee Code: ${emp.employeeCode}', style: const TextStyle(color: AsmTheme.textMuted)),
                      const SizedBox(height: 12),
                      for (final role in AppRole.values)
                        CheckboxListTile(
                          title: Text(role.displayName, style: const TextStyle(fontWeight: FontWeight.w600)),
                          value: selectedRoles.contains(role),
                          activeColor: AsmTheme.primaryNavy,
                          onChanged: (checked) {
                            setDialogState(() {
                              if (checked == true) {
                                selectedRoles.add(role);
                              } else {
                                // Ensure at least Employee role remains
                                if (role != AppRole.employee || selectedRoles.length > 1) {
                                  selectedRoles.remove(role);
                                }
                              }
                            });
                          },
                        ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogCtx),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AsmTheme.primaryNavy,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () async {
                    Navigator.pop(dialogCtx);
                    final rolesList = selectedRoles.toList();
                    final ok = await _supabase.updateEmployeeRoles(emp.id, rolesList);
                    if (ok) {
                      await _loadAllData();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Roles updated successfully for ${emp.fullName}')),
                        );
                      }
                    }
                  },
                  child: const Text('Save Roles'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ==========================================================================
  // TAB 2: COMPANY-WIDE PENDING APPROVALS & OVERRIDES
  // ==========================================================================
  Widget _buildCompanyApprovalsTab() {
    if (_pendingClaims.isEmpty && _pendingAdvances.isEmpty) {
      return const Center(
        child: Text('All company claims and advances are fully reviewed.', style: TextStyle(color: AsmTheme.textMuted)),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_pendingClaims.isNotEmpty) ...[
          _buildSectionHeader('Pending Expense Claims Across Organization (${_pendingClaims.length})'),
          const SizedBox(height: 8),
          for (final claim in _pendingClaims) _buildAdminClaimCard(claim),
          const SizedBox(height: 24),
        ],
        if (_pendingAdvances.isNotEmpty) ...[
          _buildSectionHeader('Pending Cash Advances Across Organization (${_pendingAdvances.length})'),
          const SizedBox(height: 8),
          for (final advance in _pendingAdvances) _buildAdminAdvanceCard(advance),
        ],
      ],
    );
  }

  Widget _buildSectionHeader(String title) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AsmTheme.primaryNavy.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AsmTheme.primaryNavy),
      ),
    );
  }

  Widget _buildAdminClaimCard(Map<String, dynamic> claim) {
    final claimId = claim['id'] as String;
    final claimNum = claim['claim_number'] as String? ?? 'CLM';
    final emp = claim['employees'] as Map<String, dynamic>?;
    final empName = emp?['full_name'] as String? ?? 'Employee';
    final status = claim['status'] as String? ?? 'PENDING';
    final amountMinor = ((claim['net_reimbursement_minor'] ?? claim['total_expense_minor'] ?? 0) as num).toInt();
    final amountAed = (amountMinor / 100.0).toStringAsFixed(2);
    final purpose = claim['purpose'] as String? ?? '';

    return Card(
      elevation: 1,
      color: Colors.white,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(claimNum, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      Text('$empName • Stage: $status', style: const TextStyle(fontSize: 12, color: AsmTheme.textMuted)),
                    ],
                  ),
                ),
                Text('AED $amountAed', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17, color: AsmTheme.brandBlue)),
              ],
            ),
            if (purpose.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(purpose, style: const TextStyle(fontSize: 13, color: AsmTheme.textBody)),
            ],
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton(
                  onPressed: () => context.push('/claims/$claimId'),
                  child: const Text('View Claim'),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: AsmTheme.statusApproved, foregroundColor: Colors.white),
                  icon: const Icon(Icons.check, size: 16),
                  label: const Text('Admin Override Approve'),
                  onPressed: () => _executeAdminClaimAction(claimId, 'APPROVE'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAdminAdvanceCard(Map<String, dynamic> adv) {
    final advId = adv['id'] as String;
    final advNum = adv['advance_number'] as String? ?? 'ADV';
    final emp = adv['employees'] as Map<String, dynamic>?;
    final empName = emp?['full_name'] as String? ?? 'Employee';
    final status = adv['status'] as String? ?? 'PENDING';
    final amountMinor = adv['amount_minor'] as int? ?? 0;
    final amountAed = (amountMinor / 100.0).toStringAsFixed(2);
    final purpose = adv['purpose'] as String? ?? '';

    return Card(
      elevation: 1,
      color: Colors.white,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(advNum, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      Text('$empName • Stage: $status', style: const TextStyle(fontSize: 12, color: AsmTheme.textMuted)),
                    ],
                  ),
                ),
                Text('AED $amountAed', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17, color: AsmTheme.accentGold)),
              ],
            ),
            if (purpose.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(purpose, style: const TextStyle(fontSize: 13, color: AsmTheme.textBody)),
            ],
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton(
                  onPressed: () => context.push('/advances/$advId'),
                  child: const Text('View Advance'),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: AsmTheme.statusApproved, foregroundColor: Colors.white),
                  icon: const Icon(Icons.check, size: 16),
                  label: const Text('Admin Override Approve'),
                  onPressed: () => _executeAdminAdvanceAction(advId, 'APPROVE'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _executeAdminAdvanceAction(String advId, String action) async {
    final reasonController = TextEditingController(text: 'Administrative review and executive clearance.');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Admin Advance Override'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Enter the official administrative justification for overriding this advance stage:'),
              const SizedBox(height: 12),
              TextField(
                controller: reasonController,
                maxLines: 3,
                decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'Administrative justification...'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AsmTheme.primaryNavy, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm Override'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final res = await _supabase.client.rpc('review_cash_advance', params: {
          'p_advance_id': advId,
          'p_action': action,
          'p_comments': reasonController.text.trim(),
        });

        if (mounted) {
          final isSuccess = res != null && res['success'] == true;
          if (isSuccess) {
            setState(() {
              _pendingAdvances.removeWhere((a) => a['id'] == advId);
            });
          }
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(isSuccess ? 'Advance approval override applied successfully.' : '${res?['message'] ?? 'Action failed'}'),
              backgroundColor: isSuccess ? AsmTheme.statusApproved : AsmTheme.statusRejected,
            ),
          );
          await _loadAllData();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Override failed: $e'), backgroundColor: AsmTheme.statusRejected),
          );
        }
      }
    }
  }

  Future<void> _executeAdminClaimAction(String claimId, String action) async {
    final reasonController = TextEditingController(text: 'Administrative review and executive clearance.');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Admin Approval Override'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Enter the official administrative justification for overriding this approval stage:'),
              const SizedBox(height: 12),
              TextField(
                controller: reasonController,
                maxLines: 3,
                decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'Administrative justification...'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AsmTheme.primaryNavy, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm Override'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final res = await _supabase.client.rpc('process_approval_action', params: {
          'p_claim_id': claimId,
          'p_action': action,
          'p_comments': reasonController.text.trim(),
        });

        if (mounted) {
          final isSuccess = res != null && res['success'] == true;
          if (isSuccess) {
            setState(() {
              _pendingClaims.removeWhere((c) => c['id'] == claimId);
            });
          }
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(isSuccess ? 'Approval override applied successfully.' : '${res?['message'] ?? 'Action failed'}'),
              backgroundColor: isSuccess ? AsmTheme.statusApproved : AsmTheme.statusRejected,
            ),
          );
          await _loadAllData();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Override failed: $e'), backgroundColor: AsmTheme.statusRejected),
          );
        }
      }
    }
  }

  // ==========================================================================
  // TAB 3: SYSTEM AUDIT LOGS
  // ==========================================================================
  Widget _buildAuditLogsTab() {
    if (_auditLogs.isEmpty) {
      return const Center(child: Text('No system audit events recorded yet.', style: TextStyle(color: AsmTheme.textMuted)));
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _auditLogs.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final log = _auditLogs[index];
        final action = log['action'] as String? ?? 'ACTION';
        final entityType = log['entity_type'] as String? ?? '';
        final createdAt = log['created_at'] != null ? DateTime.tryParse(log['created_at']) : null;
        final actor = log['employees'] as Map<String, dynamic>?;
        final actorName = actor?['full_name'] as String? ?? log['actor_role'] ?? 'System';

        return Card(
          elevation: 1,
          color: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          child: ExpansionTile(
            leading: const Icon(Icons.security, size: 20, color: AsmTheme.primaryNavy),
            title: Text(action, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            subtitle: Text(
              '$actorName • $entityType • ${createdAt != null ? "${createdAt.day}/${createdAt.month}/${createdAt.year} ${createdAt.hour}:${createdAt.minute.toString().padLeft(2, '0')}" : ''}',
              style: const TextStyle(fontSize: 12, color: AsmTheme.textMuted),
            ),
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AsmTheme.surfaceBackground,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'New Values: ${log['new_values'] ?? 'None'}\nOld Values: ${log['old_values'] ?? 'None'}',
                    style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ==========================================================================
  // TAB 4: CATEGORIES & POLICY RULES
  // ==========================================================================
  Widget _buildPoliciesTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildSectionHeader('Expense Categories & Receipt Mandates (${_categories.length})'),
        const SizedBox(height: 12),
        for (final cat in _categories)
          Card(
            elevation: 1,
            color: Colors.white,
            margin: const EdgeInsets.only(bottom: 8),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            child: ListTile(
              leading: const Icon(Icons.category_outlined, color: AsmTheme.brandBlue),
              title: Text(cat['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(
                'Code: ${cat['code']} • Requires Receipt: ${cat['requires_receipt'] == true ? 'YES' : 'NO'}',
                style: const TextStyle(fontSize: 12, color: AsmTheme.textMuted),
              ),
              trailing: Switch(
                value: cat['is_active'] as bool? ?? true,
                activeColor: AsmTheme.statusApproved,
                onChanged: (val) async {
                  final ok = await _supabase.toggleCategoryActive(cat['id'] as String, val);
                  if (ok) {
                    setState(() => cat['is_active'] = val);
                  }
                },
              ),
            ),
          ),
        const SizedBox(height: 24),
        _buildSectionHeader('Corporate Policy Thresholds (${_policies.length})'),
        const SizedBox(height: 12),
        for (final pol in _policies)
          Card(
            elevation: 1,
            color: Colors.white,
            margin: const EdgeInsets.only(bottom: 8),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            child: ListTile(
              leading: const Icon(Icons.rule_folder_outlined, color: AsmTheme.accentGold),
              title: Text(pol['rule_key'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(
                '${pol['description'] ?? ''}\nValue: ${pol['rule_value']}',
                style: const TextStyle(fontSize: 12, color: AsmTheme.textMuted),
              ),
              isThreeLine: true,
            ),
          ),
      ],
    );
  }
}
