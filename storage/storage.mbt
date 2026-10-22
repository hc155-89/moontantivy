// storage 包：把内存倒排索引序列化为 JSON 并落盘，以及从文件恢复索引。
//
// 文件格式（版本 1）：
// {
//   "version": 1,
//   "token_count": 17,
//   "documents": [
//     { "id": 1, "title": "...", "content": "...", "length": 5,
//       "terms": ["engine", "moonbit", "search"] }
//   ],
//   "terms": [
//     { "term": "moonbit",
//       "postings": [ { "doc_id": 1, "positions": [0, 2] } ] }
//   ]
// }
//
// 设计取舍：
// - 只持久化“分词之后”的数据（词项、位置、文档长度），不保存分词器配置。
//   这样恢复时不需要重新分词，文件读取结果与内存索引逐位一致；
// - 词频（term_freq）不单独存储，由 positions 的长度推导，避免两份数据不同步；
// - 文档集合按 ID 升序、词项按字典序输出，保证同一索引多次保存的字节内容稳定，
//   便于做 diff、缓存和完整性校验；
// - 恢复后校验 token_count 与文档长度之和一致，能尽早发现被手工篡改的文件。

///|
/// 持久化格式版本号。字段或语义发生变化时必须递增，加载时据此拒绝旧文件。
const FORMAT_VERSION : Int32 = 1

///|
/// 加载索引时可能出现的全部错误。
///
/// 底层错误（文件系统、JSON 语法、JSON 结构）在这里被统一翻译成
/// `StorageError`：上层调用方只需要处理一种错误类型，不必同时感知
/// `@fs.IOError` / `@json.ParseError` / `@json.JsonDecodeError` 三个来源；
/// 原始错误信息保留在 `IoFailure` 的字符串里，便于定位问题。
pub suberror StorageError {
  /// 读取文件失败（不存在、无权限等），携带底层错误信息。
  IoFailure(String)
  /// 文件内容不是合法 JSON。
  MalformedJson
  /// JSON 合法，但字段结构不符合索引快照定义。
  SchemaMismatch
  /// 文件版本与当前代码不兼容。
  UnsupportedVersion(Int32)
  /// 文件结构可解析，但内部统计值自相矛盾（例如 token_count 对不上）。
  CorruptIndex(String)
}

///|
/// 一篇文档的持久化记录。
///
/// `length` 是停用词过滤后的有效词项数（BM25 用的文档长度），
/// `terms` 是该文档实际写入倒排表的词项集合，恢复时用于重建反向表。
struct DocumentRecord {
  id : Int32
  title : String
  content : String
  length : Int32
  terms : Array[String]
} derive(@json.ToJson, @json.FromJson)

///|
pub extend DocumentRecord with @json.ToJson::{to_json}

///|
pub extend DocumentRecord with @json.FromJson::{from_json}

///|
/// 一条投递记录的持久化形式。
///
/// 不存 term_freq：词频恒等于 positions 的长度，重复存储只会带来不一致风险。
struct PostingRecord {
  doc_id : Int32
  positions : Array[Int32]
} derive(@json.ToJson, @json.FromJson)

///|
pub extend PostingRecord with @json.ToJson::{to_json}

///|
pub extend PostingRecord with @json.FromJson::{from_json}

///|
/// 一个词项及其完整倒排表。
struct TermRecord {
  term : String
  postings : Array[PostingRecord]
} derive(@json.ToJson, @json.FromJson)

///|
pub extend TermRecord with @json.ToJson::{to_json}

///|
pub extend TermRecord with @json.FromJson::{from_json}

///|
/// 整个索引的持久化快照，与 JSON 顶层对象一一对应。
struct IndexRecord {
  version : Int32
  token_count : Int32
  documents : Array[DocumentRecord]
  terms : Array[TermRecord]
} derive(@json.ToJson, @json.FromJson)

///|
pub extend IndexRecord with @json.ToJson::{to_json}

///|
pub extend IndexRecord with @json.FromJson::{from_json}

///|
/// 把内存索引转换成可序列化的快照。
///
/// 遍历顺序全部显式排序，而不是依赖 `HashMap` 的迭代顺序。
fn snapshot(index : @index.InvertedIndex) -> IndexRecord {
  let documents : Array[DocumentRecord] = Array()
  for doc_id in index.doc_ids() {
    let document = match index.get_document(doc_id) {
      Some(document) => document
      None => continue
    }
    let length = match index.doc_length(doc_id) {
      Some(length) => length
      None => 0
    }
    let terms : Array[String] = Array()
    match index.doc_terms_of(doc_id) {
      Some(doc_terms) =>
        for term in doc_terms {
          terms.push(term)
        }
      None => ()
    }
    terms.sort()
    documents.push({
      id: document.id,
      title: document.title,
      content: document.content,
      length,
      terms,
    })
  }
  let terms : Array[TermRecord] = Array()
  for term in index.terms() {
    let postings : Array[PostingRecord] = Array()
    match index.get_posting_list(term) {
      Some(list) =>
        for posting in list.entries() {
          postings.push({
            doc_id: posting.doc_id,
            positions: posting.positions,
          })
        }
      None => ()
    }
    terms.push({ term, postings, })
  }
  {
    version: FORMAT_VERSION,
    token_count: index.total_tokens(),
    documents,
    terms,
  }
}

///|
/// 由快照重建内存索引。
///
/// 先恢复文档（长度与词项集合），再逐条写入投递记录。`PostingList::add`
/// 内部按 doc_id 有序插入，因此文件中的顺序不影响最终结构。
fn rebuild(record : IndexRecord) -> @index.InvertedIndex {
  let index = @index.InvertedIndex::new()
  for doc in record.documents {
    let document = @moontantivy.Document::new(doc.id, doc.title, doc.content)
    index.restore_doc(document, doc.length, doc.terms)
  }
  for term_record in record.terms {
    for posting in term_record.postings {
      index.restore_posting(term_record.term, posting.doc_id, posting.positions)
    }
  }
  index
}

///|
/// 把索引写入 JSON 文件。
///
/// 若目标文件已存在会被覆盖；调用方需保证目录存在。
/// 写出的内容完全由索引数据决定（顺序稳定），可用于比对或版本控制。
pub fn save_to_file(
  index : @index.InvertedIndex,
  path : String,
) -> Unit raise @fs.IOError {
  let record = snapshot(index)
  let text = @json.to_json(record).stringify(indent=2)
  @fs.write_string_to_file(path, text)
}

///|
/// 从 JSON 文件恢复索引。
///
/// 所有底层错误都会被翻译成 `StorageError`：
/// - `IoFailure`：文件不存在或不可读，附带底层信息；
/// - `MalformedJson`：内容不是合法 JSON；
/// - `SchemaMismatch`：JSON 结构不符合快照定义（缺字段、类型错误）；
/// - `UnsupportedVersion`：版本不兼容；
/// - `CorruptIndex`：统计值自相矛盾。
///
/// 恢复后的索引与保存前的内存在文档、词项、位置、长度上完全一致，
/// 因此查询与 BM25 评分结果也保持一致。
pub fn load_from_file(path : String) -> @index.InvertedIndex raise StorageError {
  let text = @fs.read_file_to_string(path) catch {
    @fs.IOError(message) => raise IoFailure(message)
  }
  let parsed = @json.parse(text.view()) catch { _ => raise MalformedJson }
  let record : IndexRecord = @json.from_json(parsed) catch {
    _ => raise SchemaMismatch
  }
  if record.version != FORMAT_VERSION {
    raise UnsupportedVersion(record.version)
  }
  let index = rebuild(record)
  // 完整性校验：文档长度之和必须等于文件记录的总词数。
  if index.total_tokens() != record.token_count {
    raise CorruptIndex("token_count 与文档长度之和不一致")
  }
  index
}
