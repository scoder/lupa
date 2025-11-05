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

VERSION = '2.6'

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

def use_bundled_luau(path, macros):    
    import copy
    libname = os.path.basename(path.rstrip(os.sep))
    assert 'luau' in libname, libname
    print('Using bundled luau in %s' % libname)
    print('Building Luau for %r in %s' % (platform, libname))

    build_env = dict(os.environ)
    src_dir = path

    if not os.path.exists(os.path.join(src_dir, "build")):
        os.mkdir(os.path.join(src_dir, "build"))

    base_cflags = [
        "-fPIC", "-O0", "-DLUA_USE_LONGJMP=1", "-DLUA_VECTOR_SIZE=3", "-fno-math-errno", "-DLUAI_MAXCSTACK=8000", "-DLUA_API=extern \"C\"", "-DLUACODEGEN_API=extern \"C\"", "-DLUACODE_API=extern \"C\"",
        "-fexceptions"
    ]
    base_cxxflags = base_cflags + ["-std=c++17"]

    for lib in [
        ("Ast", "luauast"),
        ("CodeGen", "luaucodegen"),
        ("Compiler", "luaucompiler"),
        ("VM", "luauvm"),
    ]:
        if not os.path.exists(os.path.join(src_dir, "build", lib[1])):
            os.mkdir(os.path.join(src_dir, "build", lib[1]))

        # Skip if the library is already built
        static_lib_path = os.path.join(src_dir, "build", "lib" + lib[1] + ".a")
        if os.path.exists(static_lib_path):
            print("Static library %s already exists, skipping build." % static_lib_path)
            continue

        lib_src_dir = os.path.join(src_dir, lib[0], "src")
        lib_include_dir = os.path.join(src_dir, lib[0], "include")

        lib_build_env = {
            'CFLAGS': copy.copy(base_cflags),
            'CXXFLAGS': copy.copy(base_cxxflags)
        }

        common_includes = [
            os.path.join(src_dir, "Common", "include"),
        ]

        if lib[0] == "CodeGen": # Codegen needs VM includes (src of VM also includes headers needed by Codegen)
            common_includes.append(os.path.join(src_dir, "VM", "include"))
            common_includes.append(os.path.join(src_dir, "VM", "src"))
        elif lib[0] == "Compiler": # Compiler needs Ast includes
            common_includes.append(os.path.join(src_dir, "Ast", "include"))

        lib_build_env["CFLAGS"].append("-I" + lib_include_dir)
        lib_build_env["CFLAGS"].extend("-I" + inc for inc in common_includes)
        lib_build_env["CXXFLAGS"].append("-I" + lib_include_dir)
        lib_build_env["CXXFLAGS"].extend("-I" + inc for inc in common_includes)

        # Find all cpp files in the src directory
        cpp_files = []
        for root, dirs, files in os.walk(lib_src_dir):
            for file in files:
                if file.endswith(".cpp"):
                    cpp_files.append(os.path.join(root, file))
        if not cpp_files:
            raise RuntimeError("No .cpp files found in " + lib_src_dir)

        # Compile the library
        object_files = []
        for cpp_file in cpp_files:
            obj_file = os.path.splitext(os.path.basename(cpp_file))[0] + '.o'
            obj_file_path = os.path.join(src_dir, "build", lib[1], obj_file)
            compile_command = ["g++", "-c", cpp_file, "-o", obj_file_path] + lib_build_env['CXXFLAGS']
            print("Compiling %s" % cpp_file)
            output = subprocess.check_output(compile_command, cwd=lib_src_dir)
            object_files.append(obj_file_path)
        
        # Create the static library
        static_lib_path = os.path.join(src_dir, "build", "lib" + lib[1] + ".a")
        ar_command = ["ar", "rcs", static_lib_path] + object_files
        print("Creating static library %s" % static_lib_path)
        output = subprocess.check_output(ar_command, cwd=lib_src_dir)
        if b'error' in output.lower():
            print("Creating static library Luau did not report success:")
            print(output.decode().strip())
            print("## Creating static library Luau may have failed ##")
    
    # This is a bit of a hack, but luau doesnt have a lauxlib.h, so we make a new lauxlib.h
    # that merely includes lualib.h
    lauxlib_h_path = os.path.join(src_dir, "build", "lauxlib.h")
    if not os.path.exists(lauxlib_h_path):
        with open(lauxlib_h_path, 'w', encoding='us-ascii') as f:
            f.write("""
#pragma once
#include "lualib.h"
#include "luacode.h"
#include <stdbool.h>
#define USE_LUAU 1
#define LUA_VERSION_NUM 501

#define ref_freelist	0

// Polyfill for luaL_ref
// From https://github.com/lua/lua/blob/v5-2/lauxlib.c
LUALIB_API int luaL_ref (lua_State *L, int t) {
  int ref;
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);  /* remove from stack */
    return LUA_REFNIL;  /* `nil' has a unique fixed reference */
  }
  t = lua_absindex(L, t);
  lua_rawgeti(L, t, ref_freelist);  /* get first free element */
  ref = (int)lua_tointeger(L, -1);  /* ref = t[ref_freelist] */
  lua_pop(L, 1);  /* remove it from stack */
  if (ref != 0) {  /* any free element? */
    lua_rawgeti(L, t, ref);  /* remove it from list */
    lua_rawseti(L, t, ref_freelist);  /* (t[ref_freelist] = t[ref]) */
  }
  else  /* no free elements */
    ref = (int)lua_objlen(L, t) + 1;  /* get a new reference */
  lua_rawseti(L, t, ref);
  return ref;
}

// Polyfill for luaL_unref
// From https://github.com/lua/lua/blob/v5-2/lauxlib.c
LUALIB_API void luaL_unref (lua_State *L, int t, int ref) {
  if (ref >= 0) {
    t = lua_absindex(L, t);
    lua_rawgeti(L, t, ref_freelist);
    lua_rawseti(L, t, ref);  /* t[ref] = t[ref_freelist] */
    lua_pushinteger(L, ref);
    lua_rawseti(L, t, ref_freelist);  /* t[ref_freelist] = ref */
  }
}

// Define lua_pushcclosured using lua_pushcclosurek                    
LUALIB_API void lua_pushcclosured (lua_State *L, lua_CFunction fn, int n) {
    lua_pushcclosurek(L, fn, NULL, n, NULL);
}
                    
// Define lua_pushcfunctiond using lua_pushcfunction
LUALIB_API void lua_pushcfunctiond (lua_State *L, lua_CFunction fn) {
    lua_pushcfunction(L, fn, NULL);
}
                    
// Dummy implementation of lua_atpanic
LUALIB_API lua_CFunction lua_atpanic (lua_State *L, lua_CFunction panicf) {
    luaL_error(L, "lua_atpanic is not supported in Luau. Use lua_setpanicfunc instead.");
    return NULL; // never reached
}
                                        
LUALIB_API void lua_setpanicfunc (lua_State *L, void (*panic)(lua_State* L, int errcode)) {
    lua_callbacks(L)->panic = panic;
}
                    
// Define luaL_errord as luaL_error with return of int
LUALIB_API int luaL_errord (lua_State *L, const char *fmt, ...) {
    va_list argp;
    va_start(argp, fmt);
    luaL_error(L, fmt, argp);
    va_end(argp);
    return 0; // never reached
}
                    
// Define lua_errord as lua_error with return of int
LUALIB_API int lua_errord (lua_State *L) {
    lua_error(L);
    return 0; // never reached
}

// Define luaL_argerrord as luaL_argerror with return of int
LUALIB_API int luaL_argerrord (lua_State *L, int arg, const char *extramsg) {
    luaL_argerror(L, arg, extramsg);
    return 0; // never reached
}
                    
// Polyfill for lua_getstack via lua_getinfo on Luau
// May not be fully correct but should be the Luau equivalent
#define lua_getstack(L, level, ar) lua_getinfo(L, level, "", ar)

// Compile with luau_compile
// TODO: Compile using lupa's memory allocator
// and support luau env parameter
void chunk_dtor(void *ud) {
    if(ud == NULL) {
        return;
    }
    char* data_to_free = *(char**)ud;
    if(data_to_free == NULL) {
        return;
    }
    free(data_to_free); // This will always be called even on error etc.
}

// Polyfill for luaL_loadbuffer
// Luau doesnt provide either luaL_loadbuffer or luaL_loadbufferx etc.
LUALIB_API int luaL_loadbuffer (lua_State *L, const char *buffer, size_t size, const char *name) {
    bool textChunk = (size == 0 || buffer[0] >= '\t');
    if (textChunk) {
        void* ud = lua_newuserdatadtor(L, sizeof(char*), chunk_dtor);
        size_t outsize = 0;
        char* data = luau_compile(buffer, size, NULL, &outsize);
        // ptr::write(data_ud, data);
        *(char**)ud = data; // Now, the dtor will always free this 
        int status = luau_load(L, name, data, outsize, 0); // TODO: Support env parameter for optimized chunk environment loading
        lua_replace(L, -2); // Replace the userdata with the result
        return status;
    } else {
        // Binary chunk, load with luau_load
        return luau_load(L, name, buffer, size, 0); // TODO:
    }
}
""")

    return {
        'include_dirs': [
            os.path.join(src_dir, "Common", "include"),
            os.path.join(src_dir, "Ast", "include"), 
            os.path.join(src_dir, "CodeGen", "include"), 
            os.path.join(src_dir, "Compiler", "include"), 
            os.path.join(src_dir, "VM", "include"),
            os.path.join(src_dir, "VM", "src"),
            os.path.join(src_dir, "build"),
        ],
        'extra_objects': [
            os.path.join(src_dir, "build", "libluaucompiler.a"), 
            os.path.join(src_dir, "build", "libluaucodegen.a"), 
            os.path.join(src_dir, "build", "libluauast.a"), 
            os.path.join(src_dir, "build", "libluauvm.a")],
        'libversion': libname,
    }

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
    elif 'luau' in libname:
        return use_bundled_luau(path, macros)

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
    for i, arg in enumerate(sys.argv[1:], 1):
        if arg.startswith(name):
            arg = sys.argv.pop(i)
            if '=' in arg:
                return arg.split('=', 1)[1]
            return sys.argv.pop(i)
    return ""


def has_option(name):
    if name in sys.argv[1:]:
        sys.argv.remove(name)
        return True
    envvar_name = 'LUPA_' + name.lstrip('-').upper().replace('-', '_')
    return os.environ.get(envvar_name) == 'true'


def check_limited_api_option(name):
    def handle_arg(arg: str):
        arg = arg.lower()
        if arg == "true":
            # The default Limited API version is 3.9, unless we're on a lower Python version
            # (which is mainly for the sake of testing 3.8 on the CI)
            if sys.version_info >= (3, 9):
                return (3, 9)
            else:
                return sys.version_info[:2]
        if arg == "false":
            return None
        major, minor = arg.split('.', 1)
        return (int(major), int(minor))

    value = get_option(name)
    if value:
        return handle_arg(value)

    env_var_name = 'LUPA_' + name.lstrip('-').upper().replace("-", "_")
    env_var = os.environ.get(env_var_name)
    if env_var is None:
        return None
    return handle_arg(env_var)


c_defines = [
    ('CYTHON_CLINE_IN_TRACEBACK', '0'),
]
if has_option('--without-assert'):
    c_defines.append(('CYTHON_WITHOUT_ASSERTIONS', None))
if has_option('--with-lua-checks'):
    c_defines.append(('LUA_USE_APICHECK', None))
if has_option('--with-lua-dlopen'):
    c_defines.append(('LUA_USE_DLOPEN', None))

option_limited_api = check_limited_api_option('--limited-api')
if option_limited_api:
    c_defines.append(('Py_LIMITED_API', f'0x{option_limited_api[0]:02x}{option_limited_api[1]:02x}0000'))

# find Lua
option_no_bundle = has_option('--no-bundle')
option_use_bundle = has_option('--use-bundle')
option_no_luajit = has_option('--no-luajit')
option_use_luau = has_option('--use-luau')
if option_use_luau and option_no_bundle:
    print("Cannot use --use-luau together with --no-bundle")
    sys.exit(1)

configs = get_lua_build_from_arguments()
if not configs and not option_no_bundle:
    if option_use_luau:
        configs = [
            use_bundled_luau(lua_bundle_path, c_defines)
            for lua_bundle_path in glob.glob(os.path.join(basedir, 'third-party', 'luau*' + os.sep))
        ]
    else:
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
            libraries=['stdc++'] if option_use_luau else [],
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
