#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
OALD4 (Oxford Advanced Learner's Dictionary 4th Edition) MDX to LexDB SQLite Database Converter

Supports OALD4 双解版
Uses unified schema from lexdb_schema module for compatibility.
"""

import sqlite3
import sys
import os
import re
import json
import zlib
from pathlib import Path
from datetime import datetime
from bs4 import BeautifulSoup, Tag

try:
    from readmdict import MDX
except ImportError:
    print("Please install dependencies first: pip install readmdict python-lzo beautifulsoup4")
    sys.exit(1)

# Import unified schema module
from lexdb_schema import (
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
# OALD-specific Utility Functions
# ============================================================

def extract_text_without_zh(element):
    """Extract text from element, excluding <zh> tags."""
    if not element:
        return ""

    # Make a copy
    elem_copy = BeautifulSoup(str(element), 'html.parser')

    # Remove all <zh> tags
    for zh in elem_copy.find_all('zh'):
        zh.decompose()

    return clean_text(elem_copy.get_text())


def extract_zh(element):
    """Extract Chinese text from <zh> tag."""
    if not element:
        return ""

    zh = element.find('zh')
    if zh:
        return clean_text(zh.get_text())
    return ""


def extract_highlighted_example(element):
    """Extract example text with highlight markers.

    Args:
        element: Can be <span class="ex"> or <div class="eg">

    Returns text with <ie> content in parentheses.
    """
    if not element:
        return ""

    # Make a copy
    elem_copy = BeautifulSoup(str(element), 'html.parser')

    # Remove <zh> tags first
    for zh in elem_copy.find_all('zh'):
        zh.decompose()

    # Convert <ie> (implicit explanation) to parenthesized text
    for ie in elem_copy.find_all(class_='ie'):
        text = ie.get_text().strip()
        # Wrap in parentheses for display
        ie.replace_with(f' ({text})')

    return clean_text(elem_copy.get_text())


def parse_cross_reference(text):
    """Parse cross-reference text like '→necessity.' or '→old.'

    Returns:
        dict with 'is_crossref', 'prefix', 'clickable', 'suffix', 'target_word', 'target_sense'
        or None if not a cross-reference
    """
    if not text:
        return None

    # Pattern: →word. or → word.
    match = re.match(r'^→\s*([^.]+)\.$', text.strip())
    if match:
        target = match.group(1).strip()
        return {
            'is_crossref': True,
            'prefix': '→',
            'clickable': target,
            'suffix': None,
            'target_word': target.lower(),
            'target_sense': None  # OALD4 doesn't have sense-level cross-refs
        }
    return None


# ============================================================
# OALD4 Parser
# ============================================================

def parse_oald4_entry(html, headword_hint=None):
    """Parse a single OALD4 entry HTML into structured data.

    Args:
        html: HTML string of the entry
        headword_hint: Optional headword hint from MDX key

    Returns:
        LIST of dictionaries with parsed entry data.
        Returns a list because one MDX entry may contain multiple entries
        (e.g., mainentry for noun + hw2 for verb, like 'mother')
    """
    soup = BeautifulSoup(html, 'html.parser')
    entries = []

    # Find main entry container
    main_entry = soup.find('div', class_='mainentry')

    if main_entry:
        entry = _parse_mainentry(main_entry, headword_hint)
        if entry and (entry.get('senses') or entry.get('pos')):
            entries.append(entry)

    # Find hw2 elements (second headword, e.g., verb form of a noun)
    # These are siblings of mainentry inside oald4ec, not nested inside mainentry
    oald4ec = soup.find('div', class_='oald4ec')
    if oald4ec:
        for hw2 in oald4ec.find_all('div', class_='hw2', recursive=False):
            entry = _parse_hw2_entry(hw2, headword_hint)
            if entry and (entry.get('senses') or entry.get('pos')):
                entries.append(entry)

    # If no mainentry or hw2 found, check for standalone entries
    if not entries:
        entry = _parse_standalone_entry(soup, headword_hint)
        if entry:
            entries.append(entry)

    # Process idioms, phrases, derivatives - add to first entry only
    if oald4ec and entries:
        # Idioms
        idioms = []
        for idm_sub in oald4ec.find_all('div', class_='idmsubentry'):
            for idiom_div in idm_sub.find_all('div', class_='idiom'):
                idiom_data = parse_oald4_idiom(idiom_div)
                if idiom_data:
                    idioms.append(idiom_data)
        if idioms:
            entries[0]['attributes']['oald/idioms'] = idioms

        # Phrases
        phrases = []
        for phr_sub in oald4ec.find_all('div', class_='phrsubentry'):
            for phrase_div in phr_sub.find_all('div', class_='phrase'):
                phrase_data = parse_oald4_phrase(phrase_div)
                if phrase_data:
                    phrases.append(phrase_data)
        if phrases:
            entries[0]['attributes']['oald/phrases'] = phrases

        # Derivatives (standalone ones at oald4ec level)
        derivatives = []
        for deriv in oald4ec.find_all('div', class_='derivative', recursive=False):
            deriv_span = deriv.find('span', class_='l')
            if deriv_span:
                deriv_text = clean_text(deriv_span.get_text())
                if deriv_text:
                    derivatives.append(deriv_text)
        if derivatives:
            entries[0]['attributes']['oald/derivatives'] = derivatives

        # Image
        img = oald4ec.find('img')
        if img and img.get('src'):
            entries[0]['attributes']['oald/image'] = img.get('src')

    return entries


def _parse_hw2_entry(hw2_elem, headword_hint=None):
    """Parse a hw2 element (second headword, typically verb form of noun)."""
    entry = {
        'headword': '',
        'headword_display': '',
        'homograph': '',
        'pos': '',
        'pronunciations': [],
        'senses': [],
        'labels': [],
        'relations': [],
        'attributes': {}
    }

    # === Headword ===
    l_elem = hw2_elem.find('span', class_='l')
    if l_elem:
        entry['headword'] = clean_text(l_elem.get_text())
    elif headword_hint:
        entry['headword'] = headword_hint

    if not entry['headword']:
        return None

    # === Part of Speech ===
    pos_elem = hw2_elem.find('span', class_='pos')
    if pos_elem:
        entry['pos'] = pos_elem.get('value', '') or clean_text(pos_elem.get_text())

    # === Pronunciation ===
    pr_elem = hw2_elem.find('span', class_='pr')
    if pr_elem:
        pr_text = clean_text(pr_elem.get_text())
        if pr_text:
            if ';' in pr_text:
                parts = pr_text.split(';')
                entry['pronunciations'].append({
                    'variant': 'uk',
                    'ipa': parts[0].strip(),
                    'audio_path': ''
                })
                entry['pronunciations'].append({
                    'variant': 'us',
                    'ipa': parts[1].strip(),
                    'audio_path': ''
                })
            else:
                entry['pronunciations'].append({
                    'variant': 'uk',
                    'ipa': pr_text,
                    'audio_path': ''
                })

    # === Grammar (vps-w at hw2 level applies to all senses) ===
    # Note: value attribute is Chinese, text content is English - prefer English text
    entry_grammar = []
    for vps_w in hw2_elem.find_all('vps-w', recursive=False):
        vps_span = vps_w.find('span', class_='vps')
        if vps_span:
            # Prefer English text content over Chinese value attribute
            vps_code = clean_text(vps_span.get_text()) or vps_span.get('value', '')
            # Only use short codes without Chinese characters
            if vps_code and len(vps_code) <= 8 and not re.search(r'[\u4e00-\u9fff]', vps_code):
                entry_grammar.append(vps_code)

    # === Senses ===
    sense_order = 0
    sense_num = 1  # 1-indexed display number
    for se2 in hw2_elem.find_all('div', class_='se2', recursive=False):
        sense_data = parse_oald4_sense(se2, sense_order, sense_number=str(sense_num))
        if sense_data:
            # Add entry-level grammar if sense has none
            if entry_grammar and not sense_data.get('grammar'):
                sense_data['grammar'] = entry_grammar.copy()
            entry['senses'].append(sense_data)
            sense_order += 1
            sense_num += 1
        else:
            # se2 has no direct content, process its se3 children
            for se3 in se2.find_all('div', class_='se3', recursive=False):
                subsense_data = parse_oald4_subsense(se3, sense_order)
                if subsense_data:
                    sense = {
                        'number': str(sense_num),
                        'signpost': subsense_data.get('signpost', ''),
                        'definition': subsense_data.get('definition', ''),
                        'definition_zh': subsense_data.get('definition_zh', ''),
                        'grammar': subsense_data.get('grammar', []) or entry_grammar.copy(),
                        'labels': [],
                        'examples': subsense_data.get('examples', []),
                        'subsenses': [],
                        'sort_order': sense_order
                    }
                    entry['senses'].append(sense)
                    sense_order += 1
                    sense_num += 1

    # If no se2, try se directly
    if not entry['senses']:
        for se in hw2_elem.find_all('div', class_='se', recursive=False):
            sense_data = parse_oald4_sense(se, sense_order, sense_number=str(sense_num))
            if sense_data:
                if entry_grammar and not sense_data.get('grammar'):
                    sense_data['grammar'] = entry_grammar.copy()
                entry['senses'].append(sense_data)
                sense_order += 1
                sense_num += 1

    return entry if entry['senses'] or entry.get('pos') else None


def _parse_standalone_entry(soup, headword_hint=None):
    """Parse standalone entry (idiom, phrase, or derivative without mainentry)."""
    entry = {
        'headword': '',
        'headword_display': '',
        'homograph': '',
        'pos': '',
        'pronunciations': [],
        'senses': [],
        'labels': [],
        'relations': [],
        'attributes': {}
    }

    # Check for standalone idiom entry
    standalone_idiom = soup.find('div', class_='idiom')
    if standalone_idiom:
        idiom_data = parse_oald4_idiom(standalone_idiom)
        if idiom_data:
            entry['headword'] = idiom_data.get('text', '')
            if idiom_data.get('definition') or idiom_data.get('examples'):
                entry['senses'].append({
                    'number': '',
                    'signpost': '',
                    'definition': idiom_data.get('definition', ''),
                    'definition_zh': idiom_data.get('definition_zh', ''),
                    'grammar': [],
                    'labels': [],
                    'examples': idiom_data.get('examples', []),
                    'subsenses': [],
                    'sort_order': 0
                })
        else:
            l_elem = standalone_idiom.find('span', class_='l')
            if l_elem:
                entry['headword'] = clean_text(l_elem.get_text())

        pr_elem = standalone_idiom.find('span', class_='pr')
        if pr_elem:
            pr_text = clean_text(pr_elem.get_text())
            if pr_text:
                entry['pronunciations'].append({
                    'variant': 'uk',
                    'ipa': pr_text,
                    'audio_path': ''
                })

        entry['attributes']['oald/entry_type'] = 'idiom'
        if entry['headword']:
            return entry

    # Check for standalone phrase entry
    standalone_phrase = soup.find('div', class_='phrase')
    if standalone_phrase:
        l_elem = standalone_phrase.find('span', class_='l')
        if l_elem:
            entry['headword'] = clean_text(l_elem.get_text())

        sense_order = 0
        sense_num = 1
        for se in standalone_phrase.find_all('div', class_=['se', 'se3']):
            sense_data = parse_oald4_sense(se, sense_order, sense_number=str(sense_num))
            if sense_data:
                entry['senses'].append(sense_data)
                sense_order += 1
                sense_num += 1

        refmentry = soup.find('div', class_='refmentry')
        if refmentry:
            ref_link = refmentry.find('a', class_='refmentrylink')
            if ref_link:
                entry['attributes']['oald/main_entry'] = clean_text(ref_link.get_text())

        entry['attributes']['oald/entry_type'] = 'phrase'
        if entry['headword']:
            return entry

    # Check for standalone derivative entry
    standalone_deriv = soup.find('div', class_='derivative')
    if standalone_deriv:
        l_elem = standalone_deriv.find('span', class_='l')
        if l_elem:
            entry['headword'] = clean_text(l_elem.get_text())

        pr_elem = standalone_deriv.find('span', class_='pr')
        if pr_elem:
            pr_text = clean_text(pr_elem.get_text())
            if pr_text:
                entry['pronunciations'].append({
                    'variant': 'uk',
                    'ipa': pr_text,
                    'audio_path': ''
                })

        pos_elem = standalone_deriv.find('span', class_='pos')
        if pos_elem:
            entry['pos'] = pos_elem.get('value', '') or clean_text(pos_elem.get_text())

        sense_order = 0
        sense_num = 1
        se2_list = standalone_deriv.find_all('div', class_='se2')
        if se2_list:
            for se2 in se2_list:
                sense_data = parse_oald4_sense(se2, sense_order, sense_number=str(sense_num))
                if sense_data:
                    entry['senses'].append(sense_data)
                    sense_order += 1
                    sense_num += 1
                else:
                    for se3 in se2.find_all('div', class_='se3', recursive=False):
                        subsense_data = parse_oald4_subsense(se3, sense_order)
                        if subsense_data:
                            entry['senses'].append({
                                'number': str(sense_num),
                                'signpost': subsense_data.get('signpost', ''),
                                'definition': subsense_data.get('definition', ''),
                                'definition_zh': subsense_data.get('definition_zh', ''),
                                'grammar': subsense_data.get('grammar', []),
                                'labels': [],
                                'examples': subsense_data.get('examples', []),
                                'subsenses': [],
                                'sort_order': sense_order
                            })
                            sense_order += 1
                            sense_num += 1
        else:
            for se in standalone_deriv.find_all('div', class_='se'):
                sense_data = parse_oald4_sense(se, sense_order, sense_number=str(sense_num))
                if sense_data:
                    entry['senses'].append(sense_data)
                    sense_order += 1
                    sense_num += 1

        if not entry['senses']:
            examples_only = []
            for eg in standalone_deriv.find_all('div', class_='eg'):
                # Pass entire eg div to include <ie> siblings
                ex_text = extract_highlighted_example(eg)
                ex_zh = extract_zh(eg)
                if ex_text:
                    examples_only.append({
                        'text': ex_text,
                        'text_zh': ex_zh
                    })
            if examples_only:
                entry['attributes']['oald/examples'] = examples_only

        refmentry = soup.find('div', class_='refmentry')
        if refmentry:
            ref_link = refmentry.find('a', class_='refmentrylink')
            if ref_link:
                entry['attributes']['oald/main_entry'] = clean_text(ref_link.get_text())

        entry['attributes']['oald/entry_type'] = 'derivative'
        if entry['headword']:
            return entry

    return None


def _parse_mainentry(main_entry, headword_hint=None):
    """Parse a mainentry element into entry data."""
    entry = {
        'headword': '',
        'headword_display': '',
        'homograph': '',
        'pos': '',
        'pronunciations': [],
        'senses': [],
        'labels': [],
        'relations': [],
        'attributes': {}
    }

    # === Headword ===
    hw = main_entry.find('span', class_='hw')
    if hw:
        entry['headword'] = clean_text(hw.get_text())
        homograph = hw.get('homograph', '')
        if homograph:
            entry['homograph'] = homograph
    elif headword_hint:
        entry['headword'] = headword_hint

    if not entry['headword']:
        return None

    # === Part of Speech ===
    pos_elem = main_entry.find('span', class_='pos')
    if pos_elem:
        entry['pos'] = pos_elem.get('value', '') or clean_text(pos_elem.get_text())

    # === Pronunciation ===
    pr_elem = main_entry.find('span', class_='pr')
    if pr_elem:
        pr_text = clean_text(pr_elem.get_text())
        if ';' in pr_text:
            parts = pr_text.split(';')
            entry['pronunciations'].append({
                'variant': 'uk',
                'ipa': parts[0].strip(),
                'audio_path': ''
            })
            entry['pronunciations'].append({
                'variant': 'us',
                'ipa': parts[1].strip(),
                'audio_path': ''
            })
        elif pr_text:
            entry['pronunciations'].append({
                'variant': 'uk',
                'ipa': pr_text,
                'audio_path': ''
            })

    # === Verb forms (pt, pp) ===
    sg = main_entry.find('div', class_='sg')
    if sg:
        gr_elems = sg.find_all('span', class_='gr')
        verb_forms = []
        for gr in gr_elems:
            gr_text = clean_text(gr.get_text())
            bd = gr.find_next_sibling('span', class_='bd')
            if bd:
                form_text = clean_text(bd.get_text())
                if gr_text and form_text:
                    verb_forms.append({'type': gr_text.strip(), 'form': form_text})
        if verb_forms:
            entry['attributes']['oald/verb_forms'] = verb_forms

    # === Senses from mainentry ===
    sense_order = 0
    sense_num = 1  # 1-indexed display number
    se2_list = main_entry.find_all('div', class_='se2', recursive=True)

    if se2_list:
        for se2 in se2_list:
            sense_data = parse_oald4_sense(se2, sense_order, sense_number=str(sense_num))
            if sense_data:
                entry['senses'].append(sense_data)
                sense_order += 1
                sense_num += 1
            else:
                # se2 has no direct content, process its se3 children
                for se3 in se2.find_all('div', class_='se3', recursive=False):
                    subsense_data = parse_oald4_subsense(se3, sense_order)
                    if subsense_data:
                        entry['senses'].append({
                            'number': str(sense_num),
                            'signpost': subsense_data.get('signpost', ''),
                            'definition': subsense_data.get('definition', ''),
                            'definition_zh': subsense_data.get('definition_zh', ''),
                            'grammar': subsense_data.get('grammar', []),
                            'labels': [],
                            'examples': subsense_data.get('examples', []),
                            'subsenses': [],
                            'sort_order': sense_order
                        })
                        sense_order += 1
                        sense_num += 1
    else:
        sg = main_entry.find('div', class_='sg')
        if sg:
            for se in sg.find_all('div', class_='se', recursive=False):
                sense_data = parse_oald4_sense(se, sense_order, sense_number=str(sense_num))
                if sense_data:
                    entry['senses'].append(sense_data)
                    sense_order += 1
                    sense_num += 1

        if not entry['senses']:
            for se in main_entry.find_all('div', class_='se', recursive=True):
                sense_data = parse_oald4_sense(se, sense_order, sense_number=str(sense_num))
                if sense_data:
                    entry['senses'].append(sense_data)
                    sense_order += 1
                    sense_num += 1

    # === Topic headings ===
    topics = []
    for topic in main_entry.find_all('div', class_='topic'):
        topic_text = extract_text_without_zh(topic)
        if topic_text:
            topics.append(topic_text)
    if topics:
        entry['attributes']['oald/topics'] = topics

    return entry


def parse_oald4_idiom(idiom_div):
    """Parse an idiom element."""
    from bs4 import NavigableString

    idiom = {
        'text': '',
        'definition': '',
        'definition_zh': '',
        'examples': []
    }

    # Idiom text
    l_elem = idiom_div.find('span', class_='l')
    if l_elem:
        idiom['text'] = clean_text(l_elem.get_text())

    # Find sense (se or se3)
    se = idiom_div.find('div', class_=['se', 'se3'])
    if se:
        # First try df element
        df = se.find(['span', 'div'], class_='df')
        if df:
            idiom['definition'] = extract_text_without_zh(df)
            idiom['definition_zh'] = extract_zh(df)
        else:
            # Check for xrg (cross-reference) first
            xrg = se.find('span', class_='xrg')
            if xrg:
                idiom['definition'] = extract_text_without_zh(xrg)
                idiom['definition_zh'] = extract_zh(xrg)
            else:
                # No df or xrg - definition might be directly in se
                # Extract text excluding nested elements like eg
                def_text_parts = []
                def_zh_parts = []

                for child in se.children:
                    if isinstance(child, NavigableString):
                        text = str(child).strip()
                        if text:
                            def_text_parts.append(text)
                    elif child.name == 'zh':
                        zh_text = clean_text(child.get_text())
                        def_zh_parts.append(zh_text)
                    elif child.name == 'div' and 'eg' in child.get('class', []):
                        # Skip example divs
                        continue
                    elif child.name == 'span' and 'xrg' in child.get('class', []):
                        # Skip cross-references (already handled above)
                        continue
                    else:
                        # Get text from other elements (like span with reg)
                        text = extract_text_without_zh(child)
                        if text:
                            def_text_parts.append(text)

                if def_text_parts:
                    idiom['definition'] = ' '.join(def_text_parts)
                if def_zh_parts:
                    # Use the last/main Chinese definition (skip parenthetical ones)
                    idiom['definition_zh'] = def_zh_parts[-1] if def_zh_parts else ''

        # Examples
        ex_order = 0
        for eg in se.find_all('div', class_='eg'):
            # Pass entire eg div to include <ie> siblings
            ex_text = extract_highlighted_example(eg)
            ex_zh = extract_zh(eg)
            if ex_text:
                idiom['examples'].append({
                    'text': ex_text,
                    'text_zh': ex_zh,
                    'sort_order': ex_order
                })
                ex_order += 1

    if idiom['text']:
        # Check if definition is a cross-reference (→word.)
        crossref = parse_cross_reference(idiom['definition'])
        if crossref:
            idiom['crossref'] = crossref
        return idiom
    return None


def parse_oald4_phrase(phrase_div):
    """Parse a phrase element."""
    phrase = {
        'text': '',
        'definition': '',
        'definition_zh': ''
    }

    # Phrase text
    l_elem = phrase_div.find('span', class_='l')
    if l_elem:
        phrase['text'] = clean_text(l_elem.get_text())

    # Find sense
    se = phrase_div.find('div', class_='se')
    if se:
        df = se.find('span', class_='df')
        if df:
            phrase['definition'] = extract_text_without_zh(df)
            phrase['definition_zh'] = extract_zh(df)

    if phrase['text']:
        return phrase
    return None


def parse_oald4_sense(sense_elem, order=0, sense_number=None):
    """Parse a single sense element (se, se2 or se3).

    Args:
        sense_elem: BeautifulSoup element for the sense
        order: Sort order
        sense_number: Display number for this sense (e.g., "1", "2", "3")

    Returns:
        Dictionary with sense data, or None if no meaningful content
    """
    sense = {
        'number': sense_number or '',
        'signpost': '',
        'definition': '',
        'definition_zh': '',
        'grammar': [],
        'labels': [],
        'examples': [],
        'subsenses': [],
        'sort_order': order
    }

    # === Check if this is a container (se2) with only subsenses (se3) ===
    # In this case, we should process the se3 elements directly
    has_direct_df = sense_elem.find('span', class_='df', recursive=False)
    has_se3 = sense_elem.find('div', class_='se3', recursive=False)

    # If se2 has no direct definition but has se3, don't create empty parent sense
    if not has_direct_df and has_se3:
        # Return None - the caller should process se3 directly
        return None

    # === Grammar labels (nac = noun countability, vps = verb pattern) ===
    # Note: value attribute is Chinese, text content is English - prefer English text
    for nac in sense_elem.find_all('span', class_='nac'):
        # Skip if inside a nested se3, eg, or df (definition)
        # Grammar inside definitions belongs to variant words, not the sense
        parent_se3 = nac.find_parent('div', class_='se3')
        parent_eg = nac.find_parent('div', class_='eg')
        parent_df = nac.find_parent(['span', 'div'], class_='df')
        if (parent_se3 and parent_se3 != sense_elem) or parent_eg or parent_df:
            continue
        # Prefer English text content over Chinese value attribute
        nac_value = clean_text(nac.get_text()) or nac.get('value', '')
        if nac_value and nac_value not in sense['grammar']:
            sense['grammar'].append(nac_value)

    for vps in sense_elem.find_all('span', class_='vps'):
        # Skip if inside a nested se3 or df (definition)
        parent_se3 = vps.find_parent('div', class_='se3')
        parent_df = vps.find_parent(['span', 'div'], class_='df')
        if (parent_se3 and parent_se3 != sense_elem) or parent_df:
            continue
        # Prefer English text content over Chinese value attribute
        vps_value = clean_text(vps.get_text()) or vps.get('value', '')
        if vps_value and vps_value not in sense['grammar']:
            sense['grammar'].append(vps_value)

    # === Register labels (reg) ===
    # Structure: <span class="reg" value="文">fml</span>
    # value attribute is Chinese, text content is English - use English text
    for reg in sense_elem.find_all('span', class_='reg'):
        # Skip if inside a nested se3, eg, or df (definition)
        # Labels inside definitions belong to variant words, not the sense
        parent_se3 = reg.find_parent('div', class_='se3')
        parent_eg = reg.find_parent('div', class_='eg')
        parent_df = reg.find_parent(['span', 'div'], class_='df')
        if (parent_se3 and parent_se3 != sense_elem) or parent_eg or parent_df:
            continue
        reg_text = clean_text(reg.get_text())  # English label (e.g., "fml", "infml")
        if reg_text:
            sense['labels'].append({'type': 'register', 'value': reg_text})

    # === Definition ===
    # df can be either span or div
    df = sense_elem.find(['span', 'div'], class_='df', recursive=False)
    if not df:
        # Sometimes df is not direct child but not inside se3
        for candidate in sense_elem.find_all(['span', 'div'], class_='df'):
            parent_se3 = candidate.find_parent('div', class_='se3')
            if not parent_se3 or parent_se3 == sense_elem:
                df = candidate
                break

    if df:
        sense['definition'] = extract_text_without_zh(df)
        sense['definition_zh'] = extract_zh(df)
    else:
        # Check for xrg (cross-reference) which sometimes serves as definition
        xrg = sense_elem.find('span', class_='xrg', recursive=False)
        if not xrg:
            for candidate in sense_elem.find_all('span', class_='xrg'):
                parent_se3 = candidate.find_parent('div', class_='se3')
                if not parent_se3 or parent_se3 == sense_elem:
                    xrg = candidate
                    break

        if xrg:
            sense['definition'] = extract_text_without_zh(xrg)
            sense['definition_zh'] = extract_zh(xrg)

    # === Bold phrases (bd) as signpost ===
    bd_elems = []
    for bd in sense_elem.find_all('span', class_='bd', recursive=False):
        bd_elems.append(bd)
    if bd_elems:
        bd_texts = [clean_text(bd.get_text()) for bd in bd_elems]
        sense['signpost'] = '; '.join(filter(None, bd_texts))

    # === Examples ===
    ex_order = 0
    for eg in sense_elem.find_all('div', class_='eg'):
        # Skip if inside a nested se3
        parent_se3 = eg.find_parent('div', class_='se3')
        if parent_se3 and parent_se3 != sense_elem:
            continue

        # Pass entire eg div to include <ie> siblings
        ex_text = extract_highlighted_example(eg)
        ex_zh = extract_zh(eg)

        if ex_text:
            sense['examples'].append({
                'text': ex_text,
                'text_zh': ex_zh,
                'sort_order': ex_order
            })
            ex_order += 1

    # === Subsenses (se3) - only if this sense has its own definition ===
    if sense['definition']:
        sub_order = 0
        for se3 in sense_elem.find_all('div', class_='se3', recursive=False):
            subsense = parse_oald4_subsense(se3, sub_order)
            if subsense:
                sense['subsenses'].append(subsense)
                sub_order += 1

    # Only return if has definition or examples
    if sense['definition'] or sense['examples']:
        return sense

    return None


def parse_oald4_subsense(se3_elem, order=0):
    """Parse a subsense element (se3)."""
    subsense = {
        'definition': '',
        'definition_zh': '',
        'grammar': [],
        'examples': [],
        'sort_order': order
    }

    # === Grammar ===
    # Note: value attribute is Chinese, text content is English - prefer English text
    for nac_w in se3_elem.find_all('nac-w', recursive=False):
        nac = nac_w.find('span', class_='nac')
        if nac:
            # Prefer English text content over Chinese value attribute
            nac_value = clean_text(nac.get_text()) or nac.get('value', '')
            if nac_value:
                subsense['grammar'].append(nac_value)

    for vps_w in se3_elem.find_all('vps-w', recursive=False):
        vps = vps_w.find('span', class_='vps')
        if vps:
            # Prefer English text content over Chinese value attribute
            vps_value = clean_text(vps.get_text()) or vps.get('value', '')
            if vps_value:
                subsense['grammar'].append(vps_value)

    # === Definition ===
    df = se3_elem.find('span', class_='df', recursive=False)
    if df:
        subsense['definition'] = extract_text_without_zh(df)
        subsense['definition_zh'] = extract_zh(df)

    # === Examples ===
    ex_order = 0
    for eg in se3_elem.find_all('div', class_='eg', recursive=False):
        # Pass entire eg div to include <ie> siblings
        ex_text = extract_highlighted_example(eg)
        ex_zh = extract_zh(eg)

        if ex_text:
            subsense['examples'].append({
                'text': ex_text,
                'text_zh': ex_zh,
                'sort_order': ex_order
            })
            ex_order += 1

    if subsense['definition']:
        return subsense

    return None


# ============================================================
# Database Operations
# ============================================================

def create_database(db_path):
    """Create database with schema."""
    conn = sqlite3.connect(db_path)
    # Use unified init_database from lexdb_schema
    init_database(conn)
    return conn


def insert_entry(conn, dict_id, entry):
    """Insert parsed entry into database."""
    cursor = conn.cursor()

    # Build headword display with homograph number
    headword_display = entry.get('headword_display', '')
    if entry.get('homograph'):
        headword_display = f"{entry['headword']}{entry['homograph']}"

    # Insert entry
    cursor.execute("""
        INSERT INTO entries (dict_id, headword, headword_lower, headword_display)
        VALUES (?, ?, ?, ?)
    """, (dict_id, entry['headword'], entry['headword'].lower(), headword_display))

    entry_id = cursor.lastrowid

    # Insert POS as label
    if entry.get('pos'):
        cursor.execute("""
            INSERT INTO labels (entry_id, label_type, label_value, sort_order)
            VALUES (?, 'pos', ?, 0)
        """, (entry_id, entry['pos']))

    # Insert pronunciations
    for i, pron in enumerate(entry.get('pronunciations', [])):
        if pron.get('ipa'):  # Only insert if has IPA
            cursor.execute("""
                INSERT INTO pronunciations (entry_id, variant, ipa, audio_path, sort_order)
                VALUES (?, ?, ?, ?, ?)
            """, (entry_id, pron.get('variant', ''), pron.get('ipa', ''),
                  pron.get('audio_path', ''), i))

    # Insert senses
    for sense in entry.get('senses', []):
        # Skip senses without definition or examples
        if not sense.get('definition') and not sense.get('examples'):
            continue

        # signpost is for "also" variants like "phone call, ring", not grammar labels
        signpost = sense.get('signpost', '')

        cursor.execute("""
            INSERT INTO senses (entry_id, sense_number, signpost, definition, definition_zh, sort_order)
            VALUES (?, ?, ?, ?, ?, ?)
        """, (entry_id, sense.get('number', ''), signpost,
              sense.get('definition', ''), sense.get('definition_zh', ''),
              sense.get('sort_order', 0)))

        sense_id = cursor.lastrowid

        # Insert examples
        for ex in sense.get('examples', []):
            cursor.execute("""
                INSERT INTO examples (sense_id, text, text_zh, sort_order)
                VALUES (?, ?, ?, ?)
            """, (sense_id, ex.get('text', ''), ex.get('text_zh', ''),
                  ex.get('sort_order', 0)))

        # Insert grammar patterns
        for i, gram in enumerate(sense.get('grammar', [])):
            cursor.execute("""
                INSERT INTO grammar_patterns (sense_id, pattern, sort_order)
                VALUES (?, ?, ?)
            """, (sense_id, gram, i))

        # Insert sense labels
        for i, label in enumerate(sense.get('labels', [])):
            cursor.execute("""
                INSERT INTO labels (sense_id, label_type, label_value, sort_order)
                VALUES (?, ?, ?, ?)
            """, (sense_id, label.get('type', 'register'), label.get('value', ''), i))

        # Insert subsenses as additional senses
        for subsense in sense.get('subsenses', []):
            # Skip empty subsenses
            if not subsense.get('definition') and not subsense.get('examples'):
                continue

            sub_signpost = ' '.join(subsense.get('grammar', []))
            cursor.execute("""
                INSERT INTO senses (entry_id, sense_number, signpost, definition, definition_zh, sort_order)
                VALUES (?, ?, ?, ?, ?, ?)
            """, (entry_id, '', sub_signpost,
                  subsense.get('definition', ''), subsense.get('definition_zh', ''),
                  sense.get('sort_order', 0) * 100 + subsense.get('sort_order', 0)))

            subsense_id = cursor.lastrowid

            for ex in subsense.get('examples', []):
                cursor.execute("""
                    INSERT INTO examples (sense_id, text, text_zh, sort_order)
                    VALUES (?, ?, ?, ?)
                """, (subsense_id, ex.get('text', ''), ex.get('text_zh', ''),
                      ex.get('sort_order', 0)))

    # Insert relations (cross-refs, etc.)
    for idx, rel in enumerate(entry.get('relations', [])):
        cursor.execute("""
            INSERT INTO relations (entry_id, sense_id, relation_type, prefix, clickable, suffix, target_word, target_sense, sort_order)
            VALUES (?, NULL, ?, ?, ?, ?, ?, ?, ?)
        """, (
            entry_id,
            rel.get('type', 'cross_ref'),
            rel.get('prefix'),
            rel.get('clickable', ''),
            rel.get('suffix'),
            rel.get('target_word', ''),
            rel.get('target_sense'),
            idx
        ))

    # Insert entry attributes (compressed JSON for complex data)
    for key, value in entry.get('attributes', {}).items():
        if isinstance(value, (list, dict)):
            # Compress JSON for complex data
            json_str = json.dumps(value, ensure_ascii=False)
            compressed = zlib.compress(json_str.encode('utf-8'))
            cursor.execute("""
                INSERT OR REPLACE INTO entry_attributes (entry_id, attr_key, attr_value, attr_type)
                VALUES (?, ?, ?, 'json_compressed')
            """, (entry_id, key, compressed))
        else:
            cursor.execute("""
                INSERT OR REPLACE INTO entry_attributes (entry_id, attr_key, attr_value, attr_type)
                VALUES (?, ?, ?, 'text')
            """, (entry_id, key, str(value)))

    return entry_id


# ============================================================
# Main Conversion
# ============================================================

def convert_oald4(mdx_path, output_dir=None):
    """Convert OALD4 MDX to SQLite database.

    Args:
        mdx_path: Path to MDX file
        output_dir: Output directory (default: same as MDX)
    """
    mdx_path = Path(mdx_path)
    if not mdx_path.exists():
        print(f"Error: MDX file not found: {mdx_path}")
        sys.exit(1)

    if output_dir is None:
        output_dir = mdx_path.parent
    else:
        output_dir = Path(output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)

    db_path = output_dir / f"{mdx_path.stem}.db"
    dict_id = "oald"
    dict_name = "Oxford Advanced Learner's Dictionary (4th Edition)"

    print(f"Converting: {mdx_path.name}")
    print(f"Output: {db_path}")

    # Create database
    print(f"Creating database: {db_path.name}")
    conn = create_database(str(db_path))

    # Register dictionary
    conn.execute("""
        INSERT OR REPLACE INTO dictionaries (dict_id, name, version, source_file, created_at)
        VALUES (?, ?, ?, ?, ?)
    """, (dict_id, dict_name, "4", mdx_path.name, datetime.now().isoformat()))

    # Read MDX
    print("Reading MDX file...")
    mdx = MDX(str(mdx_path))
    items = list(mdx.items())
    total = len(items)
    print(f"Total entries in MDX: {total}")

    # Parse and import entries
    print("Parsing and importing entries...")
    imported = 0
    skipped = 0
    errors = 0

    for i, (key, value) in enumerate(items):
        if i % 1000 == 0:
            print(f"  Progress: {i}/{total} ({imported} imported, {skipped} skipped)")

        try:
            key_str = key.decode('utf-8') if isinstance(key, bytes) else key
            html = value.decode('utf-8') if isinstance(value, bytes) else value

            # Skip special entries
            if key_str.startswith('@') or key_str.startswith('#'):
                skipped += 1
                continue

            # Skip redirects
            if html.strip().startswith('@@@LINK='):
                skipped += 1
                continue

            # Skip very short entries (likely just links)
            if len(html) < 50:
                skipped += 1
                continue

            # Parse entry - now returns a LIST
            entries = parse_oald4_entry(html, key_str)

            # Insert all entries from this HTML
            for entry in entries:
                if entry and entry.get('senses'):
                    insert_entry(conn, dict_id, entry)
                    imported += 1

            if not entries:
                skipped += 1

        except Exception as e:
            errors += 1
            if errors <= 10:
                print(f"Warning: Parse failed [{key_str[:30] if key_str else '?'}]: {e}")

    # Update entry count
    conn.execute("UPDATE dictionaries SET entry_count = ? WHERE dict_id = ?",
                 (imported, dict_id))

    conn.commit()

    print(f"\nImport complete:")
    print(f"  Imported: {imported}")
    print(f"  Skipped: {skipped}")
    print(f"  Errors: {errors}")

    # Final stats
    cursor = conn.cursor()
    cursor.execute("SELECT COUNT(*) FROM entries WHERE dict_id = ?", (dict_id,))
    entry_count = cursor.fetchone()[0]
    cursor.execute("SELECT COUNT(*) FROM senses")
    sense_count = cursor.fetchone()[0]
    cursor.execute("SELECT COUNT(*) FROM examples")
    example_count = cursor.fetchone()[0]

    print(f"\nDatabase stats:")
    print(f"  Entries: {entry_count}")
    print(f"  Senses: {sense_count}")
    print(f"  Examples: {example_count}")

    conn.close()
    print(f"\nDone! Database saved to: {db_path}")


# ============================================================
# Entry Point
# ============================================================

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: python mdx2lexdb_oald.py <OALD4.mdx> [output_dir]")
        print("Example: python mdx2lexdb_oald.py oald4ec.mdx")
        sys.exit(1)

    mdx_file = sys.argv[1]
    output_dir = sys.argv[2] if len(sys.argv) > 2 else None

    convert_oald4(mdx_file, output_dir)
