# しながわ薬局比較 — Streamlit / Supabase版

## 内容

- 品川区の薬局229店、届出1,756件、品川区と周辺の駅30か所、料金マスタ13件を同梱。
- StreamlitサーバーがSupabaseから読み込み、地図UIに取得済みデータだけを渡します。
- ②基本料金または③地域供給の未記載25店は初期非表示。記載が揃う204店を表示。
- 初期条件の比較小計は中央値74点。3割換算の「安め」は222円以下の115店、「高め」は222円超の89店。
- 色付きの薬局ピン、紺色の電車アイコン・駅名、価格順一覧、最大3店舗比較。
- 数字の丸を1回押すと該当薬局をまとめて表示。地図を勝手に拡大・移動しません。

## 最短の設定方法

Python 3.11以上を使用してください。

1. SupabaseのSQL Editorで **`setup_and_import.sql`を1回実行**します。薬局専用の5テーブル・取込関数を作り、同梱データをまとめて保存します。繰り返し実行しても同じ薬局・駅・料金を重複登録しません。
2. `.streamlit/secrets.toml.example`を`.streamlit/secrets.toml`にコピーし、Supabaseのサーバー用キーを設定します。URLは接続を確認した既存プロジェクト `kotoba_app` を例として設定済みです。別のプロジェクトを使う場合はURLも変更してください。
3. 以下で起動します。

```bash
python -m pip install -r requirements.txt
streamlit run app.py
```

キーはSupabase DashboardのAPI Keysから取得する **Secret key**（`sb_secret_...`）を使用します。旧形式では`service_role`キーも利用できます。`publishable`・`anon`キーでは読み込めません。実際のキーを公開リポジトリやチャットに貼らないでください。

環境変数`SUPABASE_URL`と`SUPABASE_SECRET_KEY`でも設定できます。`SUPABASE_SERVICE_ROLE_KEY`も互換名として利用できます。

## Streamlit Community Cloud

フォルダ一式をリポジトリに配置し、メインファイルに`app.py`を選びます。Pythonは3.11以上。App settingsのSecretsへ次の形式で設定します。

```toml
[supabase]
url = "https://YOUR_PROJECT.supabase.co"
secret_key = "YOUR_SERVER_SECRET_KEY"
```

アプリの公開範囲はStreamlit側で設定してください。今回のファイル作成だけでは、Streamlit上へのデプロイは行われません。以前のSites URLはStreamlitの実行環境ではありません。

## 再取込

`schema.sql`だけを先に実行済みなら、以下でデータを保存できます。

```bash
python import_data.py --secrets .streamlit/secrets.toml
```

更新した同じ形式の取得データを使用する場合：

```bash
python import_data.py --secrets .streamlit/secrets.toml --dataset updated_dataset.json
```

保存はデータベース内の1トランザクションで行います。書き込みが失敗した場合は途中の更新を残しません。対象薬局の届出はその取込内容で置き換え、他アプリのテーブルには触れません。

`seed/dataset.json`は再取込用の原本です。通常表示はこのファイルにフォールバックせず、Supabaseの保存データだけを使用します。

## テーブル

| テーブル | 内容 |
|---|---|
| `shinagawa_pharmacies` | 薬局名、所在地、座標、出典などの原本データ |
| `shinagawa_fee_registrations` | 各薬局の基本料・加算の届出 |
| `shinagawa_stations` | 駅の代表位置・路線・主要駅フラグ |
| `shinagawa_fee_rates` | 基本料・比較対象の加算の点数マスタ |
| `shinagawa_dataset_info` | 取得元・基準日・取得日 |

すべてRLSを有効化し、`anon`・`authenticated`には権限を与えていません。読み書きはStreamlitサーバーと管理用取込処理がサーバー用キーで実行します。キーはブラウザのHTMLに含めません。RLSに公開用SELECTポリシーがないのは意図した設定です。

## 検証と今回の実保存状況

今回の環境では、Supabaseの一覧・既存テーブルの読み取りは成功しましたが、テーブル作成の書き込みが`Invalid or expired requestState`で失敗しました。そのため、**Supabaseへの実保存は未完了**です。`setup_and_import.sql`を実行すると保存できます。

コードでは、ページネーション、通信エラー、JSONの安全な埋め込み、記載有無の表示条件、Streamlit起動をテストしています。実際のサーバー用キーを用いたData API経由の疎通は、キー設定後に確認してください。

```bash
python -m unittest discover -s tests -v
```

## データの出典と料金の範囲

- 関東信越厚生局「施設基準の届出受理状況」：2026年9月1日時点、2026年10月作成。
  https://kouseikyoku.mhlw.go.jp/kantoshinetsu/chousa/kijyun.html
- 厚生労働省「医療情報ネット」：2026年6月1日版の薬局所在地・座標。一部は国土地理院の住所検索で補完。
  https://www.mhlw.go.jp/stf/seisakunitsuite/bunya/kenkou_iryou/iryou/newpage_43373.html
- 厚生労働省「調剤報酬点数表」：2026年6月施行の点数。
  https://www.mhlw.go.jp/web/t_doc?dataId=84aa9729&dataType=0&pageNo=31
- 駅座標：**HeartRails Express**。2026年10月28日取得。駅の代表位置であり出口位置ではありません。
  https://express.heartrails.com/api.html
- 背景地図：Esri, HERE, Garmin, © OpenStreetMap contributors。Leaflet同梱。

表示金額は②の基本料金と選択した③の比較小計です。薬代や②の他の仕事料金などは含まず、窓口総額ではありません。自治体助成、会計の端数処理、特殊な算定条件は反映しません。取得データは自動更新されません。
