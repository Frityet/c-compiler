import os
import subprocess

BIN_PATH = os.path.join(os.path.dirname(__file__), '..', 'bin', 'cc')

class TestHelpers:
    @staticmethod
    def run_cc(args=None, input_text=None):
        args = args or []
        result = subprocess.run([BIN_PATH] + args, input=input_text, text=True,
                                capture_output=True, check=True)
        return result.stdout
