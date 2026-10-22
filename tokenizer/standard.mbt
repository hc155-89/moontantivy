// StandardTokenizer：面向“英文为主、可混排中文”的通用分词器。

///|
/// 通用分词器。
///
/// 行为：
/// 1. 逐字符规范化（全角转半角、ASCII 转小写）；
/// 2. 按空白与标点切分 ASCII/拉丁词，并保留下划线（`yes_1` 是一个词）；
/// 3. 中日韩文字逐字切分（中文没有空格，逐字是最稳的兜底策略；
///    需要更高精度的中文检索请改用 `NGramTokenizer`）；
/// 4. 可选地过滤英文停用词。
///
/// 与 Lucene StandardAnalyzer 的一个已知差异：停用词会被丢弃，
/// 不会输出位置空洞（position increment gap）。对于本项目支持的
/// 短语查询，这已经足够；如果未来需要更精细的短语语义，再引入
/// 位置增量字段。
pub struct StandardTokenizer {
  remove_stopwords : Bool
}

///|
/// 创建通用分词器。默认过滤英文停用词。
pub fn StandardTokenizer::new(
  remove_stopwords~ : Bool = true,
) -> StandardTokenizer {
  { remove_stopwords, }
}

///|
/// 判断英文停用词。
///
/// 词表采用 Lucene EnglishAnalyzer 的经典 33 词集合：冠词、介词、
/// 连词以及最常见的助动词。它们几乎不携带区分度，却会显著抬高
/// 倒排表长度，因此在建索引与解析查询时都必须一致地丢弃，
/// 否则会出现“索引里有、查询里没有”的不对称。
///
/// 注意：这里只处理英文。中文停用词（的、了、是……）在逐字切分下
/// 单个字本身信息量就低，但目前不做过滤，避免破坏短语连续性。
fn is_stopword(word : String) -> Bool {
  match word {
    "a" | "an" | "and" | "are" | "as" | "at" => true
    "be" | "but" | "by" => true
    "for" | "if" | "in" | "into" => true
    "is" | "it" => true
    "no" | "not" => true
    "of" | "on" | "or" => true
    "such" => true
    "that" | "the" | "their" | "then" | "there" | "these" | "they" | "this" =>
      true
    "to" => true
    "was" | "will" | "with" => true
    _ => false
  }
}

///|
/// 带位置信息的分词结果。
///
/// 这是索引层实际使用的入口：倒排表需要记录词项出现位置，
/// 才能在查询阶段判断 "quick brown" 是否真的相邻。
pub impl Tokenizer for StandardTokenizer with fn analyze(self, text) -> Array[
  Token,
] {
  let tokens : Array[Token] = Array()
  let segments = split_segments(text)
  let mut position = 0
  for segment in segments {
    if !(self.remove_stopwords && is_stopword(segment)) {
      tokens.push({ term: segment, position, })
    }
    // 被过滤的词也占用一个位置，保证剩余词项的相对位置与原文一致。
    position = position + 1
  }
  tokens
}

///|
/// `Tokenizer` 接口实现：只返回词项，丢弃位置信息。
pub impl Tokenizer for StandardTokenizer with fn tokenize(self, text) {
  let tokens = self.analyze(text)
  let terms : Array[String] = Array()
  for token in tokens {
    terms.push(token.term)
  }
  terms
}

///|
/// 显式声明接口方法，避免隐式提升语法在未来的 MoonBit 版本中被移除。
pub extend StandardTokenizer with Tokenizer::{tokenize, analyze}
