import unittest
from test_utils import TestHelpers

class ParserTest(unittest.TestCase):
    def test_simple_function_ast(self):
        source = 'int main() { int a=1; if(a>0) a=a+1; while(a<10) a=a+1; return a; }'
        output = TestHelpers.run_cc(['--ast'], input_text=source)
        expected = '\n'.join([
            'FUNC:main',
            '  VAR:a',
            '    INIT',
            '      NUMBER:1',
            '  IF',
            '    COND',
            '      BIN:GT',
            '        IDENT:a',
            '        NUMBER:0',
            '    THEN',
            '      EXPR',
            '        ASSIGN',
            '          IDENT:a',
            '          BIN:PLUS',
            '            IDENT:a',
            '            NUMBER:1',
            '  WHILE',
            '    COND',
            '      BIN:LT',
            '        IDENT:a',
            '        NUMBER:10',
            '    BODY',
            '      EXPR',
            '        ASSIGN',
            '          IDENT:a',
            '          BIN:PLUS',
            '            IDENT:a',
            '            NUMBER:1',
            '  RETURN',
            '    IDENT:a',
            ''
        ])
        self.assertEqual(output.strip(), expected.strip())

    def test_parse_header(self):
        with open('include/ast.h') as f:
            src = f.read()
        output = TestHelpers.run_cc(['--ast'], input_text=src)
        self.assertEqual(output.strip(), '')

    def test_parse_parser_c(self):
        with open('src/parser.c') as f:
            src = f.read()
        output = TestHelpers.run_cc(['--ast'], input_text=src)
        self.assertEqual(output.strip(), '')

if __name__ == '__main__':
    unittest.main()
