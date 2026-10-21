"""Rotate accounts that still accept the legacy shared demo password.

Dry run (default): reports which accounts still sign in with the shared password.
--apply:           sets a unique temporary password for each of those accounts,
                   writes it only to CREDENTIALS_OUT_FILE (CSV, never printed)
                   and revokes that account's existing sessions.

Requires SUPABASE_SERVICE_ROLE_KEY (env or local .env). Run deliberately, by an
administrator, against the intended project only.
"""
import csv
import json
import os
import secrets
import sys
import urllib.error
import urllib.request
from pathlib import Path

LEGACY_SHARED_PASSWORD = 'Password123!'
SUPABASE_URL = os.environ.get('SUPABASE_URL', 'https://vrnqemqzmklrjpssneng.supabase.co')


def load_service_key():
    key = os.environ.get('SUPABASE_SERVICE_ROLE_KEY')
    env_file = Path(__file__).resolve().parent / '.env'
    if not key and env_file.exists():
        for line in env_file.read_text(encoding='utf-8').splitlines():
            if line.startswith('SUPABASE_SERVICE_ROLE_KEY='):
                key = line.split('=', 1)[1].strip().strip('"').strip("'")
                break
    if not key:
        raise RuntimeError('SUPABASE_SERVICE_ROLE_KEY environment variable is required.')
    return key


def call(method, path, key, body=None, bearer=None):
    req = urllib.request.Request(
        f'{SUPABASE_URL}{path}',
        data=None if body is None else json.dumps(body).encode('utf-8'),
        method=method,
        headers={
            'apikey': key,
            'Authorization': 'Bearer ' + (bearer or key),
            'Content-Type': 'application/json',
        },
    )
    with urllib.request.urlopen(req) as res:
        raw = res.read().decode()
        return json.loads(raw) if raw else {}


def shared_password_session(email, key):
    try:
        return call('POST', '/auth/v1/token?grant_type=password', key,
                    {'email': email, 'password': LEGACY_SHARED_PASSWORD})
    except urllib.error.HTTPError as e:
        if e.code in (400, 401, 422):
            return None
        raise


def main():
    apply = '--apply' in sys.argv
    key = load_service_key()
    out_file = os.environ.get('CREDENTIALS_OUT_FILE')
    if apply and not out_file:
        raise RuntimeError('CREDENTIALS_OUT_FILE must be set with --apply (CSV path for temporary passwords).')

    users = call('GET', '/auth/v1/admin/users?per_page=1000', key).get('users', [])
    affected = []
    for u in users:
        email = u.get('email')
        if not email:
            continue
        session = shared_password_session(email, key)
        if session and session.get('access_token'):
            affected.append((u['id'], email, session['access_token']))

    print(f'{len(affected)} of {len(users)} accounts still accept the shared password.')
    for _, email, _ in affected:
        print('  ' + email)
    if not apply:
        print('Dry run only. Re-run with --apply to rotate these accounts.')
        return

    new_file = not Path(out_file).exists()
    with open(out_file, 'a', newline='', encoding='utf-8') as fh:
        writer = csv.writer(fh)
        if new_file:
            writer.writerow(['email', 'temporary_password'])
        for uid, email, token in affected:
            temp = secrets.token_urlsafe(12)
            call('PUT', f'/auth/v1/admin/users/{uid}', key, {'password': temp})
            try:
                call('POST', '/auth/v1/logout?scope=global', key, {}, bearer=token)
            except urllib.error.HTTPError:
                pass
            writer.writerow([email, temp])
            print('Rotated:', email)
    print(f'Temporary passwords written to {out_file}. Hand them over securely, then delete the file.')


if __name__ == '__main__':
    main()
