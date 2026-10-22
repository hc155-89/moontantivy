// moontantivy 完整生命周期演示。
//
// 运行方式：
//     moon run example
//
// 演示内容：
//     1. 创建引擎并插入 6 篇关于 MoonBit / Rust / Wasm 的文档；
//     2. 执行布尔、短语、NOT 检索并打印带分数的结果；
//     3. 把索引保存为 index_data.json；
//     4. 从磁盘重新加载，再次检索并与内存中的结果比对，证明持久化有效。

///|
/// 演示使用的索引文件路径（相对 `moon run` 的工作目录，即项目根目录）。
const INDEX_PATH : String = "index_data.json"

///|
/// 把 BM25 得分格式化为固定 4 位小数，避免终端里出现一长串浮点尾数。
///
/// 实现方式是先放大 10000 倍四舍五入成整数，再手工补前导零，
/// 这样不依赖任何格式化库，输出宽度也稳定。
fn format_score(score : Double) -> String {
  let scaled = (score * 10000.0 + 0.5).to_int()
  let whole = scaled / 10000
  let fraction = scaled % 10000
  let digits = fraction.to_string()
  let builder = StringBuilder()
  builder.write_string(whole.to_string())
  builder.write_char('.')
  for _ in 0..<(4 - digits.length()) {
    builder.write_char('0')
  }
  builder.write_string(digits)
  builder.to_string()
}

///|
/// 打印一组检索结果：标题 + 名次 + 分数 + 文档 ID + 文档标题。
fn print_hits(label : String, hits : Array[@api.SearchResult]) -> Unit {
  println("  " + label)
  if hits.is_empty() {
    println("    (无命中)")
    return
  }
  for i, hit in hits {
    println(
      "    #\{i + 1}  score=\{format_score(hit.score)}  doc=\{hit.doc_id}  \{hit.title}",
    )
  }
}

///|
/// 比较两组结果的文档 ID 序列，用于验证“加载后检索结果一致”。
fn same_doc_ids(
  left : Array[@api.SearchResult],
  right : Array[@api.SearchResult],
) -> Bool {
  if left.length() != right.length() {
    return false
  }
  for i in 0..<left.length() {
    if left.unsafe_get(i).doc_id != right.unsafe_get(i).doc_id {
      return false
    }
  }
  true
}

///|
/// 演示入口。
fn main {
  println("========================================")
  println(" moontantivy 演示：建索引 -> 检索 -> 持久化")
  println("========================================")

  // ---- 1. 初始化并写入文档 ----
  println("")
  println("[1/5] 初始化引擎并插入文档")
  let engine = @api.SearchEngine::new()
  let docs : Array[@moontantivy.Document] = [
    @moontantivy.Document::new(
      1, "MoonBit Language", "moonbit is a modern language for wasm and native targets",
    ),
    @moontantivy.Document::new(
      2, "MoonBit Search Engine", "moonbit inverted index search engine with bm25 scoring",
    ),
    @moontantivy.Document::new(
      3, "Rust Ownership", "rust ownership borrow checker memory safety",
    ),
    @moontantivy.Document::new(
      4, "Rust and Wasm", "rust compiles to wasm for web deployment",
    ),
    @moontantivy.Document::new(
      5, "WebAssembly Runtime", "wasm runtime sandbox fast startup lightweight",
    ),
    @moontantivy.Document::new(
      6, "MoonBit vs Rust", "moonbit and rust both target wasm native performance",
    ),
  ]
  for doc in docs {
    engine.add_document(doc)
    println("  + doc \{doc.id}  \{doc.title}")
  }
  println("  共写入 \{engine.num_docs()} 篇文档")

  // ---- 2. 多种形态的检索 ----
  println("")
  println("[2/5] 执行检索")
  print_hits(
    "布尔: moonbit AND search (Top 3)",
    engine.search("moonbit AND search", 3),
  )
  print_hits(
    "并集: wasm OR webassembly (Top 5)",
    engine.search("wasm OR webassembly", 5),
  )
  print_hits(
    "短语: \"inverted index\" (Top 3)",
    engine.search("\"inverted index\"", 3),
  )
  print_hits(
    "排除: moonbit AND NOT rust (Top 5)",
    engine.search("moonbit AND NOT rust", 5),
  )

  // ---- 3. 记录基准结果 ----
  let base_query = "moonbit AND search"
  let before = engine.search(base_query, 3)
  println("")
  println("[3/5] 记录基准结果（用于持久化后比对）")
  print_hits("基准: " + base_query, before)

  // ---- 4. 保存到磁盘 ----
  println("")
  println("[4/5] 保存索引到 " + INDEX_PATH)
  let mut saved = true
  engine.save(INDEX_PATH) catch {
    _ => saved = false
  }
  if saved {
    let size = @fs.read_file_to_string(INDEX_PATH).length() catch { _ => 0 }
    println("  写入成功，JSON 大小 \{size} 字节")
  } else {
    println("  写入失败（请检查当前目录是否可写）")
  }

  // ---- 5. 重新加载并验证 ----
  println("")
  println("[5/5] 从磁盘重新加载并再次检索")
  let reopened = Some(@api.SearchEngine::load(INDEX_PATH)) catch { _ => None }
  match reopened {
    None =>
      println("  加载失败，请检查 " + INDEX_PATH + " 是否存在")
    Some(loaded) => {
      println("  恢复文档数：\{loaded.num_docs()}")
      let after = loaded.search(base_query, 3)
      print_hits("加载后: " + base_query, after)
      if same_doc_ids(before, after) {
        println(
          "  持久化验证通过：加载后的结果与内存中完全一致",
        )
      } else {
        println(
          "  持久化验证失败：加载后的结果与内存中不一致",
        )
      }
    }
  }
  println("")
  println(
    "演示结束。索引文件保留在 " +
    INDEX_PATH +
    "，可直接复用。",
  )
}
