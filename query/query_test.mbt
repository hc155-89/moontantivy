// query 包黑盒测试：验证解析器的优先级/规范化/错误处理，以及执行器的集合语义。
//
// 测试索引固定为 5 篇文档（StandardTokenizer，无停用词干扰）：
// 1. "MoonBit search" / "moonbit search engine"      -> moonbit[0,2] search[1,3] engine[4]
// 2. "Rust Go" / "rust go systems programming"        -> rust[0,2] go[1,3]
// 3. "Go search" / "go search web service"            -> go[0,2] search[1,3]
// 4. "Hello world" / "hello world example phrase"     -> hello[0,2] world[1,3]
// 5. "MoonBit index" / "moonbit inverted index engine" -> moonbit[0,2] index[1,4] inverted[3]

///|
/// 构造测试用的 5 篇文档索引。
fn sample_index() -> @index.InvertedIndex {
  let idx = @index.InvertedIndex::new()
  let tokenizer : &@tokenizer.Tokenizer = @tokenizer.StandardTokenizer::new()
  let docs : Array[@moontantivy.Document] = [
    @moontantivy.Document::new(1, "MoonBit search", "moonbit search engine"),
    @moontantivy.Document::new(2, "Rust Go", "rust go systems programming"),
    @moontantivy.Document::new(3, "Go search", "go search web service"),
    @moontantivy.Document::new(4, "Hello world", "hello world example phrase"),
    @moontantivy.Document::new(
      5, "MoonBit index", "moonbit inverted index engine",
    ),
  ]
  for doc in docs {
    idx.add_doc(doc, tokenizer)
  }
  idx
}

///|
/// 解析并输出规范形式；解析失败时输出带感叹号的错误描述。
fn canonical(input : String) -> String {
  match @query.parse_query(input) {
    Ok(query) => query.to_string()
    Err(error) => "!" + error.message()
  }
}

///|
/// 解析并执行；解析失败时返回空结果，便于断言“非法查询不命中任何文档”。
fn run(input : String, index : @index.InvertedIndex) -> Array[Int32] {
  match @query.parse_query(input) {
    Ok(query) => @query.execute(query, index)
    Err(_) => {
      let empty : Array[Int32] = []
      empty
    }
  }
}

///|
/// 运算符优先级：NOT > AND > OR，且二元运算左结合。
test "parser_respects_operator_precedence" {
  assert_eq(canonical("moonbit AND (rust OR go)"), "(moonbit AND (rust OR go))")
  assert_eq(canonical("a OR b AND c"), "(a OR (b AND c))")
  assert_eq(canonical("NOT a AND b"), "(NOT a AND b)")
  assert_eq(canonical("NOT (a OR b)"), "NOT (a OR b)")
  assert_eq(canonical("a OR b OR c"), "((a OR b) OR c)")
  assert_eq(canonical("a AND b AND c"), "((a AND b) AND c)")
  assert_eq(canonical("(a OR b) AND c"), "((a OR b) AND c)")
  assert_eq(canonical("a AND NOT b"), "(a AND NOT b)")
  assert_eq(canonical("NOT NOT a"), "NOT NOT a")
}

///|
/// 隐式 AND：相邻词项之间没有运算符时按 AND 处理。
test "parser_supports_implicit_and" {
  assert_eq(canonical("moonbit search"), "(moonbit AND search)")
  assert_eq(
    canonical("moonbit search engine"),
    "((moonbit AND search) AND engine)",
  )
  assert_eq(canonical("(a OR b) c"), "((a OR b) AND c)")
  assert_eq(canonical("a NOT b"), "(a AND NOT b)")
}

///|
/// 词项规范应与索引一致：大小写折叠、全角转半角、去掉标点。
test "parser_normalizes_terms_like_index" {
  assert_eq(canonical("MoonBit"), "moonbit")
  assert_eq(canonical("ＭｏｏｎＢｉｔ"), "moonbit")
  assert_eq(canonical("moonbit!"), "moonbit")
  assert_eq(canonical("  moonbit   search  "), "(moonbit AND search)")
  // 运算符本身也大小写不敏感。
  assert_eq(canonical("a and b or c"), "((a AND b) OR c)")
}

///|
/// 短语词项同样要规范化，并保留引号形式。
test "parser_supports_phrase_quotes" {
  assert_eq(canonical("\"hello world\""), "\"hello world\"")
  assert_eq(canonical("\"MoonBit Search\""), "\"moonbit search\"")
  assert_eq(
    canonical("moonbit AND \"hello world\""),
    "(moonbit AND \"hello world\")",
  )
}

///|
/// 各类语法错误都应给出明确的错误类型，而不是 panic。
test "parser_reports_syntax_errors" {
  assert_eq(canonical(""), "!查询为空")
  assert_eq(canonical("   "), "!查询为空")
  assert_eq(canonical("\"\""), "!短语引号内没有有效词项")
  assert_eq(canonical("\"hello"), "!短语引号未闭合")
  assert_eq(canonical("(a OR b"), "!括号不匹配")
  assert_eq(canonical("a )"), "!括号不匹配")
  assert_eq(canonical("a AND"), "!运算符缺少操作数")
  assert_eq(canonical("AND b"), "!运算符缺少操作数")
  assert_eq(canonical("a OR OR b"), "!运算符缺少操作数")
}

///|
/// 单词项查询：命中所有包含该词项的文档，结果升序。
test "execute_term_query" {
  let idx = sample_index()
  assert_eq(run("moonbit", idx), ([1, 5] : Array[Int32]))
  assert_eq(run("go", idx), ([2, 3] : Array[Int32]))
  assert_eq(run("rust", idx), ([2] : Array[Int32]))
  assert_eq(run("inverted", idx), ([5] : Array[Int32]))
  assert_eq(run("missingterm", idx), ([] : Array[Int32]))
}

///|
/// 布尔 AND / OR / NOT 的集合语义。
test "execute_boolean_queries" {
  let idx = sample_index()
  // AND = 交集
  assert_eq(run("moonbit AND search", idx), ([1] : Array[Int32]))
  assert_eq(run("moonbit AND engine", idx), ([1, 5] : Array[Int32]))
  assert_eq(run("moonbit AND search engine", idx), ([1] : Array[Int32]))
  // OR = 并集
  assert_eq(run("rust OR go", idx), ([2, 3] : Array[Int32]))
  assert_eq(run("engine OR hello", idx), ([1, 4, 5] : Array[Int32]))
  // NOT = 全库补集
  assert_eq(run("NOT moonbit", idx), ([2, 3, 4] : Array[Int32]))
  assert_eq(run("NOT NOT moonbit", idx), ([1, 5] : Array[Int32]))
  // 组合：moonbit 命中 1、5，其中 5 含 index，取差集后只剩 1。
  assert_eq(run("moonbit AND NOT index", idx), ([1] : Array[Int32]))
  assert_eq(run("NOT (rust OR go)", idx), ([1, 4, 5] : Array[Int32]))
  // 优先级：rust AND go 先结合，再与 search 求并集。
  assert_eq(run("search OR rust AND go", idx), ([1, 2, 3] : Array[Int32]))
  assert_eq(run("(search OR rust) AND NOT go", idx), ([1] : Array[Int32]))
  // 隐式 AND 与显式 AND 等价。
  assert_eq(run("rust go", idx), ([2] : Array[Int32]))
}

///|
/// 短语查询：词项必须按顺序、位置连续出现。
test "execute_phrase_query" {
  let idx = sample_index()
  // 文档 4 中 hello[0,2]、world[1,3]，存在相邻组合。
  assert_eq(run("\"hello world\"", idx), ([4] : Array[Int32]))
  // 文档 1 中 moonbit[0,2]、search[1,3]。
  assert_eq(run("\"moonbit search\"", idx), ([1] : Array[Int32]))
  // search[3] 与 engine[4] 相邻才命中；search[1] / engine[4] 不相邻。
  assert_eq(run("\"search engine\"", idx), ([1] : Array[Int32]))
  // 顺序不对：engine 出现在 moonbit 之后，但没有连续组合。
  assert_eq(run("\"moonbit engine\"", idx), ([] : Array[Int32]))
  // 文档 5 中 inverted[3]、index[4] 相邻；反向不成立。
  assert_eq(run("\"inverted index\"", idx), ([5] : Array[Int32]))
  assert_eq(run("\"index inverted\"", idx), ([] : Array[Int32]))
  // 只在文档 3 中 go[0] 与 search[1] 相邻。
  assert_eq(run("\"go search\"", idx), ([3] : Array[Int32]))
  // 多词项短语：moonbit[2] search[3] engine[4] 是文档 1 的连续序列。
  assert_eq(run("\"moonbit search engine\"", idx), ([1] : Array[Int32]))
  assert_eq(run("\"moonbit inverted index engine\"", idx), ([5] : Array[Int32]))
  // 单词短语等价于单词项查询。
  assert_eq(run("\"moonbit\"", idx), ([1, 5] : Array[Int32]))
}

///|
/// 解析 + 执行串联，验证真实输入能跑通。
test "parse_then_execute_end_to_end" {
  let idx = sample_index()
  assert_eq(run("moonbit AND (rust OR go)", idx), ([] : Array[Int32]))
  assert_eq(run("search AND (rust OR go)", idx), ([3] : Array[Int32]))
  assert_eq(run("NOT moonbit AND engine", idx), ([] : Array[Int32]))
  assert_eq(run("moonbit AND \"moonbit search\"", idx), ([1] : Array[Int32]))
  // 非法查询不产生结果，也不会影响索引。
  assert_eq(run("moonbit AND (", idx), ([] : Array[Int32]))
  assert_eq(run("", idx), ([] : Array[Int32]))
  assert_eq(idx.num_docs(), 5)
}
