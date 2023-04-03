import os
import sys
from pathlib import Path


cdef extern from "Python.h":
    object PyLong_FromVoidPtr(void *p)


runtime = None


def _lua_eval_intern(code, *args):
    # In this scope LuaRuntime returns tuple of (<module_name>, <dll_path>, <return_val>)
    return runtime.eval(code, *args)[2]

    
cdef public int initialize_lua_runtime(void* L):
    global runtime

    # Convert pointer to Python object to make possible pass it into LuaRuntime constructor
    state = PyLong_FromVoidPtr(L)

    print(f"Initialize LuaRuntime at proxy module with lua_State *L = {hex(state)}")

    from lupa import LuaRuntime

    # TODO: Make possible to configure others LuaRuntime options
    runtime = LuaRuntime(state=state, encoding="latin-1")
    

cdef void setup_system_path():
    # Add all lua interpreter 'require' paths to Python import paths
    paths: list[Path] = [Path(it) for it in _lua_eval_intern("package.path").split(";")]
    for path in set(it.parent for it in paths if it.parent.is_dir()):
        str_path = str(path)
        print(f"Append system path: '{str_path}'")
        sys.path.append(str_path)


virtualenv_env_variable = "LUA_PYTHON_VIRTUAL_ENV"


cdef void initialize_virtualenv():
    virtualenv_path = os.environ.get(virtualenv_env_variable)
    if virtualenv_path is None:
        print(f"Environment variable '{virtualenv_env_variable}' not set, try to use system Python")
        return
    
    this_file = os.path.join(virtualenv_path, "Scripts", "activate_this.py")
    if not os.path.isfile(this_file):
        print(f"virtualenv at '{virtualenv_path}' seems corrupted, activation file '{this_file}' not found")
        return

    print(f"Activate virtualenv at {virtualenv_env_variable}='{virtualenv_path}'")
    exec(open(this_file).read(), {'__file__': this_file})


cdef public int embedded_initialize(void *L):
    initialize_virtualenv()
    initialize_lua_runtime(L)
    setup_system_path()
    return 1


cdef extern from *:
    """
    PyMODINIT_FUNC PyInit_embedded(void);

    // use void* to make possible not to link proxy module with lua libraries
    #define LUA_ENTRY_POINT(x) __declspec(dllexport) int luaopen_ ## x (void *L)

    LUA_ENTRY_POINT(libpylua) {
        PyImport_AppendInittab("embedded", PyInit_embedded);
        Py_Initialize();
        PyImport_ImportModule("embedded");
        return embedded_initialize(L);
    }
    """

# Export proxy DLL name from this .pyd file
# This name may be used by external Python script installer, e.g.
#
# from lupa import embedded
# dylib_ext = get_dylib_ext_by_os()
# dest_path = os.path.join(dest_dir, f"{embedded.lua_dylib_name}.{dylib_ext}")
# shutil.copyfile(embedded.__file__, dest_path)
lua_dylib_name = "libpylua"
