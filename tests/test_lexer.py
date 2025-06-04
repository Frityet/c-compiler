import re
import unittest
from test_utils import TestHelpers

class LexerTest(unittest.TestCase):
    def _trim_positions(self, text: str) -> str:
        return re.sub(r' \([0-9]+,[0-9]+\)', '', text).strip()

    def test_simple_function_tokens(self):
        source = 'int main() { return 1+2; }'
        output = TestHelpers.run_cc(['--tokens'], input_text=source)
        output = self._trim_positions(output)
        expected = '\n'.join([
            'INT:int',
            'IDENT:main',
            'LPAREN:(',
            'RPAREN:)',
            'LBRACE:{',
            'RETURN:return',
            'NUMBER:1',
            'PLUS:+',
            'NUMBER:2',
            'SEMICOLON:;',
            'RBRACE:}',
            'EOF:'
        ])
        self.assertEqual(output, expected)

if __name__ == '__main__':
    unittest.main()
