#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
解析沙盒工具 - 快速调试单个词条的解析结果

用法:
    python inspect_entry.py LDOCE6.mdx "call"
    python inspect_entry.py LDOCE6.mdx "call" --parser ldoce
    python inspect_entry.py LDOCE6.mdx "call" --html-only
    python inspect_entry.py LDOCE6.mdx "call" --json-only
    python inspect_entry.py LDOCE6.mdx "call" --raw  # 不格式化 HTML

示例:
    # 查看 call 的原始 HTML 和解析结果
    python inspect_entry.py ~/dicts/LDOCE6.mdx call

    # 只看原始 HTML（调试选择器时有用）
    python inspect_entry.py ~/dicts/LDOCE6.mdx call --html-only

    # 只看解析后的 JSON（验证解析结果）
    python inspect_entry.py ~/dicts/LDOCE6.mdx call --json-only

    # 模糊搜索（找出以 call 开头的所有词条）
    python inspect_entry.py ~/dicts/LDOCE6.mdx "call*" --list
"""

import sys
import json
import argparse
import fnmatch
from pathlib import Path

try:
    from readmdict import MDX
except ImportError:
    print("请安装 readmdict: pip install readmdict")
    sys.exit(1)

try:
    from bs4 import BeautifulSoup
    # Try to use lxml for faster parsing
    try:
        import lxml
        HTML_PARSER = 'lxml'
    except ImportError:
        HTML_PARSER = 'html.parser'
except ImportError:
    print("请安装 beautifulsoup4: pip install beautifulsoup4 lxml")
    sys.exit(1)


class ParserWrapper:
    """统一的解析器包装器"""
    def __init__(self, parse_fn):
        self.parse_fn = parse_fn

    def parse(self, html, word_key):
        return self.parse_fn(html, word_key)


def load_parser(parser_name):
    """动态加载解析器"""
    if parser_name == 'ldoce':
        from mdx2db import LDOCEParser
        return LDOCEParser()
    elif parser_name == 'oald':
        from mdx2db_oald import parse_oald4_entry
        # OALD 用函数，包装成类
        def parse_oald(html, word_key):
            result = parse_oald4_entry(html, word_key)
            return [result] if result else []
        return ParserWrapper(parse_oald)
    else:
        print(f"未知的解析器: {parser_name}")
        print("可用: ldoce, oald")
        sys.exit(1)


def find_entries(mdx, pattern, limit=20):
    """查找匹配的词条"""
    pattern_lower = pattern.lower()
    is_wildcard = '*' in pattern or '?' in pattern

    results = []
    for word_key, html in mdx.items():
        if isinstance(word_key, bytes):
            word_key = word_key.decode('utf-8', errors='ignore')

        key_lower = word_key.lower()

        if is_wildcard:
            if fnmatch.fnmatch(key_lower, pattern_lower):
                if isinstance(html, bytes):
                    html = html.decode('utf-8', errors='ignore')
                results.append((word_key, html))
        else:
            if key_lower == pattern_lower:
                if isinstance(html, bytes):
                    html = html.decode('utf-8', errors='ignore')
                results.append((word_key, html))
                break  # 精确匹配只需要第一个

        if len(results) >= limit:
            break

    return results


def format_html(html, max_length=5000):
    """格式化 HTML 以便阅读"""
    soup = BeautifulSoup(html, HTML_PARSER)
    formatted = soup.prettify()

    if len(formatted) > max_length:
        return formatted[:max_length] + f"\n\n... (截断，共 {len(formatted)} 字符)"
    return formatted


def print_separator(title, char='=', width=70):
    """打印分隔线"""
    print()
    print(char * width)
    print(f" {title}")
    print(char * width)


def main():
    parser = argparse.ArgumentParser(
        description='解析沙盒 - 调试词条解析',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  %(prog)s LDOCE6.mdx call              # 查看 call 的 HTML 和解析结果
  %(prog)s LDOCE6.mdx call --html-only  # 只看原始 HTML
  %(prog)s LDOCE6.mdx call --json-only  # 只看解析结果
  %(prog)s LDOCE6.mdx "call*" --list    # 列出以 call 开头的词条
        """
    )
    parser.add_argument('mdx_file', help='MDX 文件路径')
    parser.add_argument('word', help='要查询的单词 (支持 * 和 ? 通配符)')
    parser.add_argument('--parser', '-p', default='ldoce',
                        choices=['ldoce', 'oald'],
                        help='使用的解析器 (默认: ldoce)')
    parser.add_argument('--html-only', '-H', action='store_true',
                        help='只显示原始 HTML')
    parser.add_argument('--json-only', '-J', action='store_true',
                        help='只显示解析结果')
    parser.add_argument('--raw', '-r', action='store_true',
                        help='不格式化 HTML (显示原始内容)')
    parser.add_argument('--list', '-l', action='store_true',
                        help='只列出匹配的词条名 (用于通配符搜索)')
    parser.add_argument('--max-length', '-m', type=int, default=5000,
                        help='HTML 显示的最大长度 (默认: 5000)')
    parser.add_argument('--all', '-a', action='store_true',
                        help='显示完整内容，不截断')

    args = parser.parse_args()

    # 检查文件
    mdx_path = Path(args.mdx_file).expanduser()
    if not mdx_path.exists():
        print(f"文件不存在: {mdx_path}")
        sys.exit(1)

    print(f"打开 MDX: {mdx_path}")
    mdx = MDX(str(mdx_path))

    # 查找词条
    print(f"查找: {args.word}")
    entries = find_entries(mdx, args.word)

    if not entries:
        print(f"\n未找到词条: {args.word}")
        # 尝试给出建议
        suggestions = find_entries(mdx, args.word[:3] + '*', limit=5)
        if suggestions:
            print("\n你是不是想找:")
            for word_key, _ in suggestions:
                print(f"  - {word_key}")
        sys.exit(1)

    # 如果是列表模式
    if args.list:
        print(f"\n找到 {len(entries)} 个匹配:")
        for word_key, html in entries:
            html_len = len(html)
            print(f"  - {word_key} ({html_len} bytes)")
        sys.exit(0)

    # 处理每个找到的词条
    for idx, (word_key, html) in enumerate(entries):
        if len(entries) > 1:
            print_separator(f"词条 {idx + 1}/{len(entries)}: {word_key}", '█')

        # 显示原始 HTML
        if not args.json_only:
            print_separator(f"原始 HTML ({len(html)} 字符)")
            if args.raw:
                if args.all:
                    print(html)
                else:
                    print(html[:args.max_length])
                    if len(html) > args.max_length:
                        print(f"\n... (截断，使用 --all 显示全部)")
            else:
                print(format_html(html,
                                  max_length=None if args.all else args.max_length))

        # 解析并显示结果
        if not args.html_only:
            try:
                parser_obj = load_parser(args.parser)
                parsed = parser_obj.parse(html, word_key)

                print_separator("解析结果 (JSON)")
                output = json.dumps(parsed, ensure_ascii=False, indent=2)
                if not args.all and len(output) > args.max_length:
                    print(output[:args.max_length])
                    print(f"\n... (截断，使用 --all 显示全部)")
                else:
                    print(output)

                # 显示统计
                if parsed:
                    print_separator("统计", '-', 40)
                    for i, entry in enumerate(parsed):
                        senses = entry.get('senses', [])
                        prons = entry.get('pronunciations', [])
                        colls = entry.get('collocations', [])
                        print(f"  Entry {i+1}: {entry.get('headword', '?')}")
                        print(f"    - 义项: {len(senses)}")
                        print(f"    - 发音: {len(prons)}")
                        print(f"    - 搭配: {len(colls)}")
                        total_examples = sum(
                            len(s.get('examples', [])) for s in senses
                        )
                        print(f"    - 例句: {total_examples}")

            except Exception as e:
                print_separator("解析错误", '!')
                print(f"错误: {e}")
                import traceback
                traceback.print_exc()


if __name__ == '__main__':
    main()
