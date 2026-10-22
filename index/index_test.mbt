// index 包黑盒测试：验证倒排索引的写入、查询、删除与更新语义。

///|
/// 构造 5 篇模拟文档共用的索引，避免每个测试重复建库。
///
/// 文档内容刻意同时包含停用词（an / to / by / and / a / into / with），
/// 以便验证“停用词被丢弃但仍占用位置”这一行为。
fn sample_index() -> @index.InvertedIndex {
  let idx = @index.InvertedIndex::new()
  let tokenizer : &@tokenizer.Tokenizer = @tokenizer.StandardTokenizer::new()
  let docs : Array[@moontantivy.Document] = [
    @moontantivy.Document::new(
      1, "MoonBit search engine", "moonbit search engine blazing fast",
    ),
    @moontantivy.Document::new(
      2, "Inverted index", "an inverted index maps terms to posting lists",
    ),
    @moontantivy.Document::new(
      3, "BM25 ranking", "bm25 ranks documents by term frequency and document frequency",
    ),
    @moontantivy.Document::new(
      4, "Tokenizer design", "a tokenizer splits text into terms and search needs a tokenizer",
    ),
    @moontantivy.Document::new(
      5, "MoonBit full text search", "full text search with moonbit stores an inverted index",
    ),
  ]
  for doc in docs {
    idx.add_doc(doc, tokenizer)
  }
  idx
}

///|
/// 取指定词项的倒排表，不存在时直接让测试失败，避免后续空指针式断言。
fn must_list(index : @index.InvertedIndex, term : String) -> @index.PostingList {
  match index.get_posting_list(term) {
    Some(list) => list
    None => abort("词项 " + term + " 应当存在于索引中")
  }
}

///|
/// 取某文档的投递记录，不存在时直接让测试失败。
fn must_posting(list : @index.PostingList, doc_id : Int32) -> @index.Posting {
  match list.posting(doc_id) {
    Some(posting) => posting
    None => abort("倒排表中缺少文档 " + doc_id.to_string())
  }
}

///|
/// 插入 5 篇文档后，高频词的倒排表应记录正确的文档集合、词频与位置。
test "five_documents_build_correct_posting_lists" {
  let idx = sample_index()
  // search 出现在文档 1、4、5；文档 1 与 5 各出现两次。
  let search = must_list(idx, "search")
  assert_eq(search.doc_freq(), 3)
  assert_eq(search.total_freq(), 5)
  let s1 = must_posting(search, 1)
  assert_eq(s1.term_freq, 2)
  assert_eq(s1.positions, ([1, 4] : Array[Int32]))
  let s4 = must_posting(search, 4)
  assert_eq(s4.term_freq, 1)
  assert_eq(s4.positions, ([9] : Array[Int32]))
  let s5 = must_posting(search, 5)
  assert_eq(s5.term_freq, 2)
  assert_eq(s5.positions, ([3, 6] : Array[Int32]))
  // moonbit 只出现在文档 1、5，各两次。
  let moonbit = must_list(idx, "moonbit")
  assert_eq(moonbit.doc_freq(), 2)
  assert_eq(must_posting(moonbit, 1).positions, ([0, 3] : Array[Int32]))
  assert_eq(must_posting(moonbit, 5).positions, ([0, 8] : Array[Int32]))
  // index 出现在文档 2（两次）与文档 5（一次）。
  let index_list = must_list(idx, "index")
  assert_eq(index_list.doc_freq(), 2)
  assert_eq(must_posting(index_list, 2).term_freq, 2)
  assert_eq(must_posting(index_list, 5).term_freq, 1)
  // 停用词被过滤，不应进入词典。
  assert_true(idx.get_posting_list("the") is None)
  assert_true(idx.get_posting_list("with") is None)
  assert_true(idx.get_posting_list("into") is None)
}

///|
/// 只出现在单篇文档里的词项同样应正确记录，且倒排表按 doc_id 升序。
test "single_document_terms_are_sorted_by_doc_id" {
  let idx = sample_index()
  let bm25 = must_list(idx, "bm25")
  assert_eq(bm25.doc_freq(), 1)
  let posting = must_posting(bm25, 3)
  assert_eq(posting.term_freq, 2)
  assert_eq(posting.positions, ([0, 2] : Array[Int32]))
  let frequency = must_list(idx, "frequency")
  assert_eq(must_posting(frequency, 3).positions, ([7, 10] : Array[Int32]))
  // 文档 4 中 tokenizer 出现三次，位置按阅读顺序递增。
  let tokenizer = must_list(idx, "tokenizer")
  assert_eq(must_posting(tokenizer, 4).term_freq, 3)
  assert_eq(must_posting(tokenizer, 4).positions, ([0, 3, 12] : Array[Int32]))
  // 倒排表的 doc_id 必须严格升序，供布尔查询双指针归并使用。
  let search = must_list(idx, "search")
  assert_eq(search.posting_at(0).unwrap().doc_id, 1)
  assert_eq(search.posting_at(1).unwrap().doc_id, 4)
  assert_eq(search.posting_at(2).unwrap().doc_id, 5)
  assert_true(search.posting_at(3) is None)
}

///|
/// 文档级统计：文档数、总词数、单篇长度、词汇表规模与平均长度。
test "index_reports_document_statistics" {
  let idx = sample_index()
  assert_eq(idx.num_docs(), 5)
  assert_eq(idx.total_tokens(), 45)
  assert_eq(idx.doc_length(1), Some(8))
  assert_eq(idx.doc_length(2), Some(8))
  assert_eq(idx.doc_length(3), Some(9))
  assert_eq(idx.doc_length(4), Some(9))
  assert_eq(idx.doc_length(5), Some(11))
  assert_eq(idx.doc_length(99), None)
  assert_eq(idx.vocabulary_size(), 25)
  assert_eq(idx.average_doc_length(), 9.0)
  // 原始文档可按 ID 取回。
  let doc = idx.get_document(2).unwrap()
  assert_eq(doc.title, "Inverted index")
  assert_true(idx.contains_doc(3))
  assert_false(idx.contains_doc(42))
}

///|
/// 删除文档后，倒排表与词典都应同步收缩，不残留幽灵词项。
test "remove_doc_prunes_postings_and_dictionary" {
  let idx = sample_index()
  assert_true(idx.remove_doc(2))
  assert_eq(idx.num_docs(), 4)
  assert_eq(idx.total_tokens(), 37)
  // maps / posting / lists 只在文档 2 中出现，应被整词删除。
  assert_true(idx.get_posting_list("maps") is None)
  assert_true(idx.get_posting_list("posting") is None)
  assert_true(idx.get_posting_list("lists") is None)
  assert_eq(idx.vocabulary_size(), 22)
  // inverted 与 index 仍被文档 5 引用，只删除文档 2 的投递记录。
  let index_list = must_list(idx, "index")
  assert_eq(index_list.doc_freq(), 1)
  assert_true(index_list.posting(2) is None)
  assert_eq(must_posting(index_list, 5).term_freq, 1)
  // 重复删除同一文档应返回 false，且不改变统计值。
  assert_false(idx.remove_doc(2))
  assert_eq(idx.num_docs(), 4)
  assert_eq(idx.total_tokens(), 37)
  assert_false(idx.remove_doc(12345))
}

///|
/// 重复添加同一 ID 的文档按“更新”处理：旧词项必须被清理。
test "readding_document_replaces_old_postings" {
  let idx = sample_index()
  let tokenizer : &@tokenizer.Tokenizer = @tokenizer.StandardTokenizer::new()
  let updated = @moontantivy.Document::new(
    3, "Ranking notes", "pure ranking documents",
  )
  idx.add_doc(updated, tokenizer)
  // 文档总数不变，长度与总词数按新版本重算。
  assert_eq(idx.num_docs(), 5)
  assert_eq(idx.doc_length(3), Some(5))
  assert_eq(idx.total_tokens(), 41)
  // bm25 与 frequency 只属于旧版本，必须从词典中消失。
  assert_true(idx.get_posting_list("bm25") is None)
  assert_true(idx.get_posting_list("frequency") is None)
  // 新版本中的词项正常可查，且词频为 2。
  let ranking = must_list(idx, "ranking")
  assert_eq(ranking.doc_freq(), 1)
  assert_eq(must_posting(ranking, 3).positions, ([0, 3] : Array[Int32]))
  assert_eq(idx.get_document(3).unwrap().title, "Ranking notes")
}

///|
/// 独立测试倒排表本身的有序插入、覆盖、二分查找与删除。
test "posting_list_supports_ordered_mutation" {
  let list = @index.PostingList::new()
  assert_true(list.is_empty())
  // 乱序插入，内部仍按 doc_id 升序保存。
  list.add(3, ([1, 2] : Array[Int32]))
  list.add(1, ([7] : Array[Int32]))
  list.add(2, ([0] : Array[Int32]))
  assert_eq(list.doc_freq(), 3)
  assert_eq(list.posting_at(0).unwrap().doc_id, 1)
  assert_eq(list.posting_at(1).unwrap().doc_id, 2)
  assert_eq(list.posting_at(2).unwrap().doc_id, 3)
  // 同一 doc_id 再次写入视为覆盖，词频随位置数组长度更新。
  list.add(2, ([5, 6, 8] : Array[Int32]))
  assert_eq(list.doc_freq(), 3)
  assert_eq(must_posting(list, 2).term_freq, 3)
  assert_eq(list.total_freq(), 6)
  assert_true(list.remove(2))
  assert_false(list.remove(99))
  assert_eq(list.doc_freq(), 2)
  assert_true(list.posting(2) is None)
  assert_true(list.entries().length() == 2)
}

///|
/// NGramTokenizer 建索引：中文双字词项的位置与词频应正确。
test "ngram_index_supports_chinese_terms" {
  let idx = @index.InvertedIndex::new()
  let tokenizer : &@tokenizer.Tokenizer = @tokenizer.NGramTokenizer::new()
  idx.add_doc(
    @moontantivy.Document::new(10, "搜索引擎", "全文检索"),
    tokenizer,
  )
  idx.add_doc(
    @moontantivy.Document::new(11, "搜索引擎", "搜索引擎实现"),
    tokenizer,
  )
  assert_eq(idx.num_docs(), 2)
  assert_eq(idx.doc_length(10), Some(6))
  assert_eq(idx.doc_length(11), Some(8))
  assert_eq(idx.total_tokens(), 14)
  // 搜索：文档 10 出现一次，文档 11 出现两次（标题与正文各一次）。
  let search = must_list(idx, "搜索")
  assert_eq(search.doc_freq(), 2)
  assert_eq(must_posting(search, 10).positions, ([0] : Array[Int32]))
  assert_eq(must_posting(search, 11).positions, ([0, 5] : Array[Int32]))
  // 引擎与 实现 验证相邻 bigram 的位置是连续递增的。
  assert_eq(
    must_posting(must_list(idx, "引擎"), 11).positions,
    ([2, 7] : Array[Int32]),
  )
  assert_eq(
    must_posting(must_list(idx, "实现"), 11).positions,
    ([9] : Array[Int32]),
  )
  assert_true(idx.get_posting_list("搜") is None)
}

///|
/// 空索引与不存在词项的边界行为。
test "empty_index_is_safe" {
  let idx = @index.InvertedIndex::new()
  assert_eq(idx.num_docs(), 0)
  assert_eq(idx.total_tokens(), 0)
  assert_eq(idx.vocabulary_size(), 0)
  assert_eq(idx.average_doc_length(), 0.0)
  assert_true(idx.get_posting_list("anything") is None)
  assert_eq(idx.doc_freq("anything"), 0)
  assert_false(idx.contains_doc(1))
  assert_false(idx.remove_doc(1))
}
