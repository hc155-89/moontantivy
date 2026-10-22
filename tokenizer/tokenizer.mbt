// tokenizer 包：文本规范化与分词。
//
// 设计要点：
// 1. 对外只暴露一个最小接口 `Tokenizer`，调用方不关心切分策略；
// 2. 同时提供带位置信息的 `analyze`，因为短语查询必须依赖词项位置；
// 3. 所有分词器共用同一套字符级规范化与分隔符判定，行为保持一致。

///|
/// 一个带位置信息的词项。
///
/// `position` 是词项在“词项流”中的序号，从 0 开始。
/// 注意：被停用词过滤器丢弃的词仍然会占用一个位置，这样
/// "the quick brown" 中 quick=1、brown=2，与 "quick brown" 的
/// 相对位置关系一致，短语查询不会因为停用词而误判。
pub struct Token {
  term : String
  position : Int32
} derive(Debug, Eq)

///|
/// 显式声明 derive 生成的实例方法。
pub extend Token with Eq::{not_equal, equal}

///|
pub extend Token with @debug.Debug::{to_repr}

///|
/// 分词器统一接口。
///
/// 只返回词项本身，适合“建索引 / 统计词频”这类不关心位置的场景；
/// 需要位置时请使用各实现上的 `analyze` 方法。
///
/// 实现约定：
/// - 返回的数组按原文本出现顺序排列；
/// - 可能包含重复词项（由索引层统计词频）；
/// - 不返回空字符串。
pub trait Tokenizer {
  fn tokenize(Self, String) -> Array[String]
  fn analyze(Self, String) -> Array[Token]
}

///|
/// 单字符规范化，所有分词器共用。
///
/// 处理三类情况：
/// 1. 全角 ASCII（Ｕ+FF01..U+FF5E）转半角，便于中文输入法混排的
///    "ＭｏｏｎＢｉｔ" 与 "MoonBit" 命中同一词项；
/// 2. 全角空格 U+3000 转普通空格；
/// 3. ASCII 大写转小写。
///
/// 非 ASCII 字符（含中日韩文字、带变音符的拉丁字母）原样返回，
/// 不做 Unicode 大小写折叠——MoonBit 的 `String::to_lower` 会分配新字符串，
/// 在逐字符扫描的建索引热路径上不划算，而 C++/Java 世界的主流检索
/// 实现同样只对 ASCII 做折叠。
pub fn normalize_char(ch : Char) -> Char {
  let code = ch.to_int()
  if code >= 0xFF01 && code <= 0xFF5E {
    let half = (code - 0xFEE0).unsafe_to_char()
    if half.is_ascii_uppercase() {
      half.to_ascii_lowercase()
    } else {
      half
    }
  } else if code == 0x3000 {
    ' '
  } else if ch.is_ascii_uppercase() {
    ch.to_ascii_lowercase()
  } else {
    ch
  }
}

///|
/// 判断是否为中日韩文字（含扩展区）。
///
/// 覆盖范围：CJK 统一表意文字及扩展 A/B、兼容表意文字、
/// 平假名、片假名、韩文音节。这些字符没有空格分隔，必须
/// 按字符（或 n-gram）切分，而不能像英文那样按空格切。
pub fn is_cjk(ch : Char) -> Bool {
  let code = ch.to_int()
  (code >= 0x4E00 && code <= 0x9FFF) ||
  (code >= 0x3400 && code <= 0x4DBF) ||
  (code >= 0xF900 && code <= 0xFAFF) ||
  (code >= 0x3040 && code <= 0x30FF) ||
  (code >= 0xAC00 && code <= 0xD7AF) ||
  (code >= 0x20000 && code <= 0x2FA1F)
}

///|
/// 判断是否为分隔符（词项边界）。
///
/// ASCII 规则简单：字母、数字、下划线之外的可见字符都算分隔符。
/// 非 ASCII 字符则显式列出常见的标点区段，其余字符（例如 é、俄文、
/// 日文假名）都视为词内字符，避免把 "café" 拆成 "caf"。
fn is_delimiter(ch : Char) -> Bool {
  if ch.is_whitespace() {
    true
  } else if ch.is_ascii() {
    !(ch.is_ascii_alphabetic() || ch.is_ascii_digit() || ch == '_')
  } else {
    let code = ch.to_int()
    (code >= 0x2000 && code <= 0x206F) || // 常用标点 General Punctuation
    (code >= 0x2E00 && code <= 0x2E7F) || // 补充标点 Supplemental Punctuation
    (code >= 0x3000 && code <= 0x303F) || // 中日韩标点 CJK Symbols and Punctuation
    (code >= 0xFE10 && code <= 0xFE1F) || // 竖排标点 Vertical Forms
    (code >= 0xFE30 && code <= 0xFE6F) || // 中日韩兼容形式 CJK Compatibility Forms
    (code >= 0xFF00 && code <= 0xFF65) // 全角/半角形式 Halfwidth and Fullwidth Forms
  }
}

///|
/// 判断字符是否属于“词内字符”。
///
/// 全角字母数字会先被 `normalize_char` 转成半角，因此这里只需处理
/// 规范化之后的字符。
pub fn is_word_char(ch : Char) -> Bool {
  if ch.is_ascii() {
    ch.is_ascii_alphabetic() || ch.is_ascii_digit() || ch == '_'
  } else {
    !is_cjk(ch) && !is_delimiter(ch)
  }
}

///|
/// 把文本切成连续的“片段”：ASCII/拉丁词保持完整，每个 CJK 字符单独成段。
///
/// 例如 "MoonBit 搜索引擎" -> ["moonbit", "搜", "索", "引", "擎"]。
/// 这是 StandardTokenizer 的切分基础；NGramTokenizer 需要保留连续片段
/// 做滑动窗口，因此不会直接复用本函数的输出。
///
/// 查询解析器也复用同一套切分规则，保证“索引侧”和“查询侧”生成的
/// 词项完全一致，否则会出现索引里有、查询里查不到的不对称。
pub fn split_terms(text : String) -> Array[String] {
  let segments : Array[String] = Array()
  let buffer = StringBuilder()
  let mut in_word = false
  for raw in text {
    let ch = normalize_char(raw)
    if is_cjk(ch) {
      if in_word {
        segments.push(buffer.to_string())
        buffer.reset()
        in_word = false
      }
      segments.push(ch.to_string())
    } else if is_word_char(ch) {
      buffer.write_char(ch)
      in_word = true
    } else if in_word {
      segments.push(buffer.to_string())
      buffer.reset()
      in_word = false
    }
  }
  if in_word {
    segments.push(buffer.to_string())
  }
  segments
}
