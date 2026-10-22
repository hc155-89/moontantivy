// api 包：面向使用者的统一入口。
//
// 这一层把 tokenizer / index / query / score / storage 五个子包串起来，
// 对外只暴露一个 `SearchEngine`：
//
//     let engine = SearchEngine::new()
//     engine.add_document(Document::new(1, "标题", "正文"))
//     let hits = engine.search("moonbit AND search", 10)
//
// 设计原则：
// 1. 调用方不需要知道倒排表、BM25 参数或分词器细节；
// 2. 查询串是唯一的检索入口，解析失败不 panic，而是返回空结果；
// 3. 结果按 BM25 得分降序，同分时按 doc_id 升序，保证输出可复现；
// 4. 持久化直接复用 storage 的 JSON 快照，加载后的引擎可以继续增删改。

///|
/// 一条检索结果。
///
/// 除了必需的 `doc_id` 与 `score`，额外带上 `title`：调用方拿到结果后
/// 通常要立刻展示给用户，若再按 id 回查文档会多一次索引访问。
pub struct SearchResult {
  doc_id : Int32
  title : String
  score : Double
} derive(Debug, Eq)

///|
/// 显式声明 derive 生成的实例方法，避免隐式提升语法在未来版本中被移除。
pub extend SearchResult with Eq::{not_equal, equal}

///|
pub extend SearchResult with @debug.Debug::{to_repr}

///|
/// 面向使用者的检索引擎。
///
/// 组合关系：
/// - `index`：倒排索引，负责存储与召回；
/// - `tokenizer`：建索引与解析查询共用的分词器；
/// - `config`：BM25 超参数，默认 k1 = 1.2、b = 0.75。
///
/// 引擎本身不做并发控制：同一个实例的读写应由调用方串行化。
/// 需要并发检索时，让多个引擎各自持有只读副本即可。
pub struct SearchEngine {
  index : @index.InvertedIndex
  tokenizer : @tokenizer.StandardTokenizer
  mut config : @score.BM25Config
}

///|
/// 创建一个空引擎。
pub fn SearchEngine::new() -> SearchEngine {
  {
    index: @index.InvertedIndex::new(),
    tokenizer: @tokenizer.StandardTokenizer::new(),
    config: @score.BM25Config::new(),
  }
}

///|
/// 替换 BM25 超参数，返回引擎本身以便链式调用。
///
/// 典型用法：`SearchEngine::new().set_bm25(@score.BM25Config::new(b=0.5))`。
/// 只影响后续检索，不改变已建好的索引。
pub fn SearchEngine::set_bm25(
  self : SearchEngine,
  config : @score.BM25Config,
) -> SearchEngine {
  self.config = config
  self
}

///|
/// 添加一篇文档。
///
/// 同 ID 已存在时按“更新”处理（索引层会先删除旧版本），因此重复调用
/// 不会产生重复的倒排记录。
pub fn SearchEngine::add_document(
  self : SearchEngine,
  doc : @moontantivy.Document,
) -> Unit {
  let tokenizer : &@tokenizer.Tokenizer = self.tokenizer
  self.index.add_doc(doc, tokenizer)
}

///|
/// 按 ID 删除文档，返回是否真的删除了。
pub fn SearchEngine::remove_document(
  self : SearchEngine,
  doc_id : Int32,
) -> Bool {
  self.index.remove_doc(doc_id)
}

///|
/// 索引中的文档数量。
pub fn SearchEngine::num_docs(self : SearchEngine) -> Int32 {
  self.index.num_docs()
}

///|
/// 把查询语法树里出现的全部词项收集到 `terms`。
///
/// 这些词项用于 BM25 打分。布尔结构本身不参与评分——`NOT` 的子查询
/// 词项即使在列表里，也不会给命中文档贡献分数（文档里本就不含这些词）；
/// 短语则把每个组成词项都计入，与“短语是词的组合”这一直觉一致。
fn collect_query_terms(query : @query.Query, terms : Array[String]) -> Unit {
  match query {
    Term(term) => terms.push(term)
    Phrase(phrase) =>
      for term in phrase {
        terms.push(term)
      }
    And(left, right) => {
      collect_query_terms(left, terms)
      collect_query_terms(right, terms)
    }
    Or(left, right) => {
      collect_query_terms(left, terms)
      collect_query_terms(right, terms)
    }
    Not(inner) => collect_query_terms(inner, terms)
  }
}

///|
/// 结果排序比较函数：得分降序，得分相同则 doc_id 升序。
///
/// 同分时用 doc_id 兜底，是为了让相同输入永远得到相同的输出顺序，
/// 便于测试断言与前端分页。
fn compare_results(a : SearchResult, b : SearchResult) -> Int32 {
  if a.score > b.score {
    -1
  } else if a.score < b.score {
    1
  } else if a.doc_id < b.doc_id {
    -1
  } else if a.doc_id > b.doc_id {
    1
  } else {
    0
  }
}

///|
/// 执行检索，返回得分最高的至多 `top_k` 条结果。
///
/// 流程：
/// 1. 解析查询串；语法错误（空查询、引号未闭合等）返回空数组，不抛异常；
/// 2. 用查询执行器召回匹配的文档 ID；
/// 3. 收集查询词项，对每个命中文档计算 BM25 得分；
/// 4. 按“得分降序、ID 升序”排序并截断到 `top_k`。
///
/// `top_k <= 0` 时直接返回空数组——调用方传 0 通常意味着“不要结果”，
/// 没必要为此走一遍完整的检索流程。
pub fn SearchEngine::search(
  self : SearchEngine,
  query_str : String,
  top_k : Int32,
) -> Array[SearchResult] {
  let results : Array[SearchResult] = Array()
  if top_k <= 0 {
    return results
  }
  let query = match @query.parse_query(query_str) {
    Ok(query) => query
    Err(_) => return results
  }
  let terms : Array[String] = Array()
  collect_query_terms(query, terms)
  for doc_id in @query.execute(query, self.index) {
    let title = match self.index.get_document(doc_id) {
      Some(doc) => doc.title
      None => ""
    }
    results.push({
      doc_id,
      title,
      score: @score.score(terms, doc_id, self.index, self.config),
    })
  }
  results.sort_by(compare_results)
  if results.length() <= top_k {
    return results
  }
  let top : Array[SearchResult] = Array(capacity=top_k)
  for i in 0..<top_k {
    top.push(results.unsafe_get(i))
  }
  top
}

///|
/// 把引擎的索引保存为 JSON 文件。
///
/// 只写索引数据，不写 BM25 参数与分词器配置：检索参数属于运行时选择，
/// 换一套参数检索同一份索引是完全合法的用法。
pub fn SearchEngine::save(
  self : SearchEngine,
  path : String,
) -> Unit raise @fs.IOError {
  @storage.save_to_file(self.index, path)
}

///|
/// 从 JSON 文件恢复引擎。
///
/// 恢复后的引擎使用默认分词器与默认 BM25 参数，索引数据（文档、词项、
/// 位置、长度）与保存前完全一致，并且可以继续 `add_document` /
/// `remove_document`。
pub fn SearchEngine::load(
  path : String,
) -> SearchEngine raise @storage.StorageError {
  {
    index: @storage.load_from_file(path),
    tokenizer: @tokenizer.StandardTokenizer::new(),
    config: @score.BM25Config::new(),
  }
}

///|
/// 把引擎的索引序列化为 JSON 文本，不落盘。
///
/// 适用于浏览器或边缘运行时：先由宿主通过 HTTP 取回部署好的索引文本，
/// 再交给 `SearchEngine::from_json` 恢复。这样宿主不必提供文件系统，
/// 引擎本身也不需要感知网络或存储方式。
pub fn SearchEngine::to_json(self : SearchEngine) -> String {
  @storage.save_to_string(self.index)
}

///|
/// 从 JSON 文本恢复引擎。
///
/// 与 `SearchEngine::load` 使用同一套反序列化与校验逻辑，区别只是输入
/// 来自内存字符串；适合在浏览器中 `fetch` 索引文件后直接恢复。
pub fn SearchEngine::from_json(
  text : String,
) -> SearchEngine raise @storage.StorageError {
  {
    index: @storage.load_from_string(text),
    tokenizer: @tokenizer.StandardTokenizer::new(),
    config: @score.BM25Config::new(),
  }
}
