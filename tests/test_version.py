import unittest
from test_utils import TestHelpers

class VersionTest(unittest.TestCase):
    def test_version_output(self):
        output = TestHelpers.run_cc(['--version'])
        self.assertIn('cc version', output)

if __name__ == '__main__':
    unittest.main()
