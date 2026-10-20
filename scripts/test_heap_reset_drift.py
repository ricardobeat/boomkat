#!/usr/bin/env python3
"""Regression checks for the reset coverage guard.

Run with: python3 -m unittest discover -s scripts -p test_heap_reset_drift.py
"""

from pathlib import Path
import unittest

import check_heap_reset_drift as drift


class HeapResetDriftTests(unittest.TestCase):
    def setUp(self):
        self.sources = {
            path: (Path(drift.PROJECT_DIR) / path).read_text()
            for path, _, _ in drift.RESET_HELPERS.values()
        }
        self.text = self.sources['src/heap.c3']

    def missing(self, text=None):
        text = self.text if text is None else text
        return (set(drift.extract_struct_fields(text))
                - drift.extract_reset_fields(text, self.sources)
                - drift.ALLOWED_NOT_RESET)

    def test_current_heap_is_covered(self):
        self.assertEqual(self.missing(), set())
        self.assertFalse(drift.ALLOWED_NOT_RESET - set(drift.extract_struct_fields(self.text)))

    def test_new_field_requires_coverage(self):
        text = self.text.replace('struct Heap {', 'struct Heap {\n    uint drift_probe;')
        self.assertEqual(self.missing(text), {'drift_probe'})

    def test_helpers_only_count_when_called(self):
        cases = {
            'self.drain_catcher_pool();': {'catcher_pool', 'catcher_pool_len'},
            'hobject::env_pool_teardown(self);': {'env_pool_blocks', 'env_freelist'},
            'esm::free_defined_modules(self);': {'defined_modules', 'defined_module_count'},
            'self.init_transition_table();': {'trans_count', 'trans_mask'},
        }
        for call, fields in cases.items():
            with self.subTest(call=call):
                text = self.text.replace(call, '// ' + call)
                self.assertTrue(fields <= self.missing(text))

    def test_forwarding_call_is_required(self):
        self.sources['src/hobject.c3'] = self.sources['src/hobject.c3'].replace(
            'env::env_pool_teardown(h);', '')
        self.assertIn('env_pool_blocks', self.missing())

    def test_helper_cleanup_is_required(self):
        self.sources['src/env.c3'] = self.sources['src/env.c3'].replace(
            'h.env_block_count = 0;', '// h.env_block_count = 0;')
        self.assertIn('env_block_count', self.missing())

    def test_comments_and_literals_cannot_supply_coverage(self):
        text = '''
struct Heap {
    uint missing;
    uint cleared;
    // }
}
fn void Heap.reset(&self) {
    // } self.missing = 0;
    /* { self.missing = 0; */
    char[] message = "} self.missing = 0;";
    self.cleared = 0;
}
fn void unrelated() { self.missing = 0; }
'''
        self.assertEqual(set(drift.extract_struct_fields(text)), {'missing', 'cleared'})
        self.assertEqual(drift.extract_reset_fields(text), {'cleared'})


if __name__ == '__main__':
    unittest.main()
