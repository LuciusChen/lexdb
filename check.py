#!/usr/bin/env python3
"""Check LDOCE HTML structure for inflections."""

import sys

def main():
    if len(sys.argv) < 2:
        print("Usage: uv run check_html.py /path/to/LDOCE6.mdx [word]")
        print("Example: uv run check_html.py ~/LDOCE6.mdx swing")
        sys.exit(1)

    mdx_path = sys.argv[1]
    word = sys.argv[2] if len(sys.argv) > 2 else "swing"

    try:
        from readmdict import MDX
    except ImportError:
        print("Installing readmdict...")
        import subprocess
        subprocess.run([sys.executable, "-m", "pip", "install", "readmdict", "-q"])
        from readmdict import MDX

    print(f"Loading {mdx_path}...")
    mdx = MDX(mdx_path)

    print(f"Searching for '{word}'...")
    for key, value in mdx.items():
        key_str = key.decode('utf-8') if isinstance(key, bytes) else key
        if key_str.lower() == word.lower():
            html = value.decode('utf-8') if isinstance(value, bytes) else value
            print(f"\n=== HTML for '{key_str}' ===\n")
            print(html[:5000])  # First 5000 chars
            if len(html) > 5000:
                print(f"\n... (truncated, total {len(html)} chars)")
            break
    else:
        print(f"Word '{word}' not found")

if __name__ == "__main__":
    main()
