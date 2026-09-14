# 第三方拼音词库说明

`_sources/Keyboard/PinyinData/` 中的词库是由 `tools/build_pinyin_dict.py` 生成的离线资源。生成器固定了上游 commit，以便重现和审核。

## jieba

- 项目: <https://github.com/fxsjy/jieba>
- 用途: 通用中文词频基线
- 许可证: MIT License
- 版权: jieba contributors

## Rime pinyin-simp

- 项目: <https://github.com/rime/rime-pinyin-simp>
- 固定 commit: `0c6861ef7420ee780270ca6d993d18d4101049d0`
- 用途: 简体中文词条、拼音和词频
- 许可证: Apache License 2.0
- 许可证全文: <https://github.com/rime/rime-pinyin-simp/blob/0c6861ef7420ee780270ca6d993d18d4101049d0/LICENSE>

## THUOCL

- 项目: <https://github.com/thunlp/THUOCL>
- 固定 commit: `a30ce79d895d01ab5132a5c74c29703ff7efb4cc`
- 用途: IT、财经、医疗、法律、成语等领域词汇和词频
- 许可证: MIT License
- 版权: Tsinghua University Natural Language Processing and Social Computing Lab contributors
- 许可证全文: <https://github.com/thunlp/THUOCL/blob/a30ce79d895d01ab5132a5c74c29703ff7efb4cc/LICENSE>

## Rime Ice（雾凇拼音，构建230起）

- 上游：https://github.com/iDvel/rime-ice
- 固定提交：`859e3b5300e0ea01334a627b15db101e94312a75`。
- 使用有注音的8105/base/ext，保留旧词库遗漏词条；26键与九宫格共用891394条词，分别使用全拼、T9、简拼SQLite索引。
- 词库资源及生成脚本 `tools/build_rime_ice.py` 按GPL-3.0-only分发，许可证为资源目录中的RIME-ICE-LICENSE.txt。第三方资源不受仓库专有LICENSE覆盖。
- 安装包附 `pinyin_ice_sources.zip`：固定上游原始数据、原始头部、许可、旧词库输入和生成脚本，附离线重建说明。`pinyin_ice_sources.json`固定源码包哈希；`pinyin_ice.json`记录输入、转换与输出哈希。
- 源码包可从键盘扩展资源中取得；向测试者交付同一版本时应保留其源包与许可。
