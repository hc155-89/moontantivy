// StandardTokenizer / NGramTokenizer 的行为测试。
//
// 覆盖：英文大小写与停用词、标点切分、位置信息、中文逐字与双字切分、
// 全角规范化、空输入、n 取值边界，以及通过 trait 的多态调用。

///|
/// 通过 trait 泛型调用分词器，验证 `Tokenizer` 接口可用。
fn[T : @tokenizer.Tokenizer] collect_terms(
  tokenizer : T,
  text : String,
) -> Array[String] {
  tokenizer.tokenize(text)
}

///|
test "standard_tokenizer_english_lowercase_and_stopwords" {
  let tokenizer = @tokenizer.StandardTokenizer::new()
  let terms = tokenizer.tokenize("The Quick Brown Fox Jumps Over The Lazy Dog")
  // "the" 出现两次都被过滤；其余词全部转小写并保持原顺序。
  let expected : Array[String] = [
    "quick", "brown", "fox", "jumps", "over", "lazy", "dog",
  ]
  assert_eq(terms, expected)
}

///|
test "standard_tokenizer_punctuation" {
  let tokenizer = @tokenizer.StandardTokenizer::new()
  let terms = tokenizer.tokenize(
    "Hello, world! MoonBit-based search engine... v0.1? yes_1",
  )
  // 连字符、逗号、感叹号、省略号、句点、问号都作为分隔符；
  // 下划线是词内字符，因此 "yes_1" 保持完整。
  let expected : Array[String] = [
    "hello", "world", "moonbit", "based", "search", "engine", "v0", "1", "yes_1",
  ]
  assert_eq(terms, expected)
}

///|
test "standard_tokenizer_positions_skip_stopwords_but_keep_slots" {
  let tokenizer = @tokenizer.StandardTokenizer::new()
  let tokens = tokenizer.analyze("The quick brown fox")
  assert_eq(tokens.length(), 3)
  // "the" 被过滤，但仍占用位置 0，因此 quick 从 1 开始。
  assert_eq(tokens.unsafe_get(0).term, "quick")
  assert_eq(tokens.unsafe_get(0).position, 1)
  assert_eq(tokens.unsafe_get(1).position, 2)
  assert_eq(tokens.unsafe_get(2).position, 3)
}

///|
test "standard_tokenizer_chinese_splits_each_char" {
  let tokenizer = @tokenizer.StandardTokenizer::new()
  let terms = tokenizer.tokenize("搜索引擎")
  let expected : Array[String] = ["搜", "索", "引", "擎"]
  assert_eq(terms, expected)
  // 中文标点（全角逗号、句号）必须被当作分隔符。
  let with_punctuation = tokenizer.tokenize("搜索，引擎。测试")
  let expected_punctuation : Array[String] = [
    "搜", "索", "引", "擎", "测", "试",
  ]
  assert_eq(with_punctuation, expected_punctuation)
}

///|
test "ngram_tokenizer_chinese_bigram" {
  let tokenizer = @tokenizer.NGramTokenizer::new()
  let terms = tokenizer.tokenize("我爱自然语言处理")
  let expected : Array[String] = [
    "我爱", "爱自", "自然", "然语", "语言", "言处", "处理",
  ]
  assert_eq(terms, expected)
}

///|
test "ngram_tokenizer_positions_follow_character_offsets" {
  let tokenizer = @tokenizer.NGramTokenizer::new()
  let tokens = tokenizer.analyze("搜索引擎")
  assert_eq(tokens.length(), 3)
  assert_eq(tokens.unsafe_get(0).term, "搜索")
  assert_eq(tokens.unsafe_get(0).position, 0)
  assert_eq(tokens.unsafe_get(1).term, "索引")
  assert_eq(tokens.unsafe_get(1).position, 1)
  assert_eq(tokens.unsafe_get(2).term, "引擎")
  assert_eq(tokens.unsafe_get(2).position, 2)
}

///|
test "ngram_tokenizer_mixed_latin_and_chinese" {
  let tokenizer = @tokenizer.NGramTokenizer::new(n=2)
  let terms = tokenizer.tokenize("MoonBit 搜索")
  let expected : Array[String] = ["mo", "oo", "on", "nb", "bi", "it", "搜索"]
  assert_eq(terms, expected)
}

///|
test "ngram_tokenizer_window_size_edges" {
  // n = 1 退化为逐字切分。
  let unigram = @tokenizer.NGramTokenizer::new(n=1)
  let single : Array[String] = ["搜", "索"]
  assert_eq(unigram.tokenize("搜索"), single)
  // n = 3 时不足长度的片段不产生词项。
  let trigram = @tokenizer.NGramTokenizer::new(n=3)
  let triple : Array[String] = ["abc", "bcd", "cde"]
  assert_eq(trigram.tokenize("abcde"), triple)
  assert_eq(trigram.tokenize("搜索"), [])
  // n <= 0 被夹到 1，行为可预期而不是 panic。
  let invalid = @tokenizer.NGramTokenizer::new(n=0)
  assert_eq(invalid.window_size(), 1)
  assert_eq(invalid.tokenize("ab"), (["a", "b"] : Array[String]))
}

///|
test "tokenizer_empty_and_punctuation_only_input" {
  let standard = @tokenizer.StandardTokenizer::new()
  let ngram = @tokenizer.NGramTokenizer::new()
  let empty : Array[String] = []
  assert_eq(standard.tokenize(""), empty)
  assert_eq(standard.tokenize("   \t\n  "), empty)
  assert_eq(standard.tokenize("，。！？,.!? ---"), empty)
  assert_eq(ngram.tokenize(""), empty)
  assert_eq(ngram.tokenize("，。！？"), empty)
}

///|
test "standard_tokenizer_stopwords_can_be_disabled" {
  let tokenizer = @tokenizer.StandardTokenizer::new(remove_stopwords=false)
  let expected : Array[String] = ["the", "quick", "and", "brown"]
  assert_eq(tokenizer.tokenize("The quick and brown"), expected)
}

///|
test "normalize_fullwidth_characters" {
  // 全角字母转半角并小写，全角空格转为普通空格。
  let tokenizer = @tokenizer.StandardTokenizer::new()
  let terms = tokenizer.tokenize("ＭｏｏｎＢｉｔ　搜索引擎")
  let expected : Array[String] = ["moonbit", "搜", "索", "引", "擎"]
  assert_eq(terms, expected)
  assert_eq(@tokenizer.normalize_char('Ａ'), 'a')
  assert_eq(@tokenizer.normalize_char('Ｚ'), 'z')
  assert_eq(@tokenizer.normalize_char('　'), ' ')
  assert_eq(@tokenizer.normalize_char('Z'), 'z')
}

///|
test "character_classification" {
  assert_true(@tokenizer.is_cjk('搜'))
  assert_true(@tokenizer.is_cjk('あ'))
  assert_true(@tokenizer.is_cjk('한'))
  assert_false(@tokenizer.is_cjk('a'))
  // 带变音符的拉丁字母属于词内字符，不能被拆开。
  assert_true(@tokenizer.is_word_char('é'))
  assert_false(@tokenizer.is_word_char('，'))
  assert_true(@tokenizer.is_word_char('_'))
}

///|
test "tokenizer_trait_dispatch" {
  let english : Array[String] = ["hello", "world"]
  assert_eq(
    collect_terms(@tokenizer.StandardTokenizer::new(), "Hello, World!"),
    english,
  )
  let chinese : Array[String] = ["搜索"]
  assert_eq(
    collect_terms(@tokenizer.NGramTokenizer::new(n=2), "搜索"),
    chinese,
  )
}

///|
test "repeated_terms_keep_distinct_positions" {
  // 索引层依赖位置来计算词频与短语匹配，重复词必须逐个保留。
  let tokenizer = @tokenizer.StandardTokenizer::new()
  let tokens = tokenizer.analyze("go go go")
  assert_eq(tokens.length(), 3)
  assert_eq(tokens.unsafe_get(0).position, 0)
  assert_eq(tokens.unsafe_get(1).position, 1)
  assert_eq(tokens.unsafe_get(2).position, 2)
}
