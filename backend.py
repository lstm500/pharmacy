"""Supabase Data APIをStreamlitサーバーからだけ利用するクライアント。"""
from __future__ import annotations

import copy
import json
import os
from pathlib import Path
import re
import ssl
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

PREFIX = 'shinagawa_'
PAGE_SIZE = 500

class DatabaseError(RuntimeError):
    """接続情報を含めない、利用者に表示可能なエラー。"""

class SupabaseStore:
    def __init__(self, url: str, secret_key: str, *, opener=None):
        parsed = urllib.parse.urlsplit(url.strip())
        if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise DatabaseError('SUPABASE_URLにはHTTPSのプロジェクトURLを設定してください。')
        if not secret_key or secret_key.startswith('sb_publishable_'):
            raise DatabaseError('サーバー用のSupabase Secret keyまたはservice_roleキーを設定してください。')
        if secret_key.count('.') == 2:
            import base64
            try:
                raw = secret_key.split('.')[1]
                role = json.loads(base64.urlsafe_b64decode(raw + '=' * (-len(raw) % 4))).get('role')
                if role != 'service_role':
                    raise DatabaseError('anonキーではなく、サーバー用キーを設定してください。')
            except (ValueError, TypeError, UnicodeError) as exc:
                raise DatabaseError('Supabaseキーの形式を確認してください。') from exc
        self.url = url.strip().rstrip('/')
        self._headers = {'apikey': secret_key, 'Content-Type': 'application/json'}
        if secret_key.count('.') == 2:
            self._headers['Authorization'] = 'Bearer ' + secret_key
        self._opener = opener or urllib.request.urlopen

    def _request(self, path: str, *, method='GET', body=None, query=None):
        endpoint = self.url + '/rest/v1/' + path
        if query:
            endpoint += '?' + urllib.parse.urlencode(query)
        payload = None if body is None else json.dumps(body, ensure_ascii=False).encode('utf-8')
        request = urllib.request.Request(endpoint, data=payload, headers=self._headers, method=method)
        try:
            # Python 3.11+の標準TLS設定を使用。証明書検証は無効化しない。
            with self._opener(request, timeout=45, context=ssl.create_default_context()) as response:
                raw = response.read()
            return json.loads(raw) if raw else None
        except urllib.error.HTTPError as exc:
            messages = {
                401: 'Supabase接続キーを確認してください。',
                403: '薬局専用テーブルへのアクセス権を確認してください。',
                404: 'schema.sqlの実行とData APIの設定を確認してください。',
            }
            raise DatabaseError(messages.get(exc.code, f'Supabaseへの接続でHTTP {exc.code}が発生しました。')) from None
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError):
            raise DatabaseError('Supabaseとの通信に失敗しました。接続先と通信状態を確認してください。') from None

    def all_rows(self, table: str, order: str):
        if not re.fullmatch(r'shinagawa_[a-z_]+', table):
            raise ValueError('Unexpected table')
        rows, offset = [], 0
        while True:
            page = self._request(table, query={'select': '*', 'order': order, 'limit': PAGE_SIZE, 'offset': offset})
            if not isinstance(page, list):
                raise DatabaseError('Supabaseからの応答形式を確認してください。')
            rows.extend(page)
            if not page:
                return rows
            # プロジェクト側の上限が500件未満でも読み飛ばさない。
            offset += len(page)

    def read_dataset(self):
        pharmacy_rows = self.all_rows(PREFIX + 'pharmacies', 'code.asc')
        registrations = self.all_rows(PREFIX + 'fee_registrations', 'pharmacy_code.asc,fee_name.asc')
        station_rows = self.all_rows(PREFIX + 'stations', 'name.asc')
        rate_rows = self.all_rows(PREFIX + 'fee_rates', 'fee_key.asc')
        meta_rows = self.all_rows(PREFIX + 'dataset_info', 'id.asc')
        by_code: dict[str, list] = {}
        for row in registrations:
            by_code.setdefault(row['pharmacy_code'], []).append({'name': row['fee_name'], 'abbr': row['abbreviation'], 'start': row['start_label']})
        pharmacies = []
        for row in pharmacy_rows:
            item = copy.deepcopy(row['payload'])
            item.update(code=row['code'], name=row['name'], address=row['address'], lat=row['latitude'], lon=row['longitude'], registrations=by_code.get(row['code'], []))
            pharmacies.append(item)
        stations = [{'name': row['name'], 'lat': row['latitude'], 'lon': row['longitude'], 'lines': row['lines'], 'major': row['major']} for row in station_rows]
        metadata = next((row['metadata'] for row in meta_rows if row['id'] == 'current'), {})
        if not pharmacies or not stations or not rate_rows:
            raise DatabaseError('薬局・駅・料金データが未登録です。先にimport_data.pyを実行してください。')
        rates: dict[str, Any] = {'basic': {}, 'regional': {}}
        for row in rate_rows:
            category, value = row['category'], float(row['points'])
            if category in ('basic', 'regional'):
                rates[category][row['fee_key']] = value
            else:
                rates[category] = value
        if not rates['basic'] or not rates['regional'] or not {'cooperation','digital'} <= rates.keys():
            raise DatabaseError('料金マスタに不足があります。取込データを確認してください。')
        return {'pharmacies': pharmacies, 'stations': stations, 'rates': rates, 'metadata': metadata}

    def import_dataset(self, dataset):
        return self._request('rpc/shinagawa_import_dataset', method='POST', body={'dataset': dataset})


def load_seed(root: Path):
    return json.loads((root / 'seed' / 'dataset.json').read_text(encoding='utf-8'))


def config_from_environment():
    return {'url': os.environ.get('SUPABASE_URL', ''), 'secret_key': os.environ.get('SUPABASE_SECRET_KEY') or os.environ.get('SUPABASE_SERVICE_ROLE_KEY', '')}
