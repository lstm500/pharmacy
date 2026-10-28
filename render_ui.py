"""取得データを実行可能なHTMLにしないため、JSONとURLを明示的に処理する。"""
from __future__ import annotations
import copy
import json
from pathlib import Path
import urllib.parse


def safe_json(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':')).replace('<', '\\u003c').replace('>', '\\u003e').replace('&', '\\u0026').replace('\u2028','\\u2028').replace('\u2029','\\u2029')


def valid_http_url(value):
    if not isinstance(value, str):
        return ''
    try:
        parsed = urllib.parse.urlsplit(value)
        if parsed.scheme in ('http', 'https') and parsed.hostname and not parsed.username and not parsed.password:
            return value
    except ValueError:
        pass
    return ''


def build_document(dataset, root: Path):
    dataset = copy.deepcopy(dataset)
    for row in dataset['pharmacies']:
        for field in ('website', 'officialFeesUrl'):
            if field in row:
                row[field] = valid_http_url(row[field])
    ui = root / 'ui'
    html = (ui / 'index.html').read_text(encoding='utf-8')
    css = (ui / 'style.css').read_text(encoding='utf-8')
    js = (ui / 'app.js').read_text(encoding='utf-8')
    leaflet_css = (ui / 'vendor' / 'leaflet.css').read_text(encoding='utf-8')
    leaflet_js = (ui / 'vendor' / 'leaflet.js').read_text(encoding='utf-8')
    html = html.replace('<link rel="stylesheet" href="vendor/leaflet.css">', '<style>' + leaflet_css + '</style>')
    html = html.replace('<link rel="stylesheet" href="style.css">', '<style>' + css + '</style>')
    bootstrap = '<script id="pharmacy-bootstrap" type="application/json">' + safe_json(dataset) + '</script><script>const PHARMACY_BOOTSTRAP=JSON.parse(document.getElementById("pharmacy-bootstrap").textContent);</script>'
    html = html.replace('<script src="vendor/leaflet.js"></script>', bootstrap + '<script>' + leaflet_js.replace('</script', '<\\/script') + '</script>')
    html = html.replace('<script src="app.js"></script>', '<script>' + js.replace('</script', '<\\/script') + '</script>')
    return html
