# lit configuration for JuliaIR's own tests. Run through test/litsetup.jl, which provides
# the parameters: a directory with `opt` (a wrapper around bin/jlopt), the LLVM tools of
# LLVM_utils_unified_jll (FileCheck, not, count, split-file, llvm-dis, ...), and the
# library path those tools need.
import os
import lit.formats

config.name = 'JuliaIR'
config.suffixes = ['.ll']
config.test_format = lit.formats.ShTest(False)
config.test_source_root = os.path.dirname(__file__)
config.test_exec_root = lit_config.params['exec_root']

exec(open(lit_config.params['common_cfg']).read())
