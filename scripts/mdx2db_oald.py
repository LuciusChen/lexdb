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


def extract_definition_with_format(element):
    """Extract definition text preserving format markers for UI rendering.

    Preserves:
    - Variant words (<span class="bd">, <span class="l">, <l>) as <<l>>...<</l>>
    - Register labels (<span class="reg">) as <<reg>>...<</reg>>
    - Pronunciations (<span class="pr">) as <<pr>>...<</pr>>
    - Grammar labels (<span class="nac">, <span class="vps">) as <<gram>>...<</gram>>
    - Part of speech refs (<span class="gr">) as <<pos>>...<</pos>>
    """
    if not element:
        return ""

    # Make a copy
    elem_copy = BeautifulSoup(str(element), 'html.parser')

    # Remove all <zh> tags
    for zh in elem_copy.find_all('zh'):
        zh.decompose()

    # Format variant words - <span class="bd"> (bold), <span class="l">, <l>
    for bd in elem_copy.find_all('span', class_='bd'):
        text = bd.get_text().strip()
        if text:
            bd.replace_with(f' <<l>>{text}<</l>> ')
    for l_elem in elem_copy.find_all('span', class_='l'):
        text = l_elem.get_text().strip()
        if text:
            l_elem.replace_with(f' <<l>>{text}<</l>> ')
    for l_elem in elem_copy.find_all('l'):
        text = l_elem.get_text().strip()
        if text:
            l_elem.replace_with(f' <<l>>{text}<</l>> ')

    # Format register labels (Brit, US, infml, fml, etc.)
    for reg in elem_copy.find_all('span', class_='reg'):
        text = clean_text(reg.get_text())
        if text:
            reg.replace_with(f' <<reg>>{text}<</reg>> ')

    # Format pronunciations - mark for UI rendering
    for pr in elem_copy.find_all('span', class_='pr'):
        text = pr.get_text().strip()
        if text:
            # Add slashes if not already present
            if not text.startswith('/'):
                text = f'/{text}/'
            pr.replace_with(f' <<pr>>{text}<</pr>> ')

    # Format grammar labels with markers for UI
    for nac in elem_copy.find_all('span', class_='nac'):
        # Prefer English text over Chinese value attribute
        text = clean_text(nac.get_text()) or nac.get('value', '')
        if text:
            # Add brackets if not already present
            if not text.startswith('['):
                text = f'[{text}]'
            nac.replace_with(f' <<gram>>{text}<</gram>> ')

    for vps in elem_copy.find_all('span', class_='vps'):
        # Prefer English text over Chinese value attribute
        text = clean_text(vps.get_text()) or vps.get('value', '')
        if text:
            if not text.startswith('['):
                text = f'[{text}]'
            vps.replace_with(f' <<gram>>{text}<</gram>> ')

    # Format inline part of speech references (like "n" in definitions)
    # Uses <<pos>> marker for hot pink color (same as adj, n, v etc.)
    for gr in elem_copy.find_all('span', class_='gr'):
        text = clean_text(gr.get_text())
        if text:
            # Add space after to preserve word boundaries (clean_text normalizes extra spaces)
            gr.replace_with(f'<<pos>>{text}<</pos>> ')

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

    Returns text with <ie> as 'ie: ...' and <eg/gl> as 'eg: ...' format.
    """
    if not element:
        return ""

    # Make a copy
    elem_copy = BeautifulSoup(str(element), 'html.parser')

    # Remove <zh> tags first
    for zh in elem_copy.find_all('zh'):
        zh.decompose()

    # Convert <ie> (implicit explanation) to "ie: ..." format
    # Try tag name 'ie', class='ie', and <span class="ie">
    for ie in elem_copy.find_all('ie'):
        text = ie.get_text().strip()
        ie.replace_with(f' (ie: {text})')
    for ie in elem_copy.find_all(class_='ie'):
        text = ie.get_text().strip()
        ie.replace_with(f' (ie: {text})')

    # Convert <viz> (example gloss/explanation) to "eg: ..." format
    # OALD uses <span class="viz"> for inline explanations in examples
    # Note: viz is usually already inside parentheses, so don't add more
    for viz in elem_copy.find_all('span', class_='viz'):
        text = viz.get_text().strip()
        viz.replace_with(f'eg: {text}')
    for viz in elem_copy.find_all('viz'):
        text = viz.get_text().strip()
        viz.replace_with(f'eg: {text}')
    # Also try other possible tag names
    for eg in elem_copy.find_all('eg'):
        text = eg.get_text().strip()
        eg.replace_with(f'eg: {text}')
    for gl in elem_copy.find_all('gl'):
        text = gl.get_text().strip()
        gl.replace_with(f'eg: {text}')
    # Check class='eg' but skip div containers
    for eg in elem_copy.find_all(class_='eg'):
        if eg.name == 'div':
            continue
        text = eg.get_text().strip()
        eg.replace_with(f'eg: {text}')

    return clean_text(elem_copy.get_text())


def parse_cross_reference(text):
    """Parse cross-reference text like '→necessity.' or '→coin <<pos>>v<</pos>>.'

    Returns:
        dict with 'is_crossref', 'prefix', 'clickable', 'suffix', 'target_word', 'target_sense'
        or None if not a cross-reference
    """
    if not text:
        return None

    # Pattern: →word. or → word. (may include format markers like <<pos>>v<</pos>>)
    match = re.match(r'^→\s*([^.]+)\.$', text.strip())
    if match:
        target = match.group(1).strip()
        # Separate clickable word from suffix (e.g., "coin <<pos>>v<</pos>>" -> "coin", "<<pos>>v<</pos>>")
        # Look for format markers or trailing text after the main word
        suffix_match = re.match(r'^(\S+)((?:\s+<<\w+>>.+)?)\s*$', target)
        if suffix_match:
            clickable = suffix_match.group(1)
            suffix = suffix_match.group(2).strip() if suffix_match.group(2) else None
        else:
            clickable = target
            suffix = None
        return {
            'is_crossref': True,
            'prefix': '→',
            'clickable': clickable,
            'suffix': suffix,
            'target_word': clickable.lower(),
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

        # Phrasal verbs (phrsubentry)
        phrasal_verbs = []
        for phr_sub in oald4ec.find_all('div', class_='phrsubentry'):
            for phrase_div in phr_sub.find_all('div', class_='phrase'):
                phrase_data = parse_oald4_phrase(phrase_div)
                if phrase_data:
                    phrasal_verbs.append(phrase_data)
        if phrasal_verbs:
            entries[0]['attributes']['oald/phrasal-verbs'] = phrasal_verbs

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

        # Usage notes
        usage_div = oald4ec.find('div', class_='usage')
        if usage_div:
            usage_data = parse_oald4_usage(usage_div)
            if usage_data:
                entries[0]['attributes']['oald/usage'] = usage_data

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

    # === Verb forms (pt, pp) and adjective forms (-er, -est) ===
    sg = main_entry.find('div', class_='sg')
    if sg:
        # Verb forms: <span class="gr">pt</span> <span class="bd">-ed</span>
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

        # Adjective comparative/superlative forms:
        # (<span class="bd">-nger </span><span class="pr">...</span><span class="bd">-ngest</span><span class="pr">...</span>)
        # These are direct bd elements not preceded by gr
        from bs4 import NavigableString
        inflection_parts = []
        posg = sg.find('div', class_='posg')
        # Look for content after posg that forms inflection pattern
        if posg:
            started = False
            for child in sg.children:
                if child == posg:
                    started = True
                    continue
                if not started:
                    continue
                # Stop when we hit se2 or other sense elements
                if hasattr(child, 'name') and child.name == 'div':
                    break
                if isinstance(child, NavigableString):
                    text = str(child)
                    if text.strip():
                        inflection_parts.append(text)
                elif hasattr(child, 'name'):
                    classes = child.get('class', [])
                    if 'bd' in classes:
                        # Mark with <<l>> for blue variant face
                        inflection_parts.append('<<l>>' + child.get_text() + '<</l>>')
                    elif 'pr' in classes:
                        # Mark pronunciation with <<pr>>
                        inflection_parts.append('<<pr>>' + child.get_text() + '<</pr>>')
            if inflection_parts:
                inflection_text = ''.join(inflection_parts).strip()
                inflection_text = re.sub(r'\s+', ' ', inflection_text)
                if inflection_text and '<<l>>' in inflection_text:
                    entry['attributes']['oald/inflections'] = inflection_text

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
                # se2 has no direct definition, but may have reg label and se3 children
                # e.g., <se2><span class="reg">becoming dated</span><se3>...</se3><se3>...</se3></se2>
                se3_list = se2.find_all('div', class_='se3', recursive=False)
                if se3_list:
                    # Extract parent register label if present
                    parent_labels = []
                    for reg in se2.find_all('span', class_='reg', recursive=False):
                        reg_text = clean_text(reg.get_text())
                        if reg_text:
                            parent_labels.append({'type': 'register', 'value': reg_text})

                    # Process se3 children as subsenses with letter numbering
                    subsenses = []
                    sub_letter = ord('a')
                    for se3 in se3_list:
                        subsense_data = parse_oald4_subsense(se3, len(subsenses))
                        if subsense_data:
                            subsense_data['number'] = chr(sub_letter)
                            subsenses.append(subsense_data)
                            sub_letter += 1

                    if subsenses:
                        # Create parent sense with label and subsenses
                        entry['senses'].append({
                            'number': str(sense_num),
                            'signpost': '',
                            'definition': '',
                            'definition_zh': '',
                            'grammar': [],
                            'labels': parent_labels,
                            'examples': [],
                            'subsenses': subsenses,
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


def parse_oald4_usage(usage_div):
    """Parse a usage notes section.

    Structure: <div class="usage">
      <div class="use1">text with <span class="bd">highlighted words</span>
        <div class="eg">example</div>
        <div class="use3">nested explanation
          <div class="use4">deeper nested content
            <div class="eg">example</div>
          </div>
        </div>
      </div>
    </div>
    """
    def parse_use_element(elem, level=0):
        """Recursively parse a use element (use1, use3, use4)."""
        result = {
            'level': level,
            'text': '',
            'text_zh': '',
            'examples': [],
            'children': []
        }

        # Extract text content (before child elements)
        text_parts = []
        text_zh = ''
        for child in elem.children:
            if isinstance(child, str):
                text_parts.append(child)
            elif child.name == 'zh':
                text_zh = clean_text(child.get_text())
            elif child.name == 'span':
                classes = child.get('class', [])
                text_content = child.get_text().strip()  # Strip inner whitespace from prettified HTML
                if 'bd' in classes or 'ex' in classes:
                    # Bold/highlighted word or example word - use same marker
                    # Add trailing space - clean_text normalizes multiple spaces
                    text_parts.append(f'<<l>>{text_content}<</l>> ')
                else:
                    text_parts.append(text_content)
            elif child.name == 'div':
                # Stop at child divs - they're processed separately
                break
            else:
                text_parts.append(child.get_text() if hasattr(child, 'get_text') else str(child))

        result['text'] = clean_text(''.join(text_parts))
        result['text_zh'] = text_zh

        # Extract examples
        for eg in elem.find_all('div', class_='eg', recursive=False):
            ex_text = extract_highlighted_example(eg)
            ex_zh = extract_zh(eg)
            if ex_text:
                result['examples'].append({
                    'text': ex_text,
                    'text_zh': ex_zh
                })

        # Recursively process nested use elements (use3, use4, etc.)
        for use_class in ['use2', 'use3', 'use4', 'use5']:
            for child_use in elem.find_all('div', class_=use_class, recursive=False):
                child_data = parse_use_element(child_use, level + 1)
                if child_data['text'] or child_data['examples'] or child_data['children']:
                    result['children'].append(child_data)

        return result

    usage_data = []

    # Process top-level use1 elements
    for use1 in usage_div.find_all('div', class_='use1', recursive=False):
        use_data = parse_use_element(use1, 0)
        if use_data['text'] or use_data['examples'] or use_data['children']:
            usage_data.append(use_data)

    return usage_data if usage_data else None


def parse_idiom_example(eg_elem):
    """Parse an idiom example, extracting register labels (joc, fig, etc.)."""
    ex_text = extract_highlighted_example(eg_elem)
    ex_zh = extract_zh(eg_elem)

    if not ex_text:
        return None

    # Check for register label at start of example
    reg_elem = eg_elem.find('span', class_='reg', recursive=False)
    label = ''
    if reg_elem:
        label = clean_text(reg_elem.get_text())

    return {
        'text': ex_text,
        'text_zh': ex_zh,
        'label': label  # joc, fig, etc.
    }


def parse_oald4_idiom(idiom_div):
    """Parse an idiom element.

    Supports idioms with multiple subsenses (se3 elements).
    """
    from bs4 import NavigableString

    idiom = {
        'text': '',
        'definition': '',
        'definition_zh': '',
        'labels': [],  # Register labels like fml, infml
        'examples': [],
        'senses': []  # Subsenses for idioms with multiple meanings
    }

    # Idiom text
    l_elem = idiom_div.find('span', class_='l')
    if l_elem:
        idiom['text'] = clean_text(l_elem.get_text())

    # Check for multiple se3 subsenses first
    se3_list = idiom_div.find_all('div', class_='se3', recursive=False)
    if not se3_list:
        # Try finding se3 inside se
        se = idiom_div.find('div', class_='se')
        if se:
            se3_list = se.find_all('div', class_='se3', recursive=False)

    if len(se3_list) > 1:
        # Multiple subsenses - parse each one
        for idx, se3 in enumerate(se3_list):
            subsense = {
                'number': str(idx + 1),
                'definition': '',
                'definition_zh': '',
                'labels': [],
                'examples': []
            }

            # Definition
            df = se3.find('span', class_='df')
            if df:
                subsense['definition'] = extract_definition_with_format(df)
                subsense['definition_zh'] = extract_zh(df)

            # Examples with register labels
            for eg in se3.find_all('div', class_='eg', recursive=False):
                ex_data = parse_idiom_example(eg)
                if ex_data:
                    subsense['examples'].append(ex_data)

            idiom['senses'].append(subsense)
    else:
        # Single sense or no se3 - use original logic
        se = idiom_div.find('div', class_=['se', 'se3'])
        if se:
            # Extract register labels (fml, infml, etc.) - they are outside df
            for reg in se.find_all('span', class_='reg', recursive=False):
                reg_text = clean_text(reg.get_text())
                if reg_text:
                    idiom['labels'].append({'type': 'register', 'value': reg_text})

            # First try df element
            df = se.find(['span', 'div'], class_='df')
            if df:
                idiom['definition'] = extract_definition_with_format(df)
                idiom['definition_zh'] = extract_zh(df)
            else:
                # Check for xrg (cross-reference) first
                xrg = se.find('span', class_='xrg')
                if xrg:
                    idiom['definition'] = extract_definition_with_format(xrg)
                    idiom['definition_zh'] = extract_zh(xrg)
                    # Extract cross-reference target from <a class="xr"> link
                    xr_link = xrg.find('a', class_='xr')
                    if xr_link:
                        href = xr_link.get('href', '')
                        link_text = xr_link.get_text().strip()
                        raw_target = href.replace('entry://', '') if href.startswith('entry://') else link_text
                        # Normalize target_word: remove superscripts, numbers, spaces
                        # "better³ 3" -> "better"
                        target_word = re.sub(r'[⁰¹²³⁴⁵⁶⁷⁸⁹0-9\s]+', '', raw_target).lower()
                        idiom['crossref'] = {
                            'is_crossref': True,
                            'prefix': '→',
                            'clickable': link_text,
                            'suffix': None,
                            'target_word': target_word,
                            'target_sense': None
                        }
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
                ex_data = parse_idiom_example(eg)
                if ex_data:
                    ex_data['sort_order'] = ex_order
                    idiom['examples'].append(ex_data)
                    ex_order += 1

    if idiom['text']:
        # Check if definition is a cross-reference (→word.)
        crossref = parse_cross_reference(idiom['definition'])
        if crossref:
            idiom['crossref'] = crossref
        return idiom
    return None


def parse_oald4_phrase(phrase_div):
    """Parse a phrase element (phrasal verb).

    Returns a structure compatible with lexdb-ui--render-phrasal-verbs:
    {
        'headword': 'part with sth',
        'senses': [{
            'definition': '...',
            'definition_zh': '...',
            'examples': [{'text': '...', 'text_zh': '...'}]
        }]
    }
    """
    # Phrase text
    l_elem = phrase_div.find('span', class_='l')
    if not l_elem:
        return None

    headword = clean_text(l_elem.get_text())
    if not headword:
        return None

    # Build sense
    sense = {
        'definition': '',
        'definition_zh': '',
        'examples': []
    }

    se = phrase_div.find('div', class_='se')
    if se:
        df = se.find('span', class_='df')
        if df:
            sense['definition'] = extract_definition_with_format(df)
            sense['definition_zh'] = extract_zh(df)

        # Extract examples
        for eg in se.find_all('div', class_='eg', recursive=False):
            ex_text = extract_highlighted_example(eg)
            ex_zh = extract_zh(eg)
            if ex_text:
                sense['examples'].append({
                    'text': ex_text,
                    'text_zh': ex_zh
                })

    return {
        'headword': headword,
        'senses': [sense] if sense['definition'] else []
    }


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
        'plural': '',  # Plural forms like "(pl manifestos or manifestoes)"
        'definition': '',
        'definition_zh': '',
        'grammar': [],
        'labels': [],
        'examples': [],
        'subsenses': [],
        'sort_order': order
    }

    # === Grammar labels (nac = noun countability, vps = verb pattern) ===
    # Note: value attribute is Chinese, text content is English - prefer English text

    # First, check for nac-w wrappers at sense level (direct children)
    for nac_w in sense_elem.find_all('nac-w', recursive=False):
        nac = nac_w.find('span', class_='nac')
        if nac:
            nac_value = clean_text(nac.get_text()) or nac.get('value', '')
            if nac_value and nac_value not in sense['grammar']:
                sense['grammar'].append(nac_value)

    # Also check for span.nac not in wrappers
    for nac in sense_elem.find_all('span', class_='nac'):
        # Skip if inside a nested se3, eg, df, or nac-w (already handled above)
        # Grammar inside definitions belongs to variant words, not the sense
        parent_se3 = nac.find_parent('div', class_='se3')
        parent_eg = nac.find_parent('div', class_='eg')
        parent_df = nac.find_parent(['span', 'div'], class_='df')
        parent_nac_w = nac.find_parent('nac-w')
        if (parent_se3 and parent_se3 != sense_elem) or parent_eg or parent_df or parent_nac_w:
            continue
        # Prefer English text content over Chinese value attribute
        nac_value = clean_text(nac.get_text()) or nac.get('value', '')
        if nac_value and nac_value not in sense['grammar']:
            sense['grammar'].append(nac_value)

    # Check for vps-w wrappers at sense level (direct children)
    for vps_w in sense_elem.find_all('vps-w', recursive=False):
        vps = vps_w.find('span', class_='vps')
        if vps:
            vps_value = clean_text(vps.get_text()) or vps.get('value', '')
            if vps_value and vps_value not in sense['grammar']:
                sense['grammar'].append(vps_value)

    for vps in sense_elem.find_all('span', class_='vps'):
        # Skip if inside a nested se3, df, or vps-w (already handled above)
        parent_se3 = vps.find_parent('div', class_='se3')
        parent_df = vps.find_parent(['span', 'div'], class_='df')
        parent_vps_w = vps.find_parent('vps-w')
        if (parent_se3 and parent_se3 != sense_elem) or parent_df or parent_vps_w:
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

    # === Plural forms (pl) ===
    # Structure: (<span class="gr">pl </span><span class="pl">manifestos</span> or <span class="pl">manifestoes</span>)
    # These appear as direct content before the definition
    # Mark <span class="pl"> content with <<l>>...<</l>> for blue variant face
    pl_elems = sense_elem.find_all('span', class_='pl', recursive=False)
    if pl_elems:
        # Find the df element first
        df_elem = sense_elem.find(['span', 'div'], class_='df', recursive=False)
        if df_elem:
            # Collect text/elements before df that form the plural notation
            from bs4 import NavigableString
            plural_parts = []
            for child in sense_elem.children:
                if child == df_elem:
                    break
                if isinstance(child, NavigableString):
                    text = str(child)
                    if text.strip():
                        plural_parts.append(text)
                elif hasattr(child, 'name'):
                    classes = child.get('class', [])
                    if 'pl' in classes:
                        # Mark plural words with <<l>> for blue variant face
                        plural_parts.append('<<l>>' + child.get_text() + '<</l>>')
                    elif 'gr' in classes:
                        # Mark grammar label with <<gram>> for grammar face
                        plural_parts.append('<<gram>>' + child.get_text() + '<</gram>>')

            if plural_parts:
                plural_text = ''.join(plural_parts).strip()
                plural_text = re.sub(r'\s+', ' ', plural_text)
                if plural_text:
                    sense['plural'] = plural_text

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
        sense['definition'] = extract_definition_with_format(df)
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
            sense['definition'] = extract_definition_with_format(xrg)
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

    # === Cross-references (cf) ===
    # Structure: <div class="cf">Cf <zh>参看</zh> <a class="xr" href="entry://old">old</a>2.</div>
    # Use <<xr:target>>text<</xr>> format for clickable links
    for cf in sense_elem.find_all('div', class_='cf', recursive=False):
        # Skip if inside a nested se3
        parent_se3 = cf.find_parent('div', class_='se3')
        if parent_se3 and parent_se3 != sense_elem:
            continue
        # Extract link info from <a class="xr">
        xr_link = cf.find('a', class_='xr')
        if xr_link:
            href = xr_link.get('href', '')
            link_text = clean_text(xr_link.get_text())
            # Extract target word from href (entry://old -> old)
            target_word = href.replace('entry://', '') if href.startswith('entry://') else link_text
            # Get suffix after link (like "2." in "old2.")
            suffix = ''
            if xr_link.next_sibling:
                from bs4 import NavigableString
                if isinstance(xr_link.next_sibling, NavigableString):
                    suffix = clean_text(str(xr_link.next_sibling))
            # Format: Cf <<xr:old>>old<</xr>>2.
            cf_value = f'Cf <<xr:{target_word}>>{link_text}<</xr>>{suffix}'
            sense['labels'].append({'type': 'cf', 'value': cf_value})
        else:
            # Fallback: just extract text
            cf_text = extract_text_without_zh(cf)
            if cf_text:
                sense['labels'].append({'type': 'cf', 'value': cf_text})

    # === Subsenses (se3) ===
    # Parse subsenses even if parent sense has no main definition (e.g., elder sense 1)
    sub_order = 0
    for se3 in sense_elem.find_all('div', class_='se3', recursive=False):
        subsense = parse_oald4_subsense(se3, sub_order)
        if subsense:
            sense['subsenses'].append(subsense)
            sub_order += 1

    # Return if has definition, examples, or subsenses
    if sense['definition'] or sense['examples'] or sense['subsenses']:
        return sense

    return None


def parse_oald4_subsense(se3_elem, order=0):
    """Parse a subsense element (se3)."""
    # Generate letter number: 0 -> "a)", 1 -> "b)", etc.
    letter = chr(ord('a') + order)
    subsense = {
        'number': f'{letter})',
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
        subsense['definition'] = extract_definition_with_format(df)
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
    subsenses_data = {}  # sense_number -> subsenses for storage (like LDOCE)
    for sense in entry.get('senses', []):
        # Skip senses without definition, examples, labels, or subsenses
        has_content = (sense.get('definition') or sense.get('examples') or
                       sense.get('labels') or sense.get('subsenses'))
        if not has_content:
            continue

        # signpost is for "also" variants like "phone call, ring", not grammar labels
        signpost = sense.get('signpost', '')

        cursor.execute("""
            INSERT INTO senses (entry_id, sense_number, signpost, plural, definition, definition_zh, sort_order)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, (entry_id, sense.get('number', ''), signpost, sense.get('plural', ''),
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

        # Store subsenses for later (like LDOCE - store as entry attributes)
        if sense.get('subsenses'):
            subsenses_data[sense.get('number', str(sense_id))] = sense['subsenses']

    # Add subsenses to entry attributes (like LDOCE)
    if subsenses_data:
        entry.setdefault('attributes', {})['oald/subsenses'] = subsenses_data

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
