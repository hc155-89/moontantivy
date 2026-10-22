// query 包：查询 AST、布尔表达式解析器与执行器。
//
// 分层设计：
//   String --lex--> [QueryToken] --recursive descent--> Query AST --execute--> [doc_id]
//
// 解析器支持：
// - 词项：任意非空白文本，按与索引相同的规则规范化（全角转半角、ASCII 小写、
//   CJK 逐字切分）；
// - 布尔运算：AND / OR / NOT（大小写不敏感），优先级 NOT > AND > OR；
// - 括号分组：(moonbit AND rust) OR go；
// - 短语：双引号包裹，"hello world"；
// - 隐式 AND：相邻词项之间未写运算符时按 AND 处理（moonbit search）。
//
// 执行器在有序 doc_id 数组上做集合运算，全部为线性归并，不依赖额外容器。

///|
/// 查询抽象语法树。
///
/// - `Term`：单个词项，命中倒排表即匹配；
/// - `And` / `Or` / `Not`：布尔组合，分别对应交集、并集、补集；
/// - `Phrase`：短语，要求词项在文档中按给定顺序、位置连续出现。
pub enum Query {
  Term(String)
  And(Query, Query)
  Or(Query, Query)
  Not(Query)
  Phrase(Array[String])
}

///|
/// 查询解析错误。
///
/// 解析器不会 panic：所有失败都以 `Err` 返回，让上层可以决定是提示用户
/// 还是回退为“当作普通词项搜索”。
pub enum ParseError {
  /// 输入为空或只有空白。
  EmptyQuery
  /// 双引号内没有任何有效词项，例如 `""`。
  EmptyPhrase
  /// 双引号没有闭合，例如 `"hello`。
  UnterminatedPhrase
  /// 括号不配对，缺少 `)` 或多余的 `)`。
  UnbalancedParenthesis
  /// 运算符缺少操作数，例如 `a AND`、`AND b`。
  MissingOperand
  /// 表达式结束后仍有无法归约的记号。
  TrailingToken
}

///|
/// 解析错误的可读描述，便于 API 层直接展示给调用方。
pub fn ParseError::message(self : ParseError) -> String {
  match self {
    EmptyQuery => "查询为空"
    EmptyPhrase => "短语引号内没有有效词项"
    UnterminatedPhrase => "短语引号未闭合"
    UnbalancedParenthesis => "括号不匹配"
    MissingOperand => "运算符缺少操作数"
    TrailingToken => "查询末尾存在多余内容"
  }
}

///|
/// 词法分析产生的内部记号。
///
/// `Word` / `Phrase` 中的词项已经过规范化，解析阶段不再处理文本。
priv enum QueryToken {
  Word(String)
  Phrase(Array[String])
  AndToken
  OrToken
  NotToken
  LParen
  RParen
}

///|
/// 把缓冲区里的裸词转成记号。
///
/// 缓冲区内容在扫描时已逐字符规范化（全角转半角、ASCII 小写），因此
/// 这里可以直接用小写形式识别运算符，实现大小写不敏感的 AND / OR / NOT。
/// 非运算符的裸词再按与索引相同的规则切成词项；标点会被自动丢弃，
/// 所以 `moonbit!` 与 `moonbit` 等价。
fn push_word_buffer(buffer : StringBuilder, tokens : Array[QueryToken]) -> Unit {
  let text = buffer.to_string()
  if text.is_empty() {
    return
  }
  match text {
    "and" => tokens.push(AndToken)
    "or" => tokens.push(OrToken)
    "not" => tokens.push(NotToken)
    _ =>
      for term in @tokenizer.split_terms(text) {
        tokens.push(Word(term))
      }
  }
}

///|
/// 词法分析：把查询字符串切成记号序列。
///
/// 无论是否包含空格、括号或引号，词项都由 `@tokenizer.split_terms` 统一
/// 规范化，从而与建索引时的词项写法保持一致。
fn lex(input : String) -> Result[Array[QueryToken], ParseError] {
  let tokens : Array[QueryToken] = Array()
  let buffer = StringBuilder()
  let mut in_phrase = false
  for raw in input {
    let ch = @tokenizer.normalize_char(raw)
    if in_phrase {
      if ch == '"' {
        let terms = @tokenizer.split_terms(buffer.to_string())
        if terms.is_empty() {
          return Err(EmptyPhrase)
        }
        tokens.push(Phrase(terms))
        buffer.reset()
        in_phrase = false
      } else {
        buffer.write_char(ch)
      }
    } else if ch == '"' {
      push_word_buffer(buffer, tokens)
      buffer.reset()
      in_phrase = true
    } else if ch == '(' {
      push_word_buffer(buffer, tokens)
      buffer.reset()
      tokens.push(LParen)
    } else if ch == ')' {
      push_word_buffer(buffer, tokens)
      buffer.reset()
      tokens.push(RParen)
    } else if ch.is_whitespace() {
      push_word_buffer(buffer, tokens)
      buffer.reset()
    } else {
      buffer.write_char(ch)
    }
  }
  if in_phrase {
    return Err(UnterminatedPhrase)
  }
  push_word_buffer(buffer, tokens)
  Ok(tokens)
}

///|
/// 递归下降解析器的可变状态。
///
/// 只保存记号数组与当前下标；下标允许修改，因为每一层解析都会消费记号。
priv struct QueryParser {
  tokens : Array[QueryToken]
  mut pos : Int32
}

///|
/// 查看当前记号，越界返回 `None`。
fn QueryParser::peek(self : QueryParser) -> QueryToken? {
  self.tokens.get(self.pos)
}

///|
/// 前进一个记号。
fn QueryParser::advance(self : QueryParser) -> Unit {
  self.pos = self.pos + 1
}

///|
fn QueryParser::peek_is_or(self : QueryParser) -> Bool {
  match self.peek() {
    Some(OrToken) => true
    _ => false
  }
}

///|
fn QueryParser::peek_is_and(self : QueryParser) -> Bool {
  match self.peek() {
    Some(AndToken) => true
    _ => false
  }
}

///|
fn QueryParser::peek_is_not(self : QueryParser) -> Bool {
  match self.peek() {
    Some(NotToken) => true
    _ => false
  }
}

///|
fn QueryParser::peek_is_rparen(self : QueryParser) -> Bool {
  match self.peek() {
    Some(RParen) => true
    _ => false
  }
}

///|
/// 当前位置是否能开始一个一元表达式。
///
/// 用于实现隐式 AND：`moonbit search` 在语法上等价于
/// `moonbit AND search`，只要后一个记号能作为操作数起点即可。
fn QueryParser::starts_unary(self : QueryParser) -> Bool {
  match self.peek() {
    Some(Word(_)) | Some(Phrase(_)) | Some(LParen) | Some(NotToken) => true
    _ => false
  }
}

///|
/// OR 层：优先级最低，左结合。
fn QueryParser::parse_or(self : QueryParser) -> Result[Query, ParseError] {
  let mut left = match self.parse_and() {
    Ok(query) => query
    Err(error) => return Err(error)
  }
  while self.peek_is_or() {
    self.advance()
    let right = match self.parse_and() {
      Ok(query) => query
      Err(error) => return Err(error)
    }
    left = Or(left, right)
  }
  Ok(left)
}

///|
/// AND 层：显式 `AND` 与隐式相邻词项都归约到这里，左结合。
fn QueryParser::parse_and(self : QueryParser) -> Result[Query, ParseError] {
  let mut left = match self.parse_not() {
    Ok(query) => query
    Err(error) => return Err(error)
  }
  while true {
    if self.peek_is_and() {
      self.advance()
    } else if !self.starts_unary() {
      break
    }
    let right = match self.parse_not() {
      Ok(query) => query
      Err(error) => return Err(error)
    }
    left = And(left, right)
  }
  Ok(left)
}

///|
/// NOT 层：一元前缀运算符，允许连续取反（NOT NOT a）。
fn QueryParser::parse_not(self : QueryParser) -> Result[Query, ParseError] {
  if self.peek_is_not() {
    self.advance()
    let inner = match self.parse_not() {
      Ok(query) => query
      Err(error) => return Err(error)
    }
    Ok(Not(inner))
  } else {
    self.parse_primary()
  }
}

///|
/// 原子层：词项、短语或括号分组。
fn QueryParser::parse_primary(self : QueryParser) -> Result[Query, ParseError] {
  match self.peek() {
    Some(Word(term)) => {
      self.advance()
      Ok(Term(term))
    }
    Some(Phrase(terms)) => {
      self.advance()
      Ok(Phrase(terms))
    }
    Some(LParen) => {
      self.advance()
      let inner = match self.parse_or() {
        Ok(query) => query
        Err(error) => return Err(error)
      }
      if self.peek_is_rparen() {
        self.advance()
        Ok(inner)
      } else {
        Err(UnbalancedParenthesis)
      }
    }
    _ => Err(MissingOperand)
  }
}

///|
/// 把查询字符串解析为 AST。
///
/// 示例：
/// - `"moonbit AND (rust OR go)"` -> `And(Term("moonbit"), Or(Term("rust"), Term("go")))`
/// - `"\"hello world\""` -> `Phrase(["hello", "world"])`
/// - `"moonbit search"` -> `And(Term("moonbit"), Term("search"))`
pub fn parse_query(input : String) -> Result[Query, ParseError] {
  let tokens = match lex(input) {
    Ok(tokens) => tokens
    Err(error) => return Err(error)
  }
  if tokens.is_empty() {
    return Err(EmptyQuery)
  }
  let parser : QueryParser = { tokens, pos: 0, }
  let query = match parser.parse_or() {
    Ok(query) => query
    Err(error) => return Err(error)
  }
  if parser.pos < parser.tokens.length() {
    // 解析正常结束时只可能剩下多余的右括号；其余情况都说明语法有问题。
    if parser.peek_is_rparen() {
      return Err(UnbalancedParenthesis)
    }
    return Err(TrailingToken)
  }
  Ok(query)
}

///|
/// 用空格连接短语词项，供 `to_string` 输出规范形式。
fn join_terms(terms : Array[String]) -> String {
  let builder = StringBuilder()
  let mut first = true
  for term in terms {
    if !first {
      builder.write_char(' ')
    }
    builder.write_string(term)
    first = false
  }
  builder.to_string()
}

///|
/// AST 的规范字符串形式，主要用于调试与测试断言。
///
/// 二元运算统一加括号，因此输出能无歧义地反映解析优先级。
pub fn Query::to_string(self : Query) -> String {
  match self {
    Term(term) => term
    Phrase(terms) => "\"" + join_terms(terms) + "\""
    And(left, right) =>
      "(" + left.to_string() + " AND " + right.to_string() + ")"
    Or(left, right) => "(" + left.to_string() + " OR " + right.to_string() + ")"
    Not(inner) => "NOT " + inner.to_string()
  }
}

///|
/// 两个升序 doc_id 数组求交集。
fn intersect(left : Array[Int32], right : Array[Int32]) -> Array[Int32] {
  let out : Array[Int32] = Array()
  let mut i = 0
  let mut j = 0
  while i < left.length() && j < right.length() {
    let a = left.unsafe_get(i)
    let b = right.unsafe_get(j)
    if a == b {
      out.push(a)
      i = i + 1
      j = j + 1
    } else if a < b {
      i = i + 1
    } else {
      j = j + 1
    }
  }
  out
}

///|
/// 两个升序 doc_id 数组求并集，结果仍升序且无重复。
fn union(left : Array[Int32], right : Array[Int32]) -> Array[Int32] {
  let out : Array[Int32] = Array()
  let mut i = 0
  let mut j = 0
  while i < left.length() && j < right.length() {
    let a = left.unsafe_get(i)
    let b = right.unsafe_get(j)
    if a == b {
      out.push(a)
      i = i + 1
      j = j + 1
    } else if a < b {
      out.push(a)
      i = i + 1
    } else {
      out.push(b)
      j = j + 1
    }
  }
  while i < left.length() {
    out.push(left.unsafe_get(i))
    i = i + 1
  }
  while j < right.length() {
    out.push(right.unsafe_get(j))
    j = j + 1
  }
  out
}

///|
/// 集合差：`left` 中存在、`right` 中不存在的 doc_id。
///
/// `NOT` 使用“全库文档集合 减去 子查询结果”，因此两侧都必须升序。
fn difference(left : Array[Int32], right : Array[Int32]) -> Array[Int32] {
  let out : Array[Int32] = Array()
  let mut i = 0
  let mut j = 0
  while i < left.length() {
    let a = left.unsafe_get(i)
    while j < right.length() && right.unsafe_get(j) < a {
      j = j + 1
    }
    if j >= right.length() || right.unsafe_get(j) != a {
      out.push(a)
    }
    i = i + 1
  }
  out
}

///|
/// 查询单个词项命中的文档 ID，升序。
fn term_docs(index : @index.InvertedIndex, term : String) -> Array[Int32] {
  let out : Array[Int32] = Array()
  match index.get_posting_list(term) {
    None => ()
    Some(list) =>
      for posting in list.entries() {
        out.push(posting.doc_id)
      }
  }
  out
}

///|
/// 在升序位置数组中二分查找目标位置。
///
/// 倒排表里的位置天然递增（按词项出现顺序写入），所以二分是安全的；
/// 短语里每个词项每次出现都要查一次，二分比线性扫描更稳。
fn has_position(positions : Array[Int32], target : Int32) -> Bool {
  let mut low = 0
  let mut high = positions.length() - 1
  while low <= high {
    let mid = low + (high - low) / 2
    let value = positions.unsafe_get(mid)
    if value == target {
      return true
    } else if value < target {
      low = mid + 1
    } else {
      high = mid - 1
    }
  }
  false
}

///|
/// 判断某个文档是否包含给定短语。
///
/// 算法：以第一个词项的每个出现位置为锚点 `p`，检查第 i 个词项是否
/// 恰好出现在 `p + i`。只要有一个锚点让所有词项都对齐，就算命中。
/// 这里的“位置连续”利用了分词器保留位置空洞的约定：
/// 被标点隔开的两个词不会因为过滤而变成相邻。
fn phrase_matches(
  anchor : @index.Posting,
  lists : Array[@index.PostingList],
) -> Bool {
  let count = lists.length()
  for start in anchor.positions {
    let mut matched = true
    let mut i = 1
    while i < count && matched {
      let posting = match lists.unsafe_get(i).posting(anchor.doc_id) {
        None => return false
        Some(posting) => posting
      }
      if !has_position(posting.positions, start + i) {
        matched = false
      }
      i = i + 1
    }
    if matched {
      return true
    }
  }
  false
}

///|
/// 短语查询：所有词项都命中、且位置连续递增的文档。
///
/// 任一维度的倒排表不存在，短语都不可能成立，直接返回空结果。
fn phrase_docs(
  index : @index.InvertedIndex,
  terms : Array[String],
) -> Array[Int32] {
  let out : Array[Int32] = Array()
  if terms.is_empty() {
    return out
  }
  let lists : Array[@index.PostingList] = Array()
  for term in terms {
    match index.get_posting_list(term) {
      None => return out
      Some(list) => lists.push(list)
    }
  }
  let anchor_list = lists.unsafe_get(0)
  for posting in anchor_list.entries() {
    if phrase_matches(posting, lists) {
      out.push(posting.doc_id)
    }
  }
  out
}

///|
/// 执行查询，返回匹配的文档 ID（升序、无重复）。
///
/// 每个分支都返回有序数组，因此布尔运算可以全部用双指针线性归并：
/// - `And` 求交集；
/// - `Or` 求并集；
/// - `Not` 用全库文档集合求补集（差集）；
/// - `Phrase` 在位置维度上验证相邻关系。
pub fn execute(query : Query, index : @index.InvertedIndex) -> Array[Int32] {
  match query {
    Term(term) => term_docs(index, term)
    Phrase(terms) => phrase_docs(index, terms)
    And(left, right) => intersect(execute(left, index), execute(right, index))
    Or(left, right) => union(execute(left, index), execute(right, index))
    Not(inner) => difference(index.doc_ids(), execute(inner, index))
  }
}
