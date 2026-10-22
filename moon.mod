// moontantivy —— 纯 MoonBit 实现的嵌入式全文检索引擎
// 模块配置参考：https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// 说明：当前 MoonBit 工具链（0.1.20261020）已不再支持 moon.mod.json /
// moon.pkg.json，统一使用 moon.mod / moon.pkg，因此本仓库遵循现行格式。

name = "hc155-89/moontantivy"

version = "0.1.0"

readme = "README.mbt.md"

repository = "https://github.com/hc155-89/moontantivy"

license = "Apache-2.0"

keywords = [ "search", "full-text", "inverted-index", "bm25", "tokenizer" ]

description = "纯 MoonBit 实现的嵌入式全文检索引擎：倒排索引、分词器、BM25 评分、布尔/短语查询与索引持久化，零 FFI、可运行于 WASM/WASI。"

import {
  "moonbitlang/x@0.4.48",
}
