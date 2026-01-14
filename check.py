#!/usr/bin/env python3
"""Check LDOCE HTML structure."""

import sys

def main():
    if len(sys.argv) < 2:
        print("Usage: python check_html.py /path/to/LDOCE6.mdx [word]")
        sys.exit(1)

    mdx_path = sys.argv[1]
    word = sys.argv[2] if len(sys.argv) > 2 else "call"

    from readmdict import MDX

    print(f"Loading {mdx_path}...")
    mdx = MDX(mdx_path)

    print(f"Searching for '{word}'...")

    # Collect all matching entries
    matches = []
    word_lower = word.lower()

    for key, value in mdx.items():
        key_str = key.decode('utf-8') if isinstance(key, bytes) else key
        # Match if key starts with the word (to find call1, call2, etc.)
        if key_str.lower() == word_lower or key_str.lower().startswith(word_lower + ' '):
            matches.append((key_str, value))
        # Also match call1, call2 patterns
        if key_str.lower().rstrip('0123456789') == word_lower:
            matches.append((key_str, value))

    if not matches:
        print(f"Word '{word}' not found")
        print("\nTrying to find similar entries...")
        for key, value in mdx.items():
            key_str = key.decode('utf-8') if isinstance(key, bytes) else key
            if word_lower in key_str.lower():
                print(f"  Found: {key_str}")
                if len(matches) > 10:
                    break
        return

    for key_str, value in matches[:5]:  # Show first 5 matches
        html = value.decode('utf-8') if isinstance(value, bytes) else value
        print(f"\n{'='*60}")
        print(f"=== HTML for '{key_str}' ===")
        print('='*60)

        # Find phrasal verb section
        if 'phrvbentry' in html or 'phrv' in html:
            print("\n[Contains phrasal verbs!]")
            # Extract just the phrasal verb part
            import re
            phrv_match = re.search(r'<span class="phrvbentry".*?</span>\s*</span>', html, re.DOTALL)
            if phrv_match:
                print("\n--- Phrasal verb section (first 3000 chars) ---")
                print(phrv_match.group(0)[:3000])
            else:
                # Just show part with phrv
                idx = html.find('phrvb')
                if idx > 0:
                    print("\n--- Around 'phrvb' (3000 chars) ---")
                    print(html[max(0,idx-100):idx+3000])

        print(f"\n--- Full HTML (first 2000 chars) ---")
        print(html[:2000])
        if len(html) > 2000:
            print(f"\n... (truncated, total {len(html)} chars)")

if __name__ == "__main__":
    main()
