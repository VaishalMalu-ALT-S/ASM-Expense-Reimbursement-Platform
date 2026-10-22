import '../../core/network/supabase_service.dart';

/// Row of the server-generated `notifications` table.
class AppNotification {
  final String id;
  final String title;
  final String body;
  final String eventType;
  final String entityType;
  final String entityId;
  final bool isRead;
  final DateTime createdAt;

  const AppNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.eventType,
    required this.entityType,
    required this.entityId,
    required this.isRead,
    required this.createdAt,
  });

  factory AppNotification.fromJson(Map<String, dynamic> json) {
    return AppNotification(
      id: json['id'] as String,
      title: json['title'] as String? ?? '',
      body: json['body'] as String? ?? '',
      eventType: json['event_type'] as String? ?? '',
      entityType: json['entity_type'] as String? ?? '',
      entityId: json['entity_id'] as String,
      isRead: json['is_read'] as bool? ?? false,
      createdAt: DateTime.parse(json['created_at'] as String).toLocal(),
    );
  }

  /// In-app route for the record the notification refers to, if it has one.
  String? get route {
    switch (entityType) {
      case 'expense_claim':
        if (eventType == 'REIMBURSEMENT_PAYMENT_REQUIRED') return '/finance/reimbursements';
        if (eventType == 'CLAIM_APPROVAL_REQUIRED') return '/approvals';
        return '/claims/$entityId';
      case 'cash_advance':
        return eventType == 'ADVANCE_DISBURSEMENT_REQUIRED' ? '/finance/reimbursements' : '/advances/$entityId';
      case 'reimbursement':
        return '/claims';
      default:
        return null;
    }
  }

  /// Resolves direct route when entity requires foreign-key lookup (e.g. reimbursement -> claim_id).
  Future<String?> resolveRoute() async {
    if (entityType == 'reimbursement') {
      try {
        final res = await SupabaseService().client
            .from('reimbursements')
            .select('claim_id')
            .eq('id', entityId)
            .maybeSingle();
        final claimId = res?['claim_id'] as String?;
        if (claimId != null && claimId.isNotEmpty) {
          return '/claims/$claimId';
        }
      } catch (_) {}
    }
    return route;
  }
}
