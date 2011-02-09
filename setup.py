
import subprocess
import sys
import os
from distutils.core import setup, Extension

VERSION = '0.19'

extra_setup_args = {}

# check if Cython is installed, and use it if available
try:
    from Cython.Distutils import build_ext
    import Cython.Compiler.Version
    print("building with Cython " + Cython.Compiler.Version.version)
    extra_setup_args['cmdclass'] = {'build_ext': build_ext}
    source_extension = ".pyx"
except ImportError:
    print("building without Cython")
    source_extension = ".c"

# support 'test' target if setuptools/distribute is available

if 'setuptools' in sys.modules:
    extra_setup_args['test_suite'] = 'lupa.tests.suite'
    extra_setup_args["zip_safe"] = False

# check if LuaJIT is in a subdirectory and build statically against it
def cmd_status_output(command):
    """Returns the exit code and output of the program, as a tuple"""
    proc = subprocess.Popen(command, shell=True, stdout=subprocess.PIPE)
    buff = []
    while proc.poll() is None:
        buff.append(proc.stdout.read())

    exit_code = proc.wait()
    buff.append(proc.stdout.read())
    print 'returning', (exit_code, ''.join(buff))
    return (exit_code, ''.join(buff))

def luajit2_installed():
    if (cmd_status_output('pkg-config luajit --exists')[0] == 0) and \
          (cmd_status_output('pkg-config luajit --modversion')[1][0] == '2'):
        return True
    return False

def lua_include():
    line = cmd_status_output('pkg-config luajit --cflags-only-I')[1]
    def trim_i(s):
        if s.startswith('-I'):
            return s[2:]
        return s
    return map(trim_i, filter(None, line.split()))

def lua_libs():
    line = cmd_status_output('pkg-config luajit --libs')[1]
    return filter(None, line.split())

basedir = os.path.abspath(os.path.dirname(__file__))

def find_luajit_build():
    if luajit2_installed():
        return dict(extra_objects=lua_libs(), include_dirs=lua_include())

    static_libs = []
    include_dirs = []

    os_path = os.path
    for filename in os.listdir(basedir):
        if filename.lower().startswith('luajit'):
            filepath = os_path.join(basedir, filename, 'src')
            if os_path.isdir(filepath):
                libfile = os_path.join(filepath, 'libluajit.a')
                if os_path.isfile(libfile):
                    static_libs = [libfile]
                    include_dirs = [filepath]
                    print("found LuaJIT build in %s" % filepath)
                    print("building statically")
    return dict(extra_objects=static_libs, include_dirs=include_dirs)

def has_option(name):
    if name in sys.argv[1:]:
        sys.argv.remove(name)
        return True
    return False

ext_args = find_luajit_build()
if has_option('--without-assert'):
    ext_args['define_macros'] = [('PYREX_WITHOUT_ASSERTIONS', None)]

ext_modules = [
    Extension(
        'lupa._lupa',
        sources = ['lupa/_lupa'+source_extension] + (
            source_extension == '.pyx' and ['lupa/lock.pxi'] or []),
        **ext_args
        )
    ]

def read_file(filename):
    f = open(os.path.join(basedir, filename))
    try:
        return f.read()
    finally:
        f.close()

def write_file(filename, content):
    f = open(os.path.join(basedir, filename), 'w')
    try:
        f.write(content)
    finally:
        f.close()

long_description = '\n\n'.join([
    read_file(text_file)
    for text_file in ['README.rst', 'INSTALL.txt', 'CHANGES.txt']])

write_file(os.path.join('lupa', 'version.py'), "__version__ = '%s'\n" % VERSION)

if sys.version_info >= (2,6):
    extra_setup_args['license'] = 'MIT style'

# call distutils

setup(
    name = "lupa",
    version = VERSION,
    author = "Stefan Behnel",
    author_email = "stefan_ml@behnel.de",
    maintainer = "Lupa-dev mailing list",
    maintainer_email = "lupa-dev@freelists.org",
    url = "http://pypi.python.org/pypi/lupa",
    download_url = "http://pypi.python.org/packages/source/l/lupa/lupa-%s.tar.gz" % VERSION,

    description="Python wrapper around LuaJIT",

    long_description = long_description,
    classifiers = [
        'Development Status :: 4 - Beta',
        'Intended Audience :: Developers',
        'Intended Audience :: Information Technology',
        'License :: OSI Approved :: MIT License',
        'Programming Language :: Cython',
        'Programming Language :: Python :: 2',
        'Programming Language :: Python :: 3',
        'Programming Language :: Other Scripting Engines',
        'Operating System :: OS Independent',
        'Topic :: Software Development',
    ],

    packages = ['lupa'],
#    package_data = {},
    ext_modules = ext_modules,
    **extra_setup_args
)
