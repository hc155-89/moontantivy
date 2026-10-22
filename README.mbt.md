# moontantivy

纯 MoonBit 实现的嵌入式全文检索引擎。提供位置级倒排索引、BM25 相关度排序、布尔 / 短语查询与确定性 JSON 持久化，不依赖 C / Rust 绑定，可用于 CLI、服务端与 WASM 沙箱。

- **位置级倒排表**：短语查询基于词项位置连续性验证，而不是字符串包含。
- **BM25 排序**：Lucene 平滑 IDF，`k1` / `b` 可配置，结果稳定可复现。
- **查询语法**：`AND` / `OR` / `NOT`、括号、隐式 AND、双引号短语，大小写不敏感，嵌套深度上限 64。
- **确定性持久化**：同一索引多次导出的 JSON 字节完全一致，带版本号与完整性校验。
- **可判定的错误类型**：查询解析 7 种错误、存储加载 5 种错误，均有可读消息。

## 安装

```bash
moon add hc155-89/moontantivy@0.1.0
```

在 `moon.pkg` 中引入需要的包：

```text
import {
  "hc155-89/moontantivy",
  "hc155-89/moontantivy/api",
}
```

## 快速开始

```moonbit nocheck
let engine = @api.SearchEngine::new()

engine.add_document(@moontantivy.Document::new(
  1, "MoonBit Search Engine", "moonbit inverted index search engine",
))
engine.add_document(@moontantivy.Document::new(
  2, "Rust Ownership", "rust ownership borrow checker memory safety",
))

// 布尔 + 短语组合查询，返回按 BM25 得分降序的前 10 条
for hit in engine.search("moonbit AND \"inverted index\"", 10) {
  println("doc=\{hit.doc_id} score=\{hit.score} \{hit.title}")
}
```

## 持久化

写入磁盘并从磁盘恢复：

```moonbit nocheck
engine.save("index_data.json") catch { _ => println("保存失败") }
let reopened = Some(@api.SearchEngine::load("index_data.json")) catch {
  _ => None
}
```

浏览器 / 边缘运行时没有可写文件系统，可直接使用内存文本：

```moonbit nocheck
///|
let restored = Some(@api.SearchEngine::from_json(engine.to_json())) catch {
  _ => None
}
```

## API 一览

| API | 说明 |
| --- | --- |
| `SearchEngine::new()` | 创建空引擎 |
| `add_document(doc)` | 写入文档，同 ID 按更新处理 |
| `remove_document(id)` | 按 ID 删除，返回是否删除成功 |
| `search(query, top_k)` | 解析、召回、BM25 评分并截断，非法查询返回空数组 |
| `set_bm25(config)` | 替换 BM25 的 `k1` / `b` |
| `save(path)` / `load(path)` | JSON 文件持久化 |
| `to_json()` / `from_json(text)` | 不落盘的内存序列化 |

底层包 `tokenizer`、`index`、`score`、`query`、`storage` 也可单独引入使用。

## 演示

```bash
moon run example
```

演示建索引、四类查询、保存到 `index_data.json`、重新加载并比对结果。

## 验证

```bash
moon check      # 类型检查，无错误与警告
moon test       # 56 个测试
moon fmt --check
```

## 许可证

Apache License 2.0，见仓库内 `LICENSE`。
