import copy
import json
from pathlib import Path
import unittest
import urllib.error
from backend import SupabaseStore, DatabaseError, load_seed
from render_ui import build_document, safe_json, valid_http_url

ROOT = Path(__file__).resolve().parents[1]

class Response:
    def __init__(self, value): self.value = value
    def __enter__(self): return self
    def __exit__(self, *_): return False
    def read(self): return json.dumps(self.value).encode()

class BackendTests(unittest.TestCase):
    def test_pagination_uses_actual_returned_count(self):
        seen=[]
        def opener(req, **kwargs):
            from urllib.parse import urlsplit, parse_qs
            offset=int(parse_qs(urlsplit(req.full_url).query)['offset'][0]);seen.append(offset)
            return Response([{'n':n} for n in range(offset,min(offset+2,5))])
        store=SupabaseStore('https://example.supabase.co','sb_secret_test',opener=opener)
        self.assertEqual(len(store.all_rows('shinagawa_pharmacies','code.asc')),5)
        self.assertEqual(seen,[0,2,4,5])

    def test_error_does_not_expose_key_or_response(self):
        def opener(req, **kwargs): raise urllib.error.HTTPError(req.full_url,403,'secret response',{},None)
        store=SupabaseStore('https://example.supabase.co','sb_secret_PRIVATE',opener=opener)
        with self.assertRaises(DatabaseError) as c: store.all_rows('shinagawa_pharmacies','code.asc')
        self.assertNotIn('PRIVATE',str(c.exception));self.assertNotIn('secret response',str(c.exception))

    def test_import_uses_one_atomic_rpc(self):
        seen=[]
        def opener(req, **kwargs):
            seen.append(req);return Response({'pharmacies':229})
        store=SupabaseStore('https://example.supabase.co','sb_secret_test',opener=opener)
        result=store.import_dataset({'pharmacies':[]})
        self.assertEqual(result['pharmacies'],229);self.assertEqual(len(seen),1)
        self.assertEqual(seen[0].get_method(),'POST')
        self.assertTrue(seen[0].full_url.endswith('/rpc/shinagawa_import_dataset'))

    def test_rebuild_from_canonical_rows(self):
        store=SupabaseStore('https://example.supabase.co','sb_secret_test')
        original={'code':'0000001','name':'old','address':'old','registrations':[{'name':'stale'}]}
        rows={
          'shinagawa_pharmacies':[{'code':'0000001','name':'正式薬局','address':'品川区大井','latitude':35.6,'longitude':139.7,'payload':original}],
          'shinagawa_fee_registrations':[{'pharmacy_code':'0000001','fee_name':'調剤基本料１','abbreviation':'調基１','start_label':'令和8年6月1日'}],
          'shinagawa_stations':[{'name':'大崎','latitude':35.619772,'longitude':139.728439,'lines':['JR山手線'],'major':True}],
          'shinagawa_fee_rates':[{'fee_key':'調剤基本料1','category':'basic','points':47},{'fee_key':'1','category':'regional','points':27},{'fee_key':'cooperation','category':'cooperation','points':5},{'fee_key':'digital','category':'digital','points':8}],
          'shinagawa_dataset_info':[{'id':'current','metadata':{'retrieved_on':'2026-10-28'}}]}
        store.all_rows=lambda table,order:rows[table]
        dataset=store.read_dataset()
        self.assertEqual(dataset['pharmacies'][0]['name'],'正式薬局')
        self.assertEqual(dataset['pharmacies'][0]['registrations'][0]['name'],'調剤基本料１')
        self.assertEqual(original['name'],'old')
        self.assertEqual(dataset['rates']['basic']['調剤基本料1'],47)

class RenderTests(unittest.TestCase):
    def dataset(self):
        seed=load_seed(ROOT);rates={'basic':{},'regional':{}}
        for r in seed['rates']:
            if r['category'] in ('basic','regional'): rates[r['category']][r['fee_key']]=r['points']
            else:rates[r['category']]=r['points']
        return {**seed,'rates':rates}

    def test_json_and_links_cannot_break_out(self):
        self.assertNotIn('<',safe_json({'name':'</script><script>alert(1)</script>'}))
        self.assertEqual(valid_http_url('javascript:alert(1)'),'')
        self.assertEqual(valid_http_url('https://example.com'),'https://example.com')
        self.assertEqual(valid_http_url('https://user:pass@example.com'),'')

    def test_document_is_self_contained_and_keeps_features(self):
        data=self.dataset();data['pharmacies'][0]['website']='javascript:alert(1)'
        html=build_document(data,ROOT)
        self.assertNotIn('src="app.js"',html);self.assertNotIn('href="style.css"',html)
        self.assertNotIn("fetch('data.json')",html);self.assertNotIn("fetch('stations.json')",html)
        self.assertNotIn('javascript:alert(1)',html)
        for expected in ['pharmacy-bootstrap','station-landmark','priceLow','priceHigh','showGroup','includeMissing','HeartRails Express']:
            self.assertIn(expected,html)
        self.assertEqual(len(data['pharmacies']),229);self.assertEqual(len(data['stations']),30)

if __name__=='__main__':unittest.main()
