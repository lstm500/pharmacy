"""起動: streamlit run app.py"""
from pathlib import Path
import streamlit as st
from backend import SupabaseStore, DatabaseError, config_from_environment
from render_ui import build_document

ROOT = Path(__file__).resolve().parent
st.set_page_config(page_title='しながわ薬局比較', page_icon='🚉', layout='wide', initial_sidebar_state='collapsed')
st.html('<style>.block-container{padding:0!important;max-width:none!important}header[data-testid="stHeader"]{display:none}[data-testid="stSidebarCollapsedControl"]{display:none}.stMainBlockContainer{padding-top:0!important}footer{display:none}</style>')


def settings():
    config = config_from_environment()
    try:
        values = st.secrets.get('supabase', {})
        config['url'] = config['url'] or values.get('url', '') or st.secrets.get('SUPABASE_URL', '')
        config['secret_key'] = config['secret_key'] or values.get('secret_key', '') or values.get('service_role_key', '') or st.secrets.get('SUPABASE_SECRET_KEY', '') or st.secrets.get('SUPABASE_SERVICE_ROLE_KEY', '')
    except (FileNotFoundError, st.errors.StreamlitSecretNotFoundError):
        pass
    return config


@st.cache_data(ttl=300, show_spinner='Supabaseから薬局データを読み込んでいます…')
def read_data(url, _secret_key):
    return SupabaseStore(url, _secret_key).read_dataset()


def main():
    config = settings()
    if not config['url'] or not config['secret_key']:
        st.title('しながわ薬局比較')
        st.info('Supabase接続情報を設定してください。')
        st.markdown('`.streamlit/secrets.toml.example`を参考に、StreamlitのSecretsへ接続先URLとサーバー用キーを設定してください。')
        st.code('[supabase]\nurl = "https://YOUR_PROJECT.supabase.co"\nsecret_key = "YOUR_SERVER_SECRET_KEY"', language='toml')
        st.caption('キーをチャットや公開リポジトリに貼る必要はありません。')
        return
    try:
        dataset = read_data(config['url'], config['secret_key'])
    except DatabaseError as exc:
        st.error(str(exc))
        if st.button('再読み込み'):
            read_data.clear()
            st.rerun()
        return
    # データだけを渡す。接続キーはHTMLやブラウザへ渡さない。
    st.iframe(build_document(dataset, ROOT), height=950, alt='品川区の薬局と駅を地図・公開料金で比較')
    with st.expander('データの再読み込み'):
        st.caption('Supabaseに保存したデータを読み込みます。最大5分キャッシュします。')
        if st.button('Supabaseから再取得'):
            read_data.clear()
            st.rerun()


if __name__ == '__main__':
    main()
