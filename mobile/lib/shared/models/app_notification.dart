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
}
