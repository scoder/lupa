
import sys
import os
from distutils.core import setup, Extension

VERSION = '0.20'

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

class PkgConfigError(RuntimeError):
    pass

def try_int(s):
    try:
        return int(s)
    except ValueError:
        return s

# check if LuaJIT is in a subdirectory and build statically against it
def cmd_output(command):
    """
    Returns the exit code and output of the program, as a triplet of the form
    (exit_code, stdout, stderr).
    """
    import subprocess
    proc = subprocess.Popen(command,
                            shell=True,
                            stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE)
    stdout, stderr = proc.communicate()
    exit_code = proc.wait()
    if exit_code != 0:
        raise PkgConfigError(stderr)
    return stdout

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

    lua_version = cmd_output('pkg-config %s --modversion' % package)
    try:
        if map(try_int, lua_version.split('.')) < map(try_int, min_version.split('.')):
            raise PkgConfigError("Expected version %s+ of %s, but found %s" %
                                 (min_version, package, lua_versionlj_version))
    except (ValueError, TypeError):
        print("failed to parse version '%s' of installed %s package, minimum is %s" % (
            lua_version, package, min_version))
    else:
        print("pkg-config found %s version %s" % (package, lua_version))

def lua_include(package='luajit'):
    cflag_out = cmd_output('pkg-config %s --cflags-only-I' % package)

    def trim_i(s):
        if s.startswith('-I'):
            return s[2:]
        return s
    return map(trim_i, filter(None, cflag_out.split()))

def lua_libs(package='luajit'):
    libs_out = cmd_output('pkg-config %s --libs' % package)
    return filter(None, libs_out.split())

basedir = os.path.abspath(os.path.dirname(__file__))

def find_lua_build(no_luajit=False):
    # try to find local LuaJIT2 build
    os_path = os.path
    for filename in os.listdir(basedir):
        if filename.lower().startswith('luajit'):
            filepath = os_path.join(basedir, filename, 'src')
            if os_path.isdir(filepath):
                libfile = os_path.join(filepath, 'libluajit.a')
                if os_path.isfile(libfile):
                    print("found LuaJIT build in %s" % filepath)
                    print("building statically")
                    return dict(extra_objects=[libfile], include_dirs=[filepath])
    print("No local build of LuaJIT2 found in lupa directory")

    # try to find installed LuaJIT2 or Lua
    if no_luajit:
        packages = []
    else:
        packages = [('luajit', '2')]
    packages += [(name, '5.1') for name in ('lua5.1', 'lua-5.1', 'lua')]

    for package_name, min_version in packages:
        print("Checking for installed %s library using pkg-config" % package_name)
        try:
            check_lua_installed(package_name, min_version)
            return dict(extra_objects=lua_libs(package_name), include_dirs=lua_include(package_name))
        except RuntimeError:
            print("Did not find %s using pkg-config: %s" % (package_name, sys.exc_info()[1]))

    error = ("Neither LuaJIT2 nor Lua 5.1 were found, please install the library and its development packages"
             ", or put a local build into the lupa main directory")
    if no_luajit:
        print(error)
    else:
        raise RuntimeError(error+" (or pass '--no-luajit' option)")
    return {}

def has_option(name):
    if name in sys.argv[1:]:
        sys.argv.remove(name)
        return True
    return False

ext_args = find_lua_build(no_luajit=has_option('--no-luajit'))
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
    for text_file in ['README.rst', 'INSTALL.rst', 'CHANGES.rst']])

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
    url = "https://github.com/scoder/lupa",
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
