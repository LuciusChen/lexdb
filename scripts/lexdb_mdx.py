"""MDX record streaming and MDD extraction, independent of HTML parsing."""

from pathlib import Path


def open_mdx(path):
    """Load the optional MDX dependency only when opening an archive."""
    from readmdict import MDX
    return MDX(str(path))


def iter_mdx_entries(mdx, errors='ignore'):
    """Decode one record at a time without retaining all HTML in memory.

    Use `len(mdx)` for the archive's record count without consuming this stream.
    Set ERRORS to 'strict' to reject invalid UTF-8 instead of discarding it.
    """
    for key, html in mdx.items():
        if isinstance(key, bytes):
            key = key.decode('utf-8', errors=errors)
        if isinstance(html, bytes):
            html = html.decode('utf-8', errors=errors)
        yield key, html


def extract_mdd_audio(mdx_path):
    """Extract the base and numbered MDD archives next to MDX_PATH.

    Return the audio directory, or None if no archives are present.
    """
    mdx_path = Path(mdx_path)
    base = mdx_path.with_suffix('.mdd')
    archives = [base] if base.exists() else []
    for index in range(1, 20):
        candidates = [mdx_path.with_name(f'{mdx_path.stem}{separator}{index}.mdd')
                      for separator in ('_', '.')]
        archive = next((path for path in candidates if path.exists()), None)
        if archive is None:
            break
        archives.append(archive)
    if not archives:
        print(f'Warning: No MDD files found for: {mdx_path.stem}')
        return None

    from readmdict import MDD
    audio_dir = (mdx_path.parent / 'audio').resolve()
    audio_dir.mkdir(exist_ok=True)
    print(f'Extracting {len(archives)} MDD file(s) to: {audio_dir}')
    for archive in archives:
        print(f'  Processing: {archive.name}')
        count = 0
        for key, data in MDD(str(archive)).items():
            if isinstance(key, bytes):
                key = key.decode('utf-8', errors='ignore')
            key = key.replace('\\', '/').lstrip('/')
            output = (audio_dir / key).resolve()
            if audio_dir not in output.parents:
                raise ValueError(f'MDD path escapes audio directory: {key}')
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_bytes(data)
            count += 1
        print(f'    Extracted {count} files')
    print('Audio extraction complete')
    return audio_dir
