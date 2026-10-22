// api 包黑盒测试：端到端验证 SearchEngine 的建索引、检索、排序与持久化。
//
// 测试数据模拟一个真实的小型产品/日志库，覆盖：
// - 英文标题 + 正文、带 BM25 长度归一化的排序；
// - 布尔（AND / OR / NOT）、括号、短语与中文短语；
// - Top-K 截断、无命中、非法查询；
// - 保存 -> 加载 -> 继续检索/增删。

///|
/// 构造 10 篇文档的引擎，模拟真实商品/日志数据。
///
/// 文档长度（停用词过滤后的词项数）刻意设计成不同值：
/// 1 -> 9、2 -> 9、3 -> 9、4 -> 8、5 -> 8、6 -> 7、7 -> 14、8 -> 7、9 -> 7、10 -> 7，
/// 平均长度 8.5，便于用数学上可预期的 BM25 排序做断言。
fn sample_engine() -> @api.SearchEngine {
  let engine = @api.SearchEngine::new()
  let docs : Array[@moontantivy.Document] = [
    @moontantivy.Document::new(
      1, "MoonBit Search Engine", "moonbit inverted index engine with bm25 ranking",
    ),
    @moontantivy.Document::new(
      2, "Rust Systems Programming", "rust systems programming memory safety performance",
    ),
    @moontantivy.Document::new(
      3, "Go Web Service", "go web service concurrency goroutine performance",
    ),
    @moontantivy.Document::new(
      4, "MoonBit Parser", "moonbit query parser boolean phrase search",
    ),
    @moontantivy.Document::new(
      5, "Database Index", "database btree index storage engine persistence",
    ),
    @moontantivy.Document::new(
      6, "JSON Storage", "json serialization storage persistence file",
    ),
    @moontantivy.Document::new(
      7, "Chinese Search", "中文 搜索引擎 支持 中文 检索",
    ),
    @moontantivy.Document::new(
      8, "Search Ranking", "search ranking bm25 scoring relevance",
    ),
    @moontantivy.Document::new(
      9, "WASM Runtime", "wasm runtime sandbox performance lightweight",
    ),
    @moontantivy.Document::new(
      10, "Log Analyzer", "log analyzer error query dashboard",
    ),
  ]
  for doc in docs {
    engine.add_document(doc)
  }
  engine
}

///|
/// 取出结果里的文档 ID 序列，便于断言顺序。
fn ids(results : Array[@api.SearchResult]) -> Array[Int32] {
  let out : Array[Int32] = Array()
  for result in results {
    out.push(result.doc_id)
  }
  out
}

///|
/// 删除临时文件，忽略“文件不存在”等错误。
fn cleanup(path : String) -> Unit {
  @fs.remove_file(path) catch {
    _ => ()
  }
}

///|
/// 端到端全流程：建索引 -> 多形态查询 -> Top-K -> 持久化 -> 继续增删。
test "e2e_search_engine_test" {
  let engine = sample_engine()
  assert_eq(engine.num_docs(), 10)
  // 单词检索：只有 doc 1 和 doc 4 含 moonbit，且两者词频相同（标题 + 正文各一次）。
  // doc 4 更短（8 < 9），BM25 的长度归一化让它的得分更高。
  let moonbit_hits = engine.search("moonbit", 10)
  assert_eq(ids(moonbit_hits), ([4, 1] : Array[Int32]))
  assert_true(
    moonbit_hits.unsafe_get(0).score > moonbit_hits.unsafe_get(1).score,
  )
  assert_eq(moonbit_hits.unsafe_get(0).title, "MoonBit Parser")
  // Top-K 截断：只要 1 条时返回得分最高的 doc 4。
  assert_eq(ids(engine.search("moonbit", 1)), ([4] : Array[Int32]))
  // 词频归一化：performance 出现在 doc 2/3/9，词频均为 1；
  // doc 9 最短（7 个词项），排第一；doc 2 与 doc 3 长度、词频都相同，
  // 得分并列，由 doc_id 升序兜底，得到稳定的 [9, 2, 3]。
  assert_eq(ids(engine.search("performance", 10)), ([9, 2, 3] : Array[Int32]))
  // 短语查询：inverted index 在 doc 1 中位置连续，其它文档没有 inverted。
  assert_eq(ids(engine.search("\"inverted index\"", 10)), ([1] : Array[Int32]))
  assert_eq(ids(engine.search("\"query parser\"", 10)), ([4] : Array[Int32]))
  // 布尔查询：rust 只出现在 doc 2，IDF 高于 moonbit（2 篇），因此 doc 2 排第一。
  assert_eq(
    ids(engine.search("moonbit OR rust", 10)),
    ([2, 4, 1] : Array[Int32]),
  )
  // 括号 + NOT：先取 moonbit/rust 的并集，再排除含 parser 的 doc 4。
  assert_eq(
    ids(engine.search("(moonbit OR rust) AND NOT parser", 10)),
    ([2, 1] : Array[Int32]),
  )
  // 中文短语：中文按字切分，"搜索" 在 doc 7 中位置连续。
  assert_eq(ids(engine.search("\"搜索\"", 10)), ([7] : Array[Int32]))
  // 无命中：返回空数组而不是报错。
  assert_eq(engine.search("nonexistentterm", 10).length(), 0)
  // 持久化往返：文档、词项、位置全部恢复，检索结果与得分保持一致。
  let path = "tmp_moontantivy_engine_e2e.json"
  cleanup(path)
  engine.save(path)
  let loaded = @api.SearchEngine::load(path)
  assert_eq(loaded.num_docs(), 10)
  let before = engine.search("(moonbit OR rust) AND NOT parser", 10)
  let after = loaded.search("(moonbit OR rust) AND NOT parser", 10)
  assert_eq(ids(after), ids(before))
  for i in 0..<before.length() {
    let delta = after.unsafe_get(i).score - before.unsafe_get(i).score
    assert_true(delta < 0.000000001 && delta > -0.000000001)
  }
  // 加载后的引擎仍可继续写入与删除。
  loaded.add_document(
    @moontantivy.Document::new(
      11, "MoonBit Storage", "moonbit storage persistence json file",
    ),
  )
  assert_eq(loaded.num_docs(), 11)
  assert_eq(ids(loaded.search("moonbit", 10)).length(), 3)
  assert_true(loaded.remove_document(11))
  assert_eq(loaded.num_docs(), 10)
  assert_eq(ids(loaded.search("moonbit", 10)), ([4, 1] : Array[Int32]))
  cleanup(path)
  assert_false(@fs.path_exists(path))
}

///|
/// 非法查询与非法 Top-K 都应安静地返回空结果，而不是抛错或崩溃。
test "invalid_query_and_top_k" {
  let engine = sample_engine()
  assert_eq(engine.search("", 10).length(), 0)
  assert_eq(engine.search("   ", 10).length(), 0)
  assert_eq(engine.search("\"unterminated", 10).length(), 0)
  assert_eq(engine.search("(moonbit", 10).length(), 0)
  assert_eq(engine.search("moonbit AND", 10).length(), 0)
  assert_eq(engine.search("moonbit", 0).length(), 0)
  assert_eq(engine.search("moonbit", -3).length(), 0)
}

///|
/// 同 ID 重复添加按更新处理：旧文档的词项必须从索引中彻底消失。
test "duplicate_id_updates_document" {
  let engine = @api.SearchEngine::new()
  engine.add_document(@moontantivy.Document::new(1, "Old", "rust go"))
  engine.add_document(@moontantivy.Document::new(1, "New", "moonbit search"))
  assert_eq(engine.num_docs(), 1)
  assert_eq(engine.search("rust", 10).length(), 0)
  assert_eq(ids(engine.search("moonbit", 10)), ([1] : Array[Int32]))
}

///|
/// BM25 参数确实影响排序：把 b 设为 0 后不再做长度归一化，
/// 三篇词频相同的文档得分并列，顺序退化为 doc_id 升序。
test "bm25_config_changes_ranking" {
  let engine = sample_engine().set_bm25(@score.BM25Config::new(b=0.0))
  assert_eq(ids(engine.search("performance", 10)), ([2, 3, 9] : Array[Int32]))
}
