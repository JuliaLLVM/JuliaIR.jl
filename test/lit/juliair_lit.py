# A lit test format for JuliaIR's harness, in a module of its own so that lit can send
# tests that use it to its worker processes.
import os

import lit.formats


class LedgerShTest(lit.formats.ShTest):
    """lit's shell tests, with a JuliaIR ledger per test: the environment variable
    JULIAIR_LEDGER names the file `<ledger_dir>/<test path, joined by __>.ledger`."""

    def __init__(self, ledger_dir, execute_external=False):
        super().__init__(execute_external)
        self.ledger_dir = ledger_dir

    def execute(self, test, litConfig):
        ledger = os.path.join(self.ledger_dir, '__'.join(test.path_in_suite) + '.ledger')
        test.config.environment['JULIAIR_LEDGER'] = ledger
        return super().execute(test, litConfig)
