"""Regression checks for parser imports, writer boundaries, and conversion."""

import copy
import importlib
import io
import json
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import zlib
from contextlib import closing, redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
sys.path.insert(0, str(SCRIPTS))


class WriterTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)

    def open_writer(self, kind):
        module = importlib.import_module('mdx2db_' + kind)
        path = Path(self.directory.name) / (kind + '.db')
        if kind == 'oald':
            conn = module.create_database(path)
            conn.execute("INSERT INTO dictionaries (dict_id, name, created_at) VALUES ('oald', 'test', 'test')")
            self.addCleanup(conn.close)
            return conn, lambda entry: module.insert_entry(conn, kind, entry)
        writer = module.LexDBWriter(str(path), kind, 'test')
        writer.open()
        self.addCleanup(writer.close, vacuum=False)
        return writer.conn, writer.write_entry

    def test_failed_entry_rolls_back_only_that_entry(self):
        for kind in ('ldoce', 'ode', 'oald'):
            with self.subTest(kind=kind):
                conn, write = self.open_writer(kind)
                write({'headword': 'before', 'senses': [{'definition': 'first'}]})
                with self.assertRaises(sqlite3.IntegrityError):
                    write({'headword': 'broken', 'senses': [
                        {'definition': 'valid sense'},
                        {'definition': None, 'examples': [{'text': 'forces insertion'}]},
                    ]})
                write({'headword': 'after', 'senses': [{'definition': 'last'}]})
                self.assertEqual(conn.execute('SELECT headword FROM entries ORDER BY id').fetchall(),
                                 [('before',), ('after',)])
                self.assertEqual(conn.execute('SELECT definition FROM senses ORDER BY id').fetchall(),
                                 [('first',), ('last',)])
                self.assertTrue(conn.in_transaction, 'Entry writes must not commit the outer batch')
                self.assertEqual(conn.execute('PRAGMA foreign_key_check').fetchall(), [])

    def test_writing_does_not_mutate_parsed_entries(self):
        for kind in ('ldoce', 'ode', 'oald'):
            with self.subTest(kind=kind):
                conn, write = self.open_writer(kind)
                entry = {'headword': 'sample', 'attributes': {'existing': 'kept'},
                         'senses': [{'number': '1', 'definition': 'definition',
                                     'sort_order': 2, 'subsenses': [{'definition': 'nested'}],
                                     'synonyms': ['alternate'], 'form_groups': ['samples'],
                                     'section_register': 'informal', 'transitivity': 'transitive',
                                     'expanded_examples': [{'text': 'extra'}]}]}
                original = copy.deepcopy(entry)
                write(entry)
                self.assertEqual(entry, original)
                attrs = {}
                for key, value, attr_type in conn.execute(
                        'SELECT attr_key, attr_value, attr_type FROM entry_attributes'):
                    if attr_type in ('json.gz', 'json_compressed'):
                        value = zlib.decompress(value).decode('utf-8')
                    attrs[key] = json.loads(value) if attr_type.startswith('json') else value
                if kind == 'ldoce':
                    self.assertEqual(attrs['ldoce/subsenses'], {'1': [{'definition': 'nested'}]})
                elif kind == 'ode':
                    self.assertEqual(attrs['ode/sense_synonyms'], {'2': ['alternate']})
                    self.assertEqual(attrs['ode/sense_transitivity'], {'2': 'transitive'})
                else:
                    self.assertEqual(attrs['oald/oald/subsenses'], {'1': [{'definition': 'nested'}]})

    def test_shared_storage_preserves_order_and_attribute_encodings(self):
        for kind in ('ldoce', 'ode'):
            with self.subTest(kind=kind):
                conn, write = self.open_writer(kind)
                large = {'text': '中文' * 600}
                write({'headword': 'sample', 'attributes': {
                    'small': ['中文'], 'large': large, 'rank': 3, 'enabled': True,
                    'origin': 'Old English'},
                    'collocations': [
                        {'category': 'verb', 'text': 'second', 'sort_order': 2,
                         'examples': [{'text': 'later', 'sort_order': 2},
                                      {'text': 'earlier', 'sort_order': 1}]},
                        {'category': 'noun', 'text': 'first', 'sort_order': 1}],
                    'relations': [
                        {'type': 'cross_ref', 'target': 'legacy', 'link': 'entry://legacy'},
                        {'type': 'synonym', 'prefix': 'see ', 'clickable': 'related',
                         'suffix': ' (2)', 'target_word': 'related', 'target_sense': '2'}]})
                self.assertEqual(conn.execute('SELECT text FROM collocations ORDER BY sort_order').fetchall(),
                                 [('first',), ('second',)])
                self.assertEqual(conn.execute('SELECT text FROM collocation_examples ORDER BY sort_order').fetchall(),
                                 [('earlier',), ('later',)])
                self.assertEqual(conn.execute('SELECT relation_type, clickable, target_word, target_sense FROM relations ORDER BY sort_order').fetchall(),
                                 [('cross_ref', 'legacy', 'legacy', None),
                                  ('synonym', 'related', 'related', '2')])
                attrs = {key: (value, attr_type) for key, value, attr_type in conn.execute(
                    'SELECT attr_key, attr_value, attr_type FROM entry_attributes')}
                self.assertEqual(attrs[kind + '/small'], ('["中文"]', 'json'))
                self.assertEqual(attrs[kind + '/rank'], ('3', 'integer'))
                self.assertEqual(attrs[kind + '/enabled'], ('1', 'boolean'))
                self.assertEqual(attrs[kind + '/origin'], ('Old English', 'text'))
                compressed, attr_type = attrs[kind + '/large']
                self.assertEqual(attr_type, 'json.gz')
                self.assertEqual(json.loads(zlib.decompress(compressed)), large)


class MdxTests(unittest.TestCase):
    def test_decoding_is_lazy_and_accepts_bytes_and_text(self):
        from lexdb_mdx import iter_mdx_entries
        visited = []

        def items():
            for record in [(b'one', '中文'.encode()), ('two', 'text')]:
                visited.append(record[0])
                yield record

        stream = iter_mdx_entries(SimpleNamespace(items=items))
        self.assertEqual(visited, [])
        self.assertEqual(next(stream), ('one', '中文'))
        self.assertEqual(visited, [b'one'])
        self.assertEqual(list(stream), [('two', 'text')])
        invalid = SimpleNamespace(items=lambda: iter([(b'bad\xff', b'value')]))
        self.assertEqual(list(iter_mdx_entries(invalid)), [('bad', 'value')])
        with self.assertRaises(UnicodeDecodeError):
            list(iter_mdx_entries(invalid, errors='strict'))

    def test_mdd_extraction_preserves_archive_order_and_nested_paths(self):
        from lexdb_mdx import extract_mdd_audio
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'sample.mdx'
            names = ('sample.mdd', 'sample_1.mdd', 'sample.2.mdd')
            for name in names:
                (source.parent / name).touch()
            opened = []

            def mdd(path):
                opened.append(Path(path).name)
                records = [(b'\\nested\\audio.mp3', Path(path).name.encode())]
                return SimpleNamespace(items=lambda: iter(records))

            with patch.dict(sys.modules, readmdict=SimpleNamespace(MDD=mdd)), redirect_stdout(io.StringIO()):
                output = extract_mdd_audio(source)
            self.assertEqual(opened, list(names))
            self.assertEqual((output / 'nested/audio.mp3').read_bytes(), b'sample.2.mdd')

    def test_mdd_paths_cannot_escape_output_directory(self):
        from lexdb_mdx import extract_mdd_audio
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'sample.mdx'
            source.with_suffix('.mdd').touch()
            archive = SimpleNamespace(items=lambda: iter([(b'../outside.mp3', b'bad')]))
            with patch.dict(sys.modules, readmdict=SimpleNamespace(MDD=lambda _: archive)), redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(ValueError, 'escapes audio directory'):
                    extract_mdd_audio(source)
            self.assertFalse((source.parent / 'outside.mp3').exists())

    def test_no_mdd_files_need_no_reader_dependency(self):
        from lexdb_mdx import extract_mdd_audio
        with tempfile.TemporaryDirectory() as directory:
            with patch.dict(sys.modules, readmdict=None), redirect_stdout(io.StringIO()):
                self.assertIsNone(extract_mdd_audio(Path(directory) / 'sample.mdx'))


class ConversionTests(unittest.TestCase):
    def test_missing_mdx_dependency_leaves_output_untouched(self):
        code = """
import importlib
import sys
sys.modules['readmdict'] = None
kind, source = sys.argv[1:]
module = importlib.import_module('mdx2db_' + kind)
if kind == 'oald':
    module.convert_oald4(source)
else:
    module.convert_mdx_to_lexdb(source)
"""
        for kind in ('ldoce', 'ode', 'oald'):
            for existing in (False, True):
                with self.subTest(kind=kind, existing=existing), tempfile.TemporaryDirectory() as directory:
                    source = Path(directory) / (kind + '.mdx')
                    source.write_bytes(b'source archive')
                    output = source.with_suffix('.db')
                    if existing:
                        with closing(sqlite3.connect(output)) as conn:
                            conn.execute('CREATE TABLE existing_data (value TEXT)')
                            conn.execute("INSERT INTO existing_data VALUES ('keep me')")
                            conn.commit()
                        original = output.read_bytes()
                    result = subprocess.run([sys.executable, '-B', '-c', code, kind, str(source)],
                                            cwd=SCRIPTS, text=True, capture_output=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('ModuleNotFoundError', result.stderr)
                    if existing:
                        self.assertTrue(output.exists(), 'Existing database was deleted')
                        self.assertEqual(output.read_bytes(), original)
                    else:
                        self.assertFalse(output.exists(), 'Failed conversion created a database')

    def test_audio_failure_preserves_existing_database(self):
        for kind in ('ldoce', 'ode'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                module = importlib.import_module('mdx2db_' + kind)
                source = Path(directory) / (kind + '.mdx')
                source.touch()
                output = source.with_suffix('.db')
                output.write_bytes(b'existing database')
                with patch.object(module, 'open_mdx'), \
                     patch.object(module, 'extract_mdd_audio', side_effect=ValueError('Invalid archive path')), \
                     redirect_stdout(io.StringIO()):
                    with self.assertRaisesRegex(ValueError, 'Invalid archive path'):
                        module.convert_mdx_to_lexdb(str(source), extract_audio=True)
                self.assertTrue(output.exists(), 'Existing database was deleted')
                self.assertEqual(output.read_bytes(), b'existing database')

    def test_all_converters_parse_before_reading_the_next_record(self):
        for kind in ('ldoce', 'ode', 'oald'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                module = importlib.import_module('mdx2db_' + kind)
                source = Path(directory) / (kind + '.mdx')
                source.touch()
                parsed = []
                test = self

                class Archive:
                    def __len__(self):
                        return 3

                    def items(self):
                        for index, word in enumerate(('alpha', 'bravo', 'charlie')):
                            test.assertEqual(len(parsed), index, 'Converter eagerly consumed HTML')
                            yield word.encode(), b'<div>' + b'x' * 60 + b'</div>'

                def parse(html, word):
                    parsed.append(word)
                    return [{'headword': word, 'senses': [{'definition': 'meaning'}]}]

                parser = (patch.object(module, 'parse_oald4_entry', side_effect=parse)
                          if kind == 'oald' else
                          patch.object(getattr(module, kind.upper() + 'Parser'), 'parse', side_effect=parse))
                with patch.object(module, 'open_mdx', return_value=Archive()), parser, redirect_stdout(io.StringIO()):
                    if kind == 'oald':
                        module.convert_oald4(source, directory)
                    else:
                        module.convert_mdx_to_lexdb(str(source))
                with closing(sqlite3.connect(source.with_suffix('.db'))) as conn:
                    self.assertEqual(conn.execute('SELECT headword FROM entries ORDER BY id').fetchall(),
                                     [('alpha',), ('bravo',), ('charlie',)])
                    self.assertEqual(conn.execute('SELECT entry_count FROM dictionaries').fetchone(), (3,))

    def test_oald_can_skip_an_undecodable_first_record(self):
        import mdx2db_oald as module
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'oald.mdx'
            source.touch()

            class Archive:
                def __len__(self):
                    return 2

                def items(self):
                    return iter([(b'\xff', b'invalid'), (b'valid', b'x' * 60)])

            entry = {'headword': 'valid', 'senses': [{'definition': 'meaning'}]}
            with patch.object(module, 'open_mdx', return_value=Archive()), \
                 patch.object(module, 'parse_oald4_entry', return_value=[entry]), \
                 redirect_stdout(io.StringIO()):
                module.convert_oald4(source, directory)
            with closing(sqlite3.connect(source.with_suffix('.db'))) as conn:
                self.assertEqual(conn.execute('SELECT headword FROM entries').fetchall(), [('valid',)])


class ParserImportTests(unittest.TestCase):
    def test_html_parsers_import_without_mdx_dependency(self):
        code = """
import sys
sys.modules['readmdict'] = None
import mdx2db_ldoce, mdx2db_ode, mdx2db_oald, extract_html
assert mdx2db_ldoce.LDOCEParser().parse('<div></div>', 'sample')
assert mdx2db_ode.ODEParser().parse('<div></div>', 'sample')
assert mdx2db_oald.parse_oald4_entry('<div></div>', 'sample') == []
"""
        result = subprocess.run([sys.executable, '-c', code], cwd=SCRIPTS,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, '')


if __name__ == '__main__':
    unittest.main()
