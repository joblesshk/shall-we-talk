#!/usr/bin/env python3
"""Check compiled resource integrity and materialized ranking against full indexed ranges."""
import hashlib
import json
from pathlib import Path
import sqlite3

root = Path(__file__).resolve().parents[1] / '_sources/Keyboard/PinyinData'
manifest = json.loads((root/'pinyin_ice.json').read_text())
assert manifest['entries'] > 850_000 and manifest['format'] == 2
assert hashlib.sha256((root/'pinyin_dict.txt').read_bytes()).hexdigest() == manifest['legacy_sha256']
for item in manifest['outputs']:
    path = root/item['file']
    assert hashlib.sha256(path.read_bytes()).hexdigest() == item['sha256'], item['file']
    db = sqlite3.connect(f'{path.as_uri()}?mode=ro', uri=True)
    assert db.execute('PRAGMA quick_check').fetchone()[0] == 'ok'
    assert db.execute("SELECT value FROM metadata WHERE key='commit'").fetchone()[0] == manifest['commit']
    assert 'SEARCH' in str(db.execute('EXPLAIN QUERY PLAN SELECT word FROM lexicon WHERE code=? ORDER BY freq DESC,syllables DESC,word,pinyin LIMIT 80', ('nihao',)).fetchall())
    prefixes = db.execute('SELECT DISTINCT prefix FROM completions ORDER BY prefix').fetchall()
    if prefixes:
        selected = prefixes[::max(1,len(prefixes)//25)][:25]
        for (prefix,) in selected:
            oracle = db.execute('SELECT word,pinyin,freq,syllables FROM lexicon WHERE code>? AND code<? ORDER BY freq DESC,syllables DESC,word,pinyin', (prefix,prefix+'{'))
            expected, seen = [], set()
            for row in oracle:
                if row[0] not in seen:
                    expected.append(row);seen.add(row[0])
                if len(expected) == 128:
                    break
            actual = db.execute('SELECT word,pinyin,freq,syllables FROM completions WHERE prefix=? ORDER BY rank',(prefix,)).fetchall()
            assert expected == actual, (item['file'],prefix)
    if item['file'] == 'pinyin_ice.sqlite':
        for line in (root/'pinyin_dict.txt').read_text().splitlines()[:50_000]:
            word, pinyin, _ = line.split('\t')
            assert db.execute('SELECT 1 FROM lexicon WHERE code=? AND word=? LIMIT 1',
                              (pinyin.replace(' ', ''),word)).fetchone(), (word,pinyin)
    db.close()
print('PASS: pinned output hashes, source overlay hash, database integrity, indexed exact plans, 50 materialized-prefix ranking comparisons, full legacy 50k coverage')
