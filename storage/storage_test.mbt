// storage 包黑盒测试：验证 JSON 落盘、读取恢复、确定性输出与异常处理。
//
// 所有测试都写独立的临时文件，并在断言前尽力清理，避免污染工作目录。

///|
/// 构造 4 篇文档的索引：
/// - 普通英文文档，用于验证倒排表与位置；
/// - 含引号、反斜杠、中文的文档，用于验证 JSON 转义。
fn sample_index() -> @index.InvertedIndex {
  let idx = @index.InvertedIndex::new()
  let tokenizer : &@tokenizer.Tokenizer = @tokenizer.StandardTokenizer::new()
  let docs : Array[@moontantivy.Document] = [
    @moontantivy.Document::new(1, "MoonBit search", "moonbit search engine"),
    @moontantivy.Document::new(2, "Rust Go", "rust go systems programming"),
    @moontantivy.Document::new(
      3, "MoonBit index", "moonbit inverted index engine",
    ),
    @moontantivy.Document::new(
      4, "带 \"引号\" 的标题", "反斜杠 \\ 与 检索",
    ),
  ]
  for doc in docs {
    idx.add_doc(doc, tokenizer)
  }
  idx
}

///|
/// 删除文件，忽略“文件不存在”等错误。
fn cleanup(path : String) -> Unit {
  @fs.remove_file(path) catch {
    _ => ()
  }
}

///|
/// 保存 -> 读取 -> 查询：恢复后的索引必须与内存索引完全一致。
test "roundtrip_preserves_index_and_query_results" {
  let path = "tmp_moontantivy_index_roundtrip.json"
  cleanup(path)
  let idx = sample_index()
  @storage.save_to_file(idx, path)
  assert_true(@fs.path_exists(path))
  let loaded = @storage.load_from_file(path)
  // 文件内容非空，便于确认真的发生了序列化。
  let text = @fs.read_file_to_string(path)
  assert_true(text.length() > 0)
  // 统计信息一致。
  assert_eq(loaded.num_docs(), 4)
  assert_eq(loaded.total_tokens(), 29)
  assert_eq(loaded.vocabulary_size(), 21)
  assert_eq(loaded.doc_length(2), Some(6))
  // 文档原文一致（含引号、反斜杠与中文，验证 JSON 转义）。
  let doc = loaded.get_document(4).unwrap()
  assert_eq(doc.title, "带 \"引号\" 的标题")
  assert_eq(doc.content, "反斜杠 \\ 与 检索")
  // 倒排表一致：doc_id 顺序、词频、位置都不能变。
  let moonbit = loaded.get_posting_list("moonbit").unwrap()
  assert_eq(moonbit.doc_freq(), 2)
  assert_eq(moonbit.posting(1).unwrap().term_freq, 2)
  assert_eq(moonbit.posting(1).unwrap().positions, ([0, 2] : Array[Int32]))
  assert_eq(moonbit.posting(3).unwrap().positions, ([0, 2] : Array[Int32]))
  let index_list = loaded.get_posting_list("index").unwrap()
  assert_eq(index_list.posting(3).unwrap().positions, ([1, 4] : Array[Int32]))
  // 查询结果与内存索引一致。
  let term_query = @query.parse_query("moonbit").unwrap()
  assert_eq(@query.execute(term_query, idx), ([1, 3] : Array[Int32]))
  assert_eq(@query.execute(term_query, loaded), ([1, 3] : Array[Int32]))
  let phrase_query = @query.parse_query("\"moonbit search\"").unwrap()
  assert_eq(@query.execute(phrase_query, loaded), ([1] : Array[Int32]))
  let boolean_query = @query.parse_query("moonbit AND NOT search").unwrap()
  assert_eq(@query.execute(boolean_query, loaded), ([3] : Array[Int32]))
  // 中文词项（逐字切分）也应完整往返。
  let cjk_query = @query.parse_query("检").unwrap()
  assert_eq(@query.execute(cjk_query, loaded), ([4] : Array[Int32]))
  cleanup(path)
  assert_false(@fs.path_exists(path))
}

///|
/// 同一索引多次保存应产生完全相同的字节内容（顺序稳定，可做 diff）。
test "save_is_deterministic" {
  let path_a = "tmp_moontantivy_index_det_a.json"
  let path_b = "tmp_moontantivy_index_det_b.json"
  cleanup(path_a)
  cleanup(path_b)
  let idx = sample_index()
  @storage.save_to_file(idx, path_a)
  // 从文件读回再保存，验证“恢复 -> 再序列化”不会改变内容。
  let loaded = @storage.load_from_file(path_a)
  @storage.save_to_file(loaded, path_b)
  let text_a = @fs.read_file_to_string(path_a)
  let text_b = @fs.read_file_to_string(path_b)
  assert_eq(text_a, text_b)
  cleanup(path_a)
  cleanup(path_b)
}

///|
/// 空索引也应能正常往返，不产生任何特殊分支。
test "empty_index_roundtrip" {
  let path = "tmp_moontantivy_index_empty.json"
  cleanup(path)
  let idx = @index.InvertedIndex::new()
  @storage.save_to_file(idx, path)
  let loaded = @storage.load_from_file(path)
  assert_eq(loaded.num_docs(), 0)
  assert_eq(loaded.total_tokens(), 0)
  assert_eq(loaded.vocabulary_size(), 0)
  assert_eq(loaded.doc_ids(), ([] : Array[Int32]))
  cleanup(path)
}

///|
/// 非法 JSON 应抛出解析错误，而不是返回半个索引。
test "malformed_json_is_rejected" {
  let path = "tmp_moontantivy_index_malformed.json"
  cleanup(path)
  @fs.write_string_to_file(path, "{ this is not json")
  let mut raised = false
  try {
    let _ = @storage.load_from_file(path)
  } catch {
    _ => raised = true
  }
  assert_true(raised)
  cleanup(path)
}

///|
/// 版本不兼容时必须拒绝加载，避免用错误的结构解释文件。
test "unsupported_version_is_rejected" {
  let path = "tmp_moontantivy_index_version.json"
  cleanup(path)
  let content = "{\"version\": 999, \"token_count\": 0, \"documents\": [], \"terms\": []}"
  @fs.write_string_to_file(path, content)
  let mut raised = false
  try {
    let _ = @storage.load_from_file(path)
  } catch {
    _ => raised = true
  }
  assert_true(raised)
  cleanup(path)
}

///|
/// 统计值自相矛盾的文件应被完整性校验拦下。
test "corrupt_token_count_is_rejected" {
  let path = "tmp_moontantivy_index_corrupt.json"
  cleanup(path)
  let content = "{\"version\": 1, \"token_count\": 99, \"documents\": [{\"id\": 1, \"title\": \"t\", \"content\": \"c\", \"length\": 5, \"terms\": []}], \"terms\": []}"
  @fs.write_string_to_file(path, content)
  let mut raised = false
  try {
    let _ = @storage.load_from_file(path)
  } catch {
    _ => raised = true
  }
  assert_true(raised)
  cleanup(path)
}

///|
/// 恢复后的索引仍支持增删改，不只是只读快照。
test "loaded_index_remains_mutable" {
  let path = "tmp_moontantivy_index_mutable.json"
  cleanup(path)
  let idx = sample_index()
  @storage.save_to_file(idx, path)
  let loaded = @storage.load_from_file(path)
  cleanup(path)
  // 删除文档 2，词典中的 rust / go 等词项应同步消失。
  assert_true(loaded.remove_doc(2))
  assert_eq(loaded.num_docs(), 3)
  assert_true(loaded.get_posting_list("rust") is None)
  // 新增文档 5，索引统计随之更新。
  let tokenizer : &@tokenizer.Tokenizer = @tokenizer.StandardTokenizer::new()
  loaded.add_doc(
    @moontantivy.Document::new(5, "New", "fresh content"),
    tokenizer,
  )
  assert_eq(loaded.num_docs(), 4)
  assert_eq(loaded.doc_length(5), Some(3))
  assert_true(loaded.get_posting_list("fresh") is Some(_))
}

///|
/// 文本形式的往返：不经过文件系统也能完整恢复索引与查询结果。
///
/// 这条路径是浏览器 / 边缘场景的基础——宿主 `fetch` 到 JSON 文本后，
/// 直接调用 `load_from_string` 即可，无需可写文件系统。
test "string_roundtrip_matches_memory" {
  let idx = sample_index()
  let text = @storage.save_to_string(idx)
  // 文本必须是非空的合法 JSON 对象，且与文件保存使用同一格式。
  assert_true(text.length() > 0)
  assert_true(text.has_prefix("{"))
  let loaded = @storage.load_from_string(text)
  assert_eq(loaded.num_docs(), idx.num_docs())
  assert_eq(loaded.total_tokens(), idx.total_tokens())
  assert_eq(loaded.vocabulary_size(), idx.vocabulary_size())
  // 查询结果与内存索引一致（词项 / 短语 / 布尔 / 中文各取一种）。
  let queries : Array[String] = [
    "moonbit", "\"search engine\"", "rust OR go", "\"检索\"",
  ]
  for query in queries {
    let expected = @query.execute(@query.parse_query(query).unwrap(), idx)
    let actual = @query.execute(@query.parse_query(query).unwrap(), loaded)
    assert_eq(actual, expected)
  }
}

///|
/// 非法文本与非法文件走同一套错误语义。
test "malformed_string_is_rejected" {
  let mut malformed = false
  try {
    let _ = @storage.load_from_string("{\"version\": 1,")
  } catch {
    MalformedJson => malformed = true
    _ => ()
  }
  assert_true(malformed)
  let mut mismatch = false
  try {
    let _ = @storage.load_from_string("{\"version\": 1}")
  } catch {
    SchemaMismatch => mismatch = true
    _ => ()
  }
  assert_true(mismatch)
}
