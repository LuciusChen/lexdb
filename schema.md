# LexDB Schema 规范

本文档定义了 LexDB 词典数据库的标准 Schema。任何词典只要按此规范生成 SQLite 数据库，即可被 LexDB Emacs 客户端无缝使用。

## 概述

LexDB 采用 **"能力感知"** 设计：
- 词典只需填充它拥有的数据，缺失字段留 NULL
- Emacs UI 会自动检测并只渲染存在的内容
- 扩展数据通过 `entry_attributes` 表存储，无需修改 Schema

## 数据库表结构

### 1. `dictionaries` - 词典元信息

```sql
CREATE TABLE dictionaries (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,           -- 词典名称，如 "Longman Dictionary of Contemporary English"
    version TEXT,                 -- 版本，如 "6th Edition"
    description TEXT,             -- 简介
    capabilities TEXT,            -- JSON 数组，声明词典能力
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
```

**capabilities 示例：**
```json
["pronunciation", "audio-uk", "audio-us", "frequency-band", "collocations", "chinese-definition"]
```

### 2. `entries` - 词条主表

```sql
CREATE TABLE entries (
    id INTEGER PRIMARY KEY,
    dict_id INTEGER NOT NULL REFERENCES dictionaries(id),
    headword TEXT NOT NULL,           -- 词头原形，如 "mother"
    headword_lower TEXT NOT NULL,     -- 小写形式，用于查询
    headword_display TEXT,            -- 显示形式（含音节点），如 "moth·er"
    homograph_number INTEGER,         -- 同形异义词编号，如 bank¹, bank²
    pronunciation_uk TEXT,            -- 英式音标，如 "/ˈmʌðə/"
    pronunciation_us TEXT,            -- 美式音标，如 "/ˈmʌðər/"
    audio_uk TEXT,                    -- 英式发音文件路径
    audio_us TEXT,                    -- 美式发音文件路径
    pos TEXT,                         -- 主词性，如 "noun", "verb"
    inflections TEXT,                 -- 变形，如 "mothers, mothered, mothering"
    frequency TEXT,                   -- 词频标记，如 "S1 W1"
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_entries_headword_lower ON entries(headword_lower);
CREATE INDEX idx_entries_dict_id ON entries(dict_id);
```

### 3. `senses` - 义项表

```sql
CREATE TABLE senses (
    id INTEGER PRIMARY KEY,
    entry_id INTEGER NOT NULL REFERENCES entries(id),
    sense_number TEXT,                -- 义项编号，如 "1", "2a"
    pos TEXT,                         -- 该义项的词性（可能与词条不同）
    definition TEXT,                  -- 英文释义
    definition_zh TEXT,               -- 中文释义（双解词典）
    signpost TEXT,                    -- 义项导航词，如 "PARENT", "ORIGIN"
    register TEXT,                    -- 语域标记，如 "formal", "informal", "literary"
    grammar_codes TEXT,               -- 语法代码，如 "[C]", "[U]", "[Tn]"
    domain TEXT,                      -- 学科领域，如 "medical", "legal"
    region TEXT,                      -- 地区标记，如 "BrE", "AmE"
    sort_order INTEGER DEFAULT 0      -- 排序顺序
);

CREATE INDEX idx_senses_entry_id ON senses(entry_id);
```

### 4. `examples` - 例句表

```sql
CREATE TABLE examples (
    id INTEGER PRIMARY KEY,
    sense_id INTEGER NOT NULL REFERENCES senses(id),
    text TEXT NOT NULL,               -- 英文例句
    text_zh TEXT,                     -- 中文翻译
    audio TEXT,                       -- 例句音频路径
    source TEXT,                      -- 来源，如 "corpus", "editorial"
    sort_order INTEGER DEFAULT 0
);

CREATE INDEX idx_examples_sense_id ON examples(sense_id);
```

### 5. `relations` - 关系表（交叉引用、同义词等）

采用片段化存储，将跳转信息原子化，便于渲染。

```sql
CREATE TABLE relations (
    id INTEGER PRIMARY KEY,
    entry_id INTEGER NOT NULL REFERENCES entries(id),
    sense_id INTEGER REFERENCES senses(id),  -- NULL = entry 级别
    relation_type TEXT NOT NULL,      -- cross_ref, synonym, antonym, see_also, inflection
    prefix TEXT,                      -- 前缀文本，如 "see THESAURUS at "
    clickable TEXT NOT NULL,          -- 可点击部分，如 "PHONE"
    suffix TEXT,                      -- 后缀文本，如 " (v.)"
    target_word TEXT NOT NULL,        -- 跳转目标词（规范化），如 "phone"
    target_sense TEXT,                -- 目标义项编号，如 "1"
    sort_order INTEGER DEFAULT 0
);

CREATE INDEX idx_relations_entry_id ON relations(entry_id);
CREATE INDEX idx_relations_sense_id ON relations(sense_id);
CREATE INDEX idx_relations_type ON relations(relation_type);
```

**字段说明：**

| 字段 | 说明 | 示例 |
|------|------|------|
| `prefix` | 不可点击的前缀 | "see THESAURUS at " |
| `clickable` | 可点击部分（显示文本） | "PHONE" |
| `suffix` | 不可点击的后缀 | " (v.)" |
| `target_word` | 跳转目标词（小写规范化） | "phone" |
| `target_sense` | 目标义项（可选） | "1" |

**渲染方式：**
```
[prefix][clickable 按钮][suffix]
→ "see THESAURUS at [PHONE] (v.)"
```

**relation_type 类型：**

| 类型 | 说明 |
|------|------|
| `cross_ref` | 交叉引用（→ see also） |
| `synonym` | 同义词（SYN） |
| `antonym` | 反义词（OPP） |
| `see_also` | 另见 |
| `inflection` | 词形变化 |
| `thesaurus` | 同义词库引用 |

### 6. `entry_attributes` - 扩展属性表（EAV 模式）

这是最灵活的表，用于存储各词典特有的数据。

```sql
CREATE TABLE entry_attributes (
    id INTEGER PRIMARY KEY,
    entry_id INTEGER NOT NULL REFERENCES entries(id),
    attr_key TEXT NOT NULL,           -- 属性键，如 "ldoce/collocations", "oald/idioms"
    attr_value TEXT,                  -- 属性值（字符串或 JSON）
    attr_type TEXT DEFAULT 'text'     -- 类型：text, json, json_compressed
);

CREATE INDEX idx_entry_attributes_entry_id ON entry_attributes(entry_id);
CREATE INDEX idx_entry_attributes_key ON entry_attributes(attr_key);
```

**常用 attr_key 约定：**

| attr_key | 类型 | 说明 |
|----------|------|------|
| `{dict}/idioms` | json_compressed | 习语列表 |
| `{dict}/phrasal_verbs` | json_compressed | 短语动词 |
| `{dict}/collocations` | json_compressed | 搭配 |
| `{dict}/thesaurus` | json_compressed | 同义词 |
| `{dict}/word_family` | json_compressed | 词族 |
| `{dict}/origin` | text | 词源（简短） |
| `{dict}/origin_full` | text | 词源（详细） |
| `{dict}/derivatives` | json_compressed | 派生词 |
| `{dict}/frequency_band` | text | 词频等级 |
| `{dict}/cefr_level` | text | CEFR 等级 (A1-C2) |

### 7. `sense_attributes` - 义项扩展属性表

```sql
CREATE TABLE sense_attributes (
    id INTEGER PRIMARY KEY,
    sense_id INTEGER NOT NULL REFERENCES senses(id),
    attr_key TEXT NOT NULL,
    attr_value TEXT,
    attr_type TEXT DEFAULT 'text'
);

CREATE INDEX idx_sense_attributes_sense_id ON sense_attributes(sense_id);
```

**常用 attr_key：**

| attr_key | 类型 | 说明 |
|----------|------|------|
| `{dict}/lexunits` | json_compressed | 词汇单元（短语用法） |
| `{dict}/grambox` | json_compressed | 语法框 |
| `{dict}/synonyms` | json | 同义词列表 |
| `{dict}/antonyms` | json | 反义词列表 |
| `{dict}/cross_refs` | json | 交叉引用 |

### 8. `lemmas` - 词形还原表（可选）

```sql
CREATE TABLE lemmas (
    id INTEGER PRIMARY KEY,
    dict_id INTEGER NOT NULL REFERENCES dictionaries(id),
    word TEXT NOT NULL,               -- 变形词，如 "mothers", "mothered"
    lemma TEXT NOT NULL               -- 原形，如 "mother"
);

CREATE INDEX idx_lemmas_word ON lemmas(word);
```

---

## JSON 数据结构

### Idioms (习语)

```json
[
  {
    "text": "necessity is the mother of invention",
    "definition": "used to say that when you are in difficulty, you think of clever ways",
    "definition_zh": "需要是发明之母",
    "examples": [
      {"text": "...", "text_zh": "..."}
    ]
  }
]
```

### Phrasal Verbs (短语动词)

```json
[
  {
    "headword": "call back",
    "pos": "phr v",
    "senses": [
      {
        "definition": "to telephone someone again",
        "definition_zh": "回电话",
        "examples": [...]
      }
    ]
  }
]
```

### Collocations (搭配)

```json
[
  {
    "category": "ADJECTIVES",
    "items": [
      {
        "word": "


",
        "gloss": "a mother who is expecting a baby",
        "example": "..."
      }
    ]
  }
]
```

### Thesaurus (同义词)

```json
[
  {
    "sense_hint": "female parent",
    "synonyms": [
      {"word": "mom", "register": "informal"},
      {"word": "mum", "region": "BrE"}
    ],
    "antonyms": [
      {"word": "father"}
    ]
  }
]
```

### Lexunits (词汇单元)

```json
[
  {
    "phrase": "mother of two/three etc",
    "definition": "a mother who has two, three etc children",
    "examples": [...]
  }
]
```

### Grammar Box (语法框)

```json
[
  {
    "heading": "GRAMMAR: Singular or plural verb?",
    "notes": [
      {
        "pattern": "mother + singular verb",
        "text": "Use a singular verb after mother...",
        "example": "My mother is coming.",
        "bad_example": "My mother are coming."
      }
    ]
  }
]
```

---

## 能力声明 (Capabilities)

在 `dictionaries.capabilities` 中声明词典支持的功能：

### 核心能力
| 能力 | 说明 |
|------|------|
| `lookup` | 基础查词 |
| `definition` | 英文释义 |
| `chinese-definition` | 中文释义 |
| `chinese-example` | 中文例句 |

### 语音能力
| 能力 | 说明 |
|------|------|
| `pronunciation` | 音标 |
| `audio-uk` | 英式发音 |
| `audio-us` | 美式发音 |
| `audio-example` | 例句发音 |

### 词汇信息
| 能力 | 说明 |
|------|------|
| `pos` | 词性 |
| `grammar` | 语法标注 |
| `register` | 语域标记 |
| `hyphenation` | 音节划分 |
| `inflections` | 词形变化 |

### 词频信息
| 能力 | 说明 |
|------|------|
| `frequency-band` | 词频等级 (S1/W1) |
| `frequency-rank` | 词频排名 |
| `cefr-level` | CEFR 等级 |

### 扩展内容
| 能力 | 说明 |
|------|------|
| `examples` | 例句 |
| `collocations` | 搭配 |
| `idioms` | 习语 |
| `phrasal-verbs` | 短语动词 |
| `synonyms` | 同义词 |
| `antonyms` | 反义词 |
| `thesaurus` | 词库 |
| `word-family` | 词族 |
| `origin` | 词源 |
| `lemmatization` | 词形还原 |

---

## 压缩存储

对于较大的 JSON 数据（如 collocations、thesaurus），建议使用 zlib 压缩：

```python
import zlib
import json

def compress_json(data):
    json_str = json.dumps(data, ensure_ascii=False)
    return zlib.compress(json_str.encode('utf-8'))

def decompress_json(compressed):
    json_str = zlib.decompress(compressed).decode('utf-8')
    return json.loads(json_str)
```

在 `attr_type` 字段标记为 `json_compressed`。

---

## 最小化示例

一个最简单的词典只需要：

```sql
-- 1. 创建词典
INSERT INTO dictionaries (name, capabilities)
VALUES ('My Dictionary', '["lookup", "definition"]');

-- 2. 添加词条
INSERT INTO entries (dict_id, headword, headword_lower)
VALUES (1, 'hello', 'hello');

-- 3. 添加义项
INSERT INTO senses (entry_id, definition)
VALUES (1, 'used as a greeting');
```

这样就能在 LexDB 中查询和显示了！

---

## 贡献新词典

1. **解析原始数据** - 用任意语言/工具解析 MDX/XML/其他格式
2. **生成 SQLite** - 按本 Schema 创建数据库
3. **声明能力** - 在 `dictionaries.capabilities` 中列出支持的功能
4. **编写 Adapter** - 创建 `lexdb-{dict}.el` 注册到 LexDB

Emacs UI 会自动根据能力和数据渲染，无需修改 UI 代码。

---

## 版本

- Schema Version: 1.0
- Last Updated: 2025-01
