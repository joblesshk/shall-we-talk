#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Shall We Talk contributors.
"""Compile pinned, annotated rime-ice dictionaries into a read-only SQLite index.
No runtime download, parsing or index construction. Python standard library only.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import urllib.request

COMMIT = '859e3b5300e0ea01334a627b15db101e94312a75'
ROOT = Path(__file__).resolve().parents[1]
FILES = ['cn_dicts/8105.dict.yaml', 'cn_dicts/base.dict.yaml', 'cn_dicts/ext.dict.yaml', 'LICENSE']
HASHES = {
    'cn_dicts/8105.dict.yaml': '1f9a42b91dea6982baee2551981780271aeffd78876662b9c9f324e56b37b120',
    'cn_dicts/base.dict.yaml': '9d759771544adf196a0adf9092435ba4df4c0c50d7886963b6b54bf59d14775a',
    'cn_dicts/ext.dict.yaml': '70ed708720b8d34b1de3f1256859bf7526eedd54b7bad401e600060a465718d8',
    'LICENSE': '3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986',
}
T9 = str.maketrans(dict(zip('abcdefghijklmnopqrstuvwxyz', '22233344455566677778889999')))

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--cache', type=Path, default=Path('/tmp/swt-rime-ice-source'))
    ap.add_argument('--output', type=Path, default=ROOT / '_sources/Keyboard/PinyinData/pinyin_ice.sqlite')
    args = ap.parse_args()
    args.cache.mkdir(parents=True, exist_ok=True)
    sources = []
    merged = {}
    syllable_set = set()
    for name in FILES:
        path = args.cache / Path(name).name
        # Cache content is pinned by a sidecar commit marker; unmarked files are fetched.
        marker = path.with_suffix(path.suffix + '.commit')
        if not path.exists() or not marker.exists() or marker.read_text() != COMMIT:
            path.write_bytes(urllib.request.urlopen(f'https://raw.githubusercontent.com/iDvel/rime-ice/{COMMIT}/{name}', timeout=90).read())
            marker.write_text(COMMIT)
        raw = path.read_bytes()
        if hashlib.sha256(raw).hexdigest() != HASHES[name]:
            raise ValueError(f'Pinned source hash mismatch: {path}')
        sources.append({'path': name, 'sha256': hashlib.sha256(raw).hexdigest()})
        if name == 'LICENSE':
            continue
        for line in raw.decode('utf-8-sig').splitlines():
            if not line or line.startswith('#'):
                continue
            cols = line.split('\t')
            if len(cols) < 3:
                continue
            word, pinyin = cols[:2]
            syllables = pinyin.split()
            if not 1 <= len(word) <= 32 or len(syllables) != len(word):
                continue
            if not all(re.fullmatch('[a-z]+', s) for s in syllables):
                continue
            try:
                freq = max(1, int(cols[2]))
            except ValueError:
                continue
            syllable_set.update(syllables)
            key = (word, ''.join(syllables))
            row = (word, key[1], ''.join(s[0] for s in syllables), key[1].translate(T9), freq, len(word))
            if key not in merged or freq > merged[key][4]:
                merged[key] = row
    # Preserve the previously shipped 50k vocabulary when upstream lacks a pair.
    # Includes modern terms such as 大语言模型 and character readings such as 嗯 -> ng.
    legacy = ROOT / '_sources/Keyboard/PinyinData/pinyin_dict.txt'
    aliases = 0
    for line in legacy.read_text().splitlines()[:50_000]:
        word, pinyin, frequency = line.split('\t')
        syllables = pinyin.split()
        flat = ''.join(syllables)
        if (word, flat) not in merged:
            merged[(word, flat)] = (word, flat, ''.join(s[0] for s in syllables), flat.translate(T9), int(frequency), len(word))
            syllable_set.update(syllables)
            aliases += 1
    adjustments = {('你好', 'nihao'): 500_000, ('中国', 'zhongguo'): 501_000,
                   ('升级', 'shengji'): 501_000}
    # Explicit migration compatibility for existing common-word acceptance cases.
    for key, minimum in adjustments.items():
        if key in merged:
            r = merged[key]
            merged[key] = (*r[:4], max(r[4], minimum), r[5])
    rows = sorted(merged.values(), key=lambda r: (-r[4], -r[5], r[0], r[1]))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    outputs = []
    for kind, column, col in [('pinyin', 'pinyin', 1), ('t9', 't9', 3), ('initials', 'initials', 2)]:
        destination = args.output if kind == 'pinyin' else args.output.with_stem(args.output.stem + '_' + kind)
        tmp = destination.with_suffix('.building')
        tmp.unlink(missing_ok=True)
        db = sqlite3.connect(tmp)
        db.executescript(f"""
          PRAGMA page_size=4096; PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF;
          PRAGMA user_version=2;
          CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
          CREATE TABLE lexicon(word TEXT NOT NULL, pinyin TEXT NOT NULL,
            code TEXT NOT NULL, freq INTEGER NOT NULL, syllables INTEGER NOT NULL,
            PRIMARY KEY(code,freq DESC,syllables DESC,word,pinyin)) WITHOUT ROWID;
          CREATE TABLE completions(prefix TEXT NOT NULL, rank INTEGER NOT NULL,
            word TEXT NOT NULL, pinyin TEXT NOT NULL, freq INTEGER NOT NULL, syllables INTEGER NOT NULL,
            PRIMARY KEY(prefix,rank)) WITHOUT ROWID;
        """)
        kept = rows if kind != 'initials' else [r for r in rows if 2 <= r[5] <= 6]
        db.executemany('INSERT INTO lexicon VALUES(?,?,?,?,?)', ((r[0],r[1],r[col],r[4],r[5]) for r in kept))
        if kind != 'initials':
            counts = {}
            for row in rows:
                key = row[col]
                for n in range(1, len(key)):
                    prefix = key[:n]
                    counts[prefix] = counts.get(prefix, 0) + 1
            buckets = {p: {} for p, count in counts.items() if count > 128}
            del counts
            for i, row in enumerate(rows):
                key = row[col]
                for n in range(1, len(key)):
                    bucket = buckets.get(key[:n])
                    if bucket is not None and len(bucket) < 128:
                        bucket.setdefault(row[0], i)
            db.executemany('INSERT INTO completions VALUES(?,?,?,?,?,?)',
                ((prefix, rank, rows[i][0], rows[i][1], rows[i][4], rows[i][5])
                 for prefix, bucket in sorted(buckets.items()) for rank, i in enumerate(bucket.values())))
        db.executemany('INSERT INTO metadata VALUES(?,?)', [('entries',str(len(kept))),('commit',COMMIT)])
        db.commit()
        assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
        db.close()
        tmp.replace(destination)
        outputs.append({'file':destination.name,'bytes':destination.stat().st_size,
                        'sha256':hashlib.sha256(destination.read_bytes()).hexdigest()})
    manifest = {'source':'https://github.com/iDvel/rime-ice','commit':COMMIT,'license':'GPL-3.0',
                'files':sources,'entries':len(rows),'max_word_length':max(r[5] for r in rows),
                'local_adjustments': {key[0]: value for key, value in adjustments.items()},
                'format':2,'outputs':outputs,'legacy_compatibility_entries':aliases,
                'legacy_sha256':hashlib.sha256(legacy.read_bytes()).hexdigest(),'materialized_prefix_threshold':128,'prefix_candidates':128,
                'excluded':'Unannotated tencent dictionary; no automatic polyphonic pronunciation guessing.'}
    (args.output.parent / 'pinyin_ice_syllables.txt').write_text('\n'.join(sorted(syllable_set))+'\n')
    args.output.with_suffix('.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
    (args.output.parent / 'RIME-ICE-LICENSE.txt').write_bytes((args.cache/'LICENSE').read_bytes())
    print(json.dumps({**manifest,'size_mb':sum(x['bytes'] for x in outputs)/1048576},ensure_ascii=False))

if __name__ == '__main__':
    main()
