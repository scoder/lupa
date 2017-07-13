from __future__ import absolute_import, print_function

import sys
import os.path

try:
    # use setuptools if available
    from setuptools import setup, Extension
except ImportError:
    from distutils.core import setup, Extension

VERSION = '1.4'

basedir = os.path.abspath(os.path.dirname(__file__))

extra_setup_args = {}


# support 'test' target if setuptools/distribute is available

if 'setuptools' in sys.modules:
    extra_setup_args['test_suite'] = 'lupa.tests.suite'


def has_option(name):
    if name in sys.argv[1:]:
        sys.argv.remove(name)
        return True
    return False

use_cython = has_option('--with-cython')
if not use_cython:
    if not os.path.exists(os.path.join(os.path.dirname(__file__), 'lupa', '_lupa.c')):
        use_cython = True

cythonize = None
source_extension = ".c"
if use_cython:
    try:
        import Cython.Compiler.Version
        from Cython.Build import cythonize
        source_extension = ".pyx"
    except ImportError:
        print("WARNING: trying to build with Cython, but it is not installed", file = sys.stderr)

ext_modules = [
    Extension(
        'lupa._lupa',
        sources = ['lupa/_lupa'+source_extension] + ['third-party/lua/lapi.c', 'third-party/lua/lcode.c', 'third-party/lua/lctype.c', 'third-party/lua/ldebug.c', 'third-party/lua/ldo.c', 'third-party/lua/ldump.c', 'third-party/lua/lfunc.c', 'third-party/lua/lgc.c', 'third-party/lua/llex.c', 'third-party/lua/lmem.c', 'third-party/lua/lobject.c', 'third-party/lua/lopcodes.c', 'third-party/lua/lparser.c', 'third-party/lua/lstate.c', 'third-party/lua/lstring.c', 'third-party/lua/ltable.c', 'third-party/lua/ltm.c', 'third-party/lua/lundump.c', 'third-party/lua/lvm.c', 'third-party/lua/lzio.c', 'third-party/lua/ltests.c', 'third-party/lua/lauxlib.c', 'third-party/lua/lbaselib.c', 'third-party/lua/ldblib.c', 'third-party/lua/liolib.c', 'third-party/lua/lmathlib.c', 'third-party/lua/loslib.c', 'third-party/lua/ltablib.c', 'third-party/lua/lstrlib.c', 'third-party/lua/lutf8lib.c', 'third-party/lua/lbitlib.c', 'third-party/lua/loadlib.c', 'third-party/lua/lcorolib.c', 'third-party/lua/linit.c'],
        include_dirs = ['third-party/lua']
    )]

if cythonize is not None:
    ext_modules = cythonize(ext_modules)


def read_file(filename):
    with open(os.path.join(basedir, filename)) as f:
        return f.read()


def write_file(filename, content):
    with open(os.path.join(basedir, filename), 'w') as f:
        f.write(content)


long_description = '\n\n'.join([
    read_file(text_file)
    for text_file in ['README.rst', 'INSTALL.rst', 'CHANGES.rst']])

write_file(os.path.join('lupa', 'version.py'), "__version__ = '%s'\n" % VERSION)


# call distutils

setup(
    name="lupa",
    version=VERSION,
    author="Stefan Behnel",
    author_email="stefan_ml@behnel.de",
    maintainer="Lupa-dev mailing list",
    maintainer_email="lupa-dev@freelists.org",
    url="https://github.com/scoder/lupa",

    description="Python wrapper around Lua and LuaJIT",

    long_description=long_description,
    license='MIT style',
    classifiers=[
        'Development Status :: 5 - Production/Stable',
        'Intended Audience :: Developers',
        'Intended Audience :: Information Technology',
        'License :: OSI Approved :: MIT License',
        'Programming Language :: Cython',
        'Programming Language :: Python :: 2',
        'Programming Language :: Python :: 2.6',
        'Programming Language :: Python :: 2.7',
        'Programming Language :: Python :: 3',
        'Programming Language :: Python :: 3.2',
        'Programming Language :: Python :: 3.3',
        'Programming Language :: Python :: 3.4',
        'Programming Language :: Python :: 3.5',
        'Programming Language :: Other Scripting Engines',
        'Operating System :: OS Independent',
        'Topic :: Software Development',
    ],

    packages=['lupa'],
    ext_modules=ext_modules,
    **extra_setup_args
)
