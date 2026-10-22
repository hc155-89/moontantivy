// index 包：倒排索引核心。
//
// 数据模型：
//   Document --分词--> [Token] --归并--> 词项 -> PostingList -> [Posting]
//
// 一个 Posting 记录“某词项在某文档中出现多少次、在哪些位置”，
// PostingList 则是同一词项在所有文档上的投递记录集合。

///|
/// 一条投递记录：某个词项在一篇文档中的出现情况。
///
/// `term_freq` 是词频（term frequency），即该词项在文档内出现的次数；
/// `positions` 是每次出现的位置，按出现顺序排列，供短语查询判断相邻关系。
/// 词频与位置长度始终一致，`add` 时由位置数组长度推导，避免两者不同步。
pub struct Posting {
  doc_id : Int32
  term_freq : Int32
  positions : Array[Int32]
}

///|
/// 某个词项的倒排表。
///
/// 内部按 `doc_id` 严格升序保存，这是后续布尔查询（AND / OR）能够用
/// 双指针线性归并的前提；也保证持久化再加载后顺序稳定、可复现。
pub struct PostingList {
  postings : Array[Posting]
}

///|
/// 创建空倒排表。
pub fn PostingList::new() -> PostingList {
  { postings: Array(), }
}

///|
/// 追加一条投递记录（重复 doc_id 会覆盖旧记录，用于“重建同一文档”）。
///
/// 插入位置通过一次线性扫描找到：倒排表通常按文档加入顺序增长，
/// 扫描代价接近 O(1)；显式排序则能保证乱序写入时依然有序。
pub fn PostingList::add(
  self : PostingList,
  doc_id : Int32,
  positions : Array[Int32],
) -> Unit {
  let posting : Posting = { doc_id, term_freq: positions.length(), positions, }
  let mut at = 0
  let count = self.postings.length()
  while at < count && self.postings.unsafe_get(at).doc_id < doc_id {
    at = at + 1
  }
  if at < count && self.postings.unsafe_get(at).doc_id == doc_id {
    self.postings.set(at, posting)
  } else {
    self.postings.insert(at, posting)
  }
}

///|
/// 查找指定文档的投递记录。内部有序，因此用二分查找。
pub fn PostingList::posting(self : PostingList, doc_id : Int32) -> Posting? {
  let mut low = 0
  let mut high = self.postings.length() - 1
  while low <= high {
    let mid = low + (high - low) / 2
    let current = self.postings.unsafe_get(mid)
    if current.doc_id == doc_id {
      return Some(current)
    } else if current.doc_id < doc_id {
      low = mid + 1
    } else {
      high = mid - 1
    }
  }
  None
}

///|
/// 删除指定文档的投递记录，返回是否真的删除了。
///
/// 索引层删除文档时会遍历该文档出现过的词项并逐个调用本方法；
/// 若某词项在删除后不再有任何文档，索引层会把整个词项从词典中移除。
pub fn PostingList::remove(self : PostingList, doc_id : Int32) -> Bool {
  let mut at = 0
  let count = self.postings.length()
  while at < count {
    if self.postings.unsafe_get(at).doc_id == doc_id {
      let _ = self.postings.remove(at)
      return true
    }
    at = at + 1
  }
  false
}

///|
/// 文档频率（document frequency）：包含该词项的文档数。
///
/// 注意与 `term_freq` 区分：后者是单个文档内的词频。
/// BM25 的 IDF 部分使用的是本方法返回的文档频率。
pub fn PostingList::doc_freq(self : PostingList) -> Int32 {
  self.postings.length()
}

///|
/// 倒排表是否为空（该词项已经没有任何文档）。
pub fn PostingList::is_empty(self : PostingList) -> Bool {
  self.postings.is_empty()
}

///|
/// 按下标读取投递记录，越界返回 `None`。
pub fn PostingList::posting_at(self : PostingList, index : Int32) -> Posting? {
  self.postings.get(index)
}

///|
/// 只读视图，便于查询层直接遍历，而不复制整个数组。
pub fn PostingList::entries(self : PostingList) -> ArrayView[Posting] {
  self.postings[:]
}

///|
/// 该词项在所有文档中的总出现次数，用于统计与调试。
pub fn PostingList::total_freq(self : PostingList) -> Int32 {
  let mut total = 0
  for posting in self.postings {
    total = total + posting.term_freq
  }
  total
}
