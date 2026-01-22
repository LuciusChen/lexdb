# LexDB Schema 规范

本文档定义了 LexDB 词典数据库的标准 Schema。任何词典只要按此规范生成 SQLite 数据库，即可被 LexDB Emacs 客户端无缝使用。

## 概述

LexDB 采用 **"能力感知"** 设计：
- 词典只需填充它拥有的数据，缺失字段留 NULL
- Emacs UI 会自动检测并只渲染存在的内容
- 扩展数据通过 `entry_attributes` 表存储，无需修改 Schema

---

## 表关系总览

```mermaid
erDiagram
    dictionaries ||--o{ entries : contains
    entries ||--o{ senses : has
    entries ||--o{ pronunciations : has
    entries ||--o{ labels : "entry-level"
    entries ||--o{ relations : has
    entries ||--o{ collocations : has
    entries ||--o{ entry_attributes : extends

    senses ||--o{ examples : has
    senses ||--o{ grammar_patterns : has
    senses ||--o{ labels : "sense-level"
    senses ||--o{ relations : "sense-level"

    grammar_patterns ||--o{ grammar_examples : has
    collocations ||--o{ collocation_examples : has
```

---

## 核心表：词条与义项

```mermaid
erDiagram
    entries {
        int id PK
        text dict_id FK
        text headword
        text headword_lower "查询用"
        text headword_display "显示用"
    }

    senses {
        int id PK
        int entry_id FK
        text sense_number "1, 2a"
        text signpost "导航词"
        text plural "复数形式"
        text definition
        text definition_zh "双解"
        int sort_order
    }

    entries ||--o{ senses : has
```

### `entries` - 词条主表

```sql
CREATE TABLE entries (
    id INTEGER PRIMARY KEY,
    dict_id TEXT NOT NULL,           -- 所属词典
    headword TEXT NOT NULL,          -- 词头，如 "mother"
    headword_lower TEXT NOT NULL,    -- 小写形式，用于查询
    headword_display TEXT            -- 显示形式，如 "moth·er"
);

CREATE INDEX idx_entries_headword ON entries(headword_lower);
CREATE INDEX idx_entries_headword_dict ON entries(dict_id, headword_lower);
```

### `senses` - 义项表

```sql
CREATE TABLE senses (
    id INTEGER PRIMARY KEY,
    entry_id INTEGER NOT NULL REFERENCES entries(id),
    sense_number TEXT,               -- 义项编号，如 "1", "2a"
    signpost TEXT,                   -- 导航词，如 "PARENT", "LIQUID"
    plural TEXT,                     -- 复数形式，含格式标记 <<gram>>pl<</gram>> <<l>>词<</l>>
    definition TEXT NOT NULL,        -- 英文释义
    definition_zh TEXT,              -- 中文释义（双解词典）
    sort_order INTEGER DEFAULT 0
);

CREATE INDEX idx_senses_entry ON senses(entry_id);
```

---

## 例句与语法模式

```mermaid
flowchart TB
    subgraph sense["义项 Sense"]
        direction TB
        def[定义 Definition]
        ex0["例句 (position=0)"]
        gp[语法模式]
        gex[语法模式例句]
        ex1["例句 (position=1)"]
    end

    def --> ex0
    ex0 --> gp
    gp --> gex
    gex --> ex1

    style ex0 fill:#e1f5fe
    style ex1 fill:#e1f5fe
    style gp fill:#fff3e0
    style gex fill:#fff3e0
```

### `examples` - 例句表

```sql
CREATE TABLE examples (
    id INTEGER PRIMARY KEY,
    sense_id INTEGER NOT NULL REFERENCES senses(id),
    text TEXT NOT NULL,              -- 英文例句
    text_zh TEXT,                    -- 中文翻译
    audio_path TEXT,                 -- 例句音频路径
    position INTEGER DEFAULT 0,      -- 位置：0=语法模式前，1=语法模式后
    sort_order INTEGER DEFAULT 0
);

CREATE INDEX idx_examples_sense ON examples(sense_id);
CREATE INDEX idx_examples_position ON examples(sense_id, position);
```

**position 字段说明：**

| position | 渲染位置 | 典型用途 |
|----------|----------|----------|
| `0` | grammar_patterns 之前 | 普通例句（默认） |
| `1` | grammar_patterns 之后 | 补充例句 |

### `grammar_patterns` - 语法模式表

```sql
CREATE TABLE grammar_patterns (
    id INTEGER PRIMARY KEY,
    sense_id INTEGER NOT NULL REFERENCES senses(id),
    pattern TEXT NOT NULL,           -- 语法模式，如 "on a ... day"
    gloss TEXT,                      -- 简短解释，如 "(=during a particular day)"
    sort_order INTEGER DEFAULT 0
);
```

### `grammar_examples` - 语法模式例句表

```sql
CREATE TABLE grammar_examples (
    id INTEGER PRIMARY KEY,
    pattern_id INTEGER NOT NULL REFERENCES grammar_patterns(id),
    text TEXT NOT NULL,
    audio_path TEXT,
    sort_order INTEGER DEFAULT 0
);
```

---

## 标签系统

```mermaid
flowchart LR
    subgraph labels["labels 表"]
        direction TB
        entry_labels["词条级 <br/>entry_id ≠ NULL<br/>sense_id = NULL"]
        sense_labels["义项级 <br/>entry_id = NULL<br/>sense_id ≠ NULL"]
    end

    subgraph types["label_type"]
        pos[pos 词性]
        grammar[grammar 语法]
        register[register 语域]
        geo[geo 地域]
        domain[domain 领域]
        syn[syn 同义]
        opp[opp 反义]
        freq[frequency 词频]
    end

    entry_labels --> pos
    entry_labels --> freq
    sense_labels --> grammar
    sense_labels --> register
    sense_labels --> geo
    sense_labels --> syn
    sense_labels --> opp
```

### `labels` - 统一标签表

```sql
CREATE TABLE labels (
    id INTEGER PRIMARY KEY,
    entry_id INTEGER,                -- 词条级标签
    sense_id INTEGER,                -- 义项级标签
    label_type TEXT NOT NULL,        -- 标签类型
    label_value TEXT NOT NULL,       -- 标签值
    sort_order INTEGER DEFAULT 0
);

CREATE INDEX idx_labels_entry ON labels(entry_id);
CREATE INDEX idx_labels_sense ON labels(sense_id);
```

**label_type 枚举：**

| 类型 | 级别 | 说明 | 示例值 |
|------|------|------|--------|
| `pos` | 词条 | 词性 | noun, verb, adjective |
| `grammar` | 义项 | 语法代码 | [C], [U], [Tn], [I] |
| `register` | 义项 | 语域 | formal, informal, literary |
| `geo` | 义项 | 地域 | British English, American English |
| `domain` | 义项 | 领域 | medical, legal, computing |
| `syn` | 义项 | 同义词 | SYN happy |
| `opp` | 义项 | 反义词 | OPP sad |
| `frequency` | 词条 | 词频 | S1, W2 |

---

## 关系与交叉引用

```mermaid
flowchart LR
    subgraph storage["relations 表存储"]
        prefix["prefix<br/>'→ see '"]
        clickable["clickable<br/>'mother'"]
        suffix["suffix<br/>'¹(2)'"]
        target["target_word<br/>'mother'"]
        sense["target_sense<br/>'2'"]
    end

    subgraph render["渲染结果"]
        result["→ see <u>mother</u>¹(2)"]
    end

    prefix --> result
    clickable --> result
    suffix --> result

    style clickable fill:#bbdefb
    style result fill:#c8e6c9
```

### `relations` - 关系表（Fragment 格式）

```sql
CREATE TABLE relations (
    id INTEGER PRIMARY KEY,
    entry_id INTEGER NOT NULL REFERENCES entries(id),
    sense_id INTEGER,                -- NULL = 词条级别
    relation_type TEXT NOT NULL,     -- 关系类型
    prefix TEXT,                     -- 不可点击前缀
    clickable TEXT NOT NULL,         -- 可点击部分
    suffix TEXT,                     -- 不可点击后缀
    target_word TEXT NOT NULL,       -- 跳转目标词（规范化）
    target_sense TEXT,               -- 目标义项编号
    sort_order INTEGER DEFAULT 0
);
```

**渲染示例：**

| 原文 | prefix | clickable | suffix | target_word | target_sense |
|------|--------|-----------|--------|-------------|--------------|
| `→ for all sb cares at care²(8)` | `→ for all sb cares at ` | `care²` | `(8)` | `care` | `8` |
| `SYN happy` | `SYN ` | `happy` | | `happy` | |

**relation_type 枚举：**

| 类型 | 说明 |
|------|------|
| `cross_ref` | 交叉引用 → see X |
| `synonym` | 同义词 SYN |
| `antonym` | 反义词 OPP |
| `thesaurus` | 同义词库引用 |
| `see_also` | 另见 |
| `inflection` | 词形变化 |
| `compare` | 比较 |

---

## 发音与音频

```mermaid
erDiagram
    entries ||--o{ pronunciations : has

    pronunciations {
        int id PK
        int entry_id FK
        text variant "uk/us/au"
        text ipa "音标"
        text audio_path "音频路径"
    }
```

### `pronunciations` - 发音表

```sql
CREATE TABLE pronunciations (
    id INTEGER PRIMARY KEY,
    entry_id INTEGER NOT NULL REFERENCES entries(id),
    variant TEXT,                    -- uk, us, au
    ipa TEXT,                        -- IPA 音标
    audio_path TEXT,                 -- 音频文件路径
    sort_order INTEGER DEFAULT 0
);
```

---

## 搭配 (Collocations)

```mermaid
erDiagram
    entries ||--o{ collocations : has
    collocations ||--o{ collocation_examples : has

    collocations {
        int id PK
        int entry_id FK
        text category "ADJECTIVES/VERBS"
        text text "搭配词"
        text gloss "解释"
    }

    collocation_examples {
        int id PK
        int collocation_id FK
        text text "例句"
    }
```

### `collocations` - 搭配表

```sql
CREATE TABLE collocations (
    id INTEGER PRIMARY KEY,
    entry_id INTEGER NOT NULL REFERENCES entries(id),
    category TEXT,                   -- 搭配类别，如 "ADJECTIVES", "VERBS"
    text TEXT NOT NULL,              -- 搭配文本
    gloss TEXT,                      -- 解释
    sort_order INTEGER DEFAULT 0
);
```

### `collocation_examples` - 搭配例句表

```sql
CREATE TABLE collocation_examples (
    id INTEGER PRIMARY KEY,
    collocation_id INTEGER NOT NULL REFERENCES collocations(id),
    text TEXT NOT NULL,
    sort_order INTEGER DEFAULT 0
);
```

---

## 扩展属性 (EAV 模式)

```mermaid
flowchart TB
    subgraph entry_attributes["entry_attributes 表"]
        direction LR
        key["attr_key"]
        value["attr_value"]
        type["attr_type"]
    end

    subgraph entry_level["词条级属性"]
        idioms["idioms (json)"]
        phrasal["phrasal_verbs (json)"]
        grammar_box["entry_grammar_boxes (json)"]
        runons["runons (json)"]
    end

    subgraph sense_level["义项级属性 (以 sense_number 索引)"]
        sense_grammar["sense_grammar_boxes"]
        sense_register["sense_register_boxes"]
        sense_prefix["sense_lexunit_prefixes"]
        sense_lexunits["sense_lexunits"]
    end

    entry_attributes --> entry_level
    entry_attributes --> sense_level
```

### `entry_attributes` - 扩展属性表

```sql
CREATE TABLE entry_attributes (
    id INTEGER PRIMARY KEY,
    entry_id INTEGER NOT NULL REFERENCES entries(id),
    attr_key TEXT NOT NULL,          -- 属性键
    attr_value TEXT,                 -- 属性值（TEXT 或 JSON）
    attr_type TEXT DEFAULT 'text',   -- 类型提示
    UNIQUE(entry_id, attr_key)
);
```

**attr_type 枚举：**

| 类型 | 说明 |
|------|------|
| `text` | 纯文本 |
| `json` | JSON 格式 |
| `json_compressed` | zlib 压缩的 JSON |
| `integer` | 整数 |

### 常用 attr_key

**词条级：**

| attr_key | 类型 | 说明 |
|----------|------|------|
| `ldoce/frequency` | text | 词频 "S1 W2" |
| `ldoce/homograph` | text | 同形词号 |
| `ldoce/runons` | json | 派生词（如 relevantly adverb） |
| `oald4/usage` | json | 用法说明 NOTE OF USAGE |
| `oald/idioms` | json | OALD 习语列表 |
| `oald/phrasal-verbs` | json | OALD 短语动词 (PHR V) |
| `idioms` | json | 习语列表（通用） |
| `phrasal_verbs` | json | 短语动词（通用） |
| `entry_grammar_boxes` | json | 词条级语法框 |

**义项级（以 sense_number 为 key 的 JSON 对象）：**

| attr_key | 说明 |
|----------|------|
| `sense_grammar_boxes` | `{"1": {...}, "2": {...}}` |
| `sense_register_boxes` | 语域框 |
| `sense_lexunit_prefixes` | 词组前缀（含地域变体） |
| `sense_lexunits` | 词组用法 |

---

## JSON 数据结构示例

### sense_lexunit_prefixes（词组 + 地域变体）

```json
{
  "7": [
    {"type": "lexunit", "text": "all round"},
    {"type": "geo", "text": "British English"},
    {"type": "lexvar", "text": "all around"},
    {"type": "geo", "text": "American English"}
  ]
}
```

渲染：`all round British English, all around American English`

### idioms（习语）

习语支持两种结构：单定义和多子义项。

**单定义习语：**

```json
[
  {
    "text": "necessity is the mother of invention",
    "definition": "used to say that when you are in difficulty...",
    "definition_zh": "需要是发明之母",
    "labels": [
      {"type": "register", "value": "fml"}
    ],
    "examples": [
      {"text": "...", "text_zh": "..."}
    ]
  }
]
```

**带交叉引用的习语：**

```json
{
  "text": "one's (elders and) betters",
  "definition": "= one's betters",
  "crossref": {
    "prefix": "→ ",
    "clickable": "better³",
    "target_word": "better"
  }
}
```

**多子义项习语（如 "part company"）：**

```json
{
  "text": "part company (with sb)",
  "senses": [
    {
      "number": "1",
      "definition": "to leave sb; to end a relationship with sb",
      "definition_zh": "与某人分手",
      "examples": [
        {
          "text": "We parted company at the bus stop.",
          "text_zh": "我们在公共汽车站分手。",
          "label": "joc"
        }
      ]
    },
    {
      "number": "2",
      "definition": "to disagree with sb about sth",
      "definition_zh": "与某人意见不合",
      "examples": [
        {
          "text": "I'm afraid I have to part company with you on that point.",
          "text_zh": "恐怕在那一点上我不能同意你的意见。",
          "label": "fig"
        }
      ]
    }
  ]
}
```

**字段说明：**

| 字段 | 说明 |
|------|------|
| `text` | 习语文本 |
| `definition` | 释义（单定义时） |
| `definition_zh` | 中文释义 |
| `labels` | 语域标签数组 `[{type, value}]` |
| `examples` | 例句数组 |
| `examples[].label` | 例句语域标签（如 `joc`, `fig`） |
| `senses` | 子义项数组（多义项时） |
| `senses[].number` | 子义项编号 |
| `crossref` | 交叉引用结构 |
| `crossref.prefix` | 前缀（如 `→ `） |
| `crossref.clickable` | 可点击文本 |
| `crossref.target_word` | 跳转目标词（规范化） |

### usage（用法说明）

OALD4 特有的 "NOTE OF USAGE 用法" 结构，支持嵌套层级。

```json
[
  {
    "text": "<<l>>Old<</l>> and <<l>>


<</l>> are both used...",
    "text_zh": "Old 和 elder 都可用于...",
    "examples": [
      {
        "text": "He is <<ex>>older<</ex>> than me.",
        "text_zh": "他比我年龄大。"
      }
    ],
    "children": [
      {
        "text": "<<l>>Elderly<</l>> is a polite word for <<l>>old<</l>>...",
        "text_zh": "Elderly 是 old 的委婉说法...",
        "examples": [...]
      }
    ]
  }
]
```

**字段说明：**

| 字段 | 说明 |
|------|------|
| `text` | 说明文本，支持格式标记 |
| `text_zh` | 中文翻译 |
| `examples` | 例句数组 |
| `children` | 嵌套子项（递归结构） |

**格式标记：**

| 标记 | 说明 |
|------|------|
| `<<l>>...<</l>>` | 高亮词汇（蓝色粗体） |
| `<<ex>>...<</ex>>` | 例句中高亮词（斜体） |

### phrasal-verbs（短语动词）

OALD4 的 "PHR V 动词短语" 结构。

```json
[
  {
    "headword": "part with sth",
    "senses": [
      {
        "definition": "give away or relinquish sth",
        "definition_zh": "放弃或出让某物",
        "examples": [
          {
            "text": "Despite his poverty, he refused to part with the family jewels.",
            "text_zh": "他尽管贫穷，却不肯变卖家中的珠宝。"
          },
          {
            "text": "He hates parting with <<ie>>(=spending)<</ie>> his money.",
            "text_zh": "他很不喜欢花钱。"
          }
        ]
      }
    ]
  }
]
```

**字段说明：**

| 字段 | 说明 |
|------|------|
| `headword` | 短语动词文本 |
| `senses` | 义项数组 |
| `senses[].definition` | 英文释义 |
| `senses[].definition_zh` | 中文释义 |
| `senses[].examples` | 例句数组 |

### runons（派生词）

```json
[
  {
    "word": "relevantly",
    "pos": "adverb"
  }
]
```

**说明：** 词条末尾的派生词（run-on entries），如 "—relevantly adverb"。

### sense_grammar_boxes（语法框）

```json
{
  "1": {
    "heading": "GRAMMAR: Patterns with all",
    "notes": [
      {
        "text": "You use all the or all of the before...",
        "expr": "all the, all of the",
        "examples": ["All the students passed."],
        "bad_example": "All of students..."
      }
    ]
  }
}
```

---

## 渲染顺序

```mermaid
flowchart TB
    subgraph sense_render["义项渲染顺序"]
        n1["1. sense_number 义项编号"]
        n2["2. 🌐 翻译指示器"]
        n3["3. signpost 导航词"]
        n4["4. grammar labels [C][U]"]
        n5["5. lexunit_prefix 词组前缀"]
        n6["6. register/geo labels"]
        n7["7. definition 释义"]
        n8["8. syn/opp labels"]
        n9["9. examples (position=0)"]
        n10["10. grammar_patterns + gloss"]
        n11["11. grammar_examples"]
        n12["12. examples (position=1)"]
        n13["13. subsenses/grammar_box/lexunits"]
    end

    n1 --> n2 --> n3 --> n4 --> n5 --> n6 --> n7 --> n8 --> n9 --> n10 --> n11 --> n12 --> n13
```

**视觉效果：**

```
1 🌐 PARENT [C] a female parent of a child or animal SYN mom
  🔊🌐 The mother of three young children
  [on a ... day] (=during a particular day)
    🔊 On a clear day you can see the mountains.
  🌐 She became a mother at 18.
```

---

## 元信息表

### `dictionaries` - 词典元信息

```sql
CREATE TABLE dictionaries (
    id INTEGER PRIMARY KEY,
    dict_id TEXT UNIQUE NOT NULL,    -- 词典标识 "ldoce6"
    name TEXT NOT NULL,              -- 词典名称
    version TEXT,
    source_file TEXT,
    capabilities TEXT,               -- JSON 数组
    created_at TEXT,
    entry_count INTEGER DEFAULT 0
);
```

### `_lexdb_meta` - Schema 元信息

```sql
CREATE TABLE _lexdb_meta (
    key TEXT PRIMARY KEY,
    value TEXT
);

-- 必须包含：
INSERT INTO _lexdb_meta VALUES ('schema_version', '2.1');
```

---

## 能力声明

在 `dictionaries.capabilities` 中声明词典支持的功能（JSON 数组）：

```json
["pronunciation", "audio-uk", "audio-us", "frequency-band", "collocations", "chinese-definition", "chinese-example"]
```

| 能力 | 说明 |
|------|------|
| `lookup` | 基础查词 |
| `definition` | 英文释义 |
| `chinese-definition` | 中文释义 |
| `chinese-example` | 例句中文翻译 |
| `pronunciation` | 音标 |
| `audio-uk` / `audio-us` | 英/美式发音 |
| `audio-example` | 例句音频 |
| `examples` | 例句 |
| `collocations` | 搭配 |
| `idioms` | 习语 |
| `phrasal-verbs` | 短语动词 |
| `thesaurus` | 同义词库 |
| `frequency-band` | 词频等级 |
| `signpost` | 导航词 |
| `grammar-box` | 语法框 |
| `register-box` | 语域框 |
| `usage-notes` | 用法说明 (OALD4) |

---

## 同一数据的不同存储位置

某些数据类型（如 geo）可能出现在不同上下文：

```mermaid
flowchart LR
    geo["geo 地域标签"]

    geo --> labels_sense["labels 表 <br/> 义项独立标签 <br/>'British English'"]
    geo --> lexunit_prefix["entry_attributes<br/>sense_lexunit_prefixes<br/>'all round British English'"]
    geo --> labels_entry["labels 表 <br/> 词条级标签"]

    style labels_sense fill:#e3f2fd
    style lexunit_prefix fill:#fff3e0
    style labels_entry fill:#f3e5f5
```

---

## Emacs Lisp 适配器架构

LexDB Emacs 客户端使用统一的适配器架构来支持多词典。

### 核心模块 (lexdb.el)

#### 数据库连接管理

```elisp
;; 统一的数据库连接池
(defvar lexdb--database-connections (make-hash-table :test 'eq))
(defvar lexdb--query-caches (make-hash-table :test 'eq))

;; 公共 API
(lexdb-db-ensure adapter-id db-file)   ; 确保连接打开
(lexdb-db-get adapter-id)              ; 获取连接
(lexdb-db-close adapter-id)            ; 关闭连接并清空缓存

;; 缓存 API
(lexdb-db-cache-get adapter-id key)    ; 获取缓存
(lexdb-db-cache-put adapter-id key value) ; 设置缓存
```

#### 共享数据处理函数

```elisp
;; JSON 解压（用于 json.gz 类型的 attr_value）
(lexdb--decompress-json-value compressed-data)

;; 发音构建（从标准 pronunciations 表）
(lexdb--build-pronunciations-from-db entry-id db)

;; 词形还原
(lexdb--find-lemma-with-lookup word lookup-fn)
```

### 适配器实现模式

每个词典适配器（如 `lexdb-ode.el`、`lexdb-oald.el`、`lexdb-ldoce.el`）遵循统一模式：

```elisp
;; 1. 数据库连接 - 使用共享模块
(defun lexdb-{dict}--ensure-db ()
  (lexdb-db-ensure '{dict} lexdb-{dict}-db-file))

(defun lexdb-{dict}--close ()
  (lexdb-db-close '{dict}))

;; 2. 数据处理 - 使用共享函数
(defalias 'lexdb-{dict}--decompress-json #'lexdb--decompress-json-value)
(defalias 'lexdb-{dict}--build-pronunciations #'lexdb--build-pronunciations-from-db)

;; 3. 查询 - 适配器特定逻辑
(defun lexdb-{dict}--lookup (word) ...)
(defun lexdb-{dict}--row-to-entry (row) ...)

;; 4. 注册
(lexdb-register-adapter-type '{dict} #'lexdb-{dict}--register-from-config)
```

### 能力与元数据

适配器通过 `lexdb-adapter-create` 声明能力：

```elisp
(lexdb-adapter-create
 :id 'ode
 :name "Oxford Dictionary of English"
 :capabilities '(lookup definition pronunciation
                 pos grammar register domain examples
                 phrases origin lemmatization
                 audio-uk audio-us)
 :db-file lexdb-ode-db-file
 :lookup-fn #'lexdb-ode--lookup
 :close-fn #'lexdb-ode--close
 :lemma-fn #'lexdb-ode--find-lemma)
```

---
