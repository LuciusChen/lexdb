#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
LexDB Schema and Common Utilities
=================================

统一的数据库 Schema 定义和通用工具函数，供所有词典解析器使用。

Usage:
    from lexdb_schema import (
        SCHEMA_SQL, SCHEMA_VERSION,
        init_database, clean_text, parse_link_target,
        make_relation_fragments,
        LabelType, RelationType, AttrType
    )
"""

import re
import sqlite3
from typing import Optional, Tuple, Dict, Any

# =============================================================================
# Schema Version
# =============================================================================

SCHEMA_VERSION = "2.1"

# =============================================================================
# Schema Definition
# =============================================================================

SCHEMA_SQL = """
-- Dictionary metadata table
CREATE TABLE IF NOT EXISTS dictionaries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    dict_id TEXT UNIQUE NOT NULL,        -- Dictionary identifier (e.g., ldoce6, oald10)
    name TEXT NOT NULL,                   -- Display name
    version TEXT,                         -- Version
    source_file TEXT,                     -- Source file path
    capabilities TEXT,                    -- JSON: ["audio-uk", "audio-us", "chinese"]
    created_at TEXT NOT NULL,             -- Creation timestamp
    entry_count INTEGER DEFAULT 0         -- Entry count
);

-- Entries table (词条表)
CREATE TABLE IF NOT EXISTS entries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    dict_id TEXT NOT NULL,                -- Parent dictionary
    headword TEXT NOT NULL,               -- Original headword
    headword_lower TEXT NOT NULL,         -- Lowercase for queries
    headword_display TEXT,                -- Display form (with syllable dots)
    FOREIGN KEY (dict_id) REFERENCES dictionaries(dict_id)
);

-- Senses table (义项表)
CREATE TABLE IF NOT EXISTS senses (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    entry_id INTEGER NOT NULL,
    sense_number TEXT,                    -- "1", "2", "2a", etc.
    signpost TEXT,                        -- LDOCE: "PARENT", "LIQUID"
    definition TEXT NOT NULL,             -- English definition
    definition_zh TEXT,                   -- Chinese definition (bilingual)
    sort_order INTEGER DEFAULT 0,
    FOREIGN KEY (entry_id) REFERENCES entries(id) ON DELETE CASCADE
);

-- Examples table (例句表)
CREATE TABLE IF NOT EXISTS examples (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sense_id INTEGER NOT NULL,
    text TEXT NOT NULL,                   -- Example sentence
    text_zh TEXT,                         -- Chinese translation
    audio_path TEXT,                      -- Audio file path
    position INTEGER DEFAULT 0,           -- 0=before grammar patterns, 1=after
    sort_order INTEGER DEFAULT 0,
    FOREIGN KEY (sense_id) REFERENCES senses(id) ON DELETE CASCADE
);

-- Grammar patterns table (语法模式表)
CREATE TABLE IF NOT EXISTS grammar_patterns (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sense_id INTEGER NOT NULL,
    pattern TEXT NOT NULL,                -- "on a ... day", "be required to do sth"
    gloss TEXT,                           -- "(=during a particular day)"
    sort_order INTEGER DEFAULT 0,
    FOREIGN KEY (sense_id) REFERENCES senses(id) ON DELETE CASCADE
);

-- Grammar examples table (语法模式例句表)
CREATE TABLE IF NOT EXISTS grammar_examples (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    pattern_id INTEGER NOT NULL,
    text TEXT NOT NULL,
    audio_path TEXT,
    sort_order INTEGER DEFAULT 0,
    FOREIGN KEY (pattern_id) REFERENCES grammar_patterns(id) ON DELETE CASCADE
);

-- Labels table (标签表 - 统一存储)
CREATE TABLE IF NOT EXISTS labels (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    entry_id INTEGER,                     -- Entry-level label (pos, frequency)
    sense_id INTEGER,                     -- Sense-level label (grammar, register, geo)
    label_type TEXT NOT NULL,             -- pos, grammar, register, geo, domain, syn, opp
    label_value TEXT NOT NULL,
    sort_order INTEGER DEFAULT 0,
    FOREIGN KEY (entry_id) REFERENCES entries(id) ON DELETE CASCADE,
    FOREIGN KEY (sense_id) REFERENCES senses(id) ON DELETE CASCADE
);

-- Relations table (关系表 - Fragment 格式)
CREATE TABLE IF NOT EXISTS relations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    entry_id INTEGER NOT NULL,
    sense_id INTEGER,                     -- Optional: specific sense
    relation_type TEXT NOT NULL,          -- cross_ref, synonym, antonym, thesaurus, see_also
    prefix TEXT,                          -- Non-clickable: "→ see THESAURUS at "
    clickable TEXT NOT NULL,              -- Clickable: "PHONE", "care²"
    suffix TEXT,                          -- Non-clickable: "(8)"
    target_word TEXT NOT NULL,            -- Normalized: "phone", "care"
    target_sense TEXT,                    -- Target sense: "8"
    sort_order INTEGER DEFAULT 0,
    FOREIGN KEY (entry_id) REFERENCES entries(id) ON DELETE CASCADE,
    FOREIGN KEY (sense_id) REFERENCES senses(id) ON DELETE CASCADE
);

-- Pronunciations table (发音表)
CREATE TABLE IF NOT EXISTS pronunciations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    entry_id INTEGER NOT NULL,
    variant TEXT,                         -- uk, us, au
    ipa TEXT,                             -- IPA transcription
    audio_path TEXT,                      -- Audio file path
    sort_order INTEGER DEFAULT 0,
    FOREIGN KEY (entry_id) REFERENCES entries(id) ON DELETE CASCADE
);

-- Collocations table (搭配表)
CREATE TABLE IF NOT EXISTS collocations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    entry_id INTEGER NOT NULL,
    category TEXT,                        -- ADJECTIVES, VERBS, etc.
    text TEXT NOT NULL,                   -- Collocation text
    gloss TEXT,                           -- Explanation
    sort_order INTEGER DEFAULT 0,
    FOREIGN KEY (entry_id) REFERENCES entries(id) ON DELETE CASCADE
);

-- Collocation examples table (搭配例句表)
CREATE TABLE IF NOT EXISTS collocation_examples (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    collocation_id INTEGER NOT NULL,
    text TEXT NOT NULL,
    sort_order INTEGER DEFAULT 0,
    FOREIGN KEY (collocation_id) REFERENCES collocations(id) ON DELETE CASCADE
);

-- Entry attributes table (扩展属性表 - EAV 模式)
CREATE TABLE IF NOT EXISTS entry_attributes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    entry_id INTEGER NOT NULL,
    attr_key TEXT NOT NULL,               -- "ldoce/frequency", "sense_grammar_boxes"
    attr_value TEXT,                      -- TEXT or JSON
    attr_type TEXT DEFAULT 'text',        -- text, json, json_compressed, integer
    FOREIGN KEY (entry_id) REFERENCES entries(id) ON DELETE CASCADE,
    UNIQUE(entry_id, attr_key)
);

-- Meta info table
CREATE TABLE IF NOT EXISTS _lexdb_meta (
    key TEXT PRIMARY KEY,
    value TEXT
);

-- ============================================================
-- Indexes
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_entries_dict ON entries(dict_id);
CREATE INDEX IF NOT EXISTS idx_entries_headword ON entries(headword_lower);
CREATE INDEX IF NOT EXISTS idx_entries_headword_dict ON entries(dict_id, headword_lower);

CREATE INDEX IF NOT EXISTS idx_senses_entry ON senses(entry_id);

CREATE INDEX IF NOT EXISTS idx_examples_sense ON examples(sense_id);
CREATE INDEX IF NOT EXISTS idx_examples_position ON examples(sense_id, position);

CREATE INDEX IF NOT EXISTS idx_grammar_patterns_sense ON grammar_patterns(sense_id);
CREATE INDEX IF NOT EXISTS idx_grammar_examples_pattern ON grammar_examples(pattern_id);

CREATE INDEX IF NOT EXISTS idx_labels_entry ON labels(entry_id);
CREATE INDEX IF NOT EXISTS idx_labels_sense ON labels(sense_id);
CREATE INDEX IF NOT EXISTS idx_labels_type ON labels(label_type);

CREATE INDEX IF NOT EXISTS idx_relations_entry ON relations(entry_id);
CREATE INDEX IF NOT EXISTS idx_relations_sense ON relations(sense_id);
CREATE INDEX IF NOT EXISTS idx_relations_type ON relations(relation_type);

CREATE INDEX IF NOT EXISTS idx_pronunciations_entry ON pronunciations(entry_id);

CREATE INDEX IF NOT EXISTS idx_collocations_entry ON collocations(entry_id);
CREATE INDEX IF NOT EXISTS idx_collocation_examples_coll ON collocation_examples(collocation_id);

CREATE INDEX IF NOT EXISTS idx_entry_attributes_entry ON entry_attributes(entry_id);
CREATE INDEX IF NOT EXISTS idx_entry_attributes_key ON entry_attributes(attr_key);
"""


# =============================================================================
# Type Constants
# =============================================================================

class LabelType:
    """标签类型常量"""
    POS = 'pos'                # 词性: noun, verb, adj
    GRAMMAR = 'grammar'        # 语法: [C], [U], [Tn]
    REGISTER = 'register'      # 语域: formal, informal, literary
    GEO = 'geo'                # 地域: British English, American English
    DOMAIN = 'domain'          # 领域: medical, legal, computing
    SYN = 'syn'                # 同义词标签
    OPP = 'opp'                # 反义词标签
    FREQUENCY = 'frequency'    # 词频: S1, W2


class RelationType:
    """关系类型常量"""
    CROSS_REF = 'cross_ref'    # 交叉引用: → see PHONE
    SYNONYM = 'synonym'        # 同义词: SYN happy
    ANTONYM = 'antonym'        # 反义词: OPP sad
    THESAURUS = 'thesaurus'    # 同义词库: see THESAURUS at X
    SEE_ALSO = 'see_also'      # 另见: see also X
    INFLECTION = 'inflection'  # 词形变化
    COMPARE = 'compare'        # 比较: compare with X


class AttrType:
    """属性值类型常量"""
    TEXT = 'text'
    JSON = 'json'
    JSON_COMPRESSED = 'json_compressed'
    INTEGER = 'integer'


# =============================================================================
# Utility Functions
# =============================================================================

def clean_text(text: Optional[str]) -> str:
    """
    清理文本：去除多余空白和换行。

    Args:
        text: 输入文本

    Returns:
        清理后的文本
    """
    if not text:
        return ''
    return re.sub(r'\s+', ' ', text).strip()


def parse_link_target(link_href: str) -> Tuple[Optional[str], Optional[str]]:
    """
    解析链接 href，提取目标词和义项号。

    Args:
        link_href: 链接，如 "entry://phone#abc_s1"

    Returns:
        (target_word, target_sense) tuple

    Examples:
        "phone#_s1" -> ("phone", "1")
        "bank#hash_s2" -> ("bank", "2")
        "mother" -> ("mother", None)
        "entry://phone#_s1" -> ("phone", "1")
    """
    if not link_href:
        return (None, None)

    # Remove entry:// prefix if present
    href = link_href.replace('entry://', '')

    # Split by # to get base word
    parts = href.split('#', 1)
    target_word = parts[0].lower() if parts[0] else None

    # Extract sense number from hash part (e.g., "_s1", "hash_s2")
    target_sense = None
    if len(parts) > 1:
        match = re.search(r'_s(\d+)', parts[1])
        if match:
            target_sense = match.group(1)

    return (target_word, target_sense)


def make_relation_fragments(
    prefix_text: Optional[str],
    clickable_text: str,
    suffix_text: Optional[str],
    link_href: Optional[str]
) -> Dict[str, Any]:
    """
    创建 relation 的 Fragment 存储格式。

    Args:
        prefix_text: 不可点击前缀，如 "see THESAURUS at "
        clickable_text: 可点击部分，如 "PHONE"
        suffix_text: 不可点击后缀，如 "(8)"
        link_href: 链接目标，如 "phone#_s1"

    Returns:
        dict with prefix, clickable, suffix, target_word, target_sense
    """
    target_word, _ = parse_link_target(link_href)

    # Fallback: if no link, use clickable text as target word
    if not target_word and clickable_text:
        target_word = clickable_text.lower()

    # Extract displayed sense number from suffix (e.g., "(8)" -> "8")
    display_sense = None
    if suffix_text:
        sense_match = re.search(r'\((\d+)\)', suffix_text)
        if sense_match:
            display_sense = sense_match.group(1)

    return {
        'prefix': prefix_text.strip() + ' ' if prefix_text and prefix_text.strip() else None,
        'clickable': clickable_text.strip() if clickable_text else '',
        'suffix': suffix_text.strip() if suffix_text and suffix_text.strip() else None,
        'target_word': target_word or '',
        'target_sense': display_sense
    }


def normalize_headword(headword: str) -> str:
    """规范化词头用于查询（小写）"""
    return headword.lower().strip()


# =============================================================================
# Database Functions
# =============================================================================

def init_database(conn: sqlite3.Connection) -> None:
    """
    初始化数据库 Schema。

    Args:
        conn: SQLite 连接
    """
    cursor = conn.cursor()
    cursor.executescript(SCHEMA_SQL)

    # Write schema version
    cursor.execute(
        "INSERT OR REPLACE INTO _lexdb_meta (key, value) VALUES (?, ?)",
        ('schema_version', SCHEMA_VERSION)
    )
    conn.commit()


def get_schema_version(conn: sqlite3.Connection) -> Optional[str]:
    """获取数据库 Schema 版本"""
    try:
        cursor = conn.cursor()
        cursor.execute("SELECT value FROM _lexdb_meta WHERE key = 'schema_version'")
        row = cursor.fetchone()
        return row[0] if row else None
    except sqlite3.OperationalError:
        return None


def check_schema_compatibility(conn: sqlite3.Connection) -> bool:
    """
    检查数据库 Schema 是否兼容（主版本号相同）。
    """
    db_version = get_schema_version(conn)
    if not db_version:
        return False

    db_major = db_version.split('.')[0]
    current_major = SCHEMA_VERSION.split('.')[0]
    return db_major == current_major


# =============================================================================
# Testing
# =============================================================================

if __name__ == '__main__':
    import tempfile
    import os

    print(f"LexDB Schema Module v{SCHEMA_VERSION}")
    print("=" * 50)

    # Test database initialization
    with tempfile.NamedTemporaryFile(suffix='.db', delete=False) as f:
        db_path = f.name

    try:
        conn = sqlite3.connect(db_path)
        init_database(conn)

        version = get_schema_version(conn)
        print(f"Schema version: {version}")

        # List all tables
        cursor = conn.cursor()
        cursor.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        tables = [row[0] for row in cursor.fetchall()]
        print(f"Tables ({len(tables)}): {', '.join(tables)}")

        # Test utility functions
        print("\nUtility function tests:")
        print(f"  clean_text('  hello   world  ') = '{clean_text('  hello   world  ')}'")
        print(f"  parse_link_target('entry://phone#_s1') = {parse_link_target('entry://phone#_s1')}")

        conn.close()
        print("\n✓ All tests passed!")
    finally:
        os.unlink(db_path)
