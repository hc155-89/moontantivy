// score 包黑盒测试：验证 BM25 的排序行为、参数语义与边界条件。
//
// 测试索引固定为 3 篇文档：
// - 文档 1：短文档，moonbit 出现 2 次，长度 4；
// - 文档 2：长文档，moonbit 出现 2 次，长度 14；
// - 文档 3：不含 moonbit，长度 6。
// 全库共 24 个词项，平均文档长度 8.0。

///|
/// 构造测试用的 3 篇文档索引。
fn sample_index() -> @index.InvertedIndex {
  let idx = @index.InvertedIndex::new()
  let tokenizer : &@tokenizer.Tokenizer = @tokenizer.StandardTokenizer::new()
  let docs : Array[@moontantivy.Document] = [
    @moontantivy.Document::new(1, "MoonBit search", "moonbit search"),
    @moontantivy.Document::new(
      2,
      "MoonBit search",
      "moonbit search engine tokenizer inverted index bm25 documents " +
      "ranking relevance scoring retrieval",
    ),
    @moontantivy.Document::new(3, "Cooking pasta", "pasta tomato basil garlic"),
  ]
  for doc in docs {
    idx.add_doc(doc, tokenizer)
  }
  idx
}

///|
/// 浮点近似比较：BM25 涉及对数运算，测试不应依赖二进制精确相等。
fn close(a : Double, b : Double, eps : Double) -> Bool {
  let diff = if a > b { a - b } else { b - a }
  diff <= eps
}

///|
/// 默认超参数应为信息检索领域的经验值。
test "default_bm25_config_values" {
  let config = @score.BM25Config::new()
  assert_eq(config.k1, 1.2)
  assert_eq(config.b, 0.75)
  // 也可以只覆盖单个参数。
  let custom = @score.BM25Config::new(b=1.0)
  assert_eq(custom.k1, 1.2)
  assert_eq(custom.b, 1.0)
}

///|
/// IDF：越少见的词项权重越高，且始终为正。
test "idf_is_positive_and_monotonic" {
  let rare = @score.idf(1, 3)
  let common = @score.idf(2, 3)
  let ubiquitous = @score.idf(3, 3)
  assert_true(rare > common)
  assert_true(common > ubiquitous)
  assert_true(ubiquitous > 0.0)
  // 与 Lucene 平滑 IDF 公式的解析值对齐。
  assert_true(close(rare, 0.9808292530117262, 1.0e-9))
  assert_true(close(common, 0.4700036292457356, 1.0e-9))
  assert_true(close(ubiquitous, 0.1335313926245226, 1.0e-9))
  // 词项不存在或索引为空时，IDF 退化为 0，不产生负贡献。
  assert_eq(@score.idf(0, 3), 0.0)
  assert_eq(@score.idf(3, 0), 0.0)
  // df > N 属于异常统计，应被夹到 N 而不是产生异常值。
  assert_true(close(@score.idf(10, 3), ubiquitous, 1.0e-9))
}

///|
/// Phase 4 的核心断言：两篇文档词频相同，短文档得分必须更高。
test "shorter_document_scores_higher" {
  let idx = sample_index()
  let config = @score.BM25Config::new()
  let short_score = @score.score(["moonbit"], 1, idx, config)
  let long_score = @score.score(["moonbit"], 2, idx, config)
  let missing_score = @score.score(["moonbit"], 3, idx, config)
  assert_true(short_score > long_score)
  assert_true(long_score > 0.0)
  assert_eq(missing_score, 0.0)
  // 短文档：idf(2,3)=ln(1.6)，tf=2、dl=4、avgdl=8，
  // 归一化因子 = 0.25 + 0.75 * 0.5 = 0.625，
  // 结果 = ln(1.6) * (2 * 2.2) / (2 + 1.2 * 0.625) = ln(1.6) * 1.6。
  assert_true(close(short_score, 0.7520058067931769, 1.0e-9))
}

///|
/// 参数语义：k1 = 0 时词频不再带来额外收益，两篇同词频文档得分相等；
/// b = 1 时长度归一化最强，短文档优势进一步扩大。
test "config_controls_tf_saturation_and_length_norm" {
  let idx = sample_index()
  // k1 = 0 且 b = 0：tf 因子恒为 1，两篇文档只差 IDF，而 IDF 相同。
  let flat = @score.BM25Config::new(k1=0.0, b=0.0)
  let flat_short = @score.score(["moonbit"], 1, idx, flat)
  let flat_long = @score.score(["moonbit"], 2, idx, flat)
  assert_true(close(flat_short, flat_long, 1.0e-12))
  assert_true(close(flat_short, @score.idf(2, 3), 1.0e-12))
  // b = 1：长短文档差距应比默认参数更大。
  let strict = @score.BM25Config::new(b=1.0)
  let strict_short = @score.score(["moonbit"], 1, idx, strict)
  let strict_long = @score.score(["moonbit"], 2, idx, strict)
  let default_ratio = @score.score(
    ["moonbit"],
    1,
    idx,
    @score.BM25Config::new(),
  )
  let baseline = @score.score(["moonbit"], 2, idx, @score.BM25Config::new())
  assert_true(strict_short > strict_long)
  assert_true(strict_short / strict_long > default_ratio / baseline)
}

///|
/// 查询词项按出现次数累加；多个词项的得分等于各自得分之和。
test "query_terms_accumulate_additively" {
  let idx = sample_index()
  let config = @score.BM25Config::new()
  let single = @score.score(["moonbit"], 1, idx, config)
  let doubled = @score.score(["moonbit", "moonbit"], 1, idx, config)
  assert_true(close(doubled, single * 2.0, 1.0e-12))
  // moonbit 与 search 在文档 1 中词频都是 2，IDF 也相同。
  let moonbit = @score.score(["moonbit"], 1, idx, config)
  let search = @score.score(["search"], 1, idx, config)
  let both = @score.score(["moonbit", "search"], 1, idx, config)
  assert_true(close(both, moonbit + search, 1.0e-12))
}

///|
/// 边界条件：空查询、未知词项、未知文档都应返回 0.0。
test "score_handles_edge_cases" {
  let idx = sample_index()
  let config = @score.BM25Config::new()
  let empty : Array[String] = []
  assert_eq(@score.score(empty, 1, idx, config), 0.0)
  assert_eq(@score.score(["unknownterm"], 1, idx, config), 0.0)
  assert_eq(@score.score(["moonbit"], 99, idx, config), 0.0)
  // 文档 3 只含 pasta，查 pasta 应非零，查 moonbit 应为零。
  assert_true(@score.score(["pasta"], 3, idx, config) > 0.0)
  assert_eq(@score.score(["moonbit"], 3, idx, config), 0.0)
  // 空索引不应因平均长度为 0 而除零。
  let empty_idx = @index.InvertedIndex::new()
  assert_eq(@score.score(["moonbit"], 1, empty_idx, config), 0.0)
}
