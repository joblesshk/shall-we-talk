# Third-party notices

Original application code remains proprietary. The following materials are excluded from that proprietary restriction and retain their upstream terms. Attribution is not a claim of endorsement or a blanket clearance for binary distribution.

## Bundled model

**Silero VAD / FluidInference CoreML conversion** — MIT. Original copyright (c) 2020-present Silero Team; CoreML conversion credited to Fluid Inference / FluidAudio Team in the model metadata. Source: https://github.com/snakers4/silero-vad and https://huggingface.co/FluidInference/silero-vad-coreml . The model card declares MIT; its upstream conversion code is https://github.com/FluidInference/mobius . Full original Silero terms: [LICENSES/Silero-MIT.txt](LICENSES/Silero-MIT.txt).

The bundled compiled model is `silero-vad-unified-256ms-v6.2.1.mlmodelc`. All local model files have been verified against the fixed upstream revision and SHA-256 values in [MODEL_PROVENANCE.json](MODEL_PROVENANCE.json). This identifies an exact matching upstream source snapshot, not an assertion of the original download date. Local Swift inference integration is not a linked FluidAudio SDK. [FluidAudio's Apache-2.0 text](LICENSES/FluidAudio-Apache-2.0.txt) is provided for the separately acknowledged reference project; it is not substituted for the model's MIT terms.

## Bundled dictionaries and corresponding source

**Rime Ice** — GPL-3.0-only. Upstream https://github.com/iDvel/rime-ice at `859e3b5300e0ea01334a627b15db101e94312a75`. The annotated 8105/base/ext dictionaries are transformed into full-pinyin, T9 and initials indexes, with deduplication, validation, retained legacy entries and documented frequency changes. The generated dictionaries and `ios/tools/build_rime_ice.py` retain GPL terms.

Full terms and detailed original attribution: [RIME-ICE-LICENSE.txt](ios/_sources/Keyboard/PinyinData/RIME-ICE-LICENSE.txt), [RIME-ICE-NOTICE.txt](ios/_sources/Keyboard/PinyinData/RIME-ICE-NOTICE.txt), and [ios/THIRD_PARTY_LEXICONS.md](ios/THIRD_PARTY_LEXICONS.md). The bundled `pinyin_ice_sources.zip` preserves original annotated files, headers, license, legacy inputs, generator and offline rebuilding instructions; manifests record input/output/source-archive hashes. Do not remove the corresponding source when redistributing these resources. See original headers for component word-list/frequency sources. Dictionary aggregation and application distribution obligations must be reviewed for the intended distribution; this notice does not declare GPL compatibility for every possible product combination.

Legacy dictionary inputs retained by the build:

| Component | Source and use | License text |
| --- | --- | --- |
| jieba | https://github.com/fxsjy/jieba ; Chinese word-frequency input; copyright 2013 Sun Junyi | [MIT](LICENSES/jieba-MIT.txt) |
| rime-pinyin-simp | https://github.com/rime/rime-pinyin-simp at `0c6861ef7420ee780270ca6d993d18d4101049d0`; words/readings/frequencies | [Apache-2.0](LICENSES/rime-pinyin-simp-Apache-2.0.txt) |
| THUOCL | https://github.com/thunlp/THUOCL at `a30ce79d895d01ab5132a5c74c29703ff7efb4cc`; domain vocabulary; copyright 2018 THUNLP | [MIT](LICENSES/THUOCL-MIT.txt) |

## Optional build-time tools

- **pypinyin**, https://github.com/mozillazg/python-pinyin — [MIT](LICENSES/pypinyin-MIT.txt); pronunciation generation in the legacy dictionary generator. Its package code is not embedded as a Swift runtime dependency.
- **Pillow**, https://github.com/python-pillow/Pillow — [HPND and upstream notices](LICENSES/Pillow-HPND.txt); optional app-icon generation. Tool code is not bundled into the app.
- **XcodeGen**, https://github.com/yonaskolb/XcodeGen — [MIT](LICENSES/XcodeGen-MIT.txt); generates Xcode projects. Installed separately.
- **SQLite**, https://www.sqlite.org/copyright.html — public domain; accessed via the Apple system library and Python standard library for dictionary/store tools, not a vendored SQLite implementation.

Apple frameworks and SF Symbols are Apple platform resources governed by Apple's SDK/resource terms, not relicensed by this repository. CoreML model metadata also identifies conversion tools; those packages are not linked runtime dependencies.

License downloads and checksums are recorded in [LICENSES/sources.json](LICENSES/sources.json). Original upstream headers remain authoritative. Keep this file, full license texts, resource notices and corresponding-source archive with relevant redistributions.
