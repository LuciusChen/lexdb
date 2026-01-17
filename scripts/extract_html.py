#!/usr/bin/env python3
"""
提取指定词条的原始 HTML 结构
用法: python extract_html.py your_ldoce.mdx day
"""

import sys
from pathlib import Path

try:
    from readmdict import MDX
except ImportError:
    print("请先安装依赖: pip install readmdict python-lzo")
    sys.exit(1)


def extract_entry_html(mdx_path, word):
    """提取指定词条的 HTML"""
    print(f"正在加载 MDX: {mdx_path}")
    mdx = MDX(mdx_path)

    # 获取所有词条
    items = mdx.items()

    word_lower = word.lower()
    found = []

    for key, value in items:
        key_str = key.decode('utf-8') if isinstance(key, bytes) else key
        if key_str.lower() == word_lower:
            value_str = value.decode('utf-8') if isinstance(value, bytes) else value
            found.append((key_str, value_str))

    if not found:
        print(f"未找到词条: {word}")
        return

    for i, (key, html) in enumerate(found):
        print(f"\n{'='*60}")
        print(f"词条 {i+1}: {key}")
        print('='*60)

        # 保存到文件
        output_file = f"{word}_entry_{i+1}.html"
        with open(output_file, 'w', encoding='utf-8') as f:
            f.write(html)
        print(f"已保存到: {output_file}")

        # 打印 HTML（截取前 5000 字符）
        print("\nHTML 内容预览:")
        print('-'*40)
        if len(html) > 5000:
            print(html[:5000])
            print(f"\n... (共 {len(html)} 字符，已截取前 5000)")
        else:
            print(html)


if __name__ == '__main__':
    if len(sys.argv) < 3:
        print("用法: python extract_html.py <mdx文件路径> <词条>")
        print("例如: python extract_html.py ldoce6.mdx day")
        sys.exit(1)

    mdx_path = sys.argv[1]
    word = sys.argv[2]

    if not Path(mdx_path).exists():
        print(f"文件不存在: {mdx_path}")
        sys.exit(1)

    extract_entry_html(mdx_path, word)
