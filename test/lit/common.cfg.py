# Settings shared by the lit configurations of JuliaIR's own tests and of the upstream
# fixtures (test/upstream): tools on PATH, the environment the Julia driver needs, and
# the substitutions used in RUN lines. Executed by those configurations.
import os
import platform

params = lit_config.params

for key in ('%{shlibext}', '%shlibext'):
    config.substitutions.append((key, params['shlibext']))

path = [params['bindir'], params['toolsdir']]
libpath_env = params['libpath_env']
if libpath_env == 'PATH':
    # Windows: libraries are found through PATH
    path.append(params['libpath'])
else:
    config.environment[libpath_env] = os.pathsep.join(
        p for p in [params['libpath'], os.environ.get(libpath_env, '')] if p)
path.append(os.environ.get('PATH', ''))
config.environment['PATH'] = os.pathsep.join(p for p in path if p)

# Windows cannot run the `opt` wrapper script that is on PATH elsewhere, so RUN lines
# get the command that runs jlopt instead (`substitute_jlopt=1` does that elsewhere too,
# to test it)
if platform.system() == 'Windows' or params.get('substitute_jlopt') == '1':
    for tool in ('opt', 'jlopt'):
        config.substitutions.append((r'(?<![\w.%/-])' + tool + r'(?=\s)', params['jlopt_cmd']))

# what the Julia driver needs to find its packages and write its caches
for var, value in os.environ.items():
    if var.startswith('JULIA_') or var in ('HOME', 'USER', 'TMPDIR', 'TEMP', 'TMP',
                                           'USERPROFILE', 'APPDATA', 'LOCALAPPDATA',
                                           'SYSTEMROOT', 'SYSTEMDRIVE'):
        config.environment[var] = value
# JuliaIR's ledger is opted into per RUN line (`env JULIAIR_LEDGER=%t.ledger opt ...`)
config.environment.pop('JULIAIR_LEDGER', None)
config.environment.pop('JULIAIR_JULIA', None)

if platform.machine() in ('x86_64', 'AMD64'):
    config.available_features.add('x86_64')
elif platform.machine() in ('aarch64', 'arm64'):
    config.available_features.add('aarch64')
elif platform.machine() == 'riscv64':
    config.available_features.add('riscv64')
config.environment['JULIA_OBJCACHE'] = '0' 
