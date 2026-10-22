# moontantivy 项目申报书

## 基本信息

| 项目 | 内容 |
| --- | --- |
| 项目名称 | **moontantivy**：MoonBit 原生嵌入式全文搜索引擎 |
| 参赛者 | 黄才 |
| 联系方式 | 1558929138@qq.com |
| GitHub 仓库 | <https://github.com/hc155-89/moontantivy> |
| 项目方向 | MoonBit 基础库 / 信息检索基础设施 / WASM 可嵌入组件 |
| 是否移植项目 | 否。原创项目，仅参考 Tantivy 的架构思想，未移植任何源码 |
| 开源许可证 | Apache License 2.0（仓库内 `LICENSE`） |

## 项目简介

moontantivy 是一个用 MoonBit 从零实现的嵌入式全文检索引擎。它提供与 Lucene / Tantivy 同类的核心检索能力：倒排索引、位置级短语匹配、布尔查询、BM25 相关度排序、索引持久化，以及一个只暴露必要概念的 `SearchEngine` 门面。

项目的目标不是做一个"演示级"的关键词匹配器，而是在 MoonBit 现有语言能力下交付一个**可嵌入、可持久化、行为可预测**的检索内核：

- **纯 MoonBit 实现**：核心检索逻辑不依赖任何 C / Rust 绑定，已通过 `wasm-gc` 目标编译验证（native 目标需本地 MSVC 工具链），适合沙箱与边缘环境；
- **位置级倒排表**：倒排记录保留词项的精确位置，短语查询不是字符串 `contains`，而是真正的位置连续性验证；
- **可解释的评分**：BM25 采用 Lucene 的平滑 IDF，参数 `k1` / `b` 可配置，排序结果稳定可复现；
- **确定性持久化**：同一份索引多次导出的 JSON 字节完全一致，并带版本号与完整性校验；
- **工程化边界处理**：查询语法错误有精确类型与可读消息，解析深度有硬上限，损坏的索引文件会被拒绝而不是产生半个索引。

当前仓库包含 19 个 `.mbt` 文件、3469 行代码（源码 2223 行、测试 1246 行），**56 个测试全部通过**，`moon check` 无错误与警告。

## 项目方向与通用性说明

本项目属于 **MoonBit 基础库 / 基础设施** 方向，通用性体现在四个方面：

1. **与运行时解耦**：核心库不假设宿主是浏览器、Node、CLI 还是服务端；文件持久化通过官方 `moonbitlang/x/fs` 完成，其余逻辑全部是纯计算；已验证 `wasm-gc` 目标，native 目标需要本地 MSVC 工具链。
2. **与业务解耦**：只依赖"文档 = id + 标题 + 正文"这一最小模型，不绑定商品、日志、文章等具体领域；调用方可在上层自行映射字段。
3. **API 面收敛**：对外只暴露 `Document` 与 `SearchEngine`，调用方不需要理解倒排表、分词器、评分公式；需要换分词策略或调 BM25 参数时再显式打开。
4. **可组合**：每个子包（tokenizer / index / query / score / storage）都可以单独使用：只需要分词可以做 `StandardTokenizer`，只需要评分可以把 `score` 包与 `index` 包组合使用。

## 预期使用场景

### 场景一：静态文档站 / 博客的站内搜索

- **输入**：一批 Markdown 文章（标题 + 正文）。
- **流程**：构建期用 `SearchEngine` 批量 `add_document`，`save` 成单文件 `index_data.json`，与站点静态资源一起发布；浏览器端加载 WASM 模块后，通过 `fetch` 取回 JSON 文本并调用 `SearchEngine::from_json` 恢复索引，无需可写文件系统。
- **输出**：用户输入 `"inverted index"` 或 `moonbit AND NOT rust` 时，前端直接得到按 BM25 排序的 Top-K 结果（含 `doc_id`、`title`、`score`），无需部署搜索服务。
- **价值**：零后端成本、不依赖外部搜索服务，索引随站点版本一起做 diff 与缓存。

### 场景二：桌面笔记 / 本地日志分析工具

- **输入**：本地笔记、构建日志、应用日志，持续增量产生。
- **流程**：工具启动时从磁盘 `load` 已有索引；新日志以 `add_document` 写入，过期条目以 `remove_document` 删除；退出或定时 `save` 回磁盘。
- **输出**：支持 `error AND NOT timeout` 这类精确排除、`"connection refused"` 这类短语定位，以及按相关度排序的最近问题列表。
- **价值**：单文件索引便于备份与迁移；确定性 JSON 输出让"索引是否被改坏"可以靠 diff 判断。

### 场景三：Serverless / 边缘函数中的轻量检索

- **输入**：随函数包一起部署的索引文件 + 用户查询串。
- **流程**：冷启动时读取单文件并完成纯内存反序列化（不依赖数据库连接），随后在请求内完成解析、召回、评分与截断。
- **输出**：单次请求内完成解析、召回、评分与截断，返回结构固定，便于直接序列化成 HTTP 响应。
- **价值**：没有原生动态库依赖，天然适配 WASM 沙箱；索引加载与检索都在进程内以纯内存计算完成，无需部署和运维外部搜索服务。

### 场景四：检索原理的教学与研究参考

- **输入**：想理解倒排索引、BM25、递归下降解析的学生或工程师。
- **流程**：按 `tokenizer -> index -> score -> query -> storage -> api` 的顺序阅读，每个模块都有完整注释与针对性测试；`moon run example` 可一步跑通完整生命周期。
- **输出**：一份可运行、可修改的 3400 行级参考实现，而不是伪代码。
- **价值**：填补 MoonBit 生态在信息检索方向上的空白，可作为后续项目的起点。

## 核心功能（当前已实现）

| 能力 | 说明 | 所在包 |
| --- | --- | --- |
| 文档模型 | `Document { id, title, content }`，标题与正文拼接后统一索引，空字段自动省略 | 根包 |
| 通用分词 | ASCII 小写化、全角转半角、标点切分、33 词英文停用词过滤、CJK 逐字切分 | `tokenizer` |
| N-gram 分词 | 可配置 n 的滑窗切分，面向中文与模糊匹配场景 | `tokenizer` |
| 倒排索引 | 位置级 `PostingList`，按 `doc_id` 有序插入，支持词频、文档频率、位置查询 | `index` |
| 更新与删除 | 同 ID 重复写入按更新处理；删除时只遍历该文档的词项，词项无人使用则回收 | `index` |
| BM25 评分 | Lucene 平滑 IDF + 词频饱和 + 文档长度归一化，`k1` / `b` 可配置 | `score` |
| 查询解析 | 递归下降 AST，支持 `AND` / `OR` / `NOT`、括号、隐式 AND、短语、大小写不敏感 | `query` |
| 查询执行 | 交集 / 并集 / 补集全部基于有序 `doc_id` 双指针归并；短语用位置二分验证 | `query` |
| 索引持久化 | 带版本号的 JSON 快照，支持保存、加载、完整性校验 | `storage` |
| 统一门面 | `SearchEngine`：建索引、检索、Top-K、保存、加载、删除 | `api` |
| 可运行示例 | `moon run example` 演示建索引 → 检索 → 保存 → 重载 → 结果比对 | `example` |

## 快速开始

```bash
moon check          # 类型检查，无错误与警告
moon test           # 56 个测试
moon run example    # 完整生命周期演示
```

```moonbit
let engine = @api.SearchEngine::new()
engine.add_document(@moontantivy.Document::new(
  1, "MoonBit Search Engine", "moonbit inverted index search engine",
))
engine.add_document(@moontantivy.Document::new(
  2, "Rust Ownership", "rust ownership borrow checker memory safety",
))

// 布尔 + 短语 + 排除，返回按 BM25 得分降序的前 10 条
for hit in engine.search("moonbit AND \"inverted index\"", 10) {
  println("doc=\{hit.doc_id} score=\{hit.score} \{hit.title}")
}

engine.save("index_data.json")
let reopened = @api.SearchEngine::load("index_data.json")
let hits = reopened.search("rust OR moonbit", 5)

// 浏览器 / 边缘场景：不落盘，直接在内存中序列化与恢复
let text = engine.to_json()
let from_text = @api.SearchEngine::from_json(text)
```

### 运行验证

三条命令的当前实际输出：

```text
$ moon check
Finished. moon: no work to do

$ moon test
Total tests: 56, passed: 56, failed: 0.

$ moon run example
[2/5] 执行检索
  并集: wasm OR webassembly (Top 5)
    #1  score=2.0312  doc=5  WebAssembly Runtime
    #2  score=0.6392  doc=4  Rust and Wasm
    #3  score=0.4527  doc=1  MoonBit Language
    #4  score=0.4121  doc=6  MoonBit vs Rust
[4/5] 保存索引到 index_data.json
  写入成功，JSON 大小 7734 字节
[5/5] 从磁盘重新加载并再次检索
  恢复文档数：6
  持久化验证通过：加载后的结果与内存中完全一致
```

## 关键局部改进

以下改进不是对参考实现的机械搬运，而是针对 MoonBit 的语言特性与 WASM 运行环境重新设计后形成的实际贡献，也是本项目区别于"关键词匹配 Demo"的核心依据。

### 1. 错误定位：让每一类失败都可被程序识别

检索链路上的错误被拆成**可判定的类型**，而不是统一返回一个字符串或直接 panic：

- `query.ParseError` 区分 7 种语法问题：`EmptyQuery`、`EmptyPhrase`、`UnterminatedPhrase`、`UnbalancedParenthesis`、`MissingOperand`、`TrailingToken`、`TooDeep`，每种都配有 `message()` 给出可直接展示给用户的中文描述。
- `storage.StorageError` 区分 5 种失败语义：`IoFailure`（携带底层信息）、`MalformedJson`（语法不合法）、`SchemaMismatch`（结构不符）、`UnsupportedVersion`（版本不兼容）、`CorruptIndex`（统计值自相矛盾）。
- `api.SearchEngine::search` 对非法查询**返回空结果而不是抛异常**，保证 UI 层不会因用户误输入而中断；需要区分错误时仍可直接调用 `parse_query` 拿到具体变体。

这种分层让调用方可以按错误类型做不同处理（提示补全括号 / 提示重新导入文件 / 提示升级格式），而不是只能整体判失败。

### 2. 深度限制：把递归解析的栈风险挡在入口

递归下降解析器的调用栈深度与查询嵌套层级成正比。恶意或误生成的 `((((…))))`、`NOT NOT NOT …` 可以直接把 WASM 线程栈撑爆，这类输入在真实服务中属于可利用的稳定性风险。

本项目的处理：

- 引入 `MAX_QUERY_DEPTH = 64`，在 `parse_or`（括号会递归回这一层）与 `parse_not`（连续 NOT 递归）两处统一计数；
- 深度计数在**所有返回路径**上都会复原，成功与失败都不会污染后续解析；
- 超限时返回 `ParseError::TooDeep`，错误消息为"查询嵌套层级过深"，不会崩溃也不会吞掉错误；
- 测试覆盖边界两侧：60 层嵌套正常解析，200 层括号与 200 个连续 NOT 都被明确拒绝。

### 3. 确定性持久化：让索引文件可 diff、可校验

普通序列化直接遍历哈希表，输出顺序随实现变化，导致同一索引每次导出的字节不同。本项目做了三项约束：

- 文档按 `doc_id` 升序、词项按字典序输出，保证同一索引多次保存**字节完全一致**（有专门测试验证"保存 → 读取 → 再保存"结果相同）；
- 词频不单独存储，由 `positions` 数组长度推导，消除两份数据不同步的可能；
- 加载时校验 `token_count` 与文档长度之和一致，并检查 `version`，被手工篡改或跨版本的文件会被 `CorruptIndex` / `UnsupportedVersion` 拒绝。

### 4. 停用词位置空洞：短语语义不被过滤器破坏

停用词被丢弃时仍然占用一个位置编号，例如 `the quick brown` 中 `quick=1`、`brown=2`。这样 `"quick brown"` 的短语判定在过滤前后保持一致，不会因为过滤器把两个词"挤到一起"而产生误命中。

### 5. 查询执行：全部使用有序数组的线性归并与二分

- `AND` / `OR` / `NOT` 分别对应交集、并集、差集，输入输出都保持 `doc_id` 升序，双指针一次扫描完成，不引入额外哈希集合；
- 短语匹配以第一个词项的每个出现位置为锚点，其余词项用**位置数组二分**验证，避免在大文档上线性扫描；
- 倒排表按 `doc_id` 有序插入，查询侧可以直接按序归并。

### 6. 零 FFI 的检索引擎内核

除官方 `moonbitlang/x/fs` 提供文件读写外，分词、索引、评分、解析、序列化全部由 MoonBit 标准库完成，不包含任何 C / Rust 绑定；核心逻辑可以在 WASM 沙箱中独立运行。

## 与参考项目的关系

| 项目 | 内容 |
| --- | --- |
| 参考项目名称 | Tantivy |
| 来源链接 | <https://github.com/quickwit-oss/tantivy> |
| 参考项目许可证 | Apache License 2.0 |
| 本项目许可证 | Apache License 2.0 |

说明：

- 本项目为 **原创 MoonBit 实现**，不是 Tantivy 的移植；没有复制或翻译 Tantivy 的 Rust 源码，也没有引入其任何依赖。
- 借鉴的是公开的架构思想：位置级倒排索引、BM25 评分、布尔 / 短语查询的分层设计。
- 差异点：Tantivy 以段（segment）合并与磁盘索引为核心，本项目面向**小到中等规模、单文件、可嵌入**的场景，刻意省略段合并与 mmap，把复杂度集中在查询正确性、错误处理与持久化确定性上。

## 工程质量

### 测试分布

| 包 | 测试数 | 关注点 |
| --- | ---: | --- |
| 根包 `document_test.mbt` | 3 | 文档模型与文本拼接边界 |
| `tokenizer` | 14 | 英文 / 标点 / 中文 / 全角 / 停用词 / n-gram |
| `index` | 8 | 词频、位置、更新、删除、统计 |
| `score` | 6 | IDF、长度归一化、参数影响、边界 |
| `query` | 11 | 优先级、隐式 AND、规范化、语法错误、深度限制、集合语义 |
| `storage` | 9 | 往返一致、确定性、空索引、损坏文件、版本、可继续修改、字符串往返 |
| `api` | 5 | 端到端 Top-K、非法输入、更新语义、参数影响、JSON 文本往返 |

合计 **56 个测试**，`moon test` 全部通过。

### 目录结构

```text
moontantivy/
├── document.mbt            文档模型（根包，被所有子包共享）
├── tokenizer/              规范化和两种分词器
├── index/                  倒排表与索引（含持久化支撑 API）
├── score/                  BM25
├── query/                  查询 AST、解析器、执行器
├── storage/                JSON 快照的保存与加载
├── api/                    SearchEngine 门面 + 端到端测试
├── example/                moon run example 可执行演示
└── LICENSE                 Apache License 2.0
```

### 提交记录

仓库包含 **10 次交付性提交**（初始化、核心实现与可运行示例），另有申报书与验证记录的文档修订；完整历史见 `git log`。每个交付性提交都对应可运行的状态（`moon check` 与 `moon test` 均通过）：

| # | Commit | 内容 |
| ---: | --- | --- |
| 1 | `50ad62e` | chore: init moontantivy project structure |
| 2 | `9097a71` | feat: implement core data structures and tokenizer |
| 3 | `6c0ca88` | feat: implement in-memory inverted index with posting lists |
| 4 | `6c6fa8d` | feat: implement BM25 scoring algorithm |
| 5 | `fac1ab6` | feat: implement query parser and boolean/phrase search |
| 6 | `c8c3b56` | feat: implement index persistence using JSON serialization |
| 7 | `30f60e3` | feat: unify API surface and add e2e integration tests |
| 8 | `fbabe3e` | docs: add runnable example demonstrating full lifecycle |
| 9 | `50d0e2d` | feat: guard query parser against excessive nesting depth |
| 10 | `2276678` | feat: support in-memory JSON serialization for browser and edge runtimes |

文档修订提交（如 `df5e465` 申报书初稿、`00bcab1` 更正验证输出与错误类型数量、`90b64f7` 对齐已核实能力）不计入上述交付性提交，但同样保持文档与代码一致。

## 后续规划

1. **段合并与增量索引**：当前删除依赖 `doc_terms` 反向表即时清理；文档量进一步增大后可引入分段与后台合并，降低写入抖动。
2. **字段级权重**：标题与正文使用不同的 BM25 权重（当前拼接后统一索引）。
3. **查询能力扩展**：前缀查询、通配符、模糊匹配（可复用现有 N-gram 分词器）。
4. **存储压缩**：JSON 便于审查与 diff，后续可为位置数组引入变长编码，降低索引体积。
5. **并发读**：在保持单写模型的前提下，为只读查询提供多实例共享的只读视图。
