enum AppRole {
  employee,
  lineManager,
  departmentManager,
  management,
  finance,
  admin;

  static AppRole fromString(String role) {
    switch (role.toUpperCase()) {
      case 'LINE_MANAGER':
        return AppRole.lineManager;
      case 'DEPARTMENT_MANAGER':
        return AppRole.departmentManager;
      case 'MANAGEMENT':
        return AppRole.management;
      case 'FINANCE':
        return AppRole.finance;
      case 'ADMIN':
        return AppRole.admin;
      case 'EMPLOYEE':
      default:
        return AppRole.employee;
    }
  }

  String get displayName {
    switch (this) {
      case AppRole.employee:
        return 'Employee';
      case AppRole.lineManager:
        return 'Line Manager';
      case AppRole.departmentManager:
        return 'Department Manager / HOD';
      case AppRole.management:
        return 'Management';
      case AppRole.finance:
        return 'Finance';
      case AppRole.admin:
        return 'Administrator';
    }
  }
}

class Employee {
  final String id;
  final String employeeCode;
  final String fullName;
  final String email;
  final String? phone;
  final String? departmentId;
  final String? departmentName;
  final String? designationTitle;
  final String? lineManagerId;
  final String? hodId;
  final bool isActive;
  final List<AppRole> roles;

  const Employee({
    required this.id,
    required this.employeeCode,
    required this.fullName,
    required this.email,
    this.phone,
    this.departmentId,
    this.departmentName,
    this.designationTitle,
    this.lineManagerId,
    this.hodId,
    this.isActive = true,
    this.roles = const [AppRole.employee],
  });

  factory Employee.fromJson(Map<String, dynamic> json, [List<AppRole> roles = const [AppRole.employee]]) {
    return Employee(
      id: json['id'] as String,
      employeeCode: json['employee_code'] as String? ?? 'UNKNOWN',
      fullName: json['full_name'] as String? ?? '',
      email: json['email'] as String? ?? '',
      phone: json['phone'] as String?,
      departmentId: json['department_id'] as String?,
      departmentName: json['departments'] != null ? json['departments']['name'] as String? : null,
      designationTitle: json['designations'] != null ? json['designations']['title'] as String? : null,
      lineManagerId: json['line_manager_id'] as String?,
      hodId: json['hod_id'] as String?,
      isActive: json['is_active'] as bool? ?? true,
      roles: roles,
    );
  }
}
