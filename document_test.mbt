// 核心数据结构 Document 的测试。

///|
test "document_text_joins_title_and_content" {
  let doc = @moontantivy.Document::new(
    1, "MoonBit", "embedded full-text search",
  )
  assert_eq(doc.id, 1)
  assert_eq(doc.title, "MoonBit")
  assert_eq(doc.content, "embedded full-text search")
  // 标题与正文之间补一个空格，防止首尾词粘连。
  assert_eq(doc.text(), "MoonBit embedded full-text search")
}

///|
test "document_text_handles_empty_fields" {
  let content_only = @moontantivy.Document::new(2, "", "body text")
  assert_eq(content_only.text(), "body text")
  let title_only = @moontantivy.Document::new(3, "title", "")
  assert_eq(title_only.text(), "title")
  let empty = @moontantivy.Document::new(4, "", "")
  assert_eq(empty.text(), "")
}

///|
test "document_equality_is_structural" {
  let a = @moontantivy.Document::new(7, "t", "c")
  let b = @moontantivy.Document::new(7, "t", "c")
  let c = @moontantivy.Document::new(7, "t", "different")
  assert_true(a == b)
  assert_false(a == c)
}
