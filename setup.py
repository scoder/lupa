from __future__ import absolute_import

import glob
import os
import os.path
import re
import shutil
import subprocess
import sys

from glob import iglob
from io import open as io_open
from sys import platform
from platform import machine as get_machine

try:
    # use setuptools if available
    from setuptools import setup, Extension
except ImportError:
    from distutils.core import setup, Extension

VERSION = '2.4'

extra_setup_args = {}

basedir = os.path.abspath(os.path.dirname(__file__))


# support 'test' target if setuptools/distribute is available

if 'setuptools' in sys.modules:
    extra_setup_args['test_suite'] = 'lupa.tests.suite'


class PkgConfigError(RuntimeError):
    pass


def dev_status(version):
    if 'b' in version or 'c' in version:
        # 1b1, 1beta1, 2rc1, ...
        return 'Development Status :: 4 - Beta'
    elif 'a' in version:
        # 1a1, 1alpha1, ...
        return 'Development Status :: 3 - Alpha'
    else:
        return 'Development Status :: 5 - Production/Stable'


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


def get_lua_build_from_arguments():
    lua_lib = get_option('--lua-lib')
    lua_includes = get_option('--lua-includes')

    if not lua_lib or not lua_includes:
        return []

    print('Using Lua library: %s' % lua_lib)
    print('Using Lua include directory: %s' % lua_includes)

    root, ext = os.path.splitext(lua_lib)
    if os.name == 'nt' and ext == '.lib':
        return [
            dict(extra_objects=[lua_lib],
                 include_dirs=[lua_includes],
                 libfile=lua_lib)
        ]
    else:
        return [
            dict(extra_objects=[lua_lib],
                 include_dirs=[lua_includes])
        ]


def find_lua_build(no_luajit=False):
    # try to find local LuaJIT2 build
    for filename in os.listdir(basedir):
        if not filename.lower().startswith('luajit'):
            continue
        filepath = os.path.join(basedir, filename, 'src')
        if not os.path.isdir(filepath):
            continue
        libfile = os.path.join(filepath, 'libluajit.a')
        if os.path.isfile(libfile):
            print("found LuaJIT build in %s" % filepath)
            print("building statically")
            return dict(extra_objects=[libfile],
                        include_dirs=[filepath])
        # also check for lua51.lib, the Windows equivalent of libluajit.a
        for libfile in iglob(os.path.join(filepath, 'lua5?.lib')):
            if os.path.isfile(libfile):
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
        for lua_version in ('5.4', '5.3', '5.2', '5.1')
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
    error = ("Neither LuaJIT2 nor Lua 5.[1234] were found. Please install "
             "Lua and its development packages, "
             "or put a local build into the lupa main directory.")
    print(error)
    return {}


def use_bundled_luajit(path, macros):
    libname = os.path.basename(path.rstrip(os.sep))
    assert 'luajit' in libname, libname
    print('Using bundled LuaJIT in %s' % libname)
    print('Building LuaJIT for %r in %s' % (platform, libname))

    build_env = dict(os.environ)
    src_dir = os.path.join(path, "src")
    if platform.startswith('win'):
        build_script = [os.path.join(src_dir, "msvcbuild.bat"), "static"]
        lib_file = "lua51.lib"
    else:
        build_script = ["make",  "libluajit.a"]
        lib_file = "libluajit.a"

        if 'CFLAGS' in build_env:
            if "-fPIC" not in build_env['CFLAGS']:
                build_env['CFLAGS'] += " -fPIC"
        else:
            build_env['CFLAGS'] = "-fPIC"

    output = subprocess.check_output(build_script, cwd=src_dir, env=build_env)
    if lib_file.encode("ascii") not in output:
        print("Building LuaJIT did not report success:")
        print(output.decode().strip())
        print("## Building LuaJIT may have failed ##")

    return {
        'include_dirs': [src_dir],
        'extra_objects': [os.path.join(src_dir, lib_file)],
        'libversion': libname,
    }


def use_bundled_lua(path, macros):
    libname = os.path.basename(path.rstrip(os.sep))
    if 'luajit' in libname:
        return use_bundled_luajit(path, macros)

    print('Using bundled Lua in %s' % libname)

    # Find Makefile in subrepos and downloaded sources.
    for makefile_path in [os.path.join("src", "makefile"), os.path.join("src", "Makefile"), "makefile", "Makefile"]:
        makefile = os.path.join(path, makefile_path)
        if os.path.exists(makefile):
            break
    else:
        raise RuntimeError("Makefile not found in " + path)

    # Parse .o files from Makefile
    match_var = re.compile(r"(CORE|AUX|LIB|ALL)_O\s*=(.*)").match
    is_indented = re.compile(r"\s+").match
    obj_files = []
    continuing = False
    with open(makefile) as f:
        lines = iter(f)
        for line in lines:
            if '#' in line:
                line = line.partition("#")[0]
            line = line.rstrip()
            if not line:
                continue
            match = match_var(line)
            if match:
                if match.group(1) == 'ALL':
                    break  # by now, we should have seen all that we needed
                obj_files.extend(match.group(2).rstrip('\\').split())
                continuing = line.endswith('\\')
            elif continuing and is_indented(line):
                obj_files.extend(line.rstrip('\\').split())
                continuing = line.endswith('\\')

    # Safety check, prevent Makefile variables from appearing in the sources list.
    obj_files = [
        obj_file for obj_file in obj_files
        if not obj_file.startswith('$')
    ]
    for obj_file in obj_files:
        if '$' in obj_file:
            raise RuntimeError("Makefile of %s has unexpected format, found '%s'" % (
                libname, obj_file))

    lua_sources = [
        os.path.splitext(obj_file)[0] + '.c' if obj_file != 'lj_vm.o' else 'lj_vm.s'
        for obj_file in obj_files
    ]
    if libname == 'lua52':
        lua_sources.extend(['lbitlib.c', 'lcorolib.c', 'lctype.c'])
    src_dir = os.path.dirname(makefile)
    ext_libraries = [
        [libname, {
            'sources': [os.path.join(src_dir, src) for src in lua_sources],
            'include_dirs': [src_dir],
            'macros': macros,
        }]
    ]
    return {
        'include_dirs': [src_dir],
        'ext_libraries': ext_libraries,
        'libversion': libname,
    }


def get_option(name):
    for i, arg in enumerate(sys.argv[1:-1], 1):
        if arg == name:
            sys.argv.pop(i)
            return sys.argv.pop(i)
    return ""


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
if has_option('--with-lua-dlopen'):
    c_defines.append(('LUA_USE_DLOPEN', None))


# find Lua
option_no_bundle = has_option('--no-bundle')
option_use_bundle = has_option('--use-bundle')
option_no_luajit = has_option('--no-luajit')

configs = get_lua_build_from_arguments()
if not configs and not option_no_bundle:
    configs = [
        use_bundled_lua(lua_bundle_path, c_defines)
        for lua_bundle_path in glob.glob(os.path.join(basedir, 'third-party', 'lua*' + os.sep))
        if not (
            False
            # LuaJIT 2.0 on macOS requires a CPython linked with "-pagezero_size 10000 -image_base 100000000"
            # http://t-p-j.blogspot.com/2010/11/lupa-on-os-x-with-macports-python-26.html
            # LuaJIT 2.1-alpha3 fails at runtime.
            or (platform == 'darwin' and 'luajit' in os.path.basename(lua_bundle_path.rstrip(os.sep)))
            # Let's restrict LuaJIT to x86_64 for now.
            or (get_machine() not in ("x86_64", "AMD64") and 'luajit' in os.path.basename(lua_bundle_path.rstrip(os.sep)))
        )
    ]
if not configs:
    configs = [
        (find_lua_build(no_luajit=option_no_luajit) if not option_use_bundle else {})
        or no_lua_error()
    ]


# check if Cython is installed, and use it if requested or necessary
def prepare_extensions(use_cython=True):
    ext_modules = []
    ext_libraries = []
    for config in configs:
        ext_name = config.get('libversion', 'lua')
        src, dst = os.path.join('lupa', '_lupa.pyx'), os.path.join('lupa', ext_name + '.pyx')
        if not os.path.exists(dst) or os.path.getmtime(dst) < os.path.getmtime(src):
            with open(dst, 'wb') as f_out:
                f_out.write(b'#######  DO NOT EDIT - BUILD TIME COPY OF "_lupa.pyx" #######\n\n')
                with open(src, 'rb') as f_in:
                    shutil.copyfileobj(f_in, f_out)

        libs = config.get('ext_libraries')
        ext_modules.append(Extension(
            'lupa.' + ext_name,
            sources=[dst] + (libs[0][1]['sources'] if libs else []),
            extra_objects=config.get('extra_objects'),
            include_dirs=config.get('include_dirs'),
            define_macros=c_defines,
        ))

        if not use_cython:
            if not os.path.exists(os.path.join(basedir, 'lupa', '_lupa.c')):
                print("generated sources not available, need Cython to build")
                use_cython = True

    cythonize = None
    if use_cython:
        try:
            import Cython.Compiler.Version
            import Cython.Compiler.Errors as CythonErrors
            from Cython.Build import cythonize
            print("building with Cython " + Cython.Compiler.Version.version)
            CythonErrors.LEVEL = 0
        except ImportError:
            print("WARNING: trying to build with Cython, but it is not installed")
    else:
        print("building without Cython")

    if cythonize is not None:
        ext_modules = cythonize(ext_modules)

    return ext_modules, ext_libraries


ext_modules, ext_libraries = prepare_extensions(use_cython=has_option('--with-cython'))


def read_file(filename):
    with io_open(os.path.join(basedir, filename), encoding="utf8") as f:
        return f.read()


def write_file(filename, content):
    with io_open(os.path.join(basedir, filename), 'w', encoding='us-ascii') as f:
        f.write(content)


long_description = '\n\n'.join([
    read_file(os.path.join(basedir, text_file))
    for text_file in ['README.rst', 'INSTALL.rst', 'CHANGES.rst', "LICENSE.txt"]])

write_file(os.path.join(basedir, 'lupa', 'version.py'), u"__version__ = '%s'\n" % VERSION)

dll_files = []
for config in configs:
    if config.get('libfile'):
        # include Lua DLL in the lib folder if we are on Windows
        dll_file = os.path.splitext(config['libfile'])[0] + ".dll"
        shutil.copy(dll_file, os.path.join(basedir, 'lupa'))
        dll_files.append(os.path.basename(dll_file))

if dll_files:
    extra_setup_args['package_data'] = {'lupa': dll_files}

cython_dependency = ([
    line for line in read_file(os.path.join(basedir, "requirements.txt")).splitlines()
    if 'Cython' in line
] + ["Cython"])[0]

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
        dev_status(VERSION),
        'Intended Audience :: Developers',
        'Intended Audience :: Information Technology',
        'License :: OSI Approved :: MIT License',
        'Programming Language :: Cython',
        'Programming Language :: Python :: 3',
        'Programming Language :: Lua',
        'Programming Language :: Other Scripting Engines',
        'Operating System :: OS Independent',
        'Topic :: Software Development',
    ],

    packages=['lupa'],
    setup_requires=[cython_dependency],
    ext_modules=ext_modules,
    libraries=ext_libraries,
    **extra_setup_args
)
