
cimport lua
from lua cimport lua_State

cimport cpython, cpython.ref

DEF POBJECT = "POBJECT" # as used by LunaticPython

cdef class _LuaObject

cdef struct py_object:
    cpython.ref.PyObject* obj
    int as_index

class LuaError(Exception):
    pass

cdef class LuaRuntime:
    cdef lua_State *_state

    def __cinit__(self):
        cdef lua_State* L = lua.lua_open()
        self._state = L
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

    def eval(self, lua_code):
        if isinstance(lua_code, unicode):
            lua_code = (<unicode>lua_code).encode('UTF-8')
        return run_lua(self._state, b'return ' + lua_code)

    def run(self, lua_code):
        if isinstance(lua_code, unicode):
            lua_code = (<unicode>lua_code).encode('UTF-8')
        return run_lua(self._state, lua_code)


cdef _LuaObject new_lua_object(lua_State *L, int n):
    cdef _LuaObject obj = _LuaObject.__new__(_LuaObject)
    obj._state = L
    obj._ref = lua.luaL_ref(L, lua.LUA_REGISTRYINDEX)
    return obj

cdef class _LuaObject:
    cdef lua_State *_state
    cdef int _ref
    cdef int _refiter

    def __init__(self):
        raise TypeError("Type cannot be instantiated manually")

    def __cinit__(self):
        self._state = NULL
        self._ref = 0
        self._refiter = 0

    def __dealloc__(self):
        if self._state is not NULL:
            lua.luaL_unref(self._state, lua.LUA_REGISTRYINDEX, self._ref)
            if self._refiter:
                lua.luaL_unref(self._state, lua.LUA_REGISTRYINDEX, self._refiter)

    def __call__(self, *args):
        cdef lua_State* L = self._state
        lua.lua_settop(L, 0)
        lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, self._ref)
        return call_lua(L, args)

    def __getattr__(self, name):
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
    lua.lua_pushvalue(L, lua.lua_upvalueindex(1))
    lua.lua_insert(L, 1)
    return call_python(L)


cdef object py_from_lua(lua_State *L, int n):
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
    return new_lua_object(L, n)

cdef bint py_to_lua(lua_State *L, object o, bint withnone) except -1:
    cdef char* s
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
        lua.lua_pushlstring(L, <char*>(<bytes>s), len(<bytes>s))
        ret = 1
    elif isinstance(o, int) or isinstance(o, float):
        lua.lua_pushnumber(L, <lua.lua_Number><double>o)
    elif isinstance(o, _LuaObject):
        lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, (<_LuaObject>o)._ref)
        ret = 1
    else:
        asindx =  isinstance(o, dict) or isinstance(o, list) or isinstance(o, tuple)
        ret = py_to_lua_custom(L, o, asindx)
        if ret and not asindx and callable(o):
            lua.lua_pushcclosure(L, <lua.lua_CFunction>py_asfunc_call, 1)
    return ret

cdef int py_to_lua_custom(lua_State *L, object o, int as_index):
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


cdef run_lua(lua_State* L, bytes lua_code):
    if lua.luaL_loadbuffer(L, lua_code, len(lua_code), '<python>'):
        raise LuaError("error loading code: %s" % lua.lua_tostring(L, -1))
    if lua.lua_pcall(L, 0, 1, 0):
        raise LuaError("error executing code: %s" % lua.lua_tostring(L, -1))
    try:
        return py_from_lua(L, -1)
    finally:
        lua.lua_settop(L, 0)


cdef call_lua(lua_State *L, tuple args):
    # convert arguments
    cdef Py_ssize_t i, nargs
    for i, arg in enumerate(args):
        if not py_to_lua(L, arg, 0):
            lua.lua_settop(L, 0)
            raise TypeError("failed to convert argument at index %d" % i)

    # call into Lua
    if lua.lua_pcall(L, nargs, lua.LUA_MULTRET, 0):
        raise LuaError("error: %s" % lua.lua_tostring(L, -1))

    # extract return values
    try:
        nargs = lua.lua_gettop(L)
        if nargs == 1:
            return py_from_lua(L, 1)
        elif nargs == 0:
            return None
        else:
            ret_tuple = cpython.tuple.PyTuple_New(nargs)
            for i in range(nargs):
                cpython.tuple.PyTuple_SetItem(ret_tuple, i, py_from_lua(L, i+1))
            return ret_tuple
    finally:
        lua.lua_settop(L, 0)

cdef bint call_python(lua_State *L):
    cdef py_object* py_obj = <py_object*> lua.luaL_checkudata(L, 1, POBJECT)
    cdef int nargs = lua.lua_gettop(L)-1
    cdef bint ret = 0
    cdef int i

    if not py_obj:
        lua.luaL_argerror(L, 1, "not a python object")
    args = cpython.tuple.PyTuple_New(nargs)
    for i in range(nargs):
        cpython.tuple.PyTuple_SetItem(args, i, py_from_lua(L, i+2))

    return py_to_lua(L, (<object>py_obj.obj)(*args), 0 )
