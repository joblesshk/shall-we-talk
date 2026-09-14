#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成文本应急词库资源。当前主词库由 build_rime_ice.py 构建；本文件用于降级核心集。
修改此输出后需重新运行 build_rime_ice.py，并验证 pinyin_index_resources.py。

数据源:
  - jieba (MIT): 通用词频基线
  - Rime pinyin-simp (Apache-2.0): 已标注拼音和词频的简体词表
  - THUOCL (MIT): 清华大学开放中文词库，补充 IT/财经/医疗等领域词

默认从锁定 commit 下载 Rime/THUOCL 源文件，也可传本地克隆目录:
  RIME_DIR=/path/to/rime-pinyin-simp THUOCL_DIR=/path/to/THUOCL \
    python3 tools/build_pinyin_dict.py

依赖: pip install jieba pypinyin
可调: MAX_MULTI=110000 (多字词输出上限)
"""
import os
import re
import tempfile
import urllib.request

import jieba
from pypinyin import lazy_pinyin, Style

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(HERE, "..", "_sources", "Keyboard", "PinyinData")
os.makedirs(OUT_DIR, exist_ok=True)

MAX_MULTI = int(os.environ.get("MAX_MULTI", "110000"))
MOBILE_CORE = int(os.environ.get("MOBILE_CORE", "50000"))
MAX_LEN = 8
CJK = re.compile(r"^[\u3400-\u9fff]+$")

RIME_COMMIT = "0c6861ef7420ee780270ca6d993d18d4101049d0"
THUOCL_COMMIT = "a30ce79d895d01ab5132a5c74c29703ff7efb4cc"
THUOCL_FILES = (
    "THUOCL_IT.txt", "THUOCL_animal.txt", "THUOCL_caijing.txt",
    "THUOCL_car.txt", "THUOCL_chengyu.txt", "THUOCL_diming.txt",
    "THUOCL_food.txt", "THUOCL_law.txt", "THUOCL_lishimingren.txt",
    "THUOCL_medical.txt", "THUOCL_poem.txt",
)

# 上游词库存在年份差，这些已成为日常用语的词仍可能缺失。
# 小型补丁直接在源码中可审查，不引入网络热词的不可控内容。
CURATED_MODERN_WORDS = (
    "朋友圈", "小红书", "短视频", "待办", "微信群", "视频号", "直播间", "公众号",
    "网红", "新能源", "新能源汽车", "充电桩", "自动驾驶", "网约车", "快递柜", "外卖",
    "人工智能", "大语言模型", "语音识别", "机器学习", "深度学习", "云计算", "物联网", "区块链",
    "输入法", "拼音输入法", "输入框", "剪贴板", "麦克风", "词库", "热词", "二维码",
    "验证码", "扫码", "截图", "屏幕录制", "网盘", "云盘", "电子邮件", "在线会议",
)


def normal_pinyin(word):
    syllables = lazy_pinyin(word, style=Style.NORMAL, errors="ignore")
    if len(syllables) != len(word):
        return None
    syllables = [s.lower() for s in syllables]
    if any(not s.isascii() or not s.isalpha() for s in syllables):
        return None
    return syllables


def valid_word(word):
    return bool(CJK.fullmatch(word)) and len(word) <= MAX_LEN


def fetch(url, destination):
    print(f"下载: {url}")
    urllib.request.urlretrieve(url, destination)


def source_paths():
    temp_dir = tempfile.TemporaryDirectory(prefix="voicepen-lexicons-")
    root = temp_dir.name

    rime_dir = os.environ.get("RIME_DIR")
    if rime_dir:
        rime_path = os.path.join(rime_dir, "pinyin_simp.dict.yaml")
    else:
        rime_path = os.path.join(root, "pinyin_simp.dict.yaml")
        fetch(
            f"https://raw.githubusercontent.com/rime/rime-pinyin-simp/{RIME_COMMIT}/pinyin_simp.dict.yaml",
            rime_path,
        )

    thuocl_dir = os.environ.get("THUOCL_DIR")
    thuocl_paths = []
    for filename in THUOCL_FILES:
        if thuocl_dir:
            path = os.path.join(thuocl_dir, "data", filename)
        else:
            path = os.path.join(root, filename)
            fetch(
                f"https://raw.githubusercontent.com/thunlp/THUOCL/{THUOCL_COMMIT}/data/{filename}",
                path,
            )
        thuocl_paths.append(path)
    return temp_dir, rime_path, thuocl_paths


def main():
    # (word, pinyin) -> 合并后最大词频。保留多音词的不同读法。
    merged = {}
    source_counts = {"jieba": 0, "rime": 0, "thuocl": 0, "voicepen": 0}
    source_entries = {"jieba": {}, "rime": {}, "thuocl": {}, "voicepen": {}}

    def add(word, syllables, frequency, source):
        word = word.strip().lstrip("\ufeff")
        if not valid_word(word) or not syllables or len(syllables) != len(word):
            return
        syllables = [s.lower() for s in syllables]
        if any(not s.isascii() or not s.isalpha() for s in syllables):
            return
        key = (word, " ".join(syllables))
        merged[key] = max(merged.get(key, 0), max(1, int(frequency)))
        source_entries[source][key] = max(source_entries[source].get(key, 0), max(1, int(frequency)))
        source_counts[source] += 1

    jieba_path = os.path.join(os.path.dirname(jieba.__file__), "dict.txt")
    with open(jieba_path, encoding="utf-8") as handle:
        for line in handle:
            columns = line.split()
            if len(columns) < 2 or not valid_word(columns[0]):
                continue
            try:
                frequency = int(columns[1])
            except ValueError:
                continue
            add(columns[0], normal_pinyin(columns[0]), frequency, "jieba")

    temp_dir, rime_path, thuocl_paths = source_paths()
    try:
        with open(rime_path, encoding="utf-8") as handle:
            for line in handle:
                columns = line.rstrip("\n").split("\t")
                if len(columns) != 3:
                    continue
                try:
                    frequency = int(columns[2])
                except ValueError:
                    continue
                add(columns[0], columns[1].split(), frequency, "rime")

        for path in thuocl_paths:
            with open(path, encoding="utf-8-sig") as handle:
                for line in handle:
                    columns = line.split()
                    if len(columns) < 2 or not valid_word(columns[0]):
                        continue
                    try:
                        frequency = int(columns[-1])
                    except ValueError:
                        continue
                    add(columns[0], normal_pinyin(columns[0]), frequency, "thuocl")
    finally:
        temp_dir.cleanup()

    for word in CURATED_MODERN_WORDS:
        add(word, normal_pinyin(word), 50_000, "voicepen")

    rows = [(word, pinyin, freq) for (word, pinyin), freq in merged.items()]
    singles = [row for row in rows if len(row[0]) == 1]
    multis = sorted((row for row in rows if len(row[0]) > 1), key=lambda r: (-r[2], r[0], r[1]))
    kept = singles + multis[:MAX_MULTI]

    # 输出前 MOBILE_CORE 条就是键盘实际加载集。先保留全局高频词，再为 Rime
    # 的已注音词表和 THUOCL 领域热词留配额，避免单纯全局截断再次把
    # “人工智能”等正常复合词排到运行时上限之外。
    kept_by_key = {(word, pinyin): (word, pinyin, freq) for word, pinyin, freq in kept}
    ranked_all = sorted(kept, key=lambda r: (-r[2], r[0], r[1]))
    core_keys = set()

    def take(rows, scan_limit):
        scanned = 0
        for row in rows:
            if len(core_keys) >= MOBILE_CORE or scanned >= scan_limit:
                break
            scanned += 1
            key = (row[0], row[1])
            if key in kept_by_key and key not in core_keys:
                core_keys.add(key)

    take(ranked_all, 16_000)
    rime_ranked = sorted(
        ((word, pinyin, freq) for (word, pinyin), freq in source_entries["rime"].items()),
        key=lambda r: (-r[2], r[0], r[1]),
    )
    take(rime_ranked, 34_000)
    thuocl_ranked = sorted(
        ((word, pinyin, freq) for (word, pinyin), freq in source_entries["thuocl"].items()),
        key=lambda r: (-r[2], r[0], r[1]),
    )
    take(thuocl_ranked, 20_000)
    take(ranked_all, len(ranked_all))

    core = sorted((kept_by_key[key] for key in core_keys), key=lambda r: (-r[2], r[0], r[1]))
    remainder = [row for row in ranked_all if (row[0], row[1]) not in core_keys]
    kept = core + remainder

    syllable_set = set()
    char_pinyin = {}
    for word, pinyin, _ in kept:
        syllables = pinyin.split()
        syllable_set.update(syllables)
        if len(word) == 1:
            char_pinyin.setdefault(word, syllables[0])

    dict_path = os.path.join(OUT_DIR, "pinyin_dict.txt")
    with open(dict_path, "w", encoding="utf-8") as handle:
        for word, pinyin, frequency in kept:
            handle.write(f"{word}\t{pinyin}\t{frequency}\n")

    syllable_path = os.path.join(OUT_DIR, "pinyin_syllables.txt")
    with open(syllable_path, "w", encoding="utf-8") as handle:
        for syllable in sorted(syllable_set):
            handle.write(syllable + "\n")

    char_path = os.path.join(OUT_DIR, "char_pinyin.txt")
    with open(char_path, "w", encoding="utf-8") as handle:
        for char in sorted(char_pinyin):
            handle.write(f"{char}\t{char_pinyin[char]}\n")

    def megabytes(path):
        return os.path.getsize(path) / 1024 / 1024

    print(f"源词条: {source_counts}; 合并去重: {len(rows)}")
    print(f"pinyin_dict.txt      : {len(kept)} 行, 移动核心 {len(core)} 行, {megabytes(dict_path):.2f} MB")
    print(f"pinyin_syllables.txt : {len(syllable_set)} 音节")
    print(f"char_pinyin.txt      : {len(char_pinyin)} 单字, {megabytes(char_path):.2f} MB")


if __name__ == "__main__":
    main()
