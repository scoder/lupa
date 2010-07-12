
cimport lua
from lua cimport lua_State

cimport cpython, cpython.ref
from cpython cimport pythread

__all__ = ['LuaRuntime', 'LuaError']

DEF POBJECT = "POBJECT" # as used by LunaticPython

cdef class _LuaObject

cdef struct py_object:
    cpython.ref.PyObject* obj
    int as_index

class LuaError(Exception):
    pass

cdef class LuaRuntime:
    cdef lua_State *_state
    cdef pythread.PyThread_type_lock _thread_lock

    def __cinit__(self):
        cdef lua_State* L = lua.lua_open()
        self._state = L
        if L is NULL:
            raise LuaError("Failed to initialise Lua runtime")

        self._thread_lock = pythread.PyThread_allocate_lock()
        if self._thread_lock is NULL:
            raise LuaError("Failed to initialise thread lock")

        lua.luaopen_base(L)
        lua.luaopen_table(L)
        lua.luaopen_io(L)
        lua.luaopen_string(L)
        lua.luaopen_debug(L)
        #lua.luaopen_loadlib(L)
        #luaopen_python(L)
        lua.lua_settop(L, 0)

    def __dealloc__(self):
        if self._state is not NULL:
            lua.lua_close(self._state)
            self._state = NULL

    cdef int lock(self) except -1:
        if not pythread.PyThread_acquire_lock(self._thread_lock, pythread.WAIT_LOCK):
            raise LuaError("Failed to acquire thread lock")
        return 0

    cdef void unlock(self):
        pythread.PyThread_release_lock(self._thread_lock)

    def eval(self, lua_code):
        if isinstance(lua_code, unicode):
            lua_code = (<unicode>lua_code).encode('UTF-8')
        return run_lua(self, b'return ' + lua_code)

    def run(self, lua_code):
        if isinstance(lua_code, unicode):
            lua_code = (<unicode>lua_code).encode('UTF-8')
        return run_lua(self, lua_code)


cdef _LuaObject new_lua_object(LuaRuntime runtime, int n):
    cdef _LuaObject obj = _LuaObject.__new__(_LuaObject)
    # additional INCREF to keep runtime from disappearing in GC runs
    cpython.ref.Py_INCREF(runtime)
    obj._runtime = runtime
    obj._ref = lua.luaL_ref(runtime._state, lua.LUA_REGISTRYINDEX)
    return obj

cdef class _LuaObject:
    cdef LuaRuntime _runtime
    cdef int _ref
    cdef int _refiter

    def __init__(self):
        raise TypeError("Type cannot be instantiated manually")

    def __cinit__(self):
        self._ref = 0
        self._refiter = 0

    def __dealloc__(self):
        if self._runtime is None:
            return
        lua.luaL_unref(self._runtime._state, lua.LUA_REGISTRYINDEX, self._ref)
        if self._refiter:
            lua.luaL_unref(self._runtime._state, lua.LUA_REGISTRYINDEX, self._refiter)
        # undo additional INCREF at instantiation time
        cpython.ref.Py_DECREF(self._runtime)

    def __call__(self, *args):
        assert self._runtime is not None
        cdef lua_State* L = self._runtime._state
        lua.lua_settop(L, 0)
        lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, self._ref)
        return call_lua(self._runtime, args)

    def __getattr__(self, name):
        assert self._runtime is not None
        pass
        ## lua_rawgeti(self._state, lua.LUA_REGISTRYINDEX, self._ref)
        ## if lua.lua_isnil(self._state, -1):
        ##     lua.lua_pop(self._state, 1)
        ##     raise RuntimeError("lost reference")
	## py_convert(self._state, attr, 0, "can't convert attr/key")
        ## lua_gettable(L, -2);
	## 	ret = LuaConvert(L, -1);
	## } else {
	## 	PyErr_SetString(PyExc_ValueError, "can't convert attr/key");
	## }
	## lua.lua_settop(L, 0)


cdef int py_asfunc_call(lua_State *L):
    # FIXME: LuaRuntime???
    lua.lua_pushvalue(L, lua.lua_upvalueindex(1))
    lua.lua_insert(L, 1)
    #return call_python(runtime)


cdef object py_from_lua(LuaRuntime runtime, int n):
    cdef lua_State *L = runtime._state
    cdef size_t size
    cdef char* s
    cdef lua.lua_Number number
    cdef py_object* py_obj
    cdef int lua_type = lua.lua_type(L, n)

    if lua_type == lua.LUA_TNIL:
        return None
    elif lua_type == lua.LUA_TSTRING:
        s = lua.lua_tolstring(L, n, &size)
        return s[:size]
    elif lua_type == lua.LUA_TNUMBER:
        number = lua.lua_tonumber(L, n)
        if number != <long>number:
            return <double>number
        else:
            return <long>number
    elif lua_type == lua.LUA_TBOOLEAN:
        return lua.lua_toboolean(L, n)
    elif lua_type == lua.LUA_TUSERDATA:
        py_obj = <py_object*>lua.luaL_checkudata(L, n, POBJECT)
        if py_obj:
            return <object>py_obj.obj
    return new_lua_object(runtime, n)

cdef bint py_to_lua(LuaRuntime runtime, object o, bint withnone) except -1:
    cdef lua_State *L = runtime._state
    cdef bint ret = 0
    cdef bint asindx = 0

    if o is None:
        if withnone:
            lua.lua_pushlstring(L, "Py_None", sizeof("Py_None")-1)
            lua.lua_rawget(L, lua.LUA_REGISTRYINDEX)
            if lua.lua_isnil(L, -1):
                lua.lua_pop(L, 1)
                lua.luaL_error(L, "lost none from registry")
        else:
            # Not really needed, but this way we may check for errors
            # with ret == 0.
            lua.lua_pushnil(L)
            ret = 1
    elif o is True or o is False:
        lua.lua_pushboolean(L, o is True)
        ret = 1
    elif isinstance(o, bytes):
        lua.lua_pushlstring(L, <char*>(<bytes>o), len(<bytes>o))
        ret = 1
    elif isinstance(o, int) or isinstance(o, float):
        lua.lua_pushnumber(L, <lua.lua_Number><double>o)
        ret = 1
    elif isinstance(o, _LuaObject):
        lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, (<_LuaObject>o)._ref)
        ret = 1
    else:
        asindx =  isinstance(o, dict) or isinstance(o, list) or isinstance(o, tuple)
        ret = py_to_lua_custom(runtime, o, asindx)
        if ret and not asindx and hasattr(o, '__call__'):
            lua.lua_pushcclosure(L, <lua.lua_CFunction>py_asfunc_call, 1)
    return ret

cdef int py_to_lua_custom(LuaRuntime runtime, object o, int as_index):
    cdef lua_State *L = runtime._state
    cdef bint ret = 0
    cdef py_object *py_obj = <py_object*> lua.lua_newuserdata(L, sizeof(py_object))
    if py_obj:
        cpython.ref.Py_INCREF(o)
        py_obj.obj = <cpython.ref.PyObject*>o
        py_obj.as_index = as_index
        lua.luaL_getmetatable(L, POBJECT)
        lua.lua_setmetatable(L, -2)
        return 1
    else:
        lua.luaL_error(L, "failed to allocate userdata object")
        return 0


cdef run_lua(LuaRuntime runtime, bytes lua_code):
    cdef lua_State* L = runtime._state
    runtime.lock()
    try:
        if lua.luaL_loadbuffer(L, lua_code, len(lua_code), '<python>'):
            raise LuaError("error loading code: %s" % lua.lua_tostring(L, -1))
        if lua.lua_pcall(L, 0, 1, 0):
            raise LuaError("error executing code: %s" % lua.lua_tostring(L, -1))
        try:
            return py_from_lua(runtime, -1)
        finally:
            lua.lua_settop(L, 0)
    finally:
        runtime.unlock()


cdef call_lua(LuaRuntime runtime, tuple args):
    cdef lua_State *L = runtime._state
    cdef Py_ssize_t i, nargs
    cdef int result_status
    runtime.lock()
    try:
        # convert arguments
        for i, arg in enumerate(args):
            if not py_to_lua(runtime, arg, 0):
                lua.lua_settop(L, 0)
                raise TypeError("failed to convert argument at index %d" % i)

        # call into Lua
        nargs = len(args)
        with nogil:
            result_status = lua.lua_pcall(L, nargs, lua.LUA_MULTRET, 0)
        if result_status:
            raise LuaError("error: %s" % lua.lua_tostring(L, -1))

        # extract return values
        try:
            nargs = lua.lua_gettop(L)
            if nargs == 1:
                return py_from_lua(runtime, 1)
            elif nargs == 0:
                return None
            else:
                ret_tuple = cpython.tuple.PyTuple_New(nargs)
                for i in range(nargs):
                    cpython.tuple.PyTuple_SetItem(ret_tuple, i, py_from_lua(runtime, i+1))
                return ret_tuple
        finally:
            lua.lua_settop(L, 0)
    finally:
        runtime.unlock()

cdef bint call_python(LuaRuntime runtime):
    cdef lua_State *L = runtime._state
    cdef py_object* py_obj = <py_object*> lua.luaL_checkudata(L, 1, POBJECT)
    cdef int nargs = lua.lua_gettop(L)-1
    cdef bint ret = 0
    cdef int i

    if not py_obj:
        lua.luaL_argerror(L, 1, "not a python object")
    args = cpython.tuple.PyTuple_New(nargs)
    for i in range(nargs):
        cpython.tuple.PyTuple_SetItem(args, i, py_from_lua(runtime, i+2))

    return py_to_lua(runtime, (<object>py_obj.obj)(*args), 0 )
