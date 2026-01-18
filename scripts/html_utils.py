#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
HTML 解析工具库 - 词典解析的通用组件

提供词典 HTML 解析中常用的工具函数，减少重复代码。

用法:
    from html_utils import (
        clone_element, extract_text, extract_text_excluding,
        remove_elements, get_attr_or_text, find_first,
        extract_audio_paths, convert_entry_links
    )
"""

import re
from typing import Optional, List, Dict, Any, Union, Callable
from bs4 import BeautifulSoup, Tag, NavigableString

# Try to use lxml for faster parsing
try:
    import lxml
    HTML_PARSER = 'lxml'
except ImportError:
    HTML_PARSER = 'html.parser'


# =============================================================================
# Element Cloning and Modification
# =============================================================================

def clone_element(element: Tag) -> Tag:
    """
    克隆一个 BeautifulSoup 元素，用于修改而不影响原始元素。

    Args:
        element: 要克隆的元素

    Returns:
        克隆后的元素

    Example:
        >>> elem_copy = clone_element(original)
        >>> elem_copy.find('zh').decompose()  # 不会影响 original
    """
    if not element:
        return None
    return BeautifulSoup(str(element), HTML_PARSER).find()


def remove_elements(soup: Tag, selectors: List[str]) -> Tag:
    """
    从元素中移除匹配选择器的所有子元素。

    Args:
        soup: 要处理的元素
        selectors: CSS 选择器列表，如 ['script', 'style', '.nav']

    Returns:
        修改后的元素（原地修改）

    Example:
        >>> remove_elements(soup, ['script', 'style', '.advertisement'])
    """
    for selector in selectors:
        for elem in soup.select(selector):
            elem.decompose()
    return soup


def remove_by_class(soup: Tag, class_names: List[str]) -> Tag:
    """
    移除具有指定类名的所有元素。

    Args:
        soup: 要处理的元素
        class_names: 类名列表

    Returns:
        修改后的元素（原地修改）
    """
    for class_name in class_names:
        for elem in soup.find_all(class_=class_name):
            elem.decompose()
    return soup


# =============================================================================
# Text Extraction
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


def extract_text(element: Tag, clean: bool = True) -> str:
    """
    提取元素的文本内容。

    Args:
        element: 要提取文本的元素
        clean: 是否清理空白

    Returns:
        提取的文本
    """
    if not element:
        return ''
    text = element.get_text()
    return clean_text(text) if clean else text


def extract_text_excluding(
    element: Tag,
    exclude_selectors: List[str],
    clean: bool = True
) -> str:
    """
    提取元素文本，但排除特定子元素。

    Args:
        element: 要提取文本的元素
        exclude_selectors: 要排除的选择器列表
        clean: 是否清理空白

    Returns:
        提取的文本

    Example:
        >>> # 提取文本但不包含中文翻译
        >>> text = extract_text_excluding(elem, ['zh', '.chinese'])
    """
    if not element:
        return ''
    elem_copy = clone_element(element)
    remove_elements(elem_copy, exclude_selectors)
    return extract_text(elem_copy, clean)


def get_attr_or_text(element: Tag, attr_name: str = 'value') -> str:
    """
    优先获取元素属性，如果没有则获取文本。

    很多词典格式使用 value 属性存储规范化的值，如:
    <span class="pos" value="noun">n.</span>

    Args:
        element: 元素
        attr_name: 属性名（默认 'value'）

    Returns:
        属性值或文本内容
    """
    if not element:
        return ''
    attr_value = element.get(attr_name, '')
    if attr_value:
        return clean_text(attr_value)
    return extract_text(element)


# =============================================================================
# Element Finding
# =============================================================================

def find_first(
    soup: Tag,
    selectors: List[Union[str, Dict[str, Any]]],
    default: Any = None
) -> Optional[Tag]:
    """
    按优先级尝试多个选择器，返回第一个匹配的元素。

    Args:
        soup: 要搜索的元素
        selectors: 选择器列表，可以是:
            - 字符串: CSS 选择器
            - 字典: {'class_': 'xxx'} 或 {'name': 'div', 'class_': 'xxx'}
        default: 未找到时返回的默认值

    Returns:
        第一个匹配的元素，或 default

    Example:
        >>> # 依次尝试不同的类名
        >>> headword = find_first(soup, ['.hwd', '.headword', 'h1.entry-title'])
    """
    if not soup:
        return default

    for selector in selectors:
        if isinstance(selector, str):
            result = soup.select_one(selector)
        elif isinstance(selector, dict):
            result = soup.find(**selector)
        else:
            continue

        if result:
            return result

    return default


def find_all_by_patterns(
    soup: Tag,
    patterns: List[Union[str, Dict[str, Any]]],
    limit: int = None
) -> List[Tag]:
    """
    尝试多个模式，返回所有匹配的元素（合并结果）。

    Args:
        soup: 要搜索的元素
        patterns: 选择器模式列表
        limit: 最大返回数量

    Returns:
        匹配的元素列表
    """
    if not soup:
        return []

    results = []
    seen = set()

    for pattern in patterns:
        if isinstance(pattern, str):
            elements = soup.select(pattern)
        elif isinstance(pattern, dict):
            elements = soup.find_all(**pattern)
        else:
            continue

        for elem in elements:
            elem_id = id(elem)
            if elem_id not in seen:
                seen.add(elem_id)
                results.append(elem)
                if limit and len(results) >= limit:
                    return results

    return results


# =============================================================================
# Link Processing
# =============================================================================

def parse_entry_link(href: str) -> Dict[str, Optional[str]]:
    """
    解析词典内部链接。

    Args:
        href: 链接，如 "entry://phone#_s1" 或 "phone#hash_s2"

    Returns:
        {'word': 'phone', 'sense': '1', 'raw': 'phone#_s1'}

    Example:
        >>> parse_entry_link('entry://phone#_s1')
        {'word': 'phone', 'sense': '1', 'raw': 'phone#_s1'}
    """
    if not href:
        return {'word': None, 'sense': None, 'raw': None}

    # Remove entry:// prefix
    raw = href.replace('entry://', '').replace('sound://', '')

    # Split by # to get base word
    parts = raw.split('#', 1)
    word = parts[0].lower() if parts[0] else None

    # Extract sense number from hash part
    sense = None
    if len(parts) > 1:
        match = re.search(r'_s(\d+)', parts[1])
        if match:
            sense = match.group(1)

    return {'word': word, 'sense': sense, 'raw': raw}


def convert_entry_links(
    soup: Tag,
    link_attr: str = 'href',
    target_attr: str = 'data-target'
) -> Tag:
    """
    将 entry:// 链接转换为标准格式。

    Args:
        soup: 要处理的元素
        link_attr: 原始链接属性名
        target_attr: 转换后的目标属性名

    Returns:
        修改后的元素（原地修改）
    """
    for a in soup.find_all('a', **{link_attr: True}):
        href = a.get(link_attr, '')
        if href.startswith('entry://'):
            parsed = parse_entry_link(href)
            if parsed['word']:
                a[target_attr] = parsed['word']
                if parsed['sense']:
                    a['data-sense'] = parsed['sense']
    return soup


# =============================================================================
# Audio Extraction
# =============================================================================

# Common audio extraction patterns for different dictionaries
AUDIO_PATTERNS = [
    # LDOCE style: data-src-mp3 attribute
    {'selector': '[data-src-mp3]', 'attr': 'data-src-mp3'},
    # OALD style: href with sound://
    {'selector': 'a[href^="sound://"]', 'attr': 'href', 'prefix': 'sound://'},
    # Generic: onclick with mp3
    {'selector': '[onclick*=".mp3"]', 'regex': r"['\"]([^'\"]+\.mp3)['\"]"},
    # Generic: data-audio
    {'selector': '[data-audio]', 'attr': 'data-audio'},
    # Speaker icon with src
    {'selector': '.speaker[src]', 'attr': 'src'},
]


def extract_audio_paths(
    soup: Tag,
    patterns: List[Dict] = None,
    limit: int = None
) -> List[str]:
    """
    从元素中提取音频文件路径。

    Args:
        soup: 要搜索的元素
        patterns: 提取模式列表，每个模式是:
            {
                'selector': CSS 选择器,
                'attr': 属性名（可选）,
                'regex': 正则表达式（可选）,
                'prefix': 要移除的前缀（可选）
            }
        limit: 最大返回数量

    Returns:
        音频路径列表

    Example:
        >>> paths = extract_audio_paths(entry_div)
        >>> # 或使用自定义模式
        >>> paths = extract_audio_paths(div, [
        ...     {'selector': '.sound-btn', 'attr': 'data-mp3'}
        ... ])
    """
    if not soup:
        return []

    patterns = patterns or AUDIO_PATTERNS
    results = []
    seen = set()

    for pattern in patterns:
        selector = pattern.get('selector', '')
        attr = pattern.get('attr')
        regex = pattern.get('regex')
        prefix = pattern.get('prefix', '')

        for elem in soup.select(selector):
            path = None

            if attr:
                path = elem.get(attr, '')
                if prefix and path.startswith(prefix):
                    path = path[len(prefix):]
            elif regex:
                text = elem.get('onclick', '') or str(elem)
                match = re.search(regex, text)
                if match:
                    path = match.group(1)

            if path and path not in seen:
                seen.add(path)
                results.append(path)
                if limit and len(results) >= limit:
                    return results

    return results


def extract_audio_by_variant(
    soup: Tag,
    uk_selectors: List[str] = None,
    us_selectors: List[str] = None
) -> Dict[str, Optional[str]]:
    """
    分别提取英式和美式发音音频。

    Args:
        soup: 要搜索的元素
        uk_selectors: 英式发音选择器
        us_selectors: 美式发音选择器

    Returns:
        {'uk': 'path/to/uk.mp3', 'us': 'path/to/us.mp3'}
    """
    uk_selectors = uk_selectors or ['.brefile', '.bre [data-src-mp3]', '[class*="uk"]']
    us_selectors = us_selectors or ['.amefile', '.ame [data-src-mp3]', '[class*="us"]']

    result = {'uk': None, 'us': None}

    for selector in uk_selectors:
        for elem in soup.select(selector):
            paths = extract_audio_paths(elem, limit=1)
            if paths:
                result['uk'] = paths[0]
                break
        if result['uk']:
            break

    for selector in us_selectors:
        for elem in soup.select(selector):
            paths = extract_audio_paths(elem, limit=1)
            if paths:
                result['us'] = paths[0]
                break
        if result['us']:
            break

    return result


# =============================================================================
# Text Marking and Highlighting
# =============================================================================

def mark_elements(
    element: Tag,
    markers: Dict[str, str]
) -> str:
    """
    将特定元素替换为标记文本，然后提取。

    用于保留例句中的高亮词、搭配标记等。

    Args:
        element: 要处理的元素
        markers: {选择器: 标记格式}
            标记格式使用 {text} 作为占位符

    Returns:
        带标记的文本

    Example:
        >>> # 将高亮词标记为 <<hw>>word<</hw>>
        >>> text = mark_elements(example, {
        ...     '.nodeword': '<<hw>>{text}<</hw>>',
        ...     '.colloinexa': '<<co>>{text}<</co>>'
        ... })
    """
    if not element:
        return ''

    elem_copy = clone_element(element)

    for selector, marker_format in markers.items():
        for elem in elem_copy.select(selector):
            text = elem.get_text()
            marked = marker_format.format(text=text)
            elem.replace_with(marked)

    return clean_text(elem_copy.get_text())


# =============================================================================
# Pronunciation Extraction
# =============================================================================

def extract_ipa(
    soup: Tag,
    selectors: List[str] = None,
    clean_brackets: bool = True
) -> Optional[str]:
    """
    提取 IPA 音标。

    Args:
        soup: 要搜索的元素
        selectors: 尝试的选择器列表
        clean_brackets: 是否移除音标的括号 /xxx/

    Returns:
        IPA 音标字符串
    """
    selectors = selectors or ['.pron', '.phon', '.ipa', '[class*="pron"]']

    elem = find_first(soup, selectors)
    if not elem:
        return None

    ipa = extract_text(elem)

    if clean_brackets:
        # Remove /.../ or [...] brackets
        ipa = re.sub(r'^[/\[]|[/\]]$', '', ipa.strip())

    return ipa if ipa else None


def extract_pronunciations(
    soup: Tag,
    uk_pron_selector: str = None,
    us_pron_selector: str = None,
    audio_patterns: List[Dict] = None
) -> List[Dict[str, Any]]:
    """
    提取完整的发音信息（音标 + 音频）。

    Args:
        soup: 要搜索的元素
        uk_pron_selector: 英式发音容器选择器
        us_pron_selector: 美式发音容器选择器
        audio_patterns: 音频提取模式

    Returns:
        发音信息列表: [{'ipa': '...', 'variant': 'uk', 'audio': '...'}]
    """
    results = []

    # Default selectors
    uk_selector = uk_pron_selector or '.breProns, .pron-uk, [class*="bre"]'
    us_selector = us_pron_selector or '.ameProns, .pron-us, [class*="ame"]'

    # UK pronunciation
    uk_container = soup.select_one(uk_selector)
    if uk_container:
        ipa = extract_ipa(uk_container)
        audio = extract_audio_paths(uk_container, audio_patterns, limit=1)
        if ipa or audio:
            results.append({
                'ipa': ipa,
                'variant': 'uk',
                'audio': audio[0] if audio else None
            })

    # US pronunciation
    us_container = soup.select_one(us_selector)
    if us_container:
        ipa = extract_ipa(us_container)
        audio = extract_audio_paths(us_container, audio_patterns, limit=1)
        if ipa or audio:
            results.append({
                'ipa': ipa,
                'variant': 'us',
                'audio': audio[0] if audio else None
            })

    # Fallback: single pronunciation
    if not results:
        ipa = extract_ipa(soup)
        audio = extract_audio_paths(soup, audio_patterns, limit=1)
        if ipa or audio:
            results.append({
                'ipa': ipa,
                'variant': None,
                'audio': audio[0] if audio else None
            })

    return results


# =============================================================================
# Utility Functions
# =============================================================================

def is_empty(element: Tag) -> bool:
    """检查元素是否为空（没有实际文本内容）"""
    if not element:
        return True
    text = extract_text(element)
    return not text


def get_element_path(element: Tag) -> str:
    """
    获取元素的路径（用于调试）。

    Returns:
        如 "div.entry > div.sense > span.def"
    """
    if not element:
        return ''

    parts = []
    current = element
    while current and current.name:
        classes = current.get('class', [])
        class_str = '.' + '.'.join(classes) if classes else ''
        parts.append(f"{current.name}{class_str}")
        current = current.parent

    return ' > '.join(reversed(parts))


# =============================================================================
# Test
# =============================================================================

if __name__ == '__main__':
    # Simple test
    html = '''
    <div class="entry">
        <span class="hwd">test</span>
        <span class="pron">/test/</span>
        <span class="pos" value="noun">n.</span>
        <div class="sense">
            <span class="def">a definition</span>
            <zh>中文释义</zh>
            <a href="entry://example#_s1">see example</a>
        </div>
        <a class="speaker" data-src-mp3="test.mp3"></a>
    </div>
    '''

    soup = BeautifulSoup(html, HTML_PARSER)
    entry = soup.find(class_='entry')

    print("=== html_utils test ===\n")

    # Test extract_text
    print(f"headword: {extract_text(entry.find(class_='hwd'))}")

    # Test get_attr_or_text
    print(f"pos: {get_attr_or_text(entry.find(class_='pos'))}")

    # Test extract_text_excluding
    sense = entry.find(class_='sense')
    print(f"def (with zh): {extract_text(sense.find(class_='def'))}")
    print(f"def (excl zh): {extract_text_excluding(sense, ['zh'])}")

    # Test find_first
    elem = find_first(entry, ['.headword', '.hwd', 'h1'])
    print(f"find_first: {extract_text(elem)}")

    # Test parse_entry_link
    link = entry.find('a')
    print(f"link: {parse_entry_link(link.get('href'))}")

    # Test extract_audio_paths
    paths = extract_audio_paths(entry)
    print(f"audio: {paths}")

    # Test extract_ipa
    print(f"ipa: {extract_ipa(entry)}")

    print("\n=== All tests passed ===")
