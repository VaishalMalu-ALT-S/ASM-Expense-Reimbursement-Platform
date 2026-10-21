import os, urllib.request, json, csv, secrets
from pathlib import Path

# Load service key from environment or local .env
service_key = os.environ.get('SUPABASE_SERVICE_ROLE_KEY')
if not service_key:
    env_file = Path(__file__).resolve().parent / '.env'
    if env_file.exists():
        for line in env_file.read_text(encoding='utf-8').splitlines():
            if line.startswith('SUPABASE_SERVICE_ROLE_KEY='):
                service_key = line.split('=', 1)[1].strip().strip('"').strip("'")
                break

if not service_key:
    raise RuntimeError("SUPABASE_SERVICE_ROLE_KEY environment variable is required.")

# Each account gets a unique temporary password, written only to this CSV for
# secure hand-over (never printed).
credentials_file = os.environ.get('CREDENTIALS_OUT_FILE')
if not credentials_file:
    raise RuntimeError("CREDENTIALS_OUT_FILE environment variable is required (CSV path for temporary passwords).")


def record_temporary_password(email, password):
    new_file = not Path(credentials_file).exists()
    with open(credentials_file, 'a', newline='', encoding='utf-8') as fh:
        writer = csv.writer(fh)
        if new_file:
            writer.writerow(['email', 'temporary_password'])
        writer.writerow([email, password])

headers = {
    'apikey': service_key,
    'Authorization': 'Bearer ' + service_key,
    'Content-Type': 'application/json',
    'Prefer': 'return=representation'
}

OPERATIONS_DEPT = 'e59f3c65-76dd-4f1b-8c3f-ce0aa473e2b9'
FINANCE_DEPT = '4e063a61-80e4-4a26-9979-4e6aea961e38'
ADMIN_DEPT = 'e707c393-6dce-4fe9-a286-5ed6ac646faa'
HOD_ID = '825cdfe4-93d2-4e25-9742-5e8e296a3e48' # Dr. Khalid

req_exec = urllib.request.Request(
    'https://vrnqemqzmklrjpssneng.supabase.co/rest/v1/departments?code=eq.EXEC_MGMT&select=id',
    headers=headers
)
_exec_rows = json.loads(urllib.request.urlopen(req_exec).read().decode())
if not _exec_rows:
    raise RuntimeError("Department EXEC_MGMT not found; apply seed migration 0004 first.")
EXEC_MGMT_DEPT = _exec_rows[0]['id']

users_to_create = [
    {
        'email': 'manager@alseermarine.com',
        'full_name': 'Tariq Al Hammadi (Line Manager)',
        'code': 'ASM-1002',
        'role': 'LINE_MANAGER',
        'dept': OPERATIONS_DEPT,
        'hod_id': HOD_ID
    },
    {
        'email': 'finance@alseermarine.com',
        'full_name': 'Fatima Al Mazrouei (Finance Controller)',
        'code': 'ASM-3001',
        'role': 'FINANCE',
        'dept': FINANCE_DEPT,
        'hod_id': None
    },
    {
        'email': 'management@alseermarine.com',
        'full_name': 'Siva (Management Approver)',
        'code': 'ASM-0101',
        'role': 'MANAGEMENT',
        'dept': EXEC_MGMT_DEPT,
        'hod_id': None
    },
    {
        'email': 'admin@alseermarine.com',
        'full_name': 'Saeed Al Qubaisi (System Administrator)',
        'code': 'ASM-0001',
        'role': 'ADMIN',
        'dept': ADMIN_DEPT,
        'hod_id': None
    }
]

created_ids = {}

req_existing = urllib.request.Request(
    'https://vrnqemqzmklrjpssneng.supabase.co/auth/v1/admin/users?per_page=1000',
    headers=headers
)
existing_by_email = {
    x['email']: x['id']
    for x in json.loads(urllib.request.urlopen(req_existing).read().decode()).get('users', [])
}

for u in users_to_create:
    if u['email'] in existing_by_email:
        created_ids[u['role']] = existing_by_email[u['email']]
        print('Account exists, skipped:', u['email'])
        continue

    # 1. Create in auth
    temp_password = secrets.token_urlsafe(12)
    req_auth = urllib.request.Request(
        'https://vrnqemqzmklrjpssneng.supabase.co/auth/v1/admin/users',
        data=json.dumps({
            'email': u['email'],
            'password': temp_password,
            'email_confirm': True,
            'user_metadata': {'full_name': u['full_name']}
        }).encode('utf-8'),
        headers=headers
    )
    res_auth = json.loads(urllib.request.urlopen(req_auth).read().decode())
    uid = res_auth['id']
    record_temporary_password(u['email'], temp_password)
    created_ids[u['role']] = uid
    print('Created Auth User:', u['email'], '->', uid)

    # 2. Create in employees
    emp_payload = {
        'id': uid,
        'employee_code': u['code'],
        'full_name': u['full_name'],
        'email': u['email'],
        'phone': '+971 50 555 1234',
        'department_id': u['dept'],
        'hod_id': u['hod_id'],
        'is_active': True
    }
    req_emp = urllib.request.Request(
        'https://vrnqemqzmklrjpssneng.supabase.co/rest/v1/employees',
        data=json.dumps(emp_payload).encode('utf-8'),
        headers=headers
    )
    urllib.request.urlopen(req_emp)

    # 3. Create in employee_roles
    req_role = urllib.request.Request(
        'https://vrnqemqzmklrjpssneng.supabase.co/rest/v1/employee_roles',
        data=json.dumps({'employee_id': uid, 'role': u['role']}).encode('utf-8'),
        headers=headers
    )
    urllib.request.urlopen(req_role)
    print('Configured Employee and Role:', u['role'])

# Update Ahmed's manager and HOD links
MANAGER_ID = created_ids['LINE_MANAGER']
AHMED_ID = '5015322b-3619-4c5a-bb20-165012fca712'

req_update = urllib.request.Request(
    f'https://vrnqemqzmklrjpssneng.supabase.co/rest/v1/employees?id=eq.{AHMED_ID}',
    data=json.dumps({'line_manager_id': MANAGER_ID, 'hod_id': HOD_ID}).encode('utf-8'),
    headers=headers,
    method='PATCH'
)
urllib.request.urlopen(req_update)
print('Updated Ahmed: assigned Line Manager Tariq and HOD Dr. Khalid!')

# Update Departments HODs
req_dept_ops = urllib.request.Request(
    f'https://vrnqemqzmklrjpssneng.supabase.co/rest/v1/departments?id=eq.{OPERATIONS_DEPT}',
    data=json.dumps({'hod_employee_id': HOD_ID}).encode('utf-8'),
    headers=headers,
    method='PATCH'
)
urllib.request.urlopen(req_dept_ops)

FINANCE_ID = created_ids['FINANCE']
req_dept_fin = urllib.request.Request(
    f'https://vrnqemqzmklrjpssneng.supabase.co/rest/v1/departments?id=eq.{FINANCE_DEPT}',
    data=json.dumps({'hod_employee_id': FINANCE_ID}).encode('utf-8'),
    headers=headers,
    method='PATCH'
)
urllib.request.urlopen(req_dept_fin)
print('Successfully configured HODs for Operations and Finance departments!')
