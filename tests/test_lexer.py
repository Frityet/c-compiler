import re
import unittest
from test_utils import TestHelpers

class LexerTest(unittest.TestCase):
    def _trim_positions(self, text: str) -> str:
        return re.sub(r' \([0-9]+,[0-9]+\)', '', text).strip()

    def test_simple_function_tokens(self):
        source = 'int main() { int a=1; if(a>0) a=a+1; while(a<10) a=a+1; return a; }'
        output = TestHelpers.run_cc(['--tokens'], input_text=source)
        output = self._trim_positions(output)
        expected = '\n'.join([
            'INT:int',
            'IDENT:main',
            'LPAREN:(',
            'RPAREN:)',
            'LBRACE:{',
            'INT:int',
            'IDENT:a',
            'ASSIGN:=',
            'NUMBER:1',
            'SEMICOLON:;',
            'IF:if',
            'LPAREN:(',
            'IDENT:a',
            'GT:>',
            'NUMBER:0',
            'RPAREN:)',
            'IDENT:a',
            'ASSIGN:=',
            'IDENT:a',
            'PLUS:+',
            'NUMBER:1',
            'SEMICOLON:;',
            'WHILE:while',
            'LPAREN:(',
            'IDENT:a',
            'LT:<',
            'NUMBER:10',
            'RPAREN:)',
            'IDENT:a',
            'ASSIGN:=',
            'IDENT:a',
            'PLUS:+',
            'NUMBER:1',
            'SEMICOLON:;',
            'RETURN:return',
            'IDENT:a',
            'SEMICOLON:;',
            'RBRACE:}',
            'EOF:'
        ])
        self.assertEqual(output, expected)

    def test_lex_parser_c(self):
        with open('src/parser.c') as f:
            src = f.read()
        output = TestHelpers.run_cc(['--tokens'], input_text=src)
        output = self._trim_positions(output)
        self.assertTrue(output.startswith('IDENT:static'))

if __name__ == '__main__':
    unittest.main()
