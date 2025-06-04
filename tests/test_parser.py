import unittest
from test_utils import TestHelpers

class ParserTest(unittest.TestCase):
    def test_simple_function_ast(self):
        source = 'int main() { return 1+2; }'
        output = TestHelpers.run_cc(['--ast'], input_text=source)
        expected = '\n'.join([
            'FUNC:main',
            '  RETURN',
            '    BIN:PLUS',
            '      NUMBER:1',
            '      NUMBER:2',
            ''
        ])
        self.assertEqual(output.strip(), expected.strip())

if __name__ == '__main__':
    unittest.main()
