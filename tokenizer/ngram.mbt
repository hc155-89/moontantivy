// NGramTokenizer：按滑动窗口切分，适合中文与模糊匹配。

///|
/// N-gram 分词器。
///
/// 把连续的“词内字符”切成长度为 `n` 的滑动窗口：
///
///     n = 2, "搜索引擎" -> 搜索 / 索引 / 引擎
///     n = 2, "moonbit"  -> mo / oo / on / nb / bi / it
///
/// 为什么中文需要它？
/// 中文没有空格，逐字切分（StandardTokenizer）会把“搜索引擎”拆成四个
/// 单字，查询“搜索”退化为“搜 OR 索”，精度很低；双字切分则能直接命中
/// “搜索”这个语义单元，是轻量级中文检索最常见、性价比最高的做法。
///
/// 位置语义：每个 n-gram 的位置取它在原文中的起始字符下标，因此同一段
/// 连续文本中的相邻 n-gram 位置连续（搜索=0、索引=1、引擎=2），短语查询
/// 可以直接用“位置连续”来判断；被标点或空格隔开的两段文本会留下位置
/// 空洞，不会产生跨段的伪短语命中。
pub struct NGramTokenizer {
  n : Int32
}

///|
/// 创建 n-gram 分词器，默认二元（中文检索的常用配置）。
///
/// `n <= 0` 没有意义，这里统一夹到 1，保证任何输入都能得到确定的
/// 行为，而不是 panic 或返回空结果。
pub fn NGramTokenizer::new(n~ : Int32 = 2) -> NGramTokenizer {
  if n < 1 {
    { n: 1, }
  } else {
    { n, }
  }
}

///|
/// 返回窗口大小，便于调用方（例如查询解析器）构造同样粒度的查询词项。
pub fn NGramTokenizer::window_size(self : NGramTokenizer) -> Int32 {
  self.n
}

///|
/// 判断字符是否参与 n-gram。与 `is_word_char` 的区别是：
/// CJK 字符在这里是“词内字符”，因为它们要参与滑动窗口。
fn is_ngram_char(ch : Char) -> Bool {
  is_cjk(ch) || is_word_char(ch)
}

///|
/// 在连续片段内滑动窗口，产出 n-gram 词项。
///
/// `start` 是片段第一个字符在整段文本中的下标，用来生成全局位置。
/// 片段长度不足 `n` 时不产生任何词项（例如单字中文配 n=2），
/// 这是 n-gram 的固有取舍：单字查询需要降级为逐字策略或前缀查询。
fn NGramTokenizer::emit_ngrams(
  self : NGramTokenizer,
  run : Array[Char],
  start : Int32,
  out : Array[Token],
) -> Unit {
  let n = self.n
  let len = run.length()
  if len < n {
    return
  }
  let mut i = 0
  while i + n <= len {
    let builder = StringBuilder(size_hint=n)
    let mut j = 0
    while j < n {
      builder.write_char(run.unsafe_get(i + j))
      j = j + 1
    }
    out.push({ term: builder.to_string(), position: start + i, })
    i = i + 1
  }
}

///|
/// 带位置信息的分词入口。
///
/// 先按分隔符把文本切成若干连续片段，再对每个片段做滑动窗口。
/// 空片段（连续标点、纯空白）不会产生词项。
pub fn NGramTokenizer::analyze(
  self : NGramTokenizer,
  text : String,
) -> Array[Token] {
  let tokens : Array[Token] = Array()
  let run : Array[Char] = Array()
  let mut run_start = 0
  let mut index = 0
  for raw in text {
    let ch = normalize_char(raw)
    if is_ngram_char(ch) {
      if run.is_empty() {
        run_start = index
      }
      run.push(ch)
    } else {
      self.emit_ngrams(run, run_start, tokens)
      run.clear()
    }
    index = index + 1
  }
  self.emit_ngrams(run, run_start, tokens)
  tokens
}

///|
/// `Tokenizer` 接口实现。
pub impl Tokenizer for NGramTokenizer with fn tokenize(self, text) {
  let tokens = self.analyze(text)
  let terms : Array[String] = Array()
  for token in tokens {
    terms.push(token.term)
  }
  terms
}

///|
/// 显式声明接口方法，避免隐式提升语法在未来的 MoonBit 版本中被移除。
pub extend NGramTokenizer with Tokenizer::{tokenize}
