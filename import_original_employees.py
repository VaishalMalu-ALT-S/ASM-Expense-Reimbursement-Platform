import urllib.request
import json
import ssl
import csv
import secrets

ctx = ssl.create_default_context()

import os
from pathlib import Path

# New accounts get a unique temporary password, written only to this CSV for
# secure hand-over (never printed).
credentials_file = os.environ.get('CREDENTIALS_OUT_FILE')


def record_temporary_password(email, password):
    if not credentials_file:
        raise RuntimeError('CREDENTIALS_OUT_FILE must be set before creating new auth users.')
    new_file = not Path(credentials_file).exists()
    with open(credentials_file, 'a', newline='', encoding='utf-8') as fh:
        writer = csv.writer(fh)
        if new_file:
            writer.writerow(['email', 'temporary_password'])
        writer.writerow([email, password])

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

supabase_url = os.environ.get('SUPABASE_URL', 'https://vrnqemqzmklrjpssneng.supabase.co')

headers = {
    'apikey': service_key,
    'Authorization': 'Bearer ' + service_key,
    'Content-Type': 'application/json',
    'Prefer': 'return=representation'
}

# 1. Ensure Departments Exist
dept_configs = [
    {'code': 'IMLPPM', 'name': 'IML PPM'},
    {'code': 'ICG.SCM', 'name': 'ICG Supply Chain Management'},
    {'code': 'ICG.FIN', 'name': 'ICG Finance'},
    {'code': 'ASM.Integration', 'name': 'ASM Integration'},
]

# Fetch existing departments
req_get_depts = urllib.request.Request(f'{supabase_url}/rest/v1/departments?select=*', headers=headers)
existing_depts = json.loads(urllib.request.urlopen(req_get_depts, context=ctx).read().decode())
dept_map = {d['code']: d['id'] for d in existing_depts}

for d in dept_configs:
    if d['code'] not in dept_map:
        req_ins = urllib.request.Request(
            f'{supabase_url}/rest/v1/departments',
            data=json.dumps({'code': d['code'], 'name': d['name'], 'is_active': True}).encode('utf-8'),
            headers=headers
        )
        created = json.loads(urllib.request.urlopen(req_ins, context=ctx).read().decode())
        dept_map[d['code']] = created[0]['id']
        print(f"Created department: {d['code']} -> {created[0]['id']}")
    else:
        print(f"Department exists: {d['code']} -> {dept_map[d['code']]}")

# 2. Original Employee Dataset from User Image
employees_data = [
    # Top rows
    {"code": "37317", "name": "Meharoof KottileValappil", "dept_code": "OPERATIONS", "role": "EMPLOYEE"},
    {"code": "44266", "name": "Roldan De Vera", "dept_code": "OPERATIONS", "role": "EMPLOYEE"},

    # IMLPPM
    {"code": "23833", "name": "Murugan Selvaraj", "dept_code": "IMLPPM", "role": "EMPLOYEE"},
    {"code": "48359", "name": "Simon Joseph Frederick Davis", "dept_code": "IMLPPM", "role": "LINE_MANAGER"},
    {"code": "34451", "name": "Vivek Shripad Kulkarni", "dept_code": "IMLPPM", "role": "EMPLOYEE"},
    {"code": "23775", "name": "Toufeeq Jeelani", "dept_code": "IMLPPM", "role": "EMPLOYEE"},
    {"code": "38135", "name": "Hernan Je Margarico", "dept_code": "IMLPPM", "role": "EMPLOYEE"},
    {"code": "43726", "name": "Musthaque Aramullan Valiyamadathil", "dept_code": "IMLPPM", "role": "EMPLOYEE"},
    {"code": "45237", "name": "Roelito Baltazar", "dept_code": "IMLPPM", "role": "EMPLOYEE"},
    {"code": "47451", "name": "Ravindu Vichakshana Rathnayake Rathnayake Mudiyanselage", "dept_code": "IMLPPM", "role": "EMPLOYEE"},

    # ICG.SCM
    {"code": "48752", "name": "Piotr Zbigniew Targowski", "dept_code": "ICG.SCM", "role": "LINE_MANAGER"},
    {"code": "48690", "name": "Muhammad Raheel Arif Sami", "dept_code": "ICG.SCM", "role": "EMPLOYEE"},

    # ICG.FIN
    {"code": "29018", "name": "Srikanth Kathula", "dept_code": "ICG.FIN", "role": "FINANCE"},
    {"code": "24436", "name": "Murtuza Ali Syed", "dept_code": "ICG.FIN", "role": "FINANCE"},
    {"code": "47619", "name": "Jessica Peters", "dept_code": "ICG.FIN", "role": "FINANCE"},
    {"code": "42421", "name": "Prashant Wagadre", "dept_code": "ICG.FIN", "role": "FINANCE"},
    {"code": "48407", "name": "Nishadi Dilhari Thalangodalage", "dept_code": "ICG.FIN", "role": "FINANCE"},

    # ASM.Integration
    {"code": "50312", "name": "Sebin Vadakkemelathil Thankachan", "dept_code": "ASM.Integration", "role": "EMPLOYEE"},
]

# Fetch existing auth users to avoid duplicate creation
req_auth_users = urllib.request.Request(f'{supabase_url}/auth/v1/admin/users?per_page=100', headers=headers)
auth_users_resp = json.loads(urllib.request.urlopen(req_auth_users, context=ctx).read().decode())
existing_auth_by_email = {u['email']: u['id'] for u in auth_users_resp.get('users', [])}

results = []

for emp in employees_data:
    code = emp['code']
    name = emp['name']
    dept_code = emp['dept_code']
    role = emp['role']
    email = f"{code}@alseermarine.com"
    dept_id = dept_map.get(dept_code, dept_map.get('OPERATIONS'))

    # Step 1: Ensure Auth user exists
    if email in existing_auth_by_email:
        uid = existing_auth_by_email[email]
        print(f"Auth user exists: {email} -> {uid}")
    else:
        if not credentials_file:
            print(f"Skipped {email}: set CREDENTIALS_OUT_FILE to create new auth users.")
            continue
        temp_password = secrets.token_urlsafe(12)
        req_auth = urllib.request.Request(
            f'{supabase_url}/auth/v1/admin/users',
            data=json.dumps({
                'email': email,
                'password': temp_password,
                'email_confirm': True,
                'user_metadata': {'full_name': name, 'employee_code': code}
            }).encode('utf-8'),
            headers=headers
        )
        try:
            res_auth = json.loads(urllib.request.urlopen(req_auth, context=ctx).read().decode())
            uid = res_auth['id']
            existing_auth_by_email[email] = uid
            record_temporary_password(email, temp_password)
            print(f"Created Auth user: {code} ({name}) -> {uid}")
        except Exception as e:
            print(f"Error creating auth user for {code}: {e}")
            continue

    # Step 2: Upsert into employees table
    emp_payload = {
        'id': uid,
        'employee_code': code,
        'full_name': name,
        'email': email,
        'department_id': dept_id,
        'is_active': True
    }
    
    # Check if employee record exists
    req_chk = urllib.request.Request(f'{supabase_url}/rest/v1/employees?id=eq.{uid}', headers=headers)
    existing_emp = json.loads(urllib.request.urlopen(req_chk, context=ctx).read().decode())
    
    if existing_emp:
        # Patch
        req_up = urllib.request.Request(
            f'{supabase_url}/rest/v1/employees?id=eq.{uid}',
            data=json.dumps(emp_payload).encode('utf-8'),
            headers=headers,
            method='PATCH'
        )
        urllib.request.urlopen(req_up, context=ctx)
        print(f"Updated employee record: {code} - {name}")
    else:
        # Insert
        req_ins = urllib.request.Request(
            f'{supabase_url}/rest/v1/employees',
            data=json.dumps(emp_payload).encode('utf-8'),
            headers=headers
        )
        urllib.request.urlopen(req_ins, context=ctx)
        print(f"Inserted employee record: {code} - {name}")

    # Step 3: Grant Roles in employee_roles
    # Always grant EMPLOYEE
    roles_to_grant = ['EMPLOYEE']
    if role != 'EMPLOYEE':
        roles_to_grant.append(role)

    for r in roles_to_grant:
        req_chk_role = urllib.request.Request(
            f'{supabase_url}/rest/v1/employee_roles?employee_id=eq.{uid}&role=eq.{r}',
            headers=headers
        )
        existing_role = json.loads(urllib.request.urlopen(req_chk_role, context=ctx).read().decode())
        if not existing_role:
            req_role = urllib.request.Request(
                f'{supabase_url}/rest/v1/employee_roles',
                data=json.dumps({'employee_id': uid, 'role': r}).encode('utf-8'),
                headers=headers
            )
            urllib.request.urlopen(req_role, context=ctx)
            print(f"Granted role {r} to {code} ({name})")

    results.append({
        'code': code,
        'name': name,
        'dept': dept_code,
        'role': role,
        'email': email,
        'uid': uid
    })

print(f"\nSuccessfully processed and stored {len(results)} original employees in Supabase!")
