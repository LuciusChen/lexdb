#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
MDX/MDD Dictionary to LexDB SQLite Database Converter

Supports multiple dictionaries in a single database using EAV pattern for extensibility.

Schema Design:
- dictionaries: Dictionary metadata
- entries: Core entries (minimal common fields)
- senses: Definitions
- examples: Example sentences
- labels: Labels (pos, grammar, register, etc. unified storage)
- relations: Relations (phrase, synonym, cross_ref, etc. unified storage)
- pronunciations: Pronunciation info
- collocations: Collocations
- collocation_examples: Collocation examples
- entry_attributes: EAV extension table (dictionary-specific fields)
"""

import sqlite3
import sys
import os
import re
import json
from pathlib import Path
from datetime import datetime
from bs4 import BeautifulSoup, Tag

try:
    from readmdict import MDX, MDD
except ImportError:
    print("Please install dependencies first: pip install readmdict python-lzo beautifulsoup4")
    sys.exit(1)


# ============================================================
# Schema Definition
# ============================================================

SCHEMA_VERSION = "1.0.0"

SCHEMA_SQL = """
-- Dictionary metadata table
CREATE TABLE IF NOT EXISTS dictionaries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    dict_id TEXT UNIQUE NOT NULL,      -- Dictionary identifier (e.g., ldoce, oxford)
    name TEXT NOT NULL,                 -- Display name
    version TEXT,                       -- Version
    source_file TEXT,                   -- Source file
    created_at TEXT NOT NULL,           -- Creation time
    entry_count INTEGER DEFAULT 0       -- Entry count
);

-- Core entries table (minimal common fields)
CREATE TABLE IF NOT EXISTS entries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    dict_id TEXT NOT NULL,              -- Parent dictionary
    headword TEXT NOT NULL,             -- Headword
    headword_lower TEXT NOT NULL,       -- Lowercase form (for queries)
    headword_display TEXT,              -- Display form (e.g., with syllable dots: ap·ple)
    FOREIGN KEY (dict_id) REFERENCES dictionaries(dict_id)
);

-- Senses table
CREATE TABLE IF NOT EXISTS senses (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    entry_id INTEGER NOT NULL,
    sense_number TEXT,                  -- Sense number (1, 2, 2a, etc.)
    signpost TEXT,                      -- Guide word (e.g., "MOVE FROM A FIXED POINT")
    definition TEXT NOT NULL,
    sort_order INTEGER DEFAULT 0,
    FOREIGN KEY (entry_id) REFERENCES entries(id) ON DELETE CASCADE
);

-- Examples table
CREATE TABLE IF NOT EXISTS examples (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sense_id INTEGER NOT NULL,
    text TEXT NOT NULL,
    audio_path TEXT,
    sort_order INTEGER DEFAULT 0,
    FOREIGN KEY (sense_id) REFERENCES senses(id) ON DELETE CASCADE
);

-- Grammar patterns table (e.g., "be required to do something")
CREATE TABLE IF NOT EXISTS grammar_patterns (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sense_id INTEGER NOT NULL,
    pattern TEXT NOT NULL,
    sort_order INTEGER DEFAULT 0,
    FOREIGN KEY (sense_id) REFERENCES senses(id) ON DELETE CASCADE
);

-- Grammar pattern examples table
CREATE TABLE IF NOT EXISTS grammar_examples (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    pattern_id INTEGER NOT NULL,
    text TEXT NOT NULL,
    audio_path TEXT,
    sort_order INTEGER DEFAULT 0,
    FOREIGN KEY (pattern_id) REFERENCES grammar_patterns(id) ON DELETE CASCADE
);

-- Labels table (unified storage for pos, grammar, register, domain, etc.)
CREATE TABLE IF NOT EXISTS labels (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    entry_id INTEGER,                   -- Entry-level label
    sense_id INTEGER,                   -- Sense-level label
    label_type TEXT NOT NULL,           -- Type: pos, grammar, register, domain, region
    label_value TEXT NOT NULL,
    sort_order INTEGER DEFAULT 0,
    FOREIGN KEY (entry_id) REFERENCES entries(id) ON DELETE CASCADE,
    FOREIGN KEY (sense_id) REFERENCES senses(id) ON DELETE CASCADE
);

-- Relations table (unified storage for phrase, synonym, antonym, cross_ref, etc.)
CREATE TABLE IF NOT EXISTS relations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    entry_id INTEGER NOT NULL,
    sense_id INTEGER,                   -- Optional: link to specific sense
    relation_type TEXT NOT NULL,        -- Type: phrase, synonym, antonym, cross_ref, inflection
    target_text TEXT NOT NULL,          -- Display text (e.g., "room1(5)")
    target_link TEXT,                   -- Link target (e.g., "room" extracted from href)
    target_entry_id INTEGER,            -- Target entry ID (if resolvable)
    sort_order INTEGER DEFAULT 0,
    FOREIGN KEY (entry_id) REFERENCES entries(id) ON DELETE CASCADE,
    FOREIGN KEY (sense_id) REFERENCES senses(id) ON DELETE CASCADE
);

-- Pronunciations table
CREATE TABLE IF NOT EXISTS pronunciations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    entry_id INTEGER NOT NULL,
    variant TEXT,                       -- uk, us, au, etc.
    ipa TEXT,                           -- IPA transcription
    audio_path TEXT,
    sort_order INTEGER DEFAULT 0,
    FOREIGN KEY (entry_id) REFERENCES entries(id) ON DELETE CASCADE
);

-- Collocations table
CREATE TABLE IF NOT EXISTS collocations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    entry_id INTEGER NOT NULL,
    category TEXT,                      -- Category: ADJECTIVES, VERBS, etc.
    text TEXT NOT NULL,                 -- Collocation text
    gloss TEXT,                         -- Explanation
    sort_order INTEGER DEFAULT 0,
    FOREIGN KEY (entry_id) REFERENCES entries(id) ON DELETE CASCADE
);

-- Collocation examples table
CREATE TABLE IF NOT EXISTS collocation_examples (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    collocation_id INTEGER NOT NULL,
    text TEXT NOT NULL,
    sort_order INTEGER DEFAULT 0,
    FOREIGN KEY (collocation_id) REFERENCES collocations(id) ON DELETE CASCADE
);

-- EAV extension table (dictionary-specific fields)
CREATE TABLE IF NOT EXISTS entry_attributes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    entry_id INTEGER NOT NULL,
    attr_key TEXT NOT NULL,             -- Namespaced key format, e.g., ldoce/frequency
    attr_value TEXT,                    -- Value (text or JSON)
    attr_type TEXT DEFAULT 'text',      -- Type: text, json, integer, boolean
    FOREIGN KEY (entry_id) REFERENCES entries(id) ON DELETE CASCADE,
    UNIQUE(entry_id, attr_key)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_entries_dict ON entries(dict_id);
CREATE INDEX IF NOT EXISTS idx_entries_headword ON entries(headword_lower);
CREATE INDEX IF NOT EXISTS idx_entries_headword_dict ON entries(dict_id, headword_lower);
CREATE INDEX IF NOT EXISTS idx_senses_entry ON senses(entry_id);
CREATE INDEX IF NOT EXISTS idx_examples_sense ON examples(sense_id);
CREATE INDEX IF NOT EXISTS idx_grammar_patterns_sense ON grammar_patterns(sense_id);
CREATE INDEX IF NOT EXISTS idx_grammar_examples_pattern ON grammar_examples(pattern_id);
CREATE INDEX IF NOT EXISTS idx_labels_entry ON labels(entry_id);
CREATE INDEX IF NOT EXISTS idx_labels_sense ON labels(sense_id);
CREATE INDEX IF NOT EXISTS idx_labels_type ON labels(label_type);
CREATE INDEX IF NOT EXISTS idx_relations_entry ON relations(entry_id);
CREATE INDEX IF NOT EXISTS idx_relations_type ON relations(relation_type);
CREATE INDEX IF NOT EXISTS idx_pronunciations_entry ON pronunciations(entry_id);
CREATE INDEX IF NOT EXISTS idx_collocations_entry ON collocations(entry_id);
CREATE INDEX IF NOT EXISTS idx_collocation_examples_coll ON collocation_examples(collocation_id);
CREATE INDEX IF NOT EXISTS idx_entry_attributes_entry ON entry_attributes(entry_id);
CREATE INDEX IF NOT EXISTS idx_entry_attributes_key ON entry_attributes(attr_key);

-- Meta info table
CREATE TABLE IF NOT EXISTS _lexdb_meta (
    key TEXT PRIMARY KEY,
    value TEXT
);
"""


# ============================================================
# Utility Functions
# ============================================================

def clean_text(text):
    """Clean and normalize text."""
    if not text:
        return ""
    return re.sub(r'\s+', ' ', text).strip()


def parse_hyphenation(element):
    """Parse syllable division, converting hs0 tags to · separators."""
    hyph = element.find(class_='hyphenation')
    if not hyph:
        return ''

    hyph_copy = BeautifulSoup(str(hyph), 'html.parser').find(class_='hyphenation')
    for hs in hyph_copy.find_all(class_=re.compile(r'^hs\d*$')):
        hs.replace_with('·')

    return clean_text(hyph_copy.get_text())


def parse_word_origin(soup):
    """Parse word origin/etymology information."""
    origin = {
        'century': '',
        'language': '',
        'translation': '',
        'full_text': '',
    }

    for atlink in soup.find_all(class_='at-link'):
        popheader = atlink.find(class_='popheader')
        if popheader and 'ORIGIN' in popheader.get_text().upper():
            century = atlink.find(class_='etymcentury')
            if century:
                origin['century'] = clean_text(century.get_text())

            lang = atlink.find(class_='etymlang')
            if lang:
                origin['language'] = clean_text(lang.get_text())

            tran = atlink.find(class_='etymtran')
            if tran:
                origin['translation'] = clean_text(tran.get_text())

            etymsense = atlink.find(class_='etymsense')
            if etymsense:
                origin['full_text'] = clean_text(etymsense.get_text())

            break

    return origin


# ============================================================
# LDOCE Parser
# ============================================================

class LDOCEParser:
    """Longman Dictionary of Contemporary English HTML parser."""

    DICT_ID = "ldoce"
    DICT_NAME = "Longman Dictionary of Contemporary English"

    def parse(self, html, word_key):
        """Parse entry HTML, return list of structured entries (for homographs)."""
        soup = BeautifulSoup(html, 'html.parser')

        # Find all entry divs (for homographs like swing1, swing2)
        entry_divs = soup.find_all(class_='entry')

        # If no entry divs found, treat whole HTML as single entry
        if not entry_divs:
            entry_divs = [soup]

        entries = []
        for entry_div in entry_divs:
            entry = self._parse_single_entry(entry_div, word_key)
            if entry and entry.get('senses'):
                entries.append(entry)

        # If no entries parsed, try parsing as single entry
        if not entries:
            entry = self._parse_single_entry(soup, word_key)
            if entry:
                entries.append(entry)

        return entries

    def _parse_single_entry(self, soup, word_key):
        """Parse a single entry from soup."""
        entry = {
            'headword': '',
            'headword_display': '',
            'senses': [],
            'pronunciations': [],
            'labels': [],           # Entry-level labels
            'relations': [],        # Phrases, synonyms, cross-refs
            'collocations': [],
            'attributes': {},       # Extension attributes (EAV)
        }

        # === Entry header ===
        entryhead = soup.find(class_='entryhead')
        if entryhead:
            # Headword
            hwd = entryhead.find(class_='hwd')
            if hwd:
                entry['headword'] = clean_text(hwd.get_text())

            # Syllable division
            entry['headword_display'] = parse_hyphenation(entryhead)

            # Part of speech
            pos = None
            for child in entryhead.children:
                if isinstance(child, Tag) and 'pos' in (child.get('class') or []):
                    pos = clean_text(child.get_text())
                    break

            # If no pos found, check registerlab (e.g., trademark)
            if not pos:
                for child in entryhead.children:
                    if isinstance(child, Tag) and 'registerlab' in (child.get('class') or []):
                        pos = clean_text(child.get_text())
                        break

            if pos:
                entry['labels'].append({
                    'type': 'pos',
                    'value': pos,
                    'level': 'entry'
                })
                entry['attributes']['pos'] = pos

            # Pronunciation
            pron_codes = entryhead.find(class_='proncodes')
            if pron_codes:
                # British
                pron = pron_codes.find(class_='pron')
                if pron:
                    entry['pronunciations'].append({
                        'variant': 'uk',
                        'ipa': clean_text(pron.get_text()),
                        'audio_path': ''
                    })

                # American
                amevarpron = pron_codes.find(class_='amevarpron')
                if amevarpron:
                    us_text = clean_text(amevarpron.get_text())
                    us_text = us_text.replace('$', '').strip()
                    if us_text:
                        entry['pronunciations'].append({
                            'variant': 'us',
                            'ipa': us_text,
                            'audio_path': ''
                        })

            # Frequency - dots and level are separate
            freq_dots = ''
            freq_level = []
            for child in entryhead.children:
                classes = child.get('class') or [] if isinstance(child, Tag) else []
                if isinstance(child, Tag):
                    # Check for frequency dots (often in tooltip or separate element)
                    if 'tooltip' in classes or 'frequrl' in classes:
                        text = clean_text(child.get_text())
                        # Count filled circles
                        filled = text.count('●')
                        empty = text.count('○')
                        if filled + empty > 0:
                            freq_dots = '●' * filled + '○' * empty
                    # Check for S1/W1 etc level markers
                    if 'freq' in classes:
                        text = clean_text(child.get_text())
                        # Remove dots from text, keep only S1/W1 etc
                        level_text = text.replace('●', '').replace('○', '').strip()
                        if level_text:
                            freq_level.append(level_text)

            # If no explicit dots found, try to extract from freq text
            if not freq_dots and freq_level:
                combined = ' '.join(freq_level)
                filled = combined.count('●')
                empty = combined.count('○')
                if filled + empty > 0:
                    freq_dots = '●' * filled + '○' * empty
                    # Clean the level text
                    freq_level = [combined.replace('●', '').replace('○', '').strip()]

            if freq_dots:
                entry['attributes']['frequency-dots'] = freq_dots
            if freq_level:
                entry['attributes']['frequency'] = ' '.join(freq_level)

            # Inflections (past tense, past participle, plural, etc.)
            for infl in entryhead.find_all(class_='inflections'):
                # Extract full inflection text for display
                infl_full_text = clean_text(infl.get_text())
                if infl_full_text:
                    # Clean up the text (remove extra spaces)
                    infl_full_text = re.sub(r'\s+', ' ', infl_full_text).strip()
                    # Remove surrounding parentheses if present
                    infl_full_text = infl_full_text.strip('()')
                    entry['attributes']['inflections'] = infl_full_text

                # Also extract individual inflection words for linking
                for ptpp in infl.find_all(class_=['ptandpp', 'pastonly', 'pponly', 'plural', 'compar', 'superl', 'prespart', 'past', 'thirdperson']):
                    # Get the inflection word (not the label)
                    infl_word = ''
                    for child in ptpp.children:
                        if isinstance(child, str):
                            text = child.strip()
                            if text:
                                infl_word = text
                                break
                        elif isinstance(child, Tag) and 'infllab' not in (child.get('class') or []):
                            if 'pron' not in (child.get('class') or []) and 'proncodes' not in (child.get('class') or []):
                                text = clean_text(child.get_text())
                                if text:
                                    infl_word = text
                                    break

                    if infl_word:
                        # Check if already added
                        existing = [r for r in entry['relations']
                                   if r['type'] == 'inflection' and r['target'] == infl_word]
                        if not existing:
                            entry['relations'].append({
                                'type': 'inflection',
                                'target': infl_word,
                                'link': infl_word
                            })

        # === Pronunciation audio ===
        for a in soup.find_all('a', href=True):
            href = a.get('href', '')
            if href.startswith('sound://') and '/hwd/' in href:
                path = href.replace('sound://', '')
                if '/bre/' in path:
                    for pron in entry['pronunciations']:
                        if pron['variant'] == 'uk' and not pron['audio_path']:
                            pron['audio_path'] = path
                            break
                    else:
                        entry['pronunciations'].append({
                            'variant': 'uk',
                            'ipa': '',
                            'audio_path': path
                        })
                elif '/ame/' in path:
                    for pron in entry['pronunciations']:
                        if pron['variant'] == 'us' and not pron['audio_path']:
                            pron['audio_path'] = path
                            break
                    else:
                        entry['pronunciations'].append({
                            'variant': 'us',
                            'ipa': '',
                            'audio_path': path
                        })

        # === Word origin ===
        origin = parse_word_origin(soup)
        if origin['century']:
            entry['attributes']['origin_century'] = origin['century']
        if origin['language']:
            entry['attributes']['origin_language'] = origin['language']
        if origin['full_text']:
            entry['attributes']['origin_full'] = origin['full_text']

        # === Register label ===
        register = soup.find(class_='registerlab')
        if register:
            reg_text = clean_text(register.get_text())
            if reg_text:
                entry['attributes']['register'] = reg_text

        # === Senses/Definitions ===
        for idx, sense in enumerate(soup.find_all(class_='sense')):
            sense_data = {
                'number': '',
                'signpost': '',         # Guide word (e.g., "MOVE FROM A FIXED POINT")
                'definition': '',
                'examples': [],
                'labels': [],       # Sense-level labels
                'cross_refs': [],
                'gram_examples': [],  # Grammar pattern examples
            }

            sensenum = sense.find(class_='sensenum')
            if sensenum:
                sense_data['number'] = clean_text(sensenum.get_text())

            # Signpost (guide word in uppercase)
            signpost = sense.find(class_='signpost')
            if signpost:
                sense_data['signpost'] = clean_text(signpost.get_text())

            # Grammar label
            gram = sense.find(class_='gram')
            if gram:
                sense_data['labels'].append({
                    'type': 'grammar',
                    'value': clean_text(gram.get_text())
                })

            # Definition
            defi = sense.find(class_='def')
            if defi:
                sense_data['definition'] = clean_text(defi.get_text())

            # Lexunit prefix
            lexunit = sense.find(class_='lexunit')
            if lexunit:
                prefix = clean_text(lexunit.get_text())
                if prefix and sense_data['definition']:
                    sense_data['definition'] = prefix + ': ' + sense_data['definition']
                elif prefix:
                    sense_data['definition'] = prefix

            # Grammar examples (GramExa with PROPFORM/PROPFORMPREP)
            for gramexa in sense.find_all(class_='gramexa'):
                pattern = ''
                # Try PROPFORM first, then PROPFORMPREP
                propform = gramexa.find(class_='propform')
                if propform:
                    pattern = clean_text(propform.get_text())
                else:
                    propformprep = gramexa.find(class_='propformprep')
                    if propformprep:
                        pattern = clean_text(propformprep.get_text())

                # Get examples within this GramExa
                gram_exs = []
                for ex in gramexa.find_all(class_='example'):
                    ex_text = clean_text(ex.get_text())
                    if ex_text:
                        audio_link = ex.find('a', href=lambda h: h and h.startswith('sound://'))
                        audio_path = ''
                        if audio_link:
                            audio_path = audio_link.get('href', '').replace('sound://', '')
                        gram_exs.append({
                            'text': ex_text,
                            'audio_path': audio_path
                        })

                if pattern:
                    sense_data['gram_examples'].append({
                        'pattern': pattern,
                        'examples': gram_exs
                    })

            # Regular examples (not inside GramExa)
            ex_idx = 0
            for example in sense.find_all(class_='example', recursive=False):
                # Skip if inside a GramExa
                if example.find_parent(class_='gramexa'):
                    continue
                ex_text = clean_text(example.get_text())
                audio_link = example.find('a', href=lambda h: h and h.startswith('sound://'))
                audio_path = ''
                if audio_link:
                    audio_path = audio_link.get('href', '').replace('sound://', '')
                if ex_text:
                    sense_data['examples'].append({
                        'text': ex_text,
                        'audio_path': audio_path,
                        'sort_order': ex_idx
                    })
                    ex_idx += 1

            # Also check for examples that are direct children but might be missed
            for example in sense.find_all(class_='example'):
                # Skip if already in gram_examples or has a gramexa parent
                parent_gramexa = example.find_parent(class_='gramexa')
                if parent_gramexa:
                    continue
                ex_text = clean_text(example.get_text())
                # Check if already added
                if ex_text and not any(e['text'] == ex_text for e in sense_data['examples']):
                    audio_link = example.find('a', href=lambda h: h and h.startswith('sound://'))
                    audio_path = ''
                    if audio_link:
                        audio_path = audio_link.get('href', '').replace('sound://', '')
                    sense_data['examples'].append({
                        'text': ex_text,
                        'audio_path': audio_path,
                        'sort_order': ex_idx
                    })
                    ex_idx += 1

            # Cross references within sense (only with valid links)
            for ref in sense.find_all(class_='refhwd'):
                ref_text = clean_text(ref.get_text())
                if ref_text:
                    # Try to get link target from parent <a> or self
                    link = None
                    if ref.name == 'a' and ref.get('href'):
                        link = ref.get('href')
                    elif ref.parent and ref.parent.name == 'a' and ref.parent.get('href'):
                        link = ref.parent.get('href')
                    # Extract word from entry:// link
                    target_word = None
                    if link and link.startswith('entry://'):
                        target_word = link.replace('entry://', '')
                    # Only add if has a valid link
                    if target_word:
                        sense_data['cross_refs'].append({
                            'text': ref_text,
                            'link': target_word
                        })

            if sense_data['definition']:
                sense_data['sort_order'] = idx
                entry['senses'].append(sense_data)

        # === Phrases ===
        for phrase in soup.find_all(class_='phrase'):
            phrase_text = phrase.find(class_='phrasetext')
            if phrase_text:
                text = clean_text(phrase_text.get_text())
                if text:
                    entry['relations'].append({
                        'type': 'phrase',
                        'target': text,
                        'link': None
                    })

        # === Cross references (only with valid links) ===
        cross_refs_dict = {}  # text -> link

        def extract_ref_link(ref_elem):
            """Extract link target from refhwd element."""
            link = None
            if ref_elem.name == 'a' and ref_elem.get('href'):
                link = ref_elem.get('href')
            elif ref_elem.parent and ref_elem.parent.name == 'a' and ref_elem.parent.get('href'):
                link = ref_elem.parent.get('href')
            if link and link.startswith('entry://'):
                return link.replace('entry://', '')
            return None

        tail = soup.find(class_='tail')
        if tail:
            for ref in tail.find_all(class_='refhwd'):
                ref_text = clean_text(ref.get_text())
                ref_link = extract_ref_link(ref)
                # Only add if has valid link
                if ref_text and ref_link and ref_text not in cross_refs_dict:
                    cross_refs_dict[ref_text] = ref_link

        for crossref in soup.find_all(class_='crossref'):
            for ref in crossref.find_all(class_='refhwd'):
                ref_text = clean_text(ref.get_text())
                ref_link = extract_ref_link(ref)
                # Only add if has valid link
                if ref_text and ref_link and ref_text not in cross_refs_dict:
                    cross_refs_dict[ref_text] = ref_link

        for ref_text, ref_link in cross_refs_dict.items():
            entry['relations'].append({
                'type': 'cross_ref',
                'target': ref_text,
                'link': ref_link
            })

        # === Collocations ===
        collobox = soup.find(class_='collobox')
        if collobox:
            current_category = ''
            coll_order = 0

            for section in collobox.find_all(class_='section'):
                secheading = section.find(class_='secheading')
                if secheading:
                    current_category = clean_text(secheading.get_text())

                for collocate in section.find_all(class_='collocate'):
                    coll_data = {
                        'category': current_category,
                        'text': '',
                        'gloss': '',
                        'examples': [],
                        'sort_order': coll_order
                    }

                    colloc = collocate.find(class_='colloc')
                    if colloc:
                        coll_data['text'] = clean_text(colloc.get_text())

                    collgloss = collocate.find(class_='collgloss')
                    if collgloss:
                        coll_data['gloss'] = clean_text(collgloss.get_text())

                    for ex_idx, example in enumerate(collocate.find_all(class_='example')):
                        ex_text = clean_text(example.get_text())
                        if ex_text:
                            coll_data['examples'].append({
                                'text': ex_text,
                                'sort_order': ex_idx
                            })

                    if coll_data['text']:
                        entry['collocations'].append(coll_data)
                        coll_order += 1

        # === Synonyms ===
        thesobox = soup.find(class_='thesobox')
        if thesobox:
            for relword in thesobox.find_all(class_='relword'):
                word_text = clean_text(relword.get_text())
                if word_text:
                    entry['relations'].append({
                        'type': 'synonym',
                        'target': word_text
                    })

        # Use word_key if headword not parsed
        if not entry['headword']:
            entry['headword'] = word_key

        return entry


# ============================================================
# Database Writer
# ============================================================

class LexDBWriter:
    """LexDB database writer."""

    def __init__(self, db_path, dict_id, dict_name, dict_version=None, source_file=None):
        self.db_path = db_path
        self.dict_id = dict_id
        self.dict_name = dict_name
        self.dict_version = dict_version
        self.source_file = source_file
        self.conn = None
        self.cursor = None
        self.entry_count = 0

    def open(self):
        """Open database connection and initialize schema."""
        self.conn = sqlite3.connect(self.db_path)
        self.cursor = self.conn.cursor()

        # Create schema
        self.cursor.executescript(SCHEMA_SQL)

        # Write schema version
        self.cursor.execute(
            "INSERT OR REPLACE INTO _lexdb_meta (key, value) VALUES (?, ?)",
            ('schema_version', SCHEMA_VERSION)
        )

        # Register dictionary
        self.cursor.execute("""
            INSERT OR REPLACE INTO dictionaries
            (dict_id, name, version, source_file, created_at)
            VALUES (?, ?, ?, ?, ?)
        """, (
            self.dict_id,
            self.dict_name,
            self.dict_version,
            self.source_file,
            datetime.now().isoformat()
        ))

        self.conn.commit()

    def write_entry(self, entry_data):
        """Write a single entry."""
        # Insert entry
        self.cursor.execute("""
            INSERT INTO entries (dict_id, headword, headword_lower, headword_display)
            VALUES (?, ?, ?, ?)
        """, (
            self.dict_id,
            entry_data['headword'],
            entry_data['headword'].lower(),
            entry_data.get('headword_display') or None
        ))
        entry_id = self.cursor.lastrowid

        # Insert pronunciations
        for idx, pron in enumerate(entry_data.get('pronunciations', [])):
            if pron.get('ipa') or pron.get('audio_path'):
                self.cursor.execute("""
                    INSERT INTO pronunciations (entry_id, variant, ipa, audio_path, sort_order)
                    VALUES (?, ?, ?, ?, ?)
                """, (
                    entry_id,
                    pron.get('variant'),
                    pron.get('ipa') or None,
                    pron.get('audio_path') or None,
                    idx
                ))

        # Insert entry-level labels
        for idx, label in enumerate(entry_data.get('labels', [])):
            if label.get('level') == 'entry':
                self.cursor.execute("""
                    INSERT INTO labels (entry_id, sense_id, label_type, label_value, sort_order)
                    VALUES (?, NULL, ?, ?, ?)
                """, (
                    entry_id,
                    label['type'],
                    label['value'],
                    idx
                ))

        # Insert senses
        for sense in entry_data.get('senses', []):
            self.cursor.execute("""
                INSERT INTO senses (entry_id, sense_number, signpost, definition, sort_order)
                VALUES (?, ?, ?, ?, ?)
            """, (
                entry_id,
                sense.get('number') or None,
                sense.get('signpost') or None,
                sense['definition'],
                sense.get('sort_order', 0)
            ))
            sense_id = self.cursor.lastrowid

            # Sense-level labels
            for idx, label in enumerate(sense.get('labels', [])):
                self.cursor.execute("""
                    INSERT INTO labels (entry_id, sense_id, label_type, label_value, sort_order)
                    VALUES (?, ?, ?, ?, ?)
                """, (
                    entry_id,
                    sense_id,
                    label['type'],
                    label['value'],
                    idx
                ))

            # Examples
            for example in sense.get('examples', []):
                self.cursor.execute("""
                    INSERT INTO examples (sense_id, text, audio_path, sort_order)
                    VALUES (?, ?, ?, ?)
                """, (
                    sense_id,
                    example['text'],
                    example.get('audio_path') or None,
                    example.get('sort_order', 0)
                ))

            # Grammar patterns within sense
            for pat_idx, gram_ex in enumerate(sense.get('gram_examples', [])):
                self.cursor.execute("""
                    INSERT INTO grammar_patterns (sense_id, pattern, sort_order)
                    VALUES (?, ?, ?)
                """, (
                    sense_id,
                    gram_ex['pattern'],
                    pat_idx
                ))
                pattern_id = self.cursor.lastrowid

                # Grammar pattern examples
                for ex_idx, ex in enumerate(gram_ex.get('examples', [])):
                    self.cursor.execute("""
                        INSERT INTO grammar_examples (pattern_id, text, audio_path, sort_order)
                        VALUES (?, ?, ?, ?)
                    """, (
                        pattern_id,
                        ex['text'],
                        ex.get('audio_path') or None,
                        ex_idx
                    ))

            # Cross references within sense
            for idx, ref in enumerate(sense.get('cross_refs', [])):
                # Handle both old format (string) and new format (dict)
                if isinstance(ref, str):
                    ref_text, ref_link = ref, None
                else:
                    ref_text = ref.get('text', '')
                    ref_link = ref.get('link')
                if ref_text:
                    self.cursor.execute("""
                        INSERT INTO relations (entry_id, sense_id, relation_type, target_text, target_link, sort_order)
                        VALUES (?, ?, ?, ?, ?, ?)
                    """, (
                        entry_id,
                        sense_id,
                        'cross_ref',
                        ref_text,
                        ref_link,
                        idx
                    ))

        # Insert relations (phrases, synonyms, entry-level cross-refs, inflections)
        for idx, rel in enumerate(entry_data.get('relations', [])):
            self.cursor.execute("""
                INSERT INTO relations (entry_id, sense_id, relation_type, target_text, target_link, sort_order)
                VALUES (?, NULL, ?, ?, ?, ?)
            """, (
                entry_id,
                rel['type'],
                rel['target'],
                rel.get('link'),
                idx
            ))

        # Insert collocations
        for coll in entry_data.get('collocations', []):
            self.cursor.execute("""
                INSERT INTO collocations (entry_id, category, text, gloss, sort_order)
                VALUES (?, ?, ?, ?, ?)
            """, (
                entry_id,
                coll.get('category') or None,
                coll['text'],
                coll.get('gloss') or None,
                coll.get('sort_order', 0)
            ))
            coll_id = self.cursor.lastrowid

            # Collocation examples
            for example in coll.get('examples', []):
                self.cursor.execute("""
                    INSERT INTO collocation_examples (collocation_id, text, sort_order)
                    VALUES (?, ?, ?)
                """, (
                    coll_id,
                    example['text'],
                    example.get('sort_order', 0)
                ))

        # Insert extension attributes (EAV)
        for key, value in entry_data.get('attributes', {}).items():
            if value:
                # Determine type
                if isinstance(value, bool):
                    attr_type = 'boolean'
                    attr_value = '1' if value else '0'
                elif isinstance(value, int):
                    attr_type = 'integer'
                    attr_value = str(value)
                elif isinstance(value, (dict, list)):
                    attr_type = 'json'
                    attr_value = json.dumps(value, ensure_ascii=False)
                else:
                    attr_type = 'text'
                    attr_value = str(value)

                # Use namespaced format
                full_key = f"{self.dict_id}/{key}"

                self.cursor.execute("""
                    INSERT OR REPLACE INTO entry_attributes
                    (entry_id, attr_key, attr_value, attr_type)
                    VALUES (?, ?, ?, ?)
                """, (entry_id, full_key, attr_value, attr_type))

        self.entry_count += 1
        return entry_id

    def commit(self):
        """Commit transaction."""
        if self.conn:
            self.conn.commit()

    def close(self):
        """Close connection and update entry count."""
        if self.conn:
            # Update entry count
            self.cursor.execute("""
                UPDATE dictionaries SET entry_count = ? WHERE dict_id = ?
            """, (self.entry_count, self.dict_id))
            self.conn.commit()
            self.conn.close()
            self.conn = None
            self.cursor = None


# ============================================================
# Main Conversion Function
# ============================================================

def convert_mdx_to_lexdb(mdx_file, db_path=None, extract_audio=False):
    """Convert MDX file to LexDB database."""

    mdx_path = Path(mdx_file)
    if not mdx_path.exists():
        print(f"Error: File not found: {mdx_file}")
        sys.exit(1)

    # Determine database path
    if db_path is None:
        db_path = mdx_path.with_suffix('.db')

    # Remove existing database
    if os.path.exists(db_path):
        print(f"Removing existing database: {db_path}")
        os.remove(db_path)

    print(f"Reading MDX file: {mdx_file}")
    mdx = MDX(str(mdx_file))

    # Extract audio if requested
    audio_dir = None
    if extract_audio:
        mdd_file = mdx_path.with_suffix('.mdd')
        if mdd_file.exists():
            audio_dir = mdx_path.parent / 'audio'
            audio_dir.mkdir(exist_ok=True)
            print(f"Extracting audio to: {audio_dir}")
            mdd = MDD(str(mdd_file))
            for key, data in mdd.items():
                if isinstance(key, bytes):
                    key = key.decode('utf-8', errors='ignore')
                # Normalize path separators: backslash to forward slash, strip leading slash
                key = key.replace('\\', '/').lstrip('/')
                out_path = audio_dir / key
                out_path.parent.mkdir(parents=True, exist_ok=True)
                with open(out_path, 'wb') as f:
                    f.write(data)
            print("Audio extraction complete")
        else:
            print(f"Warning: MDD file not found: {mdd_file}")

    # Create parser and writer
    parser = LDOCEParser()
    writer = LexDBWriter(
        db_path=str(db_path),
        dict_id=parser.DICT_ID,
        dict_name=parser.DICT_NAME,
        dict_version="6th Edition",
        source_file=str(mdx_path.name)
    )

    print(f"Creating database: {db_path}")
    writer.open()

    print("Parsing and importing entries...")
    items = mdx.items()
    count = 0
    success = 0

    for word_key, html in items:
        if isinstance(word_key, bytes):
            word_key = word_key.decode('utf-8', errors='ignore')
        if isinstance(html, bytes):
            html = html.decode('utf-8', errors='ignore')

        count += 1

        try:
            entries = parser.parse(html, word_key)

            # Write all entries (homographs)
            for entry_data in entries:
                if entry_data.get('senses'):
                    writer.write_entry(entry_data)
                    success += 1
        except Exception as e:
            print(f"Warning: Parse failed [{word_key}]: {e}")

        if count % 5000 == 0:
            writer.commit()
            print(f"  Processed {count}, succeeded {success}...")

    writer.close()

    db_size = os.path.getsize(db_path) / (1024 * 1024)

    print(f"""
╔══════════════════════════════════════════════════════════════╗
║  Conversion Complete!
╠══════════════════════════════════════════════════════════════╣
║  Total entries:   {count:>10}
║  Parsed:          {success:>10}
║  Database:        {db_path}
║  Size:            {db_size:.2f} MB
╚══════════════════════════════════════════════════════════════╝

Schema version: {SCHEMA_VERSION}

Tables:
────────────────────────────────────────────────────────────────
dictionaries          Dictionary metadata
entries               Core entries
senses                Definitions
examples              Example sentences
labels                Labels (pos, grammar, register, etc.)
relations             Relations (phrase, synonym, cross_ref, etc.)
pronunciations        Pronunciations
collocations          Collocations
collocation_examples  Collocation examples
entry_attributes      Extension attributes (EAV pattern)
────────────────────────────────────────────────────────────────

Example queries:
────────────────────────────────────────────────────────────────
-- Basic word info
SELECT e.headword, e.headword_display,
       p.ipa, p.variant, p.audio_path
FROM entries e
LEFT JOIN pronunciations p ON e.id = p.entry_id
WHERE e.headword_lower = 'apple' AND e.dict_id = 'ldoce';

-- Definitions and examples
SELECT s.sense_number, s.definition, ex.text as example
FROM entries e
JOIN senses s ON e.id = s.entry_id
LEFT JOIN examples ex ON s.id = ex.sense_id
WHERE e.headword_lower = 'apple' AND e.dict_id = 'ldoce';

-- Extension attributes (frequency, origin, etc.)
SELECT attr_key, attr_value
FROM entry_attributes ea
JOIN entries e ON ea.entry_id = e.id
WHERE e.headword_lower = 'apple' AND e.dict_id = 'ldoce';

-- Labels (pos, grammar)
SELECT l.label_type, l.label_value
FROM labels l
JOIN entries e ON l.entry_id = e.id
WHERE e.headword_lower = 'apple' AND e.dict_id = 'ldoce';
────────────────────────────────────────────────────────────────
""")

    if audio_dir:
        print(f"Audio directory: {audio_dir}")


# ============================================================
# Entry Point
# ============================================================

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("""
Usage:
  python mdx2lexdb.py <mdx_file>
  python mdx2lexdb.py <mdx_file> --extract-audio
  python mdx2lexdb.py <mdx_file> -o <output_db_path>

Examples:
  python mdx2lexdb.py LDOCE6.mdx
  python mdx2lexdb.py LDOCE6.mdx --extract-audio
  python mdx2lexdb.py LDOCE6.mdx -o ~/dicts/ldoce.db
""")
        sys.exit(1)

    mdx_file = sys.argv[1]
    extract_audio = '--extract-audio' in sys.argv

    # Parse output path
    db_path = None
    if '-o' in sys.argv:
        try:
            idx = sys.argv.index('-o')
            db_path = sys.argv[idx + 1]
        except (ValueError, IndexError):
            print("Error: -o requires an output path")
            sys.exit(1)

    convert_mdx_to_lexdb(mdx_file, db_path=db_path, extract_audio=extract_audio)
