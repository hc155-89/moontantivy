// InvertedIndex：内存倒排索引。

///|
/// 内存倒排索引。
///
/// 结构说明：
/// - `postings`：词典，词项 -> 倒排表；
/// - `documents`：文档表，保留原文，便于删除与后续持久化；
/// - `doc_lengths`：每篇文档的“有效词项数”（停用词过滤后），BM25 的长度归一化用；
/// - `doc_terms`：文档 -> 该文档出现过的词项集合，删除文档时只遍历这些词项，
///   避免扫描整个词典（O(文档词项数) 而不是 O(词汇表大小)）；
/// - `token_count`：全库有效词项总数，用于计算平均文档长度。
///
/// 文档 ID 由调用方提供；重复添加同一 ID 时按“更新”处理：先删除旧版本，
/// 再写入新版本，因此索引里不会残留幽灵词项。
pub struct InvertedIndex {
  postings : @hashmap.HashMap[String, PostingList]
  documents : @hashmap.HashMap[Int32, @moontantivy.Document]
  doc_lengths : @hashmap.HashMap[Int32, Int32]
  doc_terms : @hashmap.HashMap[Int32, Array[String]]
  mut token_count : Int32
}

///|
/// 创建空索引。
pub fn InvertedIndex::new() -> InvertedIndex {
  {
    postings: @hashmap.HashMap([]),
    documents: @hashmap.HashMap([]),
    doc_lengths: @hashmap.HashMap([]),
    doc_terms: @hashmap.HashMap([]),
    token_count: 0,
  }
}

///|
/// 把一篇文档分词后写入索引。
///
/// 流程：
/// 1. 若同 ID 文档已存在，先删除旧版本（更新语义）；
/// 2. 用调用方提供的分词器对“标题 + 正文”做带位置的切分；
/// 3. 按词项聚合位置，写入倒排表；同时记录文档长度与文档词项集合。
///
/// 采用 `&Tokenizer` 而不是泛型参数，是为了让上层可以持有
/// 一个运行时才决定的分词器实例（英文用 Standard，中文用 NGram），
/// 而不必把索引本身变成泛型类型。
pub fn InvertedIndex::add_doc(
  self : InvertedIndex,
  doc : @moontantivy.Document,
  tokenizer : &@tokenizer.Tokenizer,
) -> Unit {
  if self.documents.contains(doc.id) {
    let _ = self.remove_doc(doc.id)
  }
  let tokens = tokenizer.analyze(doc.text())
  let doc_length = tokens.length()
  // 第一步：按词项聚合出现位置。
  let term_positions : @hashmap.HashMap[String, Array[Int32]] = @hashmap.HashMap([],
  )
  for token in tokens {
    match term_positions.get(token.term) {
      Some(list) => list.push(token.position)
      None => {
        let list : Array[Int32] = [token.position]
        term_positions.set(token.term, list)
      }
    }
  }
  // 第二步：写入词典，并记录该文档用到哪些词项。
  let terms : Array[String] = Array()
  for term, positions in term_positions {
    terms.push(term)
    match self.postings.get(term) {
      Some(list) => list.add(doc.id, positions)
      None => {
        let list = PostingList::new()
        list.add(doc.id, positions)
        self.postings.set(term, list)
      }
    }
  }
  self.documents.set(doc.id, doc)
  self.doc_lengths.set(doc.id, doc_length)
  self.doc_terms.set(doc.id, terms)
  self.token_count = self.token_count + doc_length
}

///|
/// 按字典序返回索引中的全部词项。
///
/// 持久化与调试输出都依赖稳定的顺序：`HashMap` 遍历顺序不确定，
/// 因此这里显式排序，保证同一份索引多次导出的文件内容完全一致。
pub fn InvertedIndex::terms(self : InvertedIndex) -> Array[String] {
  let terms : Array[String] = Array()
  for term, _ in self.postings {
    terms.push(term)
  }
  terms.sort()
  terms
}

///|
/// 返回某篇文档出现过的词项集合（用于持久化与删除）。
///
/// 这些词项是分词后实际写入倒排表的那些，不含被停用词过滤的词。
pub fn InvertedIndex::doc_terms_of(
  self : InvertedIndex,
  doc_id : Int32,
) -> Array[String]? {
  self.doc_terms.get(doc_id)
}

///|
/// 直接写入一篇“已经分好词”的文档，跳过分词步骤。
///
/// 这是从持久化数据恢复索引的入口：`length` 是文档的有效词项数，
/// `terms` 是文档出现过的词项集合。同 ID 已存在时按更新语义先删除旧记录。
/// 正常建索引请使用 `add_doc`，它会在写入前完成分词与词频统计。
pub fn InvertedIndex::restore_doc(
  self : InvertedIndex,
  doc : @moontantivy.Document,
  length : Int32,
  terms : Array[String],
) -> Unit {
  if self.documents.contains(doc.id) {
    let _ = self.remove_doc(doc.id)
  }
  self.documents.set(doc.id, doc)
  self.doc_lengths.set(doc.id, length)
  self.doc_terms.set(doc.id, terms)
  self.token_count = self.token_count + length
}

///|
/// 直接写入一条投递记录，跳过分词步骤。
///
/// `positions` 必须按升序给出词项在文档中的出现位置；词频由位置个数推导，
/// 与 `PostingList::add` 的约定一致。同文档同词项重复写入会覆盖旧记录。
pub fn InvertedIndex::restore_posting(
  self : InvertedIndex,
  term : String,
  doc_id : Int32,
  positions : Array[Int32],
) -> Unit {
  match self.postings.get(term) {
    Some(list) => list.add(doc_id, positions)
    None => {
      let list = PostingList::new()
      list.add(doc_id, positions)
      self.postings.set(term, list)
    }
  }
}

///|
/// 从索引中删除一篇文档，返回是否找到并删除了该文档。
///
/// 只遍历该文档出现过的词项；某个词项在删除后若不再被任何文档包含，
/// 就把它从词典中彻底移除，防止词典无限膨胀。
pub fn InvertedIndex::remove_doc(self : InvertedIndex, doc_id : Int32) -> Bool {
  match self.doc_terms.get(doc_id) {
    None => false
    Some(terms) => {
      for term in terms {
        match self.postings.get(term) {
          Some(list) => {
            let _ = list.remove(doc_id)
            if list.is_empty() {
              self.postings.remove(term)
            }
          }
          None => ()
        }
      }
      let length = match self.doc_lengths.get(doc_id) {
        Some(value) => value
        None => 0
      }
      self.token_count = self.token_count - length
      self.doc_terms.remove(doc_id)
      self.doc_lengths.remove(doc_id)
      self.documents.remove(doc_id)
      true
    }
  }
}

///|
/// 查询词项的倒排表，词项不存在时返回 `None`。
///
/// 返回的是索引内部倒排表的句柄（`PostingList` 内部持有数组引用），
/// 因此不要在索引继续写入的同时长期持有它；查询阶段只读是安全的。
pub fn InvertedIndex::get_posting_list(
  self : InvertedIndex,
  term : String,
) -> PostingList? {
  self.postings.get(term)
}

///|
/// 文档频率：包含指定词项的文档数，不存在则为 0。
pub fn InvertedIndex::doc_freq(self : InvertedIndex, term : String) -> Int32 {
  match self.postings.get(term) {
    Some(list) => list.doc_freq()
    None => 0
  }
}

///|
/// 索引中的文档数量。
pub fn InvertedIndex::num_docs(self : InvertedIndex) -> Int32 {
  self.documents.length()
}

///|
/// 返回索引内全部文档 ID，按升序排列。
///
/// 查询层的 `NOT` 需要“全集减去匹配集”，因此必须能枚举全部文档；
/// 这里显式排序，因为 `HashMap` 的遍历顺序不保证稳定，
/// 而集合差运算与结果可复现性都依赖有序输入。
pub fn InvertedIndex::doc_ids(self : InvertedIndex) -> Array[Int32] {
  let ids : Array[Int32] = Array()
  for doc_id, _ in self.documents {
    ids.push(doc_id)
  }
  ids.sort()
  ids
}

///|
/// 全库有效词项总数（所有文档长度之和）。
pub fn InvertedIndex::total_tokens(self : InvertedIndex) -> Int32 {
  self.token_count
}

///|
/// 某篇文档的有效词项数（停用词过滤后）；不存在时返回 `None`。
pub fn InvertedIndex::doc_length(
  self : InvertedIndex,
  doc_id : Int32,
) -> Int32? {
  self.doc_lengths.get(doc_id)
}

///|
/// 按 ID 取回原始文档。
pub fn InvertedIndex::get_document(
  self : InvertedIndex,
  doc_id : Int32,
) -> @moontantivy.Document? {
  self.documents.get(doc_id)
}

///|
/// 索引中是否包含指定文档。
pub fn InvertedIndex::contains_doc(
  self : InvertedIndex,
  doc_id : Int32,
) -> Bool {
  self.documents.contains(doc_id)
}

///|
/// 词汇表大小（不同词项的数量）。
pub fn InvertedIndex::vocabulary_size(self : InvertedIndex) -> Int32 {
  self.postings.length()
}

///|
/// 平均文档长度。空索引返回 0.0，避免除零。
pub fn InvertedIndex::average_doc_length(self : InvertedIndex) -> Double {
  let count = self.num_docs()
  if count == 0 {
    0.0
  } else {
    self.token_count.to_double() / count.to_double()
  }
}
