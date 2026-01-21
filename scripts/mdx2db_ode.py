#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ODE (Oxford Dictionary of English) / OELD (Oxford English Living Dictionary) MDX to LexDB SQLite Converter

Supports ODE Living Online and similar Oxford dictionary formats.
Uses unified schema from lexdb_schema module for compatibility.
"""

import sqlite3
import sys
import os
import re
import json
import zlib
import time
from pathlib import Path
from datetime import datetime
from bs4 import BeautifulSoup, Tag

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
# ODE-specific Utility Functions
# ============================================================

def extract_example_text(element):
    """Extract example text from ODE ex element.

    ODE examples are in <em> tags inside <div class="ex">.
    """
    if not element:
        return ""

    # Find the em tag which contains the actual example
    em = element.find('em')
    if em:
        return clean_text(em.get_text())

    return clean_text(element.get_text())


def parse_frequency(element):
    """Parse frequency from class like 'frequency freq7'."""
    if not element:
        return None

    classes = element.get('class', [])
    for cls in classes:
        if cls.startswith('freq'):
            # Extract number: freq7 -> 7
            match = re.search(r'freq(\d+)', cls)
            if match:
                return int(match.group(1))
    return None


# ============================================================
# ODE Parser
# ============================================================

class ODEParser:
    """Oxford Dictionary of English HTML parser."""

    DICT_ID = "ode"
    DICT_NAME = "Oxford Dictionary of English"

    def parse(self, html, word_key):
        """Parse entry HTML, return list of structured entries."""
        soup = BeautifulSoup(html, HTML_PARSER)

        # Find entry wrappers
        entry_wrappers = soup.find_all(class_='entryWrapper')

        # If no wrappers found, treat whole HTML as single entry
        if not entry_wrappers:
            entry_wrappers = [soup]

        entries = []
        seen_entry_ids = set()

        for wrapper in entry_wrappers:
            # Check for multiple homographs within this wrapper
            # Each entryHead represents a separate homograph
            entry_heads = wrapper.find_all(class_='entryHead')

            if len(entry_heads) > 1:
                # Multiple homographs - split and parse each separately
                homograph_entries = self._split_homographs(wrapper, entry_heads)
                for homograph_soup, entry_head in homograph_entries:
                    entry_id = entry_head.get('id', '')
                    if entry_id and entry_id in seen_entry_ids:
                        continue
                    seen_entry_ids.add(entry_id)

                    entry = self._parse_single_entry(homograph_soup, word_key)
                    if entry and entry.get('senses'):
                        entries.append(entry)
            else:
                # Single entry in wrapper
                entry_head = wrapper.find(class_='entryHead')
                if entry_head:
                    entry_id = entry_head.get('id', '')
                    if entry_id and entry_id in seen_entry_ids:
                        continue
                    seen_entry_ids.add(entry_id)

                entry = self._parse_single_entry(wrapper, word_key)
                if entry and entry.get('senses'):
                    entries.append(entry)

        # If no entries parsed, try parsing whole soup as single entry
        if not entries:
            entry = self._parse_single_entry(soup, word_key)
            if entry:
                entries.append(entry)

        return entries

    def _split_homographs(self, wrapper, entry_heads):
        """Split a wrapper with multiple entryHead elements into separate soups.

        Returns list of (soup, entry_head) tuples for each homograph.
        """
        results = []

        # Get all direct children of wrapper for sequential processing
        children = list(wrapper.children)

        # Find positions of each entryHead in children list
        head_positions = []
        for i, child in enumerate(children):
            if hasattr(child, 'get') and child.get('class'):
                if 'entryHead' in child.get('class', []):
                    head_positions.append(i)

        # For each entryHead, collect elements until the next entryHead or end
        for idx, pos in enumerate(head_positions):
            # Determine end position
            end_pos = head_positions[idx + 1] if idx + 1 < len(head_positions) else len(children)

            # Create a new soup with just this homograph's elements
            new_soup = BeautifulSoup('<div class="homograph"></div>', HTML_PARSER)
            container = new_soup.find('div')

            # Copy elements from this entryHead to the next
            for i in range(pos, end_pos):
                child = children[i]
                if hasattr(child, 'name') and child.name:
                    # Skip navBar and oeldToolbar - they're shared UI elements
                    classes = child.get('class', [])
                    if 'navBar' in classes or 'oeldToolbar' in classes:
                        continue
                    container.append(BeautifulSoup(str(child), HTML_PARSER))

            # Find the entryHead in original children
            entry_head = children[pos] if hasattr(children[pos], 'get') else None
            results.append((container, entry_head))

        return results

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
        # Headword
        hw = soup.find(class_='hw')
        if hw:
            # Extract superscript for display, but remove for headword lookup
            sup_elem = hw.find('sup')
            sup_text = ''
            if sup_elem:
                sup_num = clean_text(sup_elem.get_text())
                # Convert to Unicode superscript characters
                sup_map = {'0': '⁰', '1': '¹', '2': '²', '3': '³', '4': '⁴',
                           '5': '⁵', '6': '⁶', '7': '⁷', '8': '⁸', '9': '⁹'}
                sup_text = ''.join(sup_map.get(c, c) for c in sup_num)

            # Get clean headword without superscript
            hw_copy = BeautifulSoup(str(hw), HTML_PARSER).find(class_='hw')
            if hw_copy:
                for sup in hw_copy.find_all('sup'):
                    sup.decompose()
                entry['headword'] = clean_text(hw_copy.get_text())
            else:
                entry['headword'] = clean_text(hw.get_text())

            # Display includes superscript
            entry['headword_display'] = entry['headword'] + sup_text

        if not entry['headword']:
            entry['headword'] = word_key

        # === Part of speech ===
        pos_elem = soup.find(class_='pos')
        if pos_elem:
            pos_text = clean_text(pos_elem.get_text())
            if pos_text:
                entry['labels'].append({
                    'type': LabelType.POS,
                    'value': pos_text
                })

        # === Frequency ===
        freq_elem = soup.find(class_='frequency')
        if freq_elem:
            freq_val = parse_frequency(freq_elem)
            if freq_val:
                entry['attributes']['frequency'] = freq_val

        # === Pronunciations ===
        for pron in soup.find_all(class_='phoneticSymbol'):
            ipa = clean_text(pron.get_text())
            audio_path = pron.get('addr', '')

            # Determine variant (uk/us)
            variant = 'uk'
            if 'us' in (pron.get('class') or []):
                variant = 'us'

            if ipa:
                entry['pronunciations'].append({
                    'ipa': ipa,
                    'variant': variant,
                    'audio_path': audio_path
                })

        # === Main grammar sections (gramb) - may have multiple (adjective, noun, etc.) ===
        # Only select <section class="gramb">, not <ul class="semb gramb"> in phrase sections
        for gramb in soup.find_all('section', class_='gramb'):
            self._parse_senses(gramb, entry)

        # === Phrases section ===
        self._parse_phrases(soup, entry)

        # === Derivatives section ===
        self._parse_derivatives(soup, entry)

        # === Etymology/Origin ===
        self._parse_etymology(soup, entry)

        return entry

    def _parse_senses(self, gramb, entry):
        """Parse senses from gramb section."""
        # Extract POS from grambhead for this section
        section_pos = None
        grambhead = gramb.find(class_='grambhead')
        if grambhead:
            pos_elem = grambhead.find(class_='pos')
            if pos_elem:
                section_pos = clean_text(pos_elem.get_text())

        # Find semb (sense block)
        semb = gramb.find(class_='semb')
        if not semb:
            return

        # Track if this is the first sense in this gramb section
        first_sense_in_section = True

        # Use current entry sense count as starting order
        sense_order = len(entry['senses'])

        # Process each main sense (li elements directly under semb)
        for li in semb.find_all('li', recursive=False):
            trg = li.find(class_='trg')
            if not trg:
                continue

            sense_data = self._parse_sense_block(trg, sense_order)
            if sense_data:
                # Add section POS to first sense's signpost for header display
                if first_sense_in_section and section_pos:
                    sense_data['section_pos'] = section_pos
                    first_sense_in_section = False
                entry['senses'].append(sense_data)
                sense_order += 1

            # Process subsenses
            subsenses_wrapper = li.find(class_='subSenses')
            if subsenses_wrapper:
                for subsense in subsenses_wrapper.find_all(class_='subSense'):
                    sub_data = self._parse_subsense(subsense, sense_order)
                    if sub_data:
                        entry['senses'].append(sub_data)
                        sense_order += 1

    def _parse_sense_block(self, trg, sort_order):
        """Parse a single sense block (trg element)."""
        sense_data = {
            'number': '',
            'definition': '',
            'signpost': '',
            'form_groups': '',  # e.g., "also days"
            'labels': [],
            'examples': [],
            'gram_examples': [],
            'cross_refs': [],
            'sort_order': sort_order
        }

        # Sense number (iteration)
        iteration = trg.find(class_='iteration')
        if iteration:
            sense_data['number'] = clean_text(iteration.get_text())

        # Form groups (e.g., "also days") - inside <p> element
        p_elem = trg.find('p', recursive=False)
        if p_elem:
            form_groups = p_elem.find(class_='form-groups')
            if form_groups:
                sense_data['form_groups'] = clean_text(form_groups.get_text())

        # Definition (ind) - only the first one, not nested in subSenses
        ind = trg.find(class_='ind')
        if ind and not ind.find_parent(class_='subSense'):
            sense_data['definition'] = clean_text(ind.get_text())
        elif not sense_data['definition']:
            # For combining forms, the definition might be in crossReference
            xref = trg.find(class_='crossReference')
            if xref and not xref.find_parent(class_='subSense'):
                sense_data['definition'] = clean_text(xref.get_text())

        # Helper to check if element is inside synonyms/examples containers
        def is_in_excluded_container(elem):
            return (elem.find_parent(class_='subSense') or
                    elem.find_parent(class_='synonyms') or
                    elem.find_parent(class_='examples'))

        # Register labels (technical, informal, etc.)
        # Only collect labels NOT inside subSenses, synonyms, or examples
        for reg in trg.find_all(class_='sense-registers'):
            if is_in_excluded_container(reg):
                continue
            reg_text = clean_text(reg.get_text())
            if reg_text:
                sense_data['labels'].append({
                    'type': LabelType.REGISTER,
                    'value': reg_text
                })

        # Domain labels (Astronomy, Medicine, etc.)
        for domain in trg.find_all(class_='sense-regions'):
            if is_in_excluded_container(domain):
                continue
            domain_text = clean_text(domain.get_text())
            if domain_text:
                sense_data['labels'].append({
                    'type': LabelType.DOMAIN,
                    'value': domain_text
                })

        # Grammar notes
        for gram in trg.find_all(class_='grammatical_note'):
            if is_in_excluded_container(gram):
                continue
            gram_text = clean_text(gram.get_text())
            if gram_text:
                sense_data['labels'].append({
                    'type': LabelType.GRAMMAR,
                    'value': gram_text
                })

        # Basic examples (exg > ex) - those directly under trg, NOT in subSenses/synonyms/examples containers
        ex_order = 0
        for exg in trg.find_all(class_='exg', recursive=False):
            ex = exg.find(class_='ex')
            if ex:
                ex_text = extract_example_text(ex)
                if ex_text:
                    sense_data['examples'].append({
                        'text': ex_text,
                        'audio_path': '',
                        'position': 0,
                        'sort_order': ex_order
                    })
                    ex_order += 1

        # Expanded examples (inside div.examples > div.exg)
        examples_div = trg.find(class_='examples', recursive=False)
        if examples_div:
            expanded_examples = []
            for exg in examples_div.find_all(class_='exg'):
                for ex in exg.find_all(class_='ex'):
                    ex_text = extract_example_text(ex)
                    if ex_text:
                        expanded_examples.append(ex_text)
            if expanded_examples:
                sense_data['expanded_examples'] = expanded_examples

        # Synonyms - parse structured format
        synonyms_div = trg.find(class_='synonyms', recursive=False)
        if synonyms_div:
            synonyms_data = self._parse_synonyms(synonyms_div)
            if synonyms_data:
                sense_data['synonyms'] = synonyms_data

        # Cross references (e.g., "Contrasted with universal")
        for xref_div in trg.find_all(class_='crossReference', recursive=False):
            xref_data = self._parse_cross_reference(xref_div)
            if xref_data:
                sense_data['cross_refs'].append(xref_data)

        return sense_data if sense_data['definition'] else None

    def _parse_synonyms(self, synonyms_div):
        """Parse synonyms from div.synonyms element.

        Returns a list of groups, each with:
        - register: optional register label (e.g., 'technical')
        - words: list of word objects with 'word' and 'clickable' fields

        Clickable words are those wrapped in <a href="entry://..."> tags.
        Non-clickable words are wrapped in <strong> tags.
        """
        synonyms_groups = []

        # Find all exs divs (each may have a register label)
        for exs in synonyms_div.find_all(class_='exs'):
            group = {
                'register': '',
                'words': []
            }

            # Check for register label in this group
            reg = exs.find(class_='sense-registers')
            if reg:
                group['register'] = clean_text(reg.get_text())

            # Extract synonym words (links are clickable, strong text is not)
            for elem in exs.children:
                if hasattr(elem, 'name'):
                    if elem.name == 'a':
                        # Links are clickable - can look up in dictionary
                        word = clean_text(elem.get_text())
                        if word:
                            group['words'].append({'word': word, 'clickable': True})
                    elif elem.name == 'strong':
                        # Strong text is not clickable (descriptive terms)
                        word = clean_text(elem.get_text())
                        if word:
                            group['words'].append({'word': word, 'clickable': False})

            if group['words']:
                synonyms_groups.append(group)

        return synonyms_groups if synonyms_groups else None

    def _parse_cross_reference(self, xref_div):
        """Parse a crossReference element.

        Returns a dict with:
        - type: RelationType.CROSS_REF
        - prefix: text before the link (e.g., "Contrasted with ")
        - clickable: the link text (e.g., "universal")
        - target_word: the target word from href
        - suffix: text after the link
        """
        if not xref_div:
            return None

        # Get the full text and find the link
        link = xref_div.find('a')
        if not link:
            # No clickable link, just text - skip empty crossReferences
            text = clean_text(xref_div.get_text())
            if text:
                return {
                    'type': RelationType.CROSS_REF,
                    'prefix': text,
                    'clickable': '',
                    'target_word': '',
                    'suffix': ''
                }
            return None

        # Parse the link
        link_text = clean_text(link.get_text())
        href = link.get('href', '')

        # Extract target word from href (e.g., "entry://universal" -> "universal")
        target_word = ''
        if href.startswith('entry://'):
            target_word = href[8:]  # Remove "entry://"

        # Get text before and after the link
        full_text = xref_div.get_text()
        link_pos = full_text.find(link.get_text())

        prefix = clean_text(full_text[:link_pos]) if link_pos > 0 else ''
        # Add trailing space to prefix if original had whitespace before the link
        if prefix and link_pos > 0 and full_text[link_pos - 1].isspace():
            prefix = prefix + ' '
        suffix = clean_text(full_text[link_pos + len(link.get_text()):]) if link_pos >= 0 else ''

        return {
            'type': RelationType.CROSS_REF,
            'prefix': prefix,
            'clickable': link_text,
            'target_word': target_word or link_text,
            'suffix': suffix
        }

    def _parse_subsense(self, subsense, sort_order):
        """Parse a subsense element."""
        sense_data = {
            'number': '',
            'definition': '',
            'signpost': '',
            'labels': [],
            'examples': [],
            'gram_examples': [],
            'cross_refs': [],
            'sort_order': sort_order
        }

        # Subsense number (1.1, 1.2, etc.)
        iteration = subsense.find(class_='subsenseIteration')
        if iteration:
            sense_data['number'] = clean_text(iteration.get_text())

        # Definition
        ind = subsense.find(class_='ind')
        if ind:
            sense_data['definition'] = clean_text(ind.get_text())

        # Helper to check if element is inside synonyms/examples containers
        def is_in_excluded_container(elem):
            return (elem.find_parent(class_='synonyms') or
                    elem.find_parent(class_='examples'))

        # Register labels - exclude those inside synonyms/examples
        for reg in subsense.find_all(class_='sense-registers', recursive=False):
            reg_text = clean_text(reg.get_text())
            if reg_text:
                sense_data['labels'].append({
                    'type': LabelType.REGISTER,
                    'value': reg_text
                })

        # Domain labels - these are direct children with class 'sense-regions domain_labels'
        for domain in subsense.find_all(class_='sense-regions', recursive=False):
            domain_text = clean_text(domain.get_text())
            if domain_text:
                sense_data['labels'].append({
                    'type': LabelType.DOMAIN,
                    'value': domain_text
                })

        # Grammar notes
        for gram in subsense.find_all(class_='grammatical_note', recursive=False):
            gram_text = clean_text(gram.get_text())
            if gram_text:
                sense_data['labels'].append({
                    'type': LabelType.GRAMMAR,
                    'value': gram_text
                })

        # Find trg inside subsense for examples and synonyms
        trg = subsense.find(class_='trg')

        # Basic examples - from exg elements not inside examples/synonyms containers
        ex_order = 0
        exg_container = trg if trg else subsense
        for exg in exg_container.find_all(class_='exg'):
            # Skip if inside examples or synonyms div
            if exg.find_parent(class_='examples') or exg.find_parent(class_='synonyms'):
                continue
            ex = exg.find(class_='ex')
            if ex:
                ex_text = extract_example_text(ex)
                if ex_text:
                    sense_data['examples'].append({
                        'text': ex_text,
                        'audio_path': '',
                        'position': 0,
                        'sort_order': ex_order
                    })
                    ex_order += 1

        # Expanded examples (inside div.examples)
        examples_div = exg_container.find(class_='examples') if exg_container else None
        if examples_div:
            expanded_examples = []
            for exg in examples_div.find_all(class_='exg'):
                for ex in exg.find_all(class_='ex'):
                    ex_text = extract_example_text(ex)
                    if ex_text:
                        expanded_examples.append(ex_text)
            if expanded_examples:
                sense_data['expanded_examples'] = expanded_examples

        # Synonyms
        synonyms_div = exg_container.find(class_='synonyms') if exg_container else None
        if synonyms_div:
            synonyms_data = self._parse_synonyms(synonyms_div)
            if synonyms_data:
                sense_data['synonyms'] = synonyms_data

        # Cross references (e.g., "Contrasted with universal")
        xref_container = trg if trg else subsense
        for xref_div in xref_container.find_all(class_='crossReference'):
            xref_data = self._parse_cross_reference(xref_div)
            if xref_data:
                sense_data['cross_refs'].append(xref_data)

        return sense_data if sense_data['definition'] else None

    def _parse_phrases(self, soup, entry):
        """Parse phrases from the entry.

        ODE phrase structure:
        section.etymology.phrase > senseInnerWrapper > ul.semb.gramb >
          li (contains div.trg > p > span.ind > strong.phrase)
          ul.semb >
            li.phrase_sense (contains definition and examples)
        """
        phrases_data = []

        # Find phrase sections
        for section in soup.find_all('section', class_='etymology'):
            classes = section.get('class', [])
            if 'phrase' not in classes:
                continue

            inner = section.find(class_='senseInnerWrapper')
            if not inner:
                continue

            # Find all semb containers
            semb = inner.find(class_='semb')
            if not semb:
                continue

            # Process each phrase entry
            for li in semb.find_all('li', recursive=False):
                # Find phrase text in ind > strong.phrase
                trg = li.find(class_='trg')
                if not trg:
                    continue

                ind = trg.find(class_='ind')
                if not ind:
                    continue

                phrase_strong = ind.find(class_='phrase')
                if not phrase_strong:
                    continue

                phrase_text = clean_text(phrase_strong.get_text())
                if not phrase_text:
                    continue

                # Find nested ul.semb with phrase_sense
                nested_semb = li.find_next_sibling('ul', class_='semb')
                if not nested_semb:
                    # Try finding as child
                    nested_semb = li.find('ul', class_='semb')

                if nested_semb:
                    for phrase_sense in nested_semb.find_all(class_='phrase_sense'):
                        definition = ''
                        ps_ind = phrase_sense.find(class_='ind')
                        if ps_ind:
                            definition = clean_text(ps_ind.get_text())

                        # Get examples
                        examples = []
                        ex_order = 0
                        for exg in phrase_sense.find_all(class_='exg'):
                            ex = exg.find(class_='ex')
                            if ex:
                                ex_text = extract_example_text(ex)
                                if ex_text:
                                    examples.append({
                                        'text': ex_text,
                                        'sort_order': ex_order
                                    })
                                    ex_order += 1

                        if definition:
                            phrases_data.append({
                                'phrase': phrase_text,
                                'definition': definition,
                                'examples': examples
                            })

        if phrases_data:
            entry['attributes']['phrases'] = phrases_data

    def _parse_etymology(self, soup, entry):
        """Parse etymology/origin information."""
        # Look for etym section with Origin header
        for etym in soup.find_all(class_='etym'):
            h3 = etym.find('h3')
            if h3 and 'Origin' in h3.get_text():
                # Found origin section
                inner = etym.find(class_='senseInnerWrapper')
                if inner:
                    # Get main origin text (first <p> tag, excluding appendix)
                    main_p = inner.find('p', recursive=False)
                    main_origin = ''
                    if main_p:
                        main_origin = clean_text(main_p.get_text())

                    # Try to find origin_appendix for additional info
                    appendix = inner.find(class_='origin_appendix')
                    appendix_text = ''
                    if appendix:
                        # Get text from the <p> inside appendix
                        appendix_p = appendix.find('p')
                        if appendix_p:
                            appendix_text = clean_text(appendix_p.get_text())

                    if main_origin:
                        entry['attributes']['origin'] = {
                            'text': main_origin,
                            'appendix': appendix_text
                        }
                    break

    def _parse_derivatives(self, soup, entry):
        """Parse derivatives section.

        ODE derivative structure:
        section.etymology.derivative > senseInnerWrapper > ul.semb.gramb >
          li.derivative_sense (contains strong.derivative = headword)
          div.grambhead (contains pos, pronunciation)
          ul.semb > li (contains definition and examples)
        """
        derivatives_data = []

        # Find derivative sections (section.etymology.derivative)
        for section in soup.find_all('section', class_='etymology'):
            classes = section.get('class', [])
            if 'derivative' not in classes:
                continue

            inner = section.find(class_='senseInnerWrapper')
            if not inner:
                continue

            # Find the main semb container
            main_semb = inner.find('ul', class_='semb')
            if not main_semb:
                continue

            # Process derivative entries - each derivative_sense followed by grambhead and definition semb
            deriv_senses = main_semb.find_all('li', class_='derivative_sense', recursive=False)

            for deriv_sense in deriv_senses:
                deriv_entry = {}

                # Get headword from strong.derivative
                deriv_strong = deriv_sense.find('strong', class_='derivative')
                if deriv_strong:
                    deriv_entry['headword'] = clean_text(deriv_strong.get_text())

                # Get grambhead (next sibling after derivative_sense)
                grambhead = deriv_sense.find_next_sibling('div', class_='grambhead')
                if grambhead:
                    # Get POS
                    pos_elem = grambhead.find(class_='pos')
                    if pos_elem:
                        deriv_entry['pos'] = clean_text(pos_elem.get_text())

                    # Get pronunciation
                    pron = grambhead.find(class_='phoneticSymbol')
                    if pron:
                        deriv_entry['ipa'] = clean_text(pron.get_text())

                # Get definition from nested ul.semb
                def_semb = deriv_sense.find_next_sibling('ul', class_='semb')
                if def_semb:
                    # Find definition in ind
                    ind = def_semb.find(class_='ind')
                    if ind:
                        deriv_entry['definition'] = clean_text(ind.get_text())

                    # Get inline examples (direct exg > ex, not inside .examples)
                    examples = []
                    for exg in def_semb.find_all('div', class_='exg', recursive=True):
                        # Skip if this exg is inside .examples (those are expanded examples)
                        if exg.find_parent(class_='examples'):
                            continue
                        ex = exg.find(class_='ex')
                        if ex:
                            ex_text = extract_example_text(ex)
                            if ex_text:
                                examples.append(ex_text)
                    if examples:
                        deriv_entry['examples'] = examples

                    # Get expanded examples (inside .examples > .exg > ul > li.ex)
                    expanded_examples = []
                    examples_div = def_semb.find(class_='examples')
                    if examples_div:
                        exg = examples_div.find(class_='exg')
                        if exg:
                            for li in exg.find_all('li', class_='ex'):
                                ex_text = extract_example_text(li)
                                if ex_text:
                                    expanded_examples.append(ex_text)
                    if expanded_examples:
                        deriv_entry['expanded_examples'] = expanded_examples

                if deriv_entry.get('headword'):
                    derivatives_data.append(deriv_entry)

        if derivatives_data:
            entry['attributes']['derivatives'] = derivatives_data


# ============================================================
# LexDB Writer (same as other converters)
# ============================================================

class LexDBWriter:
    """Unified writer for LexDB format."""

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

        # Initialize schema
        init_database(self.conn)

        # Register dictionary
        capabilities = json.dumps(['audio-uk', 'audio-us'])
        self.cursor.execute("""
            INSERT OR REPLACE INTO dictionaries
            (dict_id, name, version, source_file, capabilities, created_at, entry_count)
            VALUES (?, ?, ?, ?, ?, ?, 0)
        """, (
            self.dict_id,
            self.dict_name,
            self.dict_version,
            self.source_file,
            capabilities,
            datetime.now().isoformat()
        ))
        self.conn.commit()

    def write_entry(self, entry_data):
        """Write a single entry to the database."""
        # Insert entry
        headword = entry_data.get('headword', '')
        self.cursor.execute("""
            INSERT INTO entries (dict_id, headword, headword_lower, headword_display)
            VALUES (?, ?, ?, ?)
        """, (
            self.dict_id,
            headword,
            headword.lower(),
            entry_data.get('headword_display') or headword
        ))
        entry_id = self.cursor.lastrowid

        # Insert pronunciations
        for idx, pron in enumerate(entry_data.get('pronunciations', [])):
            self.cursor.execute("""
                INSERT INTO pronunciations (entry_id, variant, ipa, audio_path, sort_order)
                VALUES (?, ?, ?, ?, ?)
            """, (
                entry_id,
                pron.get('variant'),
                pron.get('ipa'),
                pron.get('audio_path'),
                idx
            ))

        # Insert entry-level labels
        for idx, label in enumerate(entry_data.get('labels', [])):
            self.cursor.execute("""
                INSERT INTO labels (entry_id, sense_id, label_type, label_value, sort_order)
                VALUES (?, NULL, ?, ?, ?)
            """, (
                entry_id,
                label['type'],
                label['value'],
                idx
            ))

        # Collect sense-level synonyms, expanded_examples, and form_groups for later storage
        # Use sort_order as key (unique per entry) instead of sense_number (can repeat across POS)
        sense_synonyms_map = {}
        sense_expanded_examples_map = {}
        sense_form_groups_map = {}

        # Insert senses
        for sense_data in entry_data.get('senses', []):
            sense_number = sense_data.get('number', '')
            sort_order = sense_data.get('sort_order', 0)
            # Use sort_order as string key for JSON compatibility
            sort_key = str(sort_order)

            # Use section_pos as signpost for ODE (marks first sense of a new POS section)
            signpost = sense_data.get('signpost') or sense_data.get('section_pos')

            self.cursor.execute("""
                INSERT INTO senses (entry_id, sense_number, signpost, definition, sort_order)
                VALUES (?, ?, ?, ?, ?)
            """, (
                entry_id,
                sense_number,
                signpost,
                sense_data.get('definition', ''),
                sort_order
            ))
            sense_id = self.cursor.lastrowid

            # Collect form_groups for this sense (e.g., "also days")
            if sense_data.get('form_groups'):
                sense_form_groups_map[sort_key] = sense_data['form_groups']

            # Collect synonyms for this sense
            if sense_data.get('synonyms'):
                sense_synonyms_map[sort_key] = sense_data['synonyms']

            # Collect expanded_examples for this sense
            if sense_data.get('expanded_examples'):
                sense_expanded_examples_map[sort_key] = sense_data['expanded_examples']

            # Sense-level labels
            for idx, label in enumerate(sense_data.get('labels', [])):
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
            for ex in sense_data.get('examples', []):
                self.cursor.execute("""
                    INSERT INTO examples (sense_id, text, audio_path, position, sort_order)
                    VALUES (?, ?, ?, ?, ?)
                """, (
                    sense_id,
                    ex['text'],
                    ex.get('audio_path', ''),
                    ex.get('position', 0),
                    ex.get('sort_order', 0)
                ))

            # Grammar patterns and examples
            for idx, gram in enumerate(sense_data.get('gram_examples', [])):
                self.cursor.execute("""
                    INSERT INTO grammar_patterns (sense_id, pattern, gloss, sort_order)
                    VALUES (?, ?, ?, ?)
                """, (
                    sense_id,
                    gram.get('pattern', ''),
                    gram.get('gloss', ''),
                    idx
                ))
                pattern_id = self.cursor.lastrowid

                for ex_idx, ex in enumerate(gram.get('examples', [])):
                    self.cursor.execute("""
                        INSERT INTO grammar_examples (pattern_id, text, audio_path, sort_order)
                        VALUES (?, ?, ?, ?)
                    """, (
                        pattern_id,
                        ex.get('text', ''),
                        ex.get('audio_path', ''),
                        ex_idx
                    ))

            # Cross references within sense
            for idx, ref in enumerate(sense_data.get('cross_refs', [])):
                self.cursor.execute("""
                    INSERT INTO relations (entry_id, sense_id, relation_type, prefix, clickable, suffix, target_word, target_sense, sort_order)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, (
                    entry_id,
                    sense_id,
                    ref.get('type', RelationType.CROSS_REF),
                    ref.get('prefix'),
                    ref.get('clickable', ''),
                    ref.get('suffix'),
                    ref.get('target_word', ''),
                    ref.get('target_sense'),
                    idx
                ))

        # Insert relations
        for idx, rel in enumerate(entry_data.get('relations', [])):
            if 'clickable' in rel:
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
                coll.get('category'),
                coll['text'],
                coll.get('gloss'),
                coll.get('sort_order', 0)
            ))
            coll_id = self.cursor.lastrowid

            for example in coll.get('examples', []):
                self.cursor.execute("""
                    INSERT INTO collocation_examples (collocation_id, text, sort_order)
                    VALUES (?, ?, ?)
                """, (
                    coll_id,
                    example['text'],
                    example.get('sort_order', 0)
                ))

        # Store sense-level synonyms, expanded_examples, and form_groups as entry attributes
        if sense_synonyms_map:
            entry_data.setdefault('attributes', {})['sense_synonyms'] = sense_synonyms_map
        if sense_expanded_examples_map:
            entry_data.setdefault('attributes', {})['sense_expanded_examples'] = sense_expanded_examples_map
        if sense_form_groups_map:
            entry_data.setdefault('attributes', {})['sense_form_groups'] = sense_form_groups_map

        # Insert extension attributes (EAV)
        for key, value in entry_data.get('attributes', {}).items():
            if value:
                if isinstance(value, bool):
                    attr_type = 'boolean'
                    attr_value = '1' if value else '0'
                elif isinstance(value, int):
                    attr_type = 'integer'
                    attr_value = str(value)
                elif isinstance(value, (dict, list)):
                    json_str = json.dumps(value, ensure_ascii=False, separators=(',', ':'))
                    if len(json_str) > 1000:
                        compressed = zlib.compress(json_str.encode('utf-8'), level=9)
                        attr_type = 'json.gz'
                        attr_value = compressed
                    else:
                        attr_type = 'json'
                        attr_value = json_str
                else:
                    attr_type = 'text'
                    attr_value = str(value)

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
        """Close connection and update entry count."""
        if self.conn:
            self.cursor.execute("""
                UPDATE dictionaries SET entry_count = ? WHERE dict_id = ?
            """, (self.entry_count, self.dict_id))
            self.conn.commit()

            if vacuum:
                print("Optimizing database...")
                self.cursor.execute("ANALYZE")
                self.cursor.execute("VACUUM")
                print("Database optimized and compressed")

            self.conn.close()
            self.conn = None
            self.cursor = None


# ============================================================
# Main Conversion Function
# ============================================================

def convert_mdx_to_lexdb(mdx_file, db_path=None, extract_audio=False):
    """Convert ODE MDX file to LexDB database."""

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
    if extract_audio:
        mdd_files = []
        base_mdd = mdx_path.with_suffix('.mdd')
        if base_mdd.exists():
            mdd_files.append(base_mdd)

        stem = mdx_path.stem
        parent = mdx_path.parent
        for i in range(1, 20):
            numbered_mdd_underscore = parent / f"{stem}_{i}.mdd"
            numbered_mdd_dot = parent / f"{stem}.{i}.mdd"

            if numbered_mdd_underscore.exists():
                mdd_files.append(numbered_mdd_underscore)
            elif numbered_mdd_dot.exists():
                mdd_files.append(numbered_mdd_dot)
            else:
                break

        if mdd_files:
            audio_dir = mdx_path.parent / 'audio'
            audio_dir.mkdir(exist_ok=True)
            print(f"Extracting audio to: {audio_dir}")
            print(f"Found {len(mdd_files)} MDD file(s)")

            for mdd_file in mdd_files:
                print(f"  Processing: {mdd_file.name}")
                mdd = MDD(str(mdd_file))
                file_count = 0
                for key, data in mdd.items():
                    if isinstance(key, bytes):
                        key = key.decode('utf-8', errors='ignore')
                    key = key.replace('\\', '/').lstrip('/')
                    out_path = audio_dir / key
                    out_path.parent.mkdir(parents=True, exist_ok=True)
                    with open(out_path, 'wb') as f:
                        f.write(data)
                    file_count += 1
                print(f"    Extracted {file_count} files")
            print("Audio extraction complete")

    # Create parser and writer
    parser = ODEParser()
    writer = LexDBWriter(
        db_path=str(db_path),
        dict_id=parser.DICT_ID,
        dict_name=parser.DICT_NAME,
        dict_version="Living Online",
        source_file=str(mdx_path.name)
    )

    print(f"Creating database: {db_path}")
    writer.open()

    print("Parsing and importing entries...")
    print(f"  Using parser: {HTML_PARSER}")

    items = list(mdx.items())
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

        # Skip redirects (entries starting with @@@LINK)
        if html.strip().startswith('@@@LINK'):
            continue

        try:
            entries = parser.parse(html, word_key)

            for entry_data in entries:
                if entry_data.get('senses'):
                    # Skip redirects
                    parsed_hw = entry_data.get('headword', '').lower()
                    word_key_lower = word_key.lower()
                    if parsed_hw and parsed_hw != word_key_lower:
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
""")


# ============================================================
# Test Function
# ============================================================

def test_parse_html(html_file):
    """Test parsing a single HTML file."""
    with open(html_file, 'r', encoding='utf-8') as f:
        html = f.read()

    parser = ODEParser()
    entries = parser.parse(html, 'test')

    for i, entry in enumerate(entries):
        print(f"\n{'='*60}")
        print(f"Entry {i+1}: {entry['headword']}")
        print(f"{'='*60}")

        print(f"\nPronunciations:")
        for pron in entry['pronunciations']:
            print(f"  [{pron['variant']}] {pron['ipa']} -> {pron['audio_path']}")

        print(f"\nLabels:")
        for label in entry['labels']:
            print(f"  {label['type']}: {label['value']}")

        print(f"\nSenses ({len(entry['senses'])}):")
        for sense in entry['senses'][:5]:
            print(f"  {sense['number']}: {sense['definition'][:80]}...")
            for label in sense['labels']:
                print(f"    [{label['type']}] {label['value']}")
            for ex in sense['examples'][:2]:
                print(f"    Ex: {ex['text'][:60]}...")

        print(f"\nAttributes:")
        for key, value in entry['attributes'].items():
            if isinstance(value, list):
                print(f"  {key}: [{len(value)} items]")
            elif isinstance(value, dict):
                print(f"  {key}: {str(value)[:80]}...")
            else:
                print(f"  {key}: {value}")


# ============================================================
# Entry Point
# ============================================================

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("""
Usage:
  python mdx2db_ode.py <mdx_file>
  python mdx2db_ode.py <mdx_file> --extract-audio
  python mdx2db_ode.py <mdx_file> -o <output_db_path>
  python mdx2db_ode.py --test <html_file>

Examples:
  python mdx2db_ode.py ODE_Living_Online.mdx
  python mdx2db_ode.py ODE_Living_Online.mdx --extract-audio
  python mdx2db_ode.py --test day_entry_1.html
""")
        sys.exit(1)

    # Parse arguments
    args = sys.argv[1:]

    if args[0] == '--test':
        if len(args) < 2:
            print("Error: --test requires HTML file path")
            sys.exit(1)
        test_parse_html(args[1])
        sys.exit(0)

    mdx_file = args[0]
    db_path = None
    extract_audio = False

    i = 1
    while i < len(args):
        if args[i] == '-o' and i + 1 < len(args):
            db_path = args[i + 1]
            i += 2
        elif args[i] == '--extract-audio':
            extract_audio = True
            i += 1
        else:
            i += 1

    convert_mdx_to_lexdb(mdx_file, db_path, extract_audio)
