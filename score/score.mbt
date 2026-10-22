// score 包：BM25 相关度评分。
//
// BM25 是信息检索里最常用的概率检索模型，本质上是“词频饱和 + 文档长度归一化”
// 的加权求和：
//
//     score(q, d) = Σ_t IDF(t) · (tf · (k1 + 1)) / (tf + k1 · (1 - b + b · |d| / avgdl))
//
// 其中：
// - tf 是词项 t 在文档 d 中的词频；
// - |d| 是文档长度（停用词过滤后的有效词项数）；
// - avgdl 是全库平均文档长度；
// - k1 控制词频饱和速度（越大，词频增长对得分的影响越持久）；
// - b 控制长度归一化强度（0 表示完全不归一化，1 表示完全归一化）；
// - IDF 衡量词项的区分度：越少见的词权重越高。
//
// 本实现选用 Lucene 的平滑 IDF：ln(1 + (N - df + 0.5) / (df + 0.5))。
// 相比经典的 log((N - df + 0.5) / (df + 0.5))，它保证 IDF 恒为正，
// 避免“词项出现在超过半数文档时得分为负”的反直觉现象。

///|
/// BM25 超参数。
///
/// 默认取信息检索领域的经验最优值：k1 = 1.2、b = 0.75。
/// 两个参数的含义：
/// - `k1`：词频饱和系数。取 0 时词频不再有额外收益（只看是否出现），
///   取较大值时词频越高得分越高、但边际收益递减；
/// - `b`：文档长度归一化系数。取 0 时长短文档同等对待，
///   取 1 时严格按长度惩罚长文档。
pub struct BM25Config {
  k1 : Double
  b : Double
}

///|
/// 创建 BM25 配置，默认 k1 = 1.2、b = 0.75。
///
/// 调用方可以只覆盖其中一个参数，例如 `BM25Config::new(b=1.0)`。
/// 非法取值（负数、NaN）不做静默裁剪：BM25 的参数语义是开放的，
/// 调参时允许出现非常规组合，评分函数仍会给出确定结果。
pub fn BM25Config::new(k1~ : Double = 1.2, b~ : Double = 0.75) -> BM25Config {
  { k1, b, }
}

///|
/// 词频饱和与长度归一化：BM25 公式中 IDF 之外的那一部分。
///
/// 该函数只处理单个词项对单个文档的贡献，是评分的核心因子。
/// 约定 `tf > 0` 且 `average_length > 0`（由调用方保证），
/// 这样内部不需要再做零值检查。
fn term_score(
  term_freq : Int32,
  doc_length : Int32,
  average_length : Double,
  config : BM25Config,
) -> Double {
  let tf = term_freq.to_double()
  let length_ratio = doc_length.to_double() / average_length
  let norm = 1.0 - config.b + config.b * length_ratio
  tf * (config.k1 + 1.0) / (tf + config.k1 * norm)
}

///|
/// 逆文档频率（IDF）：词项在多少篇文档中出现得越少，权重越大。
///
/// 采用 Lucene 的平滑形式：`ln(1 + (N - df + 0.5) / (df + 0.5))`。
/// - `df <= 0`（词项不在索引中）或 `N <= 0`（空索引）时返回 0.0，
///   表示该词项对排序没有任何贡献；
/// - `df > N` 属于统计异常（例如索引被外部篡改），按 `df = N` 处理，
///   确保结果落在可解释的区间内而不是产生负值。
pub fn idf(doc_freq : Int32, num_docs : Int32) -> Double {
  if doc_freq <= 0 || num_docs <= 0 {
    return 0.0
  }
  let df = if doc_freq > num_docs { num_docs } else { doc_freq }
  let n = num_docs.to_double()
  let d = df.to_double()
  @math.ln(1.0 + (n - d + 0.5) / (d + 0.5))
}

///|
/// 计算查询词项集合对某篇文档的 BM25 得分。
///
/// 计算流程：
/// 1. 取文档长度、全库文档数与平均长度；文档不存在或索引为空时直接返回 0.0；
/// 2. 对每个查询词项查倒排表：
///    - 词项不在索引中（df = 0）→ 贡献 0；
///    - 词项在索引中但不在本文档 → 贡献 0（长度归一化项与它无关）；
/// 3. 把 `IDF × 词频饱和因子` 累加得到最终得分。
///
/// 语义约定：
/// - 查询词项可以重复，重复词项会按次数累加（等价于提高该词的权重）；
/// - 查询词项应已由分词器规范化（小写、去停用词），评分层不再做文本处理，
///   避免索引与查询两侧使用不同的规范化规则造成不对称；
/// - 相同词项出现次数越多、文档越短，单个词项的贡献越大。
pub fn score(
  query_terms : Array[String],
  doc_id : Int32,
  index : @index.InvertedIndex,
  config : BM25Config,
) -> Double {
  let doc_length = match index.doc_length(doc_id) {
    Some(length) => length
    None => return 0.0
  }
  let num_docs = index.num_docs()
  let average_length = index.average_doc_length()
  // 空索引或全库词数为 0 时平均长度没有意义，直接返回 0.0 避免除零。
  if num_docs == 0 || average_length <= 0.0 {
    return 0.0
  }
  let mut total = 0.0
  for term in query_terms {
    let doc_freq = index.doc_freq(term)
    if doc_freq == 0 {
      continue
    }
    match index.get_posting_list(term) {
      None => ()
      Some(list) =>
        match list.posting(doc_id) {
          None => ()
          Some(posting) => {
            let weight = idf(doc_freq, num_docs)
            let tf_factor = term_score(
              posting.term_freq,
              doc_length,
              average_length,
              config,
            )
            total = total + weight * tf_factor
          }
        }
    }
  }
  total
}
