from __future__ import absolute_import

import sys
import shutil
import os
import os.path

from glob import iglob
from io import open

try:
    # use setuptools if available
    from setuptools import setup, Extension
except ImportError:
    from distutils.core import setup, Extension

VERSION = '1.9'

extra_setup_args = {}


# support 'test' target if setuptools/distribute is available

if 'setuptools' in sys.modules:
    extra_setup_args['test_suite'] = 'lupa.tests.suite'
    extra_setup_args["zip_safe"] = False


class PkgConfigError(RuntimeError):
    pass


def try_int(s):
    try:
        return int(s)
    except ValueError:
        return s


def cmd_output(command):
    """
    Returns the exit code and output of the program, as a triplet of the form
    (exit_code, stdout, stderr).
    """
    env = os.environ.copy()
    env['LANG'] = ''
    import subprocess
    proc = subprocess.Popen(command,
                            shell=True,
                            stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE,
                            env=env)
    stdout, stderr = proc.communicate()
    exit_code = proc.wait()
    if exit_code != 0:
        raise PkgConfigError(stderr.decode('ISO8859-1'))
    return stdout


def decode_path_output(s):
    if sys.version_info[0] < 3:
        return s  # no need to decode, and safer not to do it
    # we don't really know in which encoding pkgconfig
    # outputs its results, so we try to guess
    for encoding in (sys.getfilesystemencoding(),
                     sys.getdefaultencoding(),
                     'utf8'):
        try:
            return s.decode(encoding)
        except UnicodeDecodeError: pass
    return s.decode('iso8859-1')


# try to find LuaJIT installation using pkgconfig

def check_lua_installed(package='luajit', min_version='2'):
    try:
        cmd_output('pkg-config %s --exists' % package)
    except RuntimeError:
        # pkg-config gives no stdout when it is given --exists and it cannot
        # find the package, so we'll give it some better output
        error = sys.exc_info()[1]
        if not error.args[0]:
            raise RuntimeError("pkg-config cannot find an installed %s" % package)
        raise

    lua_version = cmd_output('pkg-config %s --modversion' % package).decode('iso8859-1')
    try:
        if tuple(map(try_int, lua_version.split('.'))) < tuple(map(try_int, min_version.split('.'))):
            raise PkgConfigError("Expected version %s+ of %s, but found %s" %
                                 (min_version, package, lua_version))
    except (ValueError, TypeError):
        print("failed to parse version '%s' of installed %s package, minimum is %s" % (
            lua_version, package, min_version))
    else:
        print("pkg-config found %s version %s" % (package, lua_version))


def lua_include(package='luajit'):
    cflag_out = cmd_output('pkg-config %s --cflags-only-I' % package)
    cflag_out = decode_path_output(cflag_out)

    def trim_i(s):
        if s.startswith('-I'):
            return s[2:]
        return s
    return list(map(trim_i, cflag_out.split()))


def lua_libs(package='luajit'):
    libs_out = cmd_output('pkg-config %s --libs' % package)
    libs_out = decode_path_output(libs_out)
    return libs_out.split()


basedir = os.path.abspath(os.path.dirname(__file__))


def find_lua_build(no_luajit=False):
    # try to find local LuaJIT2 build
    os_path = os.path
    for filename in os.listdir(basedir):
        if not filename.lower().startswith('luajit'):
            continue
        filepath = os_path.join(basedir, filename, 'src')
        if not os_path.isdir(filepath):
            continue
        libfile = os_path.join(filepath, 'libluajit.a')
        if os_path.isfile(libfile):
            print("found LuaJIT build in %s" % filepath)
            print("building statically")
            return dict(extra_objects=[libfile],
                        include_dirs=[filepath])
        # also check for lua51.lib, the Windows equivalent of libluajit.a
        for libfile in iglob(os_path.join(filepath, 'lua5?.lib')):
            if os_path.isfile(libfile):
                print("found LuaJIT build in %s (%s)" % (
                    filepath, os.path.basename(libfile)))
                print("building statically")
                # And return the dll file name too, as we need to
                # include it in the install directory
                return dict(extra_objects=[libfile],
                            include_dirs=[filepath],
                            libfile=libfile)
    print("No local build of LuaJIT2 found in lupa directory")

    # try to find installed LuaJIT2 or Lua
    if no_luajit:
        packages = []
    else:
        packages = [('luajit', '2')]
    packages += [
        (name, lua_version)
        for lua_version in ('5.3', '5.2', '5.1')
        for name in (
            'lua%s' % lua_version,
            'lua-%s' % lua_version,
            'lua%s' % lua_version.replace(".", ""),
            'lua',
        )
    ]

    for package_name, min_version in packages:
        print("Checking for installed %s library using pkg-config" %
            package_name)
        try:
            check_lua_installed(package_name, min_version)
            return dict(extra_objects=lua_libs(package_name),
                        include_dirs=lua_include(package_name))
        except RuntimeError:
            print("Did not find %s using pkg-config: %s" % (
                package_name, sys.exc_info()[1]))

    return {}


def no_lua_error():
    error = ("Neither LuaJIT2 nor Lua 5.[123] were found. Please install "
             "Lua and its development packages, "
             "or put a local build into the lupa main directory.")
    print(error)
    return {}


def use_bundled_lua(path, lua_sources, macros):
    print('Using bundled Lua')
    ext_libraries = [
        ['lua', {
            'sources': [path + src for src in lua_sources],
            'include_dirs': [path],
            'macros': macros,
        }]
    ]
    return {
        'include_dirs': [path],
        'ext_libraries': ext_libraries,
    }


def has_option(name):
    if name in sys.argv[1:]:
        sys.argv.remove(name)
        return True
    envvar_name = 'LUPA_' + name.lstrip('-').upper().replace('-', '_')
    return os.environ.get(envvar_name) == 'true'


c_defines = [
    ('CYTHON_CLINE_IN_TRACEBACK', 0),
]
if has_option('--without-assert'):
    c_defines.append(('CYTHON_WITHOUT_ASSERTIONS', None))
if has_option('--with-lua-checks'):
    c_defines.append(('LUA_USE_APICHECK', None))


# bundled lua
lua_bundle_path = 'third-party/lua/'
lua_sources = [
    'lapi.c',
    'lcode.c',
    'lctype.c',
    'ldebug.c',
    'ldo.c',
    'ldump.c',
    'lfunc.c',
    'lgc.c',
    'llex.c',
    'lmem.c',
    'lobject.c',
    'lopcodes.c',
    'lparser.c',
    'lstate.c',
    'lstring.c',
    'ltable.c',
    'ltm.c',
    'lundump.c',
    'lvm.c',
    'lzio.c',
    'ltests.c',
    'lauxlib.c',
    'lbaselib.c',
    'ldblib.c',
    'liolib.c',
    'lmathlib.c',
    'loslib.c',
    'ltablib.c',
    'lstrlib.c',
    'lutf8lib.c',
    'loadlib.c',
    'lcorolib.c',
    'linit.c',
]


config = None
if not has_option('--use-bundle'):
    config = find_lua_build(no_luajit=has_option('--no-luajit'))
if not config and not has_option('--no-bundle'):
    config = use_bundled_lua(lua_bundle_path, lua_sources, c_defines)
if not config:
    config = no_lua_error()

ext_args = {
    'extra_objects': config.get('extra_objects'),
    'include_dirs': config.get('include_dirs'),
    'define_macros': c_defines,
}


# check if Cython is installed, and use it if requested or necessary
use_cython = has_option('--with-cython')
if not use_cython:
    if not os.path.exists(os.path.join(os.path.dirname(__file__), 'lupa', '_lupa.c')):
        print("generated sources not available, need Cython to build")
        use_cython = True

cythonize = None
source_extension = ".c"
if use_cython:
    try:
        import Cython.Compiler.Version
        from Cython.Build import cythonize
        print("building with Cython " + Cython.Compiler.Version.version)
        source_extension = ".pyx"
    except ImportError:
        print("WARNING: trying to build with Cython, but it is not installed")
else:
    print("building without Cython")

ext_modules = [
    Extension(
        'lupa._lupa',
        sources = ['lupa/_lupa'+source_extension],
        **ext_args
    )]

if cythonize is not None:
    ext_modules = cythonize(ext_modules)


def read_file(filename):
    with open(os.path.join(basedir, filename), encoding="utf8") as f:
        return f.read()


def write_file(filename, content):
    with open(os.path.join(basedir, filename), 'w', encoding='us-ascii') as f:
        f.write(content)


long_description = '\n\n'.join([
    read_file(text_file)
    for text_file in ['README.rst', 'INSTALL.rst', 'CHANGES.rst', "LICENSE.txt"]])

write_file(os.path.join('lupa', 'version.py'), u"__version__ = '%s'\n" % VERSION)

if config.get('libfile'):
    # include lua51.dll in the lib folder if we are on windows
    dllfile = os.path.splitext(config['libfile'])[0] + ".dll"
    shutil.copy(dllfile, os.path.join(basedir, 'lupa'))
    extra_setup_args['package_data'] = {'lupa': [os.path.basename(dllfile)]}


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
        'Programming Language :: Python :: 2.7',
        'Programming Language :: Python :: 3',
        'Programming Language :: Python :: 3.5',
        'Programming Language :: Python :: 3.6',
        'Programming Language :: Python :: 3.7',
        'Programming Language :: Python :: 3.8',
        'Programming Language :: Other Scripting Engines',
        'Operating System :: OS Independent',
        'Topic :: Software Development',
    ],

    packages=['lupa'],
    ext_modules=ext_modules,
    libraries=config.get('ext_libraries'),
    **extra_setup_args
)
