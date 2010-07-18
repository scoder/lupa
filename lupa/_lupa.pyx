# cython: embedsignature=True

cimport lua
from lua cimport lua_State

cimport cpython
cimport cpython.ref
cimport cpython.bytes
cimport cpython.tuple
from cpython.ref cimport PyObject
from cpython cimport pythread

cdef extern from *:
    ctypedef char* const_char_ptr "const char*"

cdef object exc_info
from sys import exc_info

__all__ = ['LuaRuntime', 'LuaError']

DEF POBJECT = "POBJECT" # as used by LunaticPython

cdef class _LuaObject

cdef struct py_object:
    PyObject* obj
    PyObject* runtime
    int as_index

cdef lua.luaL_Reg py_object_lib[6]
cdef lua.luaL_Reg py_lib[6]

# empty for now
py_lib[0].name = NULL
py_lib[0].func = NULL


class LuaError(Exception):
    pass

cdef class LuaRuntime:
    """The main entry point to the Lua runtime.

    Available options:

    * ``encoding``: the string encoding, defaulting to UTF-8.  If set
      to ``None``, all string values will be returned as byte strings.
      Otherwise, they will be decoded to unicode strings on the way
      from Lua to Python and unicode strings will be encoded on the
      way to Lua.  Note that ``str()`` calls on Lua objects will
      always return a unicode object.

    * ``source_encoding``: the encoding used for Lua code, defaulting to
      the string encoding or UTF-8 if the string encoding is ``None``.

    Example usage::

      >>> from lupa import LuaRuntime
      >>> lua = LuaRuntime()

      >>> lua.eval('1+1')
      2

      >>> lua_func = lua.eval('function(f, n) return f(n) end')

      >>> def py_add1(n): return n+1
      >>> lua_func(py_add1, 2)
      3
    """
    cdef lua_State *_state
    cdef pythread.PyThread_type_lock _thread_lock
    cdef long _lock_owner
    cdef int _lock_count
    cdef tuple _raised_exception
    cdef bytes _encoding
    cdef bytes _source_encoding

    def __cinit__(self, encoding='UTF-8', source_encoding=None):
        self._thread_lock = self._state = NULL
        self._lock_owner = -1
        self._lock_count = 0
        cdef lua_State* L = lua.lua_open()
        if L is NULL:
            raise LuaError("Failed to initialise Lua runtime")
        self._state = L

        self._thread_lock = pythread.PyThread_allocate_lock()
        if self._thread_lock is NULL:
            raise LuaError("Failed to initialise thread lock")

        self._encoding = None if encoding is None else encoding.encode('ASCII')
        self._source_encoding = self._encoding or b'UTF-8'

        lua.luaL_openlibs(L)
        self.init_python_lib()
        lua.lua_settop(L, 0)

    def __dealloc__(self):
        if self._state is not NULL:
            lua.lua_close(self._state)
            self._state = NULL
        if self._thread_lock is not NULL:
            pythread.PyThread_free_lock(self._thread_lock)
            self._thread_lock = NULL

    cdef int lock(self) except -1:
        cdef long current_thread = pythread.PyThread_get_thread_ident()
        if self._lock_count and current_thread == self._lock_owner:
            self._lock_count += 1
            return 0
        with nogil:
            locked = pythread.PyThread_acquire_lock(self._thread_lock, pythread.WAIT_LOCK)
        if not locked:
            raise LuaError("Failed to acquire thread lock")
        self._lock_owner = current_thread
        self._lock_count = 1
        return 0

    cdef void unlock(self) nogil:
        if self._lock_count == 0:
            return
        self._lock_count -= 1
        if self._lock_count == 0:
            pythread.PyThread_release_lock(self._thread_lock)
            self._lock_owner = -1

    cdef int reraise_on_exception(self) except -1:
        if self._raised_exception is not None:
            exception = self._raised_exception
            self._raised_exception = None
            raise exception[0], exception[1], exception[2]
        return 0

    cdef int store_raised_exception(self) except -1:
        self._raised_exception = exc_info()
        return 0

    def eval(self, lua_code):
        if isinstance(lua_code, unicode):
            lua_code = (<unicode>lua_code).encode(self._source_encoding)
        return run_lua(self, b'return ' + lua_code)

    def execute(self, lua_code):
        if isinstance(lua_code, unicode):
            lua_code = (<unicode>lua_code).encode(self._source_encoding)
        return run_lua(self, lua_code)

    def require(self, modulename):
        cdef lua_State *L = self._state
        if not isinstance(modulename, (bytes, unicode)):
            raise TypeError("modulename must be a string")
        self.lock()
        try:
            lua.lua_pushlstring(L, 'require', 7)
            lua.lua_rawget(L, lua.LUA_GLOBALSINDEX)
            if lua.lua_isnil(L, -1):
                lua.lua_pop(L, 1)
                raise LuaError("require is not defined")
            return call_lua(self, (modulename,))
        finally:
            self.unlock()

    def globals(self):
        cdef lua_State *L = self._state
        self.lock()
        try:
            lua.lua_pushlstring(L, '_G', 2)
            lua.lua_rawget(L, lua.LUA_GLOBALSINDEX)
            if lua.lua_isnil(L, -1):
                lua.lua_pop(L, 1)
                raise LuaError("globals not defined")
            try:
                return py_from_lua(self, -1)
            finally:
                lua.lua_settop(L, 0)
        finally:
            self.unlock()

    cdef int register_py_object(self, bytes cname, bytes pyname, object obj) except -1:
        cdef lua_State *L = self._state
        lua.lua_pushlstring(L, cname, len(cname))
        if not py_to_lua_custom(self, obj, 0):
            lua.lua_pop(L, 1)
            message = b"failed to convert %s object" % pyname
            lua.luaL_error(L, message)
            raise LuaError(message.decode('ASCII', 'replace'))
        lua.lua_pushlstring(L, pyname, len(pyname))
        lua.lua_pushvalue(L, -2)
        lua.lua_rawset(L, -5)
        lua.lua_rawset(L, lua.LUA_REGISTRYINDEX)
        return 0

    cdef int init_python_lib(self) except -1:
        cdef lua_State *L = self._state

        # create 'python' lib and register our own object metatable
        lua.luaL_openlib(L, "python", py_lib, 0)
        lua.luaL_newmetatable(L, POBJECT)
        lua.luaL_openlib(L, NULL, py_object_lib, 0)
        lua.lua_pop(L, 1)

        # register global names in the module
        self.register_py_object(b'Py_None', b'none', None)
        self.register_py_object(b'eval',    b'eval', eval)

        return 0 # nothing left to return on the stack


cdef _LuaObject new_lua_object(LuaRuntime runtime, int n):
    cdef _LuaObject obj = _LuaObject.__new__(_LuaObject)
    # additional INCREF to keep runtime from disappearing in GC runs
    cpython.ref.Py_INCREF(runtime)
    obj._runtime = runtime
    obj._ref = lua.luaL_ref(runtime._state, lua.LUA_REGISTRYINDEX)
    return obj

cdef class _LuaObject:
    """A wrapper around a Lua object such as a table of function.
    """
    cdef LuaRuntime _runtime
    cdef int _ref

    def __init__(self):
        raise TypeError("Type cannot be instantiated manually")

    def __dealloc__(self):
        if self._runtime is None:
            return
        cdef lua_State* L = self._runtime._state
        try:
            self._runtime.lock()
            locked = True
        except:
            locked = False
        lua.luaL_unref(L, lua.LUA_REGISTRYINDEX, self._ref)
        if locked:
            self._runtime.unlock()
        # undo additional INCREF at instantiation time
        cpython.ref.Py_DECREF(self._runtime)

    cdef inline int push_lua_object(self) except -1:
        cdef lua_State* L = self._runtime._state
        lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, self._ref)
        if lua.lua_isnil(L, -1):
            lua.lua_pop(L, 1)
            raise LuaError("lost reference")

    def __call__(self, *args):
        assert self._runtime is not None
        cdef lua_State* L = self._runtime._state
        self._runtime.lock()
        try:
            lua.lua_settop(L, 0)
            self.push_lua_object()
            return call_lua(self._runtime, args)
        finally:
            self._runtime.unlock()

    def __len__(self):
        assert self._runtime is not None
        cdef lua_State* L = self._runtime._state
        self._runtime.lock()
        try:
            self.push_lua_object()
            return lua.luaL_getn(L, -1)
        finally:
            lua.lua_settop(L, 0)
            self._runtime.unlock()

    def __iter__(self):
        return _LuaIter(self, KEYS)

    def keys(self):
        """Returns an iterator over the keys of a table (or other
        iterable) that this object represents.  Same as iter(obj).
        """
        return _LuaIter(self, KEYS)

    def values(self):
        """Returns an iterator over the values of a table (or other
        iterable) that this object represents.
        """
        return _LuaIter(self, VALUES)

    def items(self):
        """Returns an iterator over the key-value pairs of a table (or
        other iterable) that this object represents.
        """
        return _LuaIter(self, ITEMS)

    def __str__(self):
        assert self._runtime is not None
        cdef lua_State* L = self._runtime._state
        cdef unicode py_string = None
        cdef bytes py_bytes = None
        cdef const_char_ptr s
        cdef void* ptr = NULL
        cdef int lua_type
        encoding = self._runtime._encoding.decode('ASCII') if self._runtime._encoding else 'UTF-8'
        self._runtime.lock()
        try:
            self.push_lua_object()
            if lua.luaL_callmeta(L, -1, "__tostring"):
                s = lua.lua_tostring(L, -1)
                try:
                    if s:
                        try:
                            py_string = s.decode(encoding)
                        except UnicodeDecodeError:
                            # safe 'decode'
                            py_string = s.decode('ISO-8859-1')
                finally:
                    lua.lua_pop(L, 1)
            if py_string is None:
                lua_type = lua.lua_type(L, -1)
                if lua_type in (lua.LUA_TTABLE, lua.LUA_TFUNCTION):
                    ptr = <void*>lua.lua_topointer(L, -1)
                elif lua_type in (lua.LUA_TUSERDATA, lua.LUA_TLIGHTUSERDATA):
                    ptr = <void*>lua.lua_touserdata(L, -1)
                elif lua_type == lua.LUA_TTHREAD:
                    ptr = <void*>lua.lua_tothread(L, -1)
                if ptr is not NULL:
                    py_bytes = cpython.bytes.PyBytes_FromFormat(
                        "<Lua %s at %p>", lua.lua_typename(L, lua_type), ptr)
                else:
                    py_bytes = cpython.bytes.PyBytes_FromFormat(
                        "<Lua %s>", lua.lua_typename(L, lua_type))
                try:
                    py_string = py_bytes.decode(encoding)
                except UnicodeDecodeError:
                    # safe 'decode'
                    py_string = py_bytes.decode('ISO-8859-1')
        finally:
            lua.lua_pop(L, 1)
            self._runtime.unlock()
        return py_string

    def __getattr__(self, name):
        assert self._runtime is not None
        cdef lua_State* L = self._runtime._state
        if isinstance(name, unicode):
            name = (<unicode>name).encode(self._runtime._source_encoding)
        self._runtime.lock()
        try:
            self.push_lua_object()
            py_to_lua(self._runtime, name, 0)
            lua.lua_gettable(L, -2)
            try:
                return py_from_lua(self._runtime, -1)
            finally:
                lua.lua_settop(L, 0)
        finally:
            self._runtime.unlock()

    def __setattr__(self, name, value):
        assert self._runtime is not None
        cdef lua_State* L = self._runtime._state
        self._runtime.lock()
        try:
            self.push_lua_object()
            if not lua.lua_istable(L, -1):
                lua.lua_pop(L, -1)
                raise TypeError("Lua object is not a table")
            try:
                py_to_lua(self._runtime, name, 0)
                py_to_lua(self._runtime, value, 0)
                lua.lua_settable(L, -3)
            finally:
                lua.lua_settop(L, 0)
        finally:
            self._runtime.unlock()

    def __getitem__(self, index_or_name):
        return self.__getattr__(index_or_name)

    def __setitem__(self, index_or_name, value):
        self.__setattr__(index_or_name, value)

cdef enum:
    KEYS = 1
    VALUES = 2
    ITEMS = 3

cdef class _LuaIter:
    cdef LuaRuntime _runtime
    cdef _LuaObject _obj
    cdef int _refiter
    cdef char _what

    def __cinit__(self, _LuaObject obj not None, int what):
        assert obj._runtime is not None
        self._runtime = obj._runtime
        # additional INCREF to keep runtime from disappearing in GC runs
        cpython.ref.Py_INCREF(self._runtime)

        self._obj = obj
        self._refiter = 0
        self._what = what

    def __dealloc__(self):
        if self._runtime is None:
            return
        cdef lua_State* L = self._runtime._state
        if self._refiter:
            try:
                self._runtime.lock()
                locked = True
            except:
                locked = False
            lua.luaL_unref(L, lua.LUA_REGISTRYINDEX, self._refiter)
            if locked:
                self._runtime.unlock()
        # undo additional INCREF at instantiation time
        cpython.ref.Py_DECREF(self._runtime)

    def __iter__(self):
        return self

    def __next__(self):
        if self._obj is None:
            raise StopIteration
        cdef lua_State* L = self._runtime._state
        self._runtime.lock()
        try:
            if self._obj is None:
                raise StopIteration
            # iterable object
            lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, self._obj._ref)
            if not lua.lua_istable(L, -1):
                if lua.lua_isnil(L, -1):
                    lua.lua_pop(L, 1)
                    raise LuaError("lost reference")
                raise TypeError("cannot iterate over non-table")
            if not self._refiter:
                # initial key
                lua.lua_pushnil(L)
            else:
                # last key
                lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, self._refiter)
            if lua.lua_next(L, -2):
                try:
                    if self._what == KEYS:
                        retval = py_from_lua(self._runtime, -2)
                    elif self._what == VALUES:
                        retval = py_from_lua(self._runtime, -1)
                    else: # ITEMS
                        retval = (py_from_lua(self._runtime, -2), py_from_lua(self._runtime, -1))
                finally:
                    # pop value
                    lua.lua_pop(L, 1)
                    # pop and store key
                    if not self._refiter:
                        self._refiter = lua.luaL_ref(L, lua.LUA_REGISTRYINDEX)
                    else:
                        lua.lua_rawseti(L, lua.LUA_REGISTRYINDEX, self._refiter)
                return retval
            elif self._refiter:
                lua.luaL_unref(L, lua.LUA_REGISTRYINDEX, self._refiter)
            self._obj = None
        finally:
            self._runtime.unlock()
        raise StopIteration


cdef int py_asfunc_call(lua_State *L):
    lua.lua_pushvalue(L, lua.lua_upvalueindex(1))
    lua.lua_insert(L, 1)
    return py_object_call(L)


cdef object py_from_lua(LuaRuntime runtime, int n):
    cdef lua_State *L = runtime._state
    cdef size_t size
    cdef const_char_ptr s
    cdef lua.lua_Number number
    cdef py_object* py_obj
    cdef int lua_type = lua.lua_type(L, n)

    if lua_type == lua.LUA_TNIL:
        return None
    elif lua_type == lua.LUA_TSTRING:
        s = lua.lua_tolstring(L, n, &size)
        if runtime._encoding is not None:
            return s[:size].decode(runtime._encoding)
        else:
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
    cdef bint pushed_values_count = 0
    cdef bint as_index = 0
    cdef bytes bytes_string

    if o is None:
        if withnone:
            lua.lua_pushlstring(L, "Py_None", 7)
            lua.lua_rawget(L, lua.LUA_REGISTRYINDEX)
            if lua.lua_isnil(L, -1):
                lua.lua_pop(L, 1)
                lua.luaL_error(L, "lost none from registry")
        else:
            # Not really needed, but this way we may check for errors
            # with pushed_values_count == 0.
            lua.lua_pushnil(L)
            pushed_values_count = 1
    elif o is True or o is False:
        lua.lua_pushboolean(L, o is True)
        pushed_values_count = 1
    elif isinstance(o, bytes):
        lua.lua_pushlstring(L, <char*>(<bytes>o), len(<bytes>o))
        pushed_values_count = 1
    elif isinstance(o, unicode) and runtime._encoding is not None:
        bytes_string = (<unicode>o).encode(runtime._encoding)
        lua.lua_pushlstring(L, <char*>bytes_string, len(bytes_string))
        pushed_values_count = 1
    elif isinstance(o, int) or isinstance(o, float):
        lua.lua_pushnumber(L, <lua.lua_Number><double>o)
        pushed_values_count = 1
    elif isinstance(o, _LuaObject):
        if (<_LuaObject>o)._runtime is not runtime:
            raise LuaError("cannot mix objects from different Lua runtimes")
        lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, (<_LuaObject>o)._ref)
        pushed_values_count = 1
    else:
        as_index =  isinstance(o, dict) or isinstance(o, list) or isinstance(o, tuple)
        pushed_values_count = py_to_lua_custom(runtime, o, as_index)
        if pushed_values_count and not as_index and hasattr(o, '__call__'):
            lua.lua_pushcclosure(L, <lua.lua_CFunction>py_asfunc_call, 1)
    return pushed_values_count

cdef bint py_to_lua_custom(LuaRuntime runtime, object o, int as_index):
    cdef lua_State *L = runtime._state
    cdef py_object *py_obj = <py_object*> lua.lua_newuserdata(L, sizeof(py_object))
    if py_obj:
        cpython.ref.Py_INCREF(o)
        cpython.ref.Py_INCREF(runtime)
        py_obj.obj = <PyObject*>o
        py_obj.runtime = <PyObject*>runtime
        py_obj.as_index = as_index
        lua.luaL_getmetatable(L, POBJECT)
        lua.lua_setmetatable(L, -2)
        return 1 # values pushed
    else:
        lua.luaL_error(L, "failed to allocate userdata object")
        return 0 # values pushed


cdef run_lua(LuaRuntime runtime, bytes lua_code):
    # locks the runtime
    cdef lua_State* L = runtime._state
    cdef bint result
    runtime.lock()
    try:
        if lua.luaL_loadbuffer(L, lua_code, len(lua_code), '<python>'):
            raise LuaError("error loading code: %s" % lua.lua_tostring(L, -1))
        with nogil:
            result = lua.lua_pcall(L, 0, 1, 0)
        runtime.reraise_on_exception()
        if result:
            raise LuaError("error executing code: %s" % lua.lua_tostring(L, -1))
        try:
            return py_from_lua(runtime, -1)
        finally:
            lua.lua_settop(L, 0)
    finally:
        runtime.unlock()


cdef call_lua(LuaRuntime runtime, tuple args):
    # does not lock the runtime!
    cdef lua_State *L = runtime._state
    cdef Py_ssize_t i, nargs
    cdef int result_status
    # convert arguments
    for i, arg in enumerate(args):
        if not py_to_lua(runtime, arg, 0):
            lua.lua_settop(L, 0)
            raise TypeError("failed to convert argument at index %d" % i)

    # call into Lua
    nargs = len(args)
    with nogil:
        result_status = lua.lua_pcall(L, nargs, lua.LUA_MULTRET, 0)
    runtime.reraise_on_exception()
    if result_status:
        raise LuaError("error: %s" % lua.lua_tostring(L, -1))

    # extract return values
    try:
        nargs = lua.lua_gettop(L)
        if nargs == 1:
            return py_from_lua(runtime, 1)
        elif nargs == 0:
            return None

        args = cpython.tuple.PyTuple_New(nargs)
        for i in range(nargs):
            arg = py_from_lua(runtime, i+1)
            cpython.ref.Py_INCREF(arg)
            cpython.tuple.PyTuple_SET_ITEM(args, i, arg)
        return args
    finally:
        lua.lua_settop(L, 0)


################################################################################
# Python support in Lua

# ref-counting support for Python objects

cdef void decref_with_gil(py_object *py_obj) with gil:
    cpython.ref.Py_XDECREF(py_obj.obj)
    cpython.ref.Py_XDECREF(py_obj.runtime)

cdef int py_object_gc(lua_State* L):
    cdef py_object *py_obj = <py_object*> lua.luaL_checkudata(L, 1, POBJECT)
    if py_obj is not NULL and py_obj.obj is not NULL:
        decref_with_gil(py_obj)
    return 0

# calling Python objects

cdef bint call_python(LuaRuntime runtime, py_object* py_obj) except -1:
    cdef lua_State *L = runtime._state
    cdef int nargs = lua.lua_gettop(L) - 1
    cdef bint ret = 0

    if not py_obj:
        lua.luaL_argerror(L, 1, "not a python object")
        return 0

    args = cpython.tuple.PyTuple_New(nargs)
    for i in range(nargs):
        arg = py_from_lua(runtime, i+2)
        cpython.ref.Py_INCREF(arg)
        cpython.tuple.PyTuple_SET_ITEM(args, i, arg)

    return py_to_lua(runtime, (<object>py_obj.obj)(*args), 0)

cdef int py_call_with_gil(lua_State* L, py_object *py_obj) with gil:
    cdef LuaRuntime runtime = None
    try:
        runtime = <LuaRuntime?>py_obj.runtime
        if runtime._state is not L:
            lua.luaL_argerror(L, 1, "cannot mix objects from different Lua runtimes")
            return 0
        return call_python(runtime, py_obj)
    except:
        runtime.store_raised_exception()
        try:
            message = (u"error during Python call: %r" % exc_info()[1]).encode('UTF-8')
            lua.luaL_error(L, message)
        except:
            lua.luaL_error(L, b"error during Python call")
        return 0

cdef int py_object_call(lua_State* L):
    cdef py_object *py_obj = <py_object*> lua.luaL_checkudata(L, 1, POBJECT)
    if not py_obj:
        lua.luaL_argerror(L, 1, "not a python object")
        return 0

    return py_call_with_gil(L, py_obj)

# str() support for Python objects

cdef int py_str_with_gil(lua_State* L, py_object* py_obj) with gil:
    cdef LuaRuntime runtime
    try:
        runtime = <LuaRuntime?>py_obj.runtime
        if runtime._state is not L:
            lua.luaL_argerror(L, 1, "cannot mix objects from different Lua runtimes")
            return 0
        s = str(<object>py_obj.obj)
        if isinstance(s, unicode):
            s = (<unicode>s).encode('UTF-8')
        else:
            assert isinstance(s, bytes)
        lua.lua_pushlstring(L, <bytes>s, len(<bytes>s))
        return 1 # returning 1 value
    except:
        runtime.store_raised_exception()
        try:
            message = (u"error during Python str() call: %r" % exc_info()[1]).encode('UTF-8')
            lua.luaL_error(L, message)
        except:
            lua.luaL_error(L, b"error during Python str() call")
        return 0

cdef int py_object_str(lua_State* L):
    cdef py_object *py_obj = <py_object*> lua.luaL_checkudata(L, 1, POBJECT)
    if not py_obj:
        lua.luaL_argerror(L, 1, "not a python object")
        return 0
    return py_str_with_gil(L, py_obj)

# special methods for Lua

py_object_lib[0] = lua.luaL_Reg(name = "__gc",       func = <lua.lua_CFunction> py_object_gc)
py_object_lib[1] = lua.luaL_Reg(name = "__call",     func = <lua.lua_CFunction> py_object_call)
py_object_lib[2] = lua.luaL_Reg(name = "__tostring", func = <lua.lua_CFunction> py_object_str)
py_object_lib[3] = lua.luaL_Reg(name = NULL, func = NULL)

## static const luaL_reg py_object_lib[] = {
## 	{"__call",	py_object_call},
## 	{"__index",	py_object_index},
## 	{"__newindex",	py_object_newindex},
## 	{"__gc",	py_object_gc},
## 	{"__tostring",	py_object_tostring},
## 	{NULL, NULL}
## };

