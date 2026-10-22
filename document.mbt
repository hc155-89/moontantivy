// 模块根包：核心数据结构。
//
// 这里只放被各子包共享的纯数据类型，不依赖任何子包，
// 从而避免 tokenizer / index / api 之间出现循环依赖。

///|
/// 检索系统中的一篇文档。
///
/// `id` 由调用方提供，并且必须在同一个索引内唯一。倒排索引内部直接
/// 用它作为文档编号，因此推荐从 0 或 1 开始连续分配，便于持久化后恢复。
///
/// 标题与正文会被分别索引吗？
/// 当前阶段先用 `text()` 把两者拼成一段文本统一索引；字段级权重
/// （标题加权）留到评分阶段再扩展，避免过早引入复杂度。
pub struct Document {
  id : Int32
  title : String
  content : String
} derive(Debug, Eq)

///|
/// 显式声明 derive 生成的实例方法，避免未来版本中“隐式提升”语法被移除。
pub extend Document with Eq::{not_equal, equal}

///|
pub extend Document with @debug.Debug::{to_repr}

///|
/// 创建一篇文档。三个参数均为必填，避免出现“空 id / 空标题”的隐式默认值。
pub fn Document::new(id : Int32, title : String, content : String) -> Document {
  { id, title, content, }
}

///|
/// 返回建立索引时使用的完整文本：标题在前，正文在后。
///
/// 两者之间补一个空格，确保标题末尾的词与正文开头的词不会被粘成一个
/// 新词（例如标题 "search" + 正文 "engine" 不应产生 "searchengine"）。
/// 任一字段为空时只返回另一个字段，避免留下多余空白。
pub fn Document::text(self : Document) -> String {
  if self.title.is_empty() {
    self.content
  } else if self.content.is_empty() {
    self.title
  } else {
    self.title + " " + self.content
  }
}
