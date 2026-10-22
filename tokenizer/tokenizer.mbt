// tokenizer 包：文本规范化与分词。
//
// 规划能力（Phase 2 实现）：
// - normalize：全角转半角、大小写折叠、标点处理
// - tokenize：ASCII 单词切分 + CJK 双字切分（bigram）
// - 停用词过滤
// - 输出词项及其在原文中的位置，供短语查询使用
