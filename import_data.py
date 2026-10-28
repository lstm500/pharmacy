"""取得済みデータをSupabaseへまとめて保存。DB内のRPCで原子的にupsertする。"""
import argparse
from pathlib import Path
import tomllib
from backend import SupabaseStore, DatabaseError, config_from_environment, load_seed


def main():
    parser = argparse.ArgumentParser(description='取得済み薬局・届出・駅・料金マスタをSupabaseに保存')
    parser.add_argument('--dataset', type=Path, help='省略時は同梱seed/dataset.json')
    parser.add_argument('--secrets', type=Path, help='環境変数を使わない場合のsecrets.tomlのパス')
    args = parser.parse_args()
    config = config_from_environment()
    if args.secrets:
        with args.secrets.open('rb') as f:
            secrets = tomllib.load(f)
        values = secrets.get('supabase', {})
        config['url'] = config['url'] or values.get('url', '') or secrets.get('SUPABASE_URL', '')
        config['secret_key'] = config['secret_key'] or values.get('secret_key', '') or values.get('service_role_key', '') or secrets.get('SUPABASE_SECRET_KEY', '') or secrets.get('SUPABASE_SERVICE_ROLE_KEY', '')
    if not all(config.values()):
        parser.error('SUPABASE_URLとSUPABASE_SECRET_KEY、または--secretsを設定してください。')
    import json
    dataset = json.loads(args.dataset.read_text(encoding='utf-8')) if args.dataset else load_seed(Path(__file__).parent)
    try:
        result = SupabaseStore(**config).import_dataset(dataset)
    except DatabaseError as exc:
        parser.exit(1, str(exc) + '\n')
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
