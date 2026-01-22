#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
MDX/MDD Dictionary to LexDB SQLite Database Converter (LDOCE)

Supports multiple dictionaries in a single database using EAV pattern for extensibility.
Uses unified schema from lexdb_common module.
"""

import sqlite3
import sys
import os
import re
import json
from pathlib import Path
from datetime import datetime
from bs4 import BeautifulSoup, Tag
import time

try:
    from readmdict import MDX, MDD
except ImportError:
    print("Please install dependencies first: pip install readmdict python-lzo beautifulsoup4")
    sys.exit(1)

# Try to use lxml for faster parsing, fallback to html.parser
try:
    import lxml
    HTML_PARSER = 'lxml'
except ImportError:
    HTML_PARSER = 'html.parser'
    print("Note: Install lxml for faster parsing: pip install lxml")

# Import unified common module
from lexdb_common import (
    SCHEMA_SQL,
    SCHEMA_VERSION,
    init_database,
    clean_text,
    parse_link_target,
    make_relation_fragments,
    LabelType,
    RelationType,
    AttrType
)


# ============================================================
# LDOCE-specific Utility Functions
# ============================================================

def extract_highlighted_text(element):
    """Extract text with highlight markers for nodeword and colloinexa.

    Returns text with special markers:
    - <<hw>>word<</hw>> for nodeword (highlighted word in example)
    - <<co>>phrase<</co>> for colloinexa (collocation highlight)
    """
    if not element:
        return ""

    # Make a copy to avoid modifying original
    elem_copy = BeautifulSoup(str(element), HTML_PARSER)

    # Replace nodeword with markers
    for nodeword in elem_copy.find_all(class_='nodeword'):
        text = nodeword.get_text()
        nodeword.replace_with(f'<<hw>>{text}<</hw>>')

    # Replace colloinexa with markers
    for collo in elem_copy.find_all(class_='colloinexa'):
        text = collo.get_text()
        collo.replace_with(f'<<co>>{text}<</co>>')

    return clean_text(elem_copy.get_text())


def parse_hyphenation(element):
    """Parse syllable division, converting hs0 tags to · separators."""
    hyph = element.find(class_='hyphenation')
    if not hyph:
        return ''

    hyph_copy = BeautifulSoup(str(hyph), HTML_PARSER).find(class_='hyphenation')
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
        soup = BeautifulSoup(html, HTML_PARSER)

        # Find all entry divs (for homographs like swing1, swing2)
        # Exclude entries inside popups (at-link) - they are nested entries for Word Origin, Examples, etc.
        entry_divs = []
        for entry_elem in soup.find_all(class_='entry'):
            # Skip if inside a popup (at-link)
            if entry_elem.find_parent(class_='at-link'):
                continue
            entry_divs.append(entry_elem)

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

            # Homograph number (e.g., call1, call2)
            homnum = entryhead.find(class_='homnum')
            if homnum:
                num = clean_text(homnum.get_text())
                if num:
                    entry['attributes']['homnum'] = num
                    # Append to headword for display
                    entry['headword'] = entry['headword'] + num

            # Syllable division
            entry['headword_display'] = parse_hyphenation(entryhead)
            # If we have homnum, append it to display too
            if entry['attributes'].get('homnum'):
                entry['headword_display'] = entry['headword_display'] + entry['attributes']['homnum']

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
                                   if r['type'] == 'inflection' and r.get('clickable') == infl_word]
                        if not existing:
                            fragments = make_relation_fragments('', infl_word, '', infl_word)
                            entry['relations'].append({
                                'type': 'inflection',
                                **fragments
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
        # Only get senses that are NOT inside phrasal verb entries
        for idx, sense in enumerate(soup.find_all(class_='sense')):
            # Skip senses inside phrasal verb entries
            if sense.find_parent(class_='phrvbentry'):
                continue

            sense_data = {
                'number': '',
                'signpost': '',         # Guide word (e.g., "MOVE FROM A FIXED POINT")
                'definition': '',
                'examples': [],
                'labels': [],       # Sense-level labels
                'cross_refs': [],
                'gram_examples': [],  # Grammar pattern examples
                'subsenses': [],    # Sub-senses (a, b, c)
            }

            # Get the direct sensenum (not from subsense)
            sensenum = sense.find(class_='sensenum', recursive=False)
            if not sensenum:
                # Try finding first sensenum that's not inside a subsense
                for sn in sense.find_all(class_='sensenum'):
                    if not sn.find_parent(class_='subsense'):
                        sensenum = sn
                        break
            if sensenum:
                num_text = clean_text(sensenum.get_text())
                # Only use if it's a main sense number (digit), not a/b/c
                if num_text and (num_text.isdigit() or not num_text.rstrip(')').isalpha()):
                    sense_data['number'] = num_text

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

            # Register and geographic labels - parse in HTML order
            # registerlab (e.g., "formal", "old-fashioned") and geo (e.g., "British English")
            # These should appear in their original order in the dictionary
            # Note: geo labels that are part of lexunit+variant pattern are handled separately
            lexunit_elem = sense.find(class_='lexunit', recursive=False)
            if not lexunit_elem:
                for lu in sense.find_all(class_='lexunit'):
                    if not lu.find_parent(class_='subsense'):
                        lexunit_elem = lu
                        break

            for child in sense.children:
                if not hasattr(child, 'get'):
                    continue
                classes = child.get('class') or []

                if 'registerlab' in classes:
                    reg_text = clean_text(child.get_text())
                    if reg_text:
                        sense_data['labels'].append({
                            'type': 'register',
                            'value': reg_text
                        })
                elif 'geo' in classes:
                    # Skip if inside amequiv (will be handled separately)
                    if child.find_parent(class_='amequiv'):
                        continue
                    # Skip if inside variant (handled in lexunit_prefix)
                    if child.find_parent(class_='variant'):
                        continue
                    # Skip if this geo directly follows lexunit (handled in lexunit_prefix)
                    if lexunit_elem:
                        prev_sib = child.find_previous_sibling()
                        if prev_sib and prev_sib == lexunit_elem:
                            continue
                    geo_text = clean_text(child.get_text())
                    if geo_text:
                        sense_data['labels'].append({
                            'type': 'geo',
                            'value': geo_text
                        })

            # American English equivalent (e.g., "SYN stuff American English")
            # Structure: <span class="amequiv"><span class="synopp">SYN</span> stuff <span class="geo">American English</span></span>
            for amequiv in sense.find_all(class_='amequiv'):
                synopp = amequiv.find(class_='synopp')
                geo = amequiv.find(class_='geo')
                if synopp:
                    # Get the synonym word (text content minus synopp and geo)
                    full_text = clean_text(amequiv.get_text())
                    synopp_text = clean_text(synopp.get_text())
                    geo_text = clean_text(geo.get_text()) if geo else ''

                    # Extract just the word
                    syn_word = full_text.replace(synopp_text, '').replace(geo_text, '').strip()

                    if syn_word:
                        # Format: "SYN stuff American English"
                        label_value = syn_word
                        if geo_text:
                            label_value = f"{syn_word} {geo_text}"
                        sense_data['labels'].append({
                            'type': 'syn',
                            'value': label_value
                        })

            # Check for subsenses first
            subsenses = sense.find_all(class_='subsense')
            if subsenses:
                # Has subsenses - parse each one
                # First get the main definition (def or lexunit)
                defi = sense.find(class_='def', recursive=False)
                if not defi:
                    # Try finding def that's not inside a subsense
                    for d in sense.find_all(class_='def'):
                        if not d.find_parent(class_='subsense'):
                            defi = d
                            break
                if defi:
                    sense_data['definition'] = clean_text(defi.get_text())

                # Also check for lexunit that applies to all subsenses
                lexunit = sense.find(class_='lexunit', recursive=False)
                if not lexunit:
                    for lu in sense.find_all(class_='lexunit'):
                        if not lu.find_parent(class_='subsense'):
                            lexunit = lu
                            break

                lexunit_text = clean_text(lexunit.get_text()) if lexunit else ''

                # Get geo label that directly follows lexunit
                lexunit_geo = ''
                if lexunit:
                    next_sib = lexunit.find_next_sibling()
                    if next_sib and 'geo' in (next_sib.get('class') or []):
                        lexunit_geo = clean_text(next_sib.get_text())

                # Variant (e.g., ", all around American English")
                variant = sense.find(class_='variant', recursive=False)
                if not variant:
                    for v in sense.find_all(class_='variant'):
                        if not v.find_parent(class_='subsense'):
                            variant = v
                            break

                variant_lexvar = ''
                variant_geo = ''
                if variant:
                    lexvar = variant.find(class_='lexvar')
                    var_geo = variant.find(class_='geo')
                    if lexvar:
                        variant_lexvar = clean_text(lexvar.get_text())
                    if var_geo:
                        variant_geo = clean_text(var_geo.get_text())

                # Build lexunit_prefix as structured list for proper rendering
                # Format: [{'type': 'lexunit'/'geo', 'text': '...'}, ...]
                prefix_parts = []
                if lexunit_text:
                    prefix_parts.append({'type': 'lexunit', 'text': lexunit_text})
                if lexunit_geo:
                    prefix_parts.append({'type': 'geo', 'text': lexunit_geo})
                if variant_lexvar:
                    prefix_parts.append({'type': 'lexvar', 'text': variant_lexvar})
                if variant_geo:
                    prefix_parts.append({'type': 'geo', 'text': variant_geo})

                if prefix_parts:
                    sense_data['lexunit_prefix'] = prefix_parts

                for subsense in subsenses:
                    sub_data = {
                        'number': '',
                        'definition': '',
                        'labels': [],
                        'examples': []
                    }

                    # Subsense number (a, b, c)
                    sub_num = subsense.find(class_='sensenum')
                    if sub_num:
                        sub_data['number'] = clean_text(sub_num.get_text())

                    # Subsense definition
                    sub_def = subsense.find(class_='def')
                    if sub_def:
                        sub_data['definition'] = clean_text(sub_def.get_text())

                    # Subsense labels
                    for reg in subsense.find_all(class_='registerlab'):
                        reg_text = clean_text(reg.get_text())
                        if reg_text:
                            sub_data['labels'].append({'type': 'register', 'value': reg_text})

                    # Subsense grammar label
                    sub_gram = subsense.find(class_='gram')
                    if sub_gram:
                        sub_data['labels'].append({'type': 'grammar', 'value': clean_text(sub_gram.get_text())})

                    # Subsense examples
                    for ex in subsense.find_all(class_='example'):
                        ex_text = clean_text(ex.get_text())
                        if ex_text:
                            audio_link = ex.find('a', href=lambda h: h and h.startswith('sound://'))
                            audio_path = ''
                            if audio_link:
                                audio_path = audio_link.get('href', '').replace('sound://', '')
                            sub_data['examples'].append({
                                'text': ex_text,
                                'audio_path': audio_path
                            })

                    if sub_data['definition']:
                        sense_data['subsenses'].append(sub_data)

                # When there are subsenses, don't set a main definition
                # The lexunit_prefix will show the main phrase, subsenses have their own definitions
            else:
                # No subsenses - regular definition parsing
                defi = sense.find(class_='def')
                if defi:
                    sense_data['definition'] = clean_text(defi.get_text())

                # Fullform for abbreviations (e.g., "CALL" -> "computer-assisted language learning")
                fullform = sense.find(class_='fullform')
                if fullform:
                    fullform_text = clean_text(fullform.get_text())
                    if fullform_text:
                        if sense_data['definition']:
                            sense_data['definition'] = fullform_text + ' ' + sense_data['definition']
                        else:
                            sense_data['definition'] = fullform_text

                # Lexunit prefix (e.g., "from day to day")
                lexunit = sense.find(class_='lexunit', recursive=False)
                if not lexunit:
                    # Try finding lexunit that's not inside a subsense
                    for lu in sense.find_all(class_='lexunit'):
                        if not lu.find_parent(class_='subsense'):
                            lexunit = lu
                            break

                lexunit_text = ''
                if lexunit:
                    lexunit_text = clean_text(lexunit.get_text())

                # Get geo label that directly follows lexunit (not inside variant or amequiv)
                # Structure: <span class="lexunit">all round</span><span class="geo">British English</span>
                lexunit_geo = ''
                if lexunit:
                    next_sib = lexunit.find_next_sibling()
                    if next_sib and 'geo' in (next_sib.get('class') or []):
                        lexunit_geo = clean_text(next_sib.get_text())

                # Variant (e.g., ", all around American English")
                # Structure: <span class="variant"><span class="neutral">,</span><span class="lexvar">all around</span><span class="geo">American English</span></span>
                variant = sense.find(class_='variant', recursive=False)
                if not variant:
                    for v in sense.find_all(class_='variant'):
                        if not v.find_parent(class_='subsense'):
                            variant = v
                            break

                variant_lexvar = ''
                variant_geo = ''
                if variant:
                    lexvar = variant.find(class_='lexvar')
                    var_geo = variant.find(class_='geo')
                    if lexvar:
                        variant_lexvar = clean_text(lexvar.get_text())
                    if var_geo:
                        variant_geo = clean_text(var_geo.get_text())

                # Build lexunit_prefix as structured list for proper rendering
                # Format: [{'type': 'lexunit'/'geo'/'lexvar', 'text': '...'}, ...]
                prefix_parts = []
                if lexunit_text:
                    prefix_parts.append({'type': 'lexunit', 'text': lexunit_text})
                if lexunit_geo:
                    prefix_parts.append({'type': 'geo', 'text': lexunit_geo})
                if variant_lexvar:
                    prefix_parts.append({'type': 'lexvar', 'text': variant_lexvar})
                if variant_geo:
                    prefix_parts.append({'type': 'geo', 'text': variant_geo})

                if prefix_parts:
                    sense_data['lexunit_prefix'] = prefix_parts
                # definition stays as-is (just the def text)

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

                # Get gloss (short explanation like "(=during a particular day)")
                gloss = gramexa.find(class_='gloss')
                gloss_text = clean_text(gloss.get_text()) if gloss else ''

                # Get examples within this GramExa
                gram_exs = []
                for ex in gramexa.find_all(class_='example'):
                    ex_text = extract_highlighted_text(ex)
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
                        'gloss': gloss_text,
                        'examples': gram_exs
                    })

            # Parse examples and gramexa in HTML order
            # We need to preserve the order: some examples come before gramexa, some after
            # Strategy: iterate through direct children in order
            # Position: 0 = before any gramexa, 1 = after gramexa
            ex_idx = 0
            has_seen_gramexa = False
            processed_examples = set()

            for child in sense.children:
                if not hasattr(child, 'get'):
                    continue
                classes = child.get('class') or []

                if 'gramexa' in classes:
                    has_seen_gramexa = True
                    continue

                if 'example' in classes:
                    # Skip if inside special containers
                    if child.find_parent(class_='gramexa'):
                        continue
                    if child.find_parent(class_='grambox'):
                        continue
                    if child.find_parent(class_='colloexa'):
                        continue
                    if child.find_parent(class_='f2nbox'):
                        continue
                    if child.find_parent(class_='subsense'):
                        continue

                    ex_text = extract_highlighted_text(child)
                    if ex_text and ex_text not in processed_examples:
                        processed_examples.add(ex_text)
                        audio_link = child.find('a', href=lambda h: h and h.startswith('sound://'))
                        audio_path = ''
                        if audio_link:
                            audio_path = audio_link.get('href', '').replace('sound://', '')
                        sense_data['examples'].append({
                            'text': ex_text,
                            'audio_path': audio_path,
                            'position': 1 if has_seen_gramexa else 0,
                            'sort_order': ex_idx
                        })
                        ex_idx += 1

            # Cross references within sense - use fragment format
            # Structure in LDOCE:
            # Type 1: <span class="crossref">
            #   <span class="neutral">→</span>
            #   <a href="..."><span class="refhwd">word</span></a>
            # </span>
            # Type 2: <span class="crossref">
            #   <span class="reflex">see THESAURUS at</span>
            #   <a href="..."><span class="refhwd">THING</span></a>
            # </span>
            for crossref in sense.find_all(class_='crossref'):
                children = list(crossref.children)
                i = 0
                current_prefix = ''

                while i < len(children):
                    child = children[i]

                    # Check for neutral span with arrow (standalone → at start)
                    if hasattr(child, 'get') and 'neutral' in (child.get('class') or []):
                        text = clean_text(child.get_text())
                        if '→' in text or text:  # Capture any neutral text as prefix
                            current_prefix = text
                        i += 1
                        continue

                    # Check for reflex span (contains "→", "see THESAURUS at", etc.)
                    if hasattr(child, 'get') and 'reflex' in (child.get('class') or []):
                        reflex_text = clean_text(child.get_text())
                        # Remove leading comma and space (separator from previous ref)
                        reflex_text = re.sub(r'^,\s*', '', reflex_text)
                        current_prefix = reflex_text
                        i += 1
                        continue

                    # Check for any other span that might contain prefix text (like "see THESAURUS at")
                    if hasattr(child, 'name') and child.name == 'span' and child.name != 'a':
                        classes = child.get('class') or []
                        # Skip refhwd as it's the clickable part
                        if 'refhwd' not in classes and 'refhomnum' not in classes and 'refsensenum' not in classes:
                            text = clean_text(child.get_text())
                            if text:
                                current_prefix = current_prefix + ' ' + text if current_prefix else text
                        i += 1
                        continue

                    # Check for <a> tag (the actual link)
                    if hasattr(child, 'name') and child.name == 'a':
                        href = child.get('href', '')

                        # Extract clickable text from refhwd
                        # Note: refhwd may contain <span class="neutral">at</span> - keep it as part of clickable
                        refhwd = child.find(class_='refhwd')
                        clickable_text = ''
                        if refhwd:
                            clickable_text = clean_text(refhwd.get_text())

                        # Get homnum (homograph number) - append to clickable for "care2" -> "care²"
                        # Get sensenum as suffix "(8)"
                        homnum = child.find(class_='refhomnum')
                        sensenum = child.find(class_='refsensenum')

                        # Append homnum to clickable text (e.g., "care" + "2" = "care2")
                        if homnum:
                            homnum_text = clean_text(homnum.get_text())
                            if homnum_text:
                                clickable_text = clickable_text + homnum_text

                        # Only sensenum goes to suffix
                        suffix_text = clean_text(sensenum.get_text()) if sensenum else ''

                        # Extract displayed sense number from refsensenum (e.g., "(8)" -> "8")
                        # This is what the user sees and should jump to
                        display_sense = None
                        if sensenum:
                            sense_match = re.search(r'\((\d+)\)', suffix_text)
                            if sense_match:
                                display_sense = sense_match.group(1)

                        # Parse link target for word
                        link_href = ''
                        if href.startswith('entry://'):
                            link_href = href.replace('entry://', '')

                        target_word, _ = parse_link_target(link_href)
                        if not target_word and clickable_text:
                            target_word = clickable_text.lower()

                        # Create cross_ref entry - use display_sense for jumping
                        if clickable_text:
                            sense_data['cross_refs'].append({
                                'prefix': current_prefix.strip() + ' ' if current_prefix and current_prefix.strip() else None,
                                'clickable': clickable_text.strip(),
                                'suffix': suffix_text if suffix_text else None,
                                'target_word': target_word or '',
                                'target_sense': display_sense
                            })

                        # Reset prefix for next link
                        current_prefix = ''
                        i += 1
                        continue

                    i += 1

            # Also handle refhwd not inside crossref or thesref (legacy/simple format)
            for ref in sense.find_all(class_='refhwd'):
                # Skip if inside a crossref or thesref (already processed above)
                if ref.find_parent(class_='crossref'):
                    continue
                if ref.find_parent(class_='thesref'):
                    continue
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
                    # Only add if has a valid link and not already added
                    if target_word:
                        already_added = any(
                            r.get('target_word') == target_word or r.get('link') == target_word
                            for r in sense_data['cross_refs']
                        )
                        if not already_added:
                            sense_data['cross_refs'].append({
                                'text': ref_text,
                                'link': target_word
                            })

            # Synonym (SYN) within sense - store as label, not clickable
            # Structure: <span class="syn"><span class="synopp">SYN</span> word</span>
            for syn in sense.find_all(class_='syn'):
                synopp = syn.find(class_='synopp')
                if synopp:
                    syn_word = clean_text(syn.get_text().replace(synopp.get_text(), ''))
                    if syn_word:
                        sense_data['labels'].append({'type': 'syn', 'value': syn_word})

            # Antonym (OPP) within sense - store as label, not clickable
            # Structure: <span class="opp"><span class="synopp">OPP</span> word</span>
            for opp in sense.find_all(class_='opp'):
                synopp = opp.find(class_='synopp')
                if synopp:
                    opp_word = clean_text(opp.get_text().replace(synopp.get_text(), ''))
                    if opp_word:
                        sense_data['labels'].append({'type': 'opp', 'value': opp_word})

            # Thesaurus reference (► see THESAURUS at THING)
            # Structure: <span class="thesref">
            #   <span class="thesaurus">►</span> see <span class="thesaurus">thesaurus</span> at
            #   <a href="..."><span class="refhwd">thing</span></a>
            # </span>
            for thesref in sense.find_all(class_='thesref'):
                # Build prefix from text before <a> tag
                prefix_parts = []
                link_elem = thesref.find('a')

                if link_elem:
                    # Collect all text/elements before the <a> tag
                    for child in thesref.children:
                        if child == link_elem:
                            break
                        if hasattr(child, 'get_text'):
                            text = clean_text(child.get_text())
                            if text:
                                prefix_parts.append(text)
                        elif isinstance(child, str):
                            text = clean_text(child)
                            if text:
                                prefix_parts.append(text)

                    # Get clickable word
                    refhwd = link_elem.find(class_='refhwd')
                    clickable_text = clean_text(refhwd.get_text()) if refhwd else ''

                    # Get link target
                    href = link_elem.get('href', '')
                    link_href = href.replace('entry://', '') if href.startswith('entry://') else ''
                    target_word, target_sense = parse_link_target(link_href)
                    if not target_word and clickable_text:
                        target_word = clickable_text.lower()

                    # Create cross_ref with prefix
                    prefix_text = ' '.join(prefix_parts)
                    if clickable_text:
                        sense_data['cross_refs'].append({
                            'prefix': prefix_text + ' ' if prefix_text else None,
                            'clickable': clickable_text,
                            'suffix': None,
                            'target_word': target_word or '',
                            'target_sense': target_sense
                        })

            # Lexunit (sub-phrase like "call a doctor/the police")
            # May contain alsoform like "(also from one day to the next)"
            # Only get direct lexunits, not ones already processed for subsenses
            for lexunit in sense.find_all(class_='lexunit', recursive=False):
                # Get the main lexunit text
                lu_text = clean_text(lexunit.get_text())

                # Check for alsoform within or following the lexunit
                alsoform = lexunit.find(class_='alsoform')
                if not alsoform:
                    # Check if alsoform follows the lexunit
                    next_elem = lexunit.find_next_sibling()
                    if next_elem and hasattr(next_elem, 'get') and 'alsoform' in (next_elem.get('class') or []):
                        alsoform = next_elem

                also_text = ''
                if alsoform:
                    also_text = clean_text(alsoform.get_text())
                    # If alsoform was inside lexunit, it's already in lu_text
                    # If it was outside, we need to append it
                    if also_text and also_text not in lu_text:
                        lu_text = lu_text + ' ' + also_text

                if lu_text and lu_text != sense_data.get('definition', ''):
                    # Find definition that follows this lexunit (or alsoform)
                    lu_def = ''
                    next_sib = alsoform.find_next_sibling() if alsoform and alsoform != lexunit else lexunit.find_next_sibling()
                    while next_sib:
                        # Skip alsoform if we haven't already
                        if hasattr(next_sib, 'get') and 'alsoform' in (next_sib.get('class') or []):
                            next_sib = next_sib.find_next_sibling()
                            continue
                        if next_sib.get('class') and 'def' in next_sib.get('class', []):
                            lu_def = clean_text(next_sib.get_text())
                            break
                        # Check if it's a text node with definition in parentheses
                        if hasattr(next_sib, 'get_text'):
                            text = clean_text(next_sib.get_text())
                            if text.startswith('(=') or text.startswith('('):
                                lu_def = text
                                break
                        next_sib = next_sib.find_next_sibling()

                    if not sense_data.get('lexunits'):
                        sense_data['lexunits'] = []
                    sense_data['lexunits'].append({
                        'text': lu_text,
                        'definition': lu_def
                    })

            # Colloexa - collocation examples (similar to lexunit but with collo class)
            # Structure: <span class="colloexa"><span class="collo">text</span><span class="gloss">def</span><span class="example">...</span></span>
            for colloexa in sense.find_all(class_='colloexa'):
                collo = colloexa.find(class_='collo')
                if collo:
                    collo_text = clean_text(collo.get_text())
                    if collo_text:
                        # Get gloss (definition)
                        gloss = colloexa.find(class_='gloss')
                        collo_def = clean_text(gloss.get_text()) if gloss else ''

                        # Get examples
                        collo_examples = []
                        for ex in colloexa.find_all(class_='example'):
                            ex_text = extract_highlighted_text(ex)
                            if ex_text:
                                # Get audio if available
                                audio_link = ex.find('a', href=lambda h: h and h.startswith('sound://'))
                                audio_path = audio_link.get('href', '').replace('sound://', '') if audio_link else ''
                                collo_examples.append({
                                    'text': ex_text,
                                    'audio_path': audio_path
                                })

                        if not sense_data.get('lexunits'):
                            sense_data['lexunits'] = []
                        sense_data['lexunits'].append({
                            'text': collo_text,
                            'definition': collo_def,
                            'examples': collo_examples
                        })

            # Grammar box (GRAMMAR section with usage notes)
            grambox = sense.find(class_='grambox')
            if grambox:
                grammar_box_data = {
                    'heading': '',
                    'notes': []
                }
                heading = grambox.find(class_='heading')
                if heading:
                    grammar_box_data['heading'] = clean_text(heading.get_text())

                # Parse explanation items
                for expl in grambox.find_all(class_='expl'):
                    note = {
                        'text': '',
                        'expr': '',
                        'examples': [],  # Changed to list for multiple examples
                        'bad_example': ''
                    }
                    # Main expressions (may be multiple)
                    exprs = [clean_text(e.get_text()) for e in expl.find_all(class_='expr')]
                    if exprs:
                        note['expr'] = ', '.join(exprs)

                    # Get the explanation text (excluding nested elements)
                    note['text'] = clean_text(expl.get_text())

                    # Good examples (may be multiple)
                    for example in expl.find_all(class_='example'):
                        ex_text = clean_text(example.get_text()).lstrip('·').strip()
                        if ex_text:
                            note['examples'].append(ex_text)

                    # Bad example (what NOT to say)
                    badexa = expl.find(class_='badexa')
                    if badexa:
                        note['bad_example'] = clean_text(badexa.get_text())

                    grammar_box_data['notes'].append(note)

                sense_data['grammar_box'] = grammar_box_data

            # Register box (f2nbox) - usage register notes
            # Structure: <span class="f2nbox"><span class="heading">Register</span><span class="expl">...</span></span>
            f2nbox = sense.find(class_='f2nbox')
            if f2nbox:
                register_box_data = {
                    'heading': '',
                    'notes': []
                }
                heading = f2nbox.find(class_='heading')
                if heading:
                    register_box_data['heading'] = clean_text(heading.get_text())

                # Parse explanation items
                for expl in f2nbox.find_all(class_='expl'):
                    note = {
                        'text': '',
                        'expr': '',
                        'examples': []  # Changed to list for multiple examples
                    }
                    # Extract expressions (highlighted words)
                    exprs = [clean_text(e.get_text()) for e in expl.find_all(class_='expr')]
                    if exprs:
                        note['expr'] = ', '.join(exprs)

                    # Get the explanation text
                    note['text'] = clean_text(expl.get_text())

                    # Examples (may be multiple)
                    for example in expl.find_all(class_='example'):
                        ex_text = clean_text(example.get_text()).lstrip('·').strip()
                        if ex_text:
                            note['examples'].append(ex_text)

                    register_box_data['notes'].append(note)

                sense_data['register_box'] = register_box_data

            # Add sense if it has definition OR subsenses OR lexunit_prefix
            if sense_data['definition'] or sense_data.get('subsenses') or sense_data.get('lexunit_prefix'):
                sense_data['sort_order'] = idx
                entry['senses'].append(sense_data)

        # Collect sense-level data (lexunits, grambox, registerbox, lexunit_prefix) to entry attributes
        # This allows storage in entry_attributes table
        # Use sense number as key (e.g., "1", "2") for lookup in rendering
        sense_lexunits = {}
        sense_grammar_boxes = {}
        sense_register_boxes = {}
        sense_lexunit_prefixes = {}
        for sense in entry['senses']:
            # Use sense number (e.g., "1", "2"), fallback to sort_order+1 if no number
            sense_num = sense.get('number')
            if not sense_num:
                sense_num = str(sense.get('sort_order', 0) + 1)  # Convert 0-based to 1-based

            if sense.get('lexunits'):
                sense_lexunits[sense_num] = sense['lexunits']
            if sense.get('grammar_box'):
                sense_grammar_boxes[sense_num] = sense['grammar_box']
            if sense.get('register_box'):
                sense_register_boxes[sense_num] = sense['register_box']
            if sense.get('lexunit_prefix'):
                sense_lexunit_prefixes[sense_num] = sense['lexunit_prefix']

        if sense_lexunits:
            entry['attributes']['sense_lexunits'] = sense_lexunits
        if sense_grammar_boxes:
            entry['attributes']['sense_grammar_boxes'] = sense_grammar_boxes
        if sense_register_boxes:
            entry['attributes']['sense_register_boxes'] = sense_register_boxes
        if sense_lexunit_prefixes:
            entry['attributes']['sense_lexunit_prefixes'] = sense_lexunit_prefixes

        # === Phrasal Verbs ===
        phrasal_verbs = []
        for phrv_entry in soup.find_all(class_='phrvbentry'):
            phrv_data = {
                'headword': '',
                'pos': 'phrasal verb',
                'senses': []
            }

            # Phrasal verb headword
            phrv_hwd = phrv_entry.find(class_='phrvbhwd')
            if phrv_hwd:
                phrv_data['headword'] = clean_text(phrv_hwd.get_text())

            # Parse senses within this phrasal verb
            for sense_idx, sense in enumerate(phrv_entry.find_all(class_='sense')):
                phrv_sense = {
                    'number': '',
                    'lexunit': '',  # Grammar form like "call (somebody) back"
                    'definition': '',
                    'labels': [],
                    'examples': []
                }

                # Sense number
                sensenum = sense.find(class_='sensenum')
                if sensenum:
                    phrv_sense['number'] = clean_text(sensenum.get_text())

                # Lexical unit (grammar form)
                lexunit = sense.find(class_='lexunit')
                if lexunit:
                    phrv_sense['lexunit'] = clean_text(lexunit.get_text())

                # Definition
                def_elem = sense.find(class_='def')
                if def_elem:
                    phrv_sense['definition'] = clean_text(def_elem.get_text())

                # Labels (register, geo, etc.) - exclude those inside amequiv
                for geo in sense.find_all(class_='geo'):
                    # Skip if inside amequiv (American English equivalent)
                    if geo.find_parent(class_='amequiv'):
                        continue
                    geo_text = clean_text(geo.get_text())
                    if geo_text:
                        phrv_sense['labels'].append({'type': 'geo', 'value': geo_text})

                for reg in sense.find_all(class_='registerlab'):
                    reg_text = clean_text(reg.get_text())
                    if reg_text:
                        phrv_sense['labels'].append({'type': 'register', 'value': reg_text})

                # Synonym - check both 'syn' class and 'amequiv' class
                syn = sense.find(class_='syn')
                if syn:
                    synopp = syn.find(class_='synopp')
                    if synopp:
                        syn_word = clean_text(syn.get_text().replace(synopp.get_text(), ''))
                        if syn_word:
                            phrv_sense['labels'].append({'type': 'syn', 'value': syn_word})

                # American English equivalent (e.g., "SYN draft American English")
                amequiv = sense.find(class_='amequiv')
                if amequiv:
                    synopp = amequiv.find(class_='synopp')
                    geo = amequiv.find(class_='geo')
                    if synopp:
                        # Get the synonym word (text between synopp and geo)
                        syn_word = clean_text(amequiv.get_text())
                        # Remove "SYN" prefix
                        syn_word = syn_word.replace(clean_text(synopp.get_text()), '').strip()
                        # Remove geo suffix if present
                        if geo:
                            geo_text = clean_text(geo.get_text())
                            syn_word = syn_word.replace(geo_text, '').strip()
                        if syn_word:
                            # Format: "draft American English" or just "draft"
                            if geo:
                                phrv_sense['labels'].append({'type': 'syn', 'value': f"{syn_word} {geo_text}"})
                            else:
                                phrv_sense['labels'].append({'type': 'syn', 'value': syn_word})

                # Examples
                for ex in sense.find_all(class_='example'):
                    ex_text = clean_text(ex.get_text())
                    if ex_text:
                        phrv_sense['examples'].append(ex_text)

                # Related word reference (e.g., "→ call-up")
                relatedwd = sense.find(class_='relatedwd')
                if relatedwd:
                    related_text = clean_text(relatedwd.get_text())
                    if related_text:
                        phrv_sense['labels'].append({'type': 'related', 'value': related_text})

                # Grammar examples (propformprep patterns)
                for gramexa in sense.find_all(class_='gramexa'):
                    propform = gramexa.find(class_='propformprep')
                    if propform:
                        pattern = clean_text(propform.get_text())
                        if pattern:
                            phrv_sense['lexunit'] = pattern  # Use as lexunit if present
                    for ex in gramexa.find_all(class_='example'):
                        ex_text = clean_text(ex.get_text())
                        if ex_text:
                            phrv_sense['examples'].append(ex_text)

                if phrv_sense['definition']:
                    phrv_data['senses'].append(phrv_sense)

            if phrv_data['headword'] and phrv_data['senses']:
                phrasal_verbs.append(phrv_data)

        if phrasal_verbs:
            entry['attributes']['phrasal-verbs'] = phrasal_verbs

        # NOTE: Phrases are parsed from popup sections, not directly from entry
        # (All phrases are inside popup containers in LDOCE)

        # === Entry-level Grammar Box (e.g., "GRAMMAR: Patterns with day") ===
        # These are gramboxes NOT inside any sense (usually in .tail section)
        entry_grammar_boxes = []
        for grambox in soup.find_all(class_='grambox'):
            # Skip if inside a sense (those are handled separately)
            if grambox.find_parent(class_='sense'):
                continue

            grammar_box_data = {
                'heading': '',
                'notes': []
            }
            heading = grambox.find(class_='heading')
            if heading:
                grammar_box_data['heading'] = clean_text(heading.get_text())

            # Parse compareword items (for "Patterns with X" style)
            for compareword in grambox.find_all(class_='compareword'):
                note = {
                    'text': '',
                    'expr': '',
                    'examples': [],  # Changed to list for multiple examples
                    'bad_example': '',
                    'pattern': ''  # e.g., "on a day"
                }

                # Pattern display (e.g., "on a day")
                exp_display = compareword.find(class_='exp')
                if exp_display:
                    note['pattern'] = clean_text(exp_display.get_text())

                # Explanation
                expl = compareword.find(class_='expl')
                if expl:
                    note['text'] = clean_text(expl.get_text())
                    # Expression to highlight
                    expr = expl.find(class_='expr')
                    if expr:
                        note['expr'] = clean_text(expr.get_text())
                    # Good examples (may be multiple)
                    for example in expl.find_all(class_='example'):
                        ex_text = clean_text(example.get_text()).lstrip('·').strip()
                        if ex_text:
                            note['examples'].append(ex_text)
                    # Bad example
                    badexa = expl.find(class_='badexa')
                    if badexa:
                        note['bad_example'] = clean_text(badexa.get_text())

                if note['text'] or note['pattern']:
                    grammar_box_data['notes'].append(note)

            # Also parse regular expl items (for standard GRAMMAR style)
            for expl in grambox.find_all(class_='expl', recursive=False):
                # Skip if already processed as part of compareword
                if expl.find_parent(class_='compareword'):
                    continue
                note = {
                    'text': clean_text(expl.get_text()),
                    'expr': '',
                    'examples': [],  # Changed to list for multiple examples
                    'bad_example': ''
                }
                # Expressions (may be multiple)
                exprs = [clean_text(e.get_text()) for e in expl.find_all(class_='expr')]
                if exprs:
                    note['expr'] = ', '.join(exprs)
                # Good examples (may be multiple)
                for example in expl.find_all(class_='example'):
                    ex_text = clean_text(example.get_text()).lstrip('·').strip()
                    if ex_text:
                        note['examples'].append(ex_text)
                badexa = expl.find(class_='badexa')
                if badexa:
                    note['bad_example'] = clean_text(badexa.get_text())

                if note['text']:
                    grammar_box_data['notes'].append(note)

            if grammar_box_data['heading'] or grammar_box_data['notes']:
                entry_grammar_boxes.append(grammar_box_data)

        if entry_grammar_boxes:
            entry['attributes']['entry_grammar_boxes'] = entry_grammar_boxes

        # === Cross references (only with valid links) ===
        # Using fragment storage: prefix + clickable + suffix
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

            # Extract run-on entries (derived words like "—relevantly adverb")
            runons = []
            for runon in tail.find_all(class_='runon'):
                deriv = runon.find(class_='deriv')
                pos = runon.find(class_='pos')
                gram = runon.find(class_='gram')
                proncodes = runon.find(class_='proncodes')
                if deriv:
                    deriv_text = clean_text(deriv.get_text())
                    # Remove leading dash if present
                    if deriv_text.startswith('—') or deriv_text.startswith('-'):
                        deriv_text = deriv_text[1:].strip()
                    pos_text = clean_text(pos.get_text()) if pos else ''
                    gram_text = clean_text(gram.get_text()) if gram else ''
                    # Extract pronunciation (UK and US)
                    pron_uk = ''
                    pron_us = ''
                    if proncodes:
                        pron_elem = proncodes.find(class_='pron')
                        amevarpron = proncodes.find(class_='amevarpron')
                        if pron_elem:
                            pron_uk = clean_text(pron_elem.get_text())
                        if amevarpron:
                            pron_us = clean_text(amevarpron.get_text())
                            # Remove leading "$ " if present
                            if pron_us.startswith('$'):
                                pron_us = pron_us[1:].strip()
                    if deriv_text:
                        runon_data = {
                            'word': deriv_text,
                            'pos': pos_text
                        }
                        if gram_text:
                            runon_data['gram'] = gram_text
                        if pron_uk:
                            runon_data['pron_uk'] = pron_uk
                        if pron_us:
                            runon_data['pron_us'] = pron_us
                        runons.append(runon_data)
            if runons:
                entry['attributes']['runons'] = runons

        # Parse crossref sections - handle reflex + link combinations
        # Now using fragment storage for cleaner rendering
        for crossref in soup.find_all(class_='crossref'):
            # Process children in order to properly associate reflex with following link
            children = list(crossref.children)
            i = 0
            while i < len(children):
                child = children[i]
                if hasattr(child, 'get') and 'reflex' in (child.get('class') or []):
                    # Found a reflex - this is the prefix (e.g., "see THESAURUS at")
                    prefix_text = clean_text(child.get_text())
                    # Look for following <a> tag
                    clickable_text = ''
                    link_href = ''
                    suffix_text = ''
                    # Check next siblings for <a> tag
                    j = i + 1
                    while j < len(children):
                        next_child = children[j]
                        if hasattr(next_child, 'name') and next_child.name == 'a':
                            # Found the associated link - this is the clickable part
                            refhwd = next_child.find(class_='refhwd')
                            if refhwd:
                                clickable_text = clean_text(refhwd.get_text())
                            homnum = next_child.find(class_='refhomnum')
                            sensenum = next_child.find(class_='refsensenum')
                            # homnum goes into clickable (e.g., "care" + "2" = "care2")
                            # sensenum goes into suffix (e.g., "(8)")
                            if homnum:
                                homnum_text = clean_text(homnum.get_text())
                                if homnum_text:
                                    clickable_text = clickable_text + homnum_text
                            suffix_text = clean_text(sensenum.get_text()) if sensenum else ''
                            link_href = extract_ref_link(next_child) or ''
                            break
                        elif hasattr(next_child, 'get') and 'reflex' in (next_child.get('class') or []):
                            # Hit another reflex, stop looking
                            break
                        j += 1

                    # Create fragment-based relation
                    if prefix_text or clickable_text:
                        fragments = make_relation_fragments(
                            prefix_text, clickable_text, suffix_text, link_href
                        )
                        entry['relations'].append({
                            'type': 'cross_ref',
                            **fragments
                        })
                    i = j + 1 if link_href else i + 1
                elif hasattr(child, 'name') and child.name == 'a':
                    # Standalone link (not preceded by reflex)
                    refhwd = child.find(class_='refhwd')
                    if refhwd:
                        clickable_text = clean_text(refhwd.get_text())
                        homnum = child.find(class_='refhomnum')
                        sensenum = child.find(class_='refsensenum')
                        # homnum goes into clickable (e.g., "care" + "2" = "care2")
                        # sensenum goes into suffix (e.g., "(8)")
                        if homnum:
                            homnum_text = clean_text(homnum.get_text())
                            if homnum_text:
                                clickable_text = clickable_text + homnum_text
                        suffix_text = clean_text(sensenum.get_text()) if sensenum else ''
                        standalone_link = extract_ref_link(child) or ''
                        if clickable_text and standalone_link:
                            # Check if this was already added as part of a reflex combination
                            already_added = any(
                                r.get('target_word') == parse_link_target(standalone_link)[0]
                                for r in entry['relations']
                                if r.get('type') == 'cross_ref'
                            )
                            if not already_added:
                                fragments = make_relation_fragments(
                                    '', clickable_text, suffix_text, standalone_link
                                )
                                entry['relations'].append({
                                    'type': 'cross_ref',
                                    **fragments
                                })
                    i += 1
                else:
                    i += 1

        # === Collocations ===
        # Method 1: Try collobox (traditional format)
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

        # Method 2: Try popup format (at-link with popcollo header)
        if not entry['collocations']:
            coll_order = 0
            for popup in soup.find_all(class_='at-link'):
                header = popup.find(class_='popcollo')
                if header:
                    # Get category from header text
                    header_text = clean_text(header.get_text())
                    current_category = ''
                    if 'FROM THE ENTRY' in header_text:
                        current_category = 'FROM THE ENTRY'
                    elif 'FROM OTHER' in header_text:
                        current_category = 'FROM OTHER ENTRIES'

                    for collocate in popup.find_all(class_='collocate'):
                        coll_data = {
                            'category': current_category,
                            'text': '',
                            'gloss': '',
                            'examples': [],
                            'sort_order': coll_order
                        }

                        # Try both 'colloc' and 'colloc collo' classes
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

        # === Synonyms (thesobox format) ===
        thesobox = soup.find(class_='thesobox')
        if thesobox:
            for relword in thesobox.find_all(class_='relword'):
                word_text = clean_text(relword.get_text())
                if word_text:
                    fragments = make_relation_fragments('', word_text, '', word_text)
                    entry['relations'].append({
                        'type': 'synonym',
                        **fragments
                    })

        # === Verb Table ===
        verbtable = soup.find(class_='verbtable')
        if verbtable:
            verb_forms = []
            current_tense = ''
            for row in verbtable.find_all('tr'):
                cols = row.find_all('td')
                if cols:
                    tense_text = clean_text(cols[0].get_text()) if len(cols) > 0 else ''
                    if tense_text and cols[0].get('class') and 'col1' in cols[0].get('class', []):
                        current_tense = tense_text
                    elif tense_text and not current_tense:
                        current_tense = tense_text

                    subject = clean_text(cols[1].get_text()) if len(cols) > 1 else ''
                    form = clean_text(cols[2].get_text()) if len(cols) > 2 else ''

                    if form:
                        verb_forms.append({
                            'tense': current_tense,
                            'subject': subject,
                            'form': form
                        })
            if verb_forms:
                entry['attributes']['verb_table'] = verb_forms

        # === Parse all popups in one pass ===
        corpus_examples = []
        thesaurus = []
        word_family = []
        entry_menu = []
        popup_phrases = []  # Phrases from popup (additional to inline)
        popup_collocations = []  # Additional collocations from popup

        for popup in soup.find_all(class_='at-link'):
            # Get all headers in this popup
            headers = popup.find_all(class_='popheader')

            for header in headers:
                header_text = clean_text(header.get_text())
                header_classes = header.get('class', [])

                # Determine popup type from class or header text
                popup_type = None
                if 'pope_menu' in header_classes:
                    popup_type = 'entry_menu'
                elif 'popexa' in header_classes:
                    popup_type = 'examples'
                elif 'popthes' in header_classes:
                    if 'WORD SETS' in header_text.upper():
                        popup_type = 'word_sets'
                    else:
                        popup_type = 'thesaurus'
                elif 'popcollo' in header_classes:
                    popup_type = 'collocations'
                elif 'popphrase' in header_classes:
                    popup_type = 'phrases'
                elif 'popwf' in header_classes:
                    popup_type = 'word_family'
                elif 'popetym' in header_classes:
                    popup_type = 'origin'  # Already handled elsewhere
                elif 'WORD SETS' in header_text.upper():
                    popup_type = 'word_sets'

                if not popup_type:
                    continue

                # Get the container - usually the parent entry span
                container = header.find_parent(class_='entry') or popup

                # === ENTRY MENU ===
                if popup_type == 'entry_menu':
                    menu_items = []
                    for item in container.find_all(class_='menuitem'):
                        num = item.find(class_='sensenum')
                        signpost = item.find(class_='signpost')
                        lexunit = item.find(class_='lexunit')
                        num_text = clean_text(num.get_text()) if num else ''
                        label_text = clean_text(signpost.get_text()) if signpost else (clean_text(lexunit.get_text()) if lexunit else '')
                        # Only add if has number or label
                        if num_text or label_text:
                            menu_items.append({
                                'number': num_text,
                                'label': label_text
                            })
                    if menu_items:
                        entry_menu.append({
                            'header': header_text,
                            'items': menu_items
                        })

                # === EXAMPLES ===
                elif popup_type == 'examples':
                    exas = container.find(class_='exas')
                    if exas:
                        examples_list = []
                        for li in exas.find_all('li'):
                            ex_text = extract_highlighted_text(li).lstrip('·').strip()
                            if ex_text:
                                examples_list.append(ex_text)
                        if examples_list:
                            corpus_examples.append({
                                'header': header_text,
                                'examples': examples_list
                            })

                # === THESAURUS ===
                elif popup_type == 'thesaurus':
                    section_containers = container.find_all(class_='section')
                    for sec_container in section_containers:
                        sec_heading = sec_container.find(class_='secheading')
                        sec_text = clean_text(sec_heading.get_text()) if sec_heading else ''

                        # Parse each exponent (thesaurus entry)
                        exponents = []
                        for exp in sec_container.find_all(class_='exponent'):
                            exp_data = {}

                            # Get the headword (exp display)
                            exp_display = exp.find(class_='exp')
                            if exp_display:
                                exp_data['word'] = clean_text(exp_display.get_text())

                            # Get definition
                            content = exp.find(class_='content')
                            if content:
                                def_elem = content.find(class_='def')
                                if def_elem:
                                    exp_data['definition'] = clean_text(def_elem.get_text())

                                # Get register/geo labels
                                labels = []
                                for geo in content.find_all(class_='geo'):
                                    labels.append(clean_text(geo.get_text()))
                                for reg in content.find_all(class_='registerlab'):
                                    labels.append(clean_text(reg.get_text()))
                                if labels:
                                    exp_data['labels'] = labels

                                # Get examples
                                examples = []
                                for ex in content.find_all(class_='example'):
                                    ex_text = clean_text(ex.get_text()).lstrip('·').strip()
                                    if ex_text:
                                        examples.append(ex_text)
                                if examples:
                                    exp_data['examples'] = examples

                            if exp_data.get('word'):
                                exponents.append(exp_data)

                        if sec_text or exponents:
                            thesaurus.append({
                                'header': header_text,
                                'section': sec_text,
                                'items': exponents
                            })

                    # If no sections, try direct exponents
                    if not thesaurus:
                        exponents = []
                        for exp in container.find_all(class_='exponent'):
                            exp_data = {}
                            exp_display = exp.find(class_='exp')
                            if exp_display:
                                exp_data['word'] = clean_text(exp_display.get_text())

                            content = exp.find(class_='content')
                            if content:
                                def_elem = content.find(class_='def')
                                if def_elem:
                                    exp_data['definition'] = clean_text(def_elem.get_text())

                                examples = []
                                for ex in content.find_all(class_='example'):
                                    ex_text = clean_text(ex.get_text()).lstrip('·').strip()
                                    if ex_text:
                                        examples.append(ex_text)
                                if examples:
                                    exp_data['examples'] = examples

                            if exp_data.get('word'):
                                exponents.append(exp_data)

                        if exponents:
                            thesaurus.append({
                                'header': header_text,
                                'section': '',
                                'items': exponents
                            })

                # === WORD SETS (part of thesaurus) ===
                elif popup_type == 'word_sets':
                    # Word sets have categories with expandable content
                    for category in container.find_all(class_='category'):
                        ws_head = category.find(class_='ws-head')
                        if ws_head:
                            cat_name = clean_text(ws_head.get_text())

                            # Get words from content
                            content = category.find(class_='content')
                            words = []
                            if content:
                                for wswd in content.find_all(class_='wswd'):
                                    word_text = clean_text(wswd.get_text())
                                    # Parse word and pos
                                    pos_elem = wswd.find(class_='pos')
                                    pos = clean_text(pos_elem.get_text()) if pos_elem else ''
                                    if pos:
                                        word_text = word_text.replace(pos, '').strip().rstrip(',')
                                    words.append({
                                        'word': word_text,
                                        'pos': pos
                                    })

                            if cat_name:
                                thesaurus.append({
                                    'header': header_text,
                                    'section': cat_name,
                                    'items': words
                                })

                # === COLLOCATIONS (popup) ===
                elif popup_type == 'collocations':
                    sections = container.find_all(class_='secheading')
                    current_section = ''

                    # Get all collocates with their sections
                    colls_in_popup = []
                    for sec in sections:
                        current_section = clean_text(sec.get_text())

                    for collocate in container.find_all(class_='collocate'):
                        coll_text_elem = collocate.find(class_='colloc')
                        if coll_text_elem:
                            coll_text = clean_text(coll_text_elem.get_text())
                            examples = []
                            for ex in collocate.find_all(class_='example'):
                                ex_text = clean_text(ex.get_text())
                                if ex_text:
                                    examples.append(ex_text)
                            if coll_text:
                                colls_in_popup.append({
                                    'text': coll_text,
                                    'examples': examples
                                })

                    if colls_in_popup:
                        popup_collocations.append({
                            'header': header_text,
                            'items': colls_in_popup
                        })

                # === PHRASES (popup) ===
                elif popup_type == 'phrases':
                    phrases_in_popup = []
                    for phrase in container.find_all(class_='phrase'):
                        phrase_text = phrase.find(class_='phrasetext')
                        if phrase_text:
                            text = clean_text(phrase_text.get_text()).lstrip('►').strip()
                        else:
                            # Try expandable span
                            exp = phrase.find(class_='expandable')
                            if exp:
                                ptext = exp.find(class_='phrasetext')
                                text = clean_text(ptext.get_text()).lstrip('►').strip() if ptext else ''
                            else:
                                text = clean_text(phrase.get_text()).lstrip('►').strip()

                        if text:
                            # Get examples from content div (expandable items)
                            examples = []
                            content_div = phrase.find(class_='content')
                            if content_div:
                                # Examples in exas list
                                exas = content_div.find(class_='exas')
                                if exas:
                                    for li in exas.find_all('li'):
                                        ex_text = extract_highlighted_text(li).lstrip('·').strip()
                                        if ex_text:
                                            examples.append(ex_text)
                                # Also check direct examples
                                for ex in content_div.find_all(class_='example'):
                                    ex_text = extract_highlighted_text(ex).lstrip('·').strip()
                                    if ex_text and ex_text not in examples:
                                        examples.append(ex_text)

                            phrases_in_popup.append({
                                'text': text,
                                'examples': examples
                            })
                    if phrases_in_popup:
                        popup_phrases.append({
                            'header': header_text,
                            'items': phrases_in_popup
                        })

                # === WORD FAMILY ===
                elif popup_type == 'word_family':
                    # Word family is grouped by POS
                    wf_groups = []
                    wf_container = container.find(class_='wf')
                    if wf_container:
                        for group in wf_container.find_all(class_='group'):
                            pos_elem = group.find(class_='pos')
                            pos_text = clean_text(pos_elem.get_text()) if pos_elem else ''

                            words = []
                            for w in group.find_all(class_='w'):
                                wfwd = w.find(class_='wfwd')
                                if wfwd:
                                    word_text = clean_text(wfwd.get_text())
                                    if word_text:
                                        words.append(word_text)

                            if pos_text or words:
                                wf_groups.append({
                                    'pos': pos_text,
                                    'words': words
                                })

                    if wf_groups and not word_family:  # Only first occurrence
                        word_family = [{
                            'header': header_text,
                            'groups': wf_groups
                        }]

        # Store all parsed popup data
        if corpus_examples:
            entry['attributes']['corpus_examples'] = corpus_examples
        if thesaurus:
            entry['attributes']['thesaurus'] = thesaurus
        if word_family:
            entry['attributes']['word_family'] = word_family
        if entry_menu:
            entry['attributes']['entry_menu'] = entry_menu
        if popup_phrases:
            entry['attributes']['popup_phrases'] = popup_phrases
        if popup_collocations:
            entry['attributes']['popup_collocations'] = popup_collocations

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

        # Initialize schema using unified module
        init_database(self.conn)

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
        # Generate headword_lower (strip trailing digits for homograph grouping)
        headword = entry_data['headword']
        headword_lower = re.sub(r'\d+$', '', headword).lower()

        # Insert entry
        self.cursor.execute("""
            INSERT INTO entries (dict_id, headword, headword_lower, headword_display)
            VALUES (?, ?, ?, ?)
        """, (
            self.dict_id,
            headword,
            headword_lower,
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
        subsenses_data = {}  # sense_number -> subsenses for storage
        for sense in entry_data.get('senses', []):
            self.cursor.execute("""
                INSERT INTO senses (entry_id, sense_number, signpost, definition, definition_zh, sort_order)
                VALUES (?, ?, ?, ?, ?, ?)
            """, (
                entry_id,
                sense.get('number') or None,
                sense.get('signpost') or None,
                sense.get('definition', ''),
                sense.get('chinese_def') or None,
                sense.get('sort_order', 0)
            ))
            sense_id = self.cursor.lastrowid

            # Store subsenses for later
            if sense.get('subsenses'):
                subsenses_data[str(sense_id)] = sense['subsenses']

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
                    INSERT INTO examples (sense_id, text, text_zh, audio_path, position, sort_order)
                    VALUES (?, ?, ?, ?, ?, ?)
                """, (
                    sense_id,
                    example['text'],
                    example.get('chinese') or None,
                    example.get('audio_path') or None,
                    example.get('position', 0),
                    example.get('sort_order', 0)
                ))

            # Grammar patterns within sense
            for pat_idx, gram_ex in enumerate(sense.get('gram_examples', [])):
                self.cursor.execute("""
                    INSERT INTO grammar_patterns (sense_id, pattern, gloss, sort_order)
                    VALUES (?, ?, ?, ?)
                """, (
                    sense_id,
                    gram_ex['pattern'],
                    gram_ex.get('gloss') or None,
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
                    # Legacy string format - convert to fragments
                    ref_text, ref_link = ref, None
                    fragments = make_relation_fragments('', ref_text, '', ref_link)
                elif 'clickable' in ref:
                    # Already in fragment format
                    fragments = ref
                else:
                    # Old dict format with text/link
                    ref_text = ref.get('text', '')
                    ref_link = ref.get('link')
                    fragments = make_relation_fragments('', ref_text, '', ref_link)

                if fragments.get('clickable'):
                    self.cursor.execute("""
                        INSERT INTO relations (entry_id, sense_id, relation_type, prefix, clickable, suffix, target_word, target_sense, sort_order)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, (
                        entry_id,
                        sense_id,
                        'cross_ref',
                        fragments.get('prefix'),
                        fragments.get('clickable'),
                        fragments.get('suffix'),
                        fragments.get('target_word', ''),
                        fragments.get('target_sense'),
                        idx
                    ))

        # Insert relations (phrases, synonyms, entry-level cross-refs, inflections)
        # Now using fragment storage format
        for idx, rel in enumerate(entry_data.get('relations', [])):
            # Check if relation is in new fragment format or old format
            if 'clickable' in rel:
                # New fragment format
                self.cursor.execute("""
                    INSERT INTO relations (entry_id, sense_id, relation_type, prefix, clickable, suffix, target_word, target_sense, sort_order)
                    VALUES (?, NULL, ?, ?, ?, ?, ?, ?, ?)
                """, (
                    entry_id,
                    rel['type'],
                    rel.get('prefix'),
                    rel.get('clickable'),
                    rel.get('suffix'),
                    rel.get('target_word', ''),
                    rel.get('target_sense'),
                    idx
                ))
            else:
                # Old format - convert to fragments
                fragments = make_relation_fragments('', rel.get('target', ''), '', rel.get('link'))
                self.cursor.execute("""
                    INSERT INTO relations (entry_id, sense_id, relation_type, prefix, clickable, suffix, target_word, target_sense, sort_order)
                    VALUES (?, NULL, ?, ?, ?, ?, ?, ?, ?)
                """, (
                    entry_id,
                    rel['type'],
                    fragments.get('prefix'),
                    fragments.get('clickable'),
                    fragments.get('suffix'),
                    fragments.get('target_word', ''),
                    fragments.get('target_sense'),
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
        # First add subsenses if any
        if subsenses_data:
            entry_data.setdefault('attributes', {})['subsenses'] = subsenses_data

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
                    # Compact JSON (no extra whitespace)
                    json_str = json.dumps(value, ensure_ascii=False, separators=(',', ':'))
                    # Compress large JSON with zlib
                    if len(json_str) > 1000:
                        import zlib
                        compressed = zlib.compress(json_str.encode('utf-8'), level=9)
                        attr_type = 'json.gz'
                        attr_value = compressed  # Store as BLOB
                    else:
                        attr_type = 'json'
                        attr_value = json_str
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

    def close(self, vacuum=True):
        """Close connection and update entry count.
        If vacuum is True, optimize and compress the database."""
        if self.conn:
            # Update entry count
            self.cursor.execute("""
                UPDATE dictionaries SET entry_count = ? WHERE dict_id = ?
            """, (self.entry_count, self.dict_id))
            self.conn.commit()

            if vacuum:
                print("Optimizing database...")
                # Analyze for query optimization
                self.cursor.execute("ANALYZE")
                # Vacuum to reclaim space and defragment
                self.cursor.execute("VACUUM")
                print("Database optimized and compressed")

            self.conn.close()
            self.conn = None
            self.cursor = None


# ============================================================
# Main Conversion Function
# ============================================================

def convert_mdx_to_lexdb(mdx_file, db_path=None, extract_audio=False, dict_type=None):
    """Convert MDX file to LexDB database.

    dict_type: 'ldoce', 'oaldpe', or None for auto-detect
    """

    mdx_path = Path(mdx_file)
    if not mdx_path.exists():
        print(f"Error: File not found: {mdx_file}")
        sys.exit(1)

    # Auto-detect dictionary type from filename (currently only LDOCE supported)
    if dict_type is None:
        filename_lower = mdx_path.stem.lower()
        if 'ldoce' in filename_lower or 'longman' in filename_lower:
            dict_type = 'ldoce'
        else:
            # Default to LDOCE for now
            print(f"Warning: Could not detect dictionary type from filename '{mdx_path.name}'")
            print("Assuming LDOCE format. Use --dict-type ldoce to suppress this warning.")
            dict_type = 'ldoce'

    print(f"Dictionary type: {dict_type}")

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
        # Find all MDD files: name.mdd, name_1.mdd, name.1.mdd, name_2.mdd, name.2.mdd, etc.
        mdd_files = []
        base_mdd = mdx_path.with_suffix('.mdd')
        if base_mdd.exists():
            mdd_files.append(base_mdd)

        # Look for numbered MDD files (both formats: name_1.mdd and name.1.mdd)
        stem = mdx_path.stem
        parent = mdx_path.parent
        for i in range(1, 20):  # Check up to 19
            # Try underscore format: name_1.mdd
            numbered_mdd_underscore = parent / f"{stem}_{i}.mdd"
            # Try dot format: name.1.mdd
            numbered_mdd_dot = parent / f"{stem}.{i}.mdd"

            if numbered_mdd_underscore.exists():
                mdd_files.append(numbered_mdd_underscore)
            elif numbered_mdd_dot.exists():
                mdd_files.append(numbered_mdd_dot)
            else:
                break  # Stop if neither format found

        if mdd_files:
            audio_dir = mdx_path.parent / 'audio'
            audio_dir.mkdir(exist_ok=True)
            print(f"Extracting audio to: {audio_dir}")
            print(f"Found {len(mdd_files)} MDD file(s): {[f.name for f in mdd_files]}")

            for mdd_file in mdd_files:
                print(f"  Processing: {mdd_file.name}")
                mdd = MDD(str(mdd_file))
                file_count = 0
                for key, data in mdd.items():
                    if isinstance(key, bytes):
                        key = key.decode('utf-8', errors='ignore')
                    # Normalize path separators: backslash to forward slash, strip leading slash
                    key = key.replace('\\', '/').lstrip('/')
                    out_path = audio_dir / key
                    out_path.parent.mkdir(parents=True, exist_ok=True)
                    with open(out_path, 'wb') as f:
                        f.write(data)
                    file_count += 1
                print(f"    Extracted {file_count} files")
            print("Audio extraction complete")
        else:
            print(f"Warning: No MDD files found for: {mdx_path.stem}")

    # Create parser based on dictionary type
    if dict_type == 'ldoce':
        parser = LDOCEParser()
        dict_version = "6th Edition"
    else:
        print(f"Error: Unknown dictionary type: {dict_type}")
        print("Currently only 'ldoce' is supported.")
        sys.exit(1)

    writer = LexDBWriter(
        db_path=str(db_path),
        dict_id=parser.DICT_ID,
        dict_name=parser.DICT_NAME,
        dict_version=dict_version,
        source_file=str(mdx_path.name)
    )

    print(f"Creating database: {db_path}")
    writer.open()

    print("Parsing and importing entries...")
    print(f"  Using parser: {HTML_PARSER}")

    items = list(mdx.items())  # Convert to list for progress tracking
    total = len(items)
    start_time = time.time()

    # Decode items
    decoded_items = []
    for word_key, html in items:
        if isinstance(word_key, bytes):
            word_key = word_key.decode('utf-8', errors='ignore')
        if isinstance(html, bytes):
            html = html.decode('utf-8', errors='ignore')
        decoded_items.append((word_key, html))

    print(f"  Total entries: {total}")

    batch_size = 1000
    count = 0
    success = 0

    for word_key, html in decoded_items:
        count += 1

        try:
            entries = parser.parse(html, word_key)

            for entry_data in entries:
                if entry_data.get('senses'):
                    # Skip redirects: if parsed headword differs from MDX key, it's a redirect
                    parsed_hw = entry_data.get('headword', '').lower().rstrip('0123456789')
                    word_key_lower = word_key.lower()
                    if parsed_hw and parsed_hw != word_key_lower:
                        # This is likely a redirect (e.g., "relevantly" -> "relevant")
                        continue
                    writer.write_entry(entry_data)
                    success += 1
        except Exception as e:
            print(f"Warning: Parse failed [{word_key}]: {e}")

        if count % batch_size == 0:
            writer.commit()
            elapsed = time.time() - start_time
            rate = count / elapsed if elapsed > 0 else 0
            remaining = (total - count) / rate if rate > 0 else 0
            print(f"  Processed {count}/{total} ({count*100//total}%), "
                  f"{rate:.0f} entries/sec, ~{remaining:.0f}s remaining")

    writer.close()

    elapsed = time.time() - start_time

    db_size = os.path.getsize(db_path) / (1024 * 1024)
    rate = count / elapsed if elapsed > 0 else 0

    print(f"""
╔══════════════════════════════════════════════════════════════╗
║  Conversion Complete!
╠══════════════════════════════════════════════════════════════╣
║  Total entries:   {count:>10}
║  Parsed:          {success:>10}
║  Time:            {elapsed:>10.1f}s ({rate:.0f} entries/sec)
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

def vacuum_database(db_path):
    """Optimize and compress an existing database."""
    import sqlite3
    if not Path(db_path).exists():
        print(f"Error: Database not found: {db_path}")
        sys.exit(1)

    print(f"Optimizing database: {db_path}")
    original_size = Path(db_path).stat().st_size

    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    cursor.execute("ANALYZE")
    cursor.execute("VACUUM")
    conn.close()

    new_size = Path(db_path).stat().st_size
    saved = original_size - new_size
    print(f"Original size: {original_size / 1024 / 1024:.2f} MB")
    print(f"New size: {new_size / 1024 / 1024:.2f} MB")
    print(f"Saved: {saved / 1024 / 1024:.2f} MB ({saved * 100 / original_size:.1f}%)")


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("""
Usage:
  python mdx2lexdb.py <mdx_file>
  python mdx2lexdb.py <mdx_file> --extract-audio
  python mdx2lexdb.py <mdx_file> -o <output_db_path>
  python mdx2lexdb.py --vacuum <db_file>

Dictionary types:
  ldoce     Longman Dictionary of Contemporary English (auto-detected)

Examples:
  python mdx2lexdb.py LDOCE6.mdx
  python mdx2lexdb.py LDOCE6.mdx --extract-audio
  python mdx2lexdb.py LDOCE6.mdx -o ~/dicts/ldoce.db
  python mdx2lexdb.py --vacuum LDOCE6.db
""")
        sys.exit(1)

    # Check for vacuum command
    if sys.argv[1] == '--vacuum':
        if len(sys.argv) < 3:
            print("Error: --vacuum requires a database path")
            sys.exit(1)
        vacuum_database(sys.argv[2])
        sys.exit(0)

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

    # Parse dictionary type
    dict_type = None
    if '--dict-type' in sys.argv:
        try:
            idx = sys.argv.index('--dict-type')
            dict_type = sys.argv[idx + 1]
        except (ValueError, IndexError):
            print("Error: --dict-type requires a type (currently only 'ldoce' supported)")
            sys.exit(1)

    convert_mdx_to_lexdb(mdx_file, db_path=db_path, extract_audio=extract_audio, dict_type=dict_type)
