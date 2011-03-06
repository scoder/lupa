# cython: embedsignature=True

"""
A fast Python wrapper around Lua and LuaJIT2.
"""

cimport lua
from lua cimport lua_State

cimport cpython
cimport cpython.ref
cimport cpython.bytes
cimport cpython.tuple
cimport cpython.float
cimport cpython.long
from cpython.ref cimport PyObject
from cpython.version cimport PY_VERSION_HEX, PY_MAJOR_VERSION

cdef extern from *:
    ctypedef char* const_char_ptr "const char*"

cdef object exc_info
from sys import exc_info

__all__ = ['LuaRuntime', 'LuaError', 'as_itemgetter', 'as_attrgetter']

cdef object builtins
try:
    import __builtin__ as builtins
except ImportError:
    import builtins

DEF POBJECT = "POBJECT" # as used by LunaticPython

cdef class _LuaObject

cdef enum WrappedObjectFlags:
    # flags that determine the behaviour of a wrapped object:
    OBJ_AS_INDEX = 1 # prefers the getitem protocol (over getattr)
    OBJ_UNPACK_TUPLE = 2 # unpacks into separate values if it is a tuple
    OBJ_ENUMERATOR = 4 # iteration uses native enumerate() implementation

cdef struct py_object:
    PyObject* obj
    PyObject* runtime
    int type_flags  # or-ed set of WrappedObjectFlags

include "lock.pxi"

class LuaError(Exception):
    """Base class for errors in the Lua runtime.
    """
    pass

class LuaSyntaxError(LuaError):
    """Syntax error in Lua code.
    """
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
    cdef FastRLock _lock
    cdef tuple _raised_exception
    cdef bytes _encoding
    cdef bytes _source_encoding

    def __cinit__(self, encoding='UTF-8', source_encoding=None):
        self._state = NULL
        cdef lua_State* L = lua.lua_open()
        if L is NULL:
            raise LuaError("Failed to initialise Lua runtime")
        self._state = L
        self._lock = FastRLock()
        self._encoding = None if encoding is None else encoding.encode('ASCII')
        self._source_encoding = self._encoding or b'UTF-8'

        lua.luaL_openlibs(L)
        self.init_python_lib()
        lua.lua_settop(L, 0)
        lua.lua_atpanic(L, <lua.lua_CFunction>1)

    def __dealloc__(self):
        if self._state is not NULL:
            lua.lua_close(self._state)
            self._state = NULL

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
        """Evaluate a Lua expression passed in a string.
        """
        assert self._state is not NULL
        if isinstance(lua_code, unicode):
            lua_code = (<unicode>lua_code).encode(self._source_encoding)
        return run_lua(self, b'return ' + lua_code)

    def execute(self, lua_code):
        """Execute a Lua program passed in a string.
        """
        assert self._state is not NULL
        if isinstance(lua_code, unicode):
            lua_code = (<unicode>lua_code).encode(self._source_encoding)
        return run_lua(self, lua_code)

    def require(self, modulename):
        """Load a Lua library into the runtime.
        """
        assert self._state is not NULL
        cdef lua_State *L = self._state
        if not isinstance(modulename, (bytes, unicode)):
            raise TypeError("modulename must be a string")
        lock_runtime(self)
        try:
            lua.lua_pushlstring(L, 'require', 7)
            lua.lua_rawget(L, lua.LUA_GLOBALSINDEX)
            if lua.lua_isnil(L, -1):
                lua.lua_pop(L, 1)
                raise LuaError("require is not defined")
            return call_lua(self, L, (modulename,))
        finally:
            unlock_runtime(self)

    def globals(self):
        """Return the globals defined in this Lua runtime as a Lua
        table.
        """
        assert self._state is not NULL
        cdef lua_State *L = self._state
        lock_runtime(self)
        try:
            lua.lua_pushlstring(L, '_G', 2)
            lua.lua_rawget(L, lua.LUA_GLOBALSINDEX)
            if lua.lua_isnil(L, -1):
                lua.lua_pop(L, 1)
                raise LuaError("globals not defined")
            try:
                return py_from_lua(self, L, -1)
            finally:
                lua.lua_settop(L, 0)
        finally:
            unlock_runtime(self)

    def table(self, *items, **kwargs):
        """Creates a new table with the provided items.  Positional
        arguments are placed in the table in order, keyword arguments
        are set as key-value pairs.
        """
        assert self._state is not NULL
        cdef lua_State *L = self._state
        cdef int i
        lock_runtime(self)
        try:
            lua.lua_createtable(L, len(items), len(kwargs))
            # FIXME: how to check for failure?
            for i, arg in enumerate(items):
                py_to_lua(self, L, arg, 1)
                lua.lua_rawseti(L, -2, i+1)
            for key, value in kwargs.iteritems():
                py_to_lua(self, L, key, 1)
                py_to_lua(self, L, value, 1)
                lua.lua_rawset(L, -3)
            return py_from_lua(self, L, -1)
        finally:
            lua.lua_settop(L, 0)
            unlock_runtime(self)

    cdef int register_py_object(self, bytes cname, bytes pyname, object obj) except -1:
        cdef lua_State *L = self._state
        lua.lua_pushlstring(L, cname, len(cname))
        if not py_to_lua_custom(self, L, obj, 0):
            lua.lua_pop(L, 1)
            raise LuaError("failed to convert %s object" % pyname)
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
        self.register_py_object(b'Py_None',  b'none', None)
        self.register_py_object(b'eval',     b'eval', eval)
        self.register_py_object(b'builtins', b'builtins', builtins)

        return 0 # nothing left to return on the stack


################################################################################
# fast, re-entrant runtime locking

cdef inline int lock_runtime(LuaRuntime runtime) except -1:
    if not lock_lock(runtime._lock, pythread.PyThread_get_thread_ident(), True):
        raise LuaError("Failed to acquire thread lock")
    return 0

cdef inline void unlock_runtime(LuaRuntime runtime) nogil:
    unlock_lock(runtime._lock)


################################################################################
# Lua object wrappers

cdef class _LuaObject:
    """A wrapper around a Lua object such as a table of function.
    """
    cdef LuaRuntime _runtime
    cdef lua_State* _state
    cdef int _ref

    def __init__(self):
        raise TypeError("Type cannot be instantiated manually")

    def __dealloc__(self):
        if self._runtime is None:
            return
        cdef lua_State* L = self._state
        try:
            lock_runtime(self._runtime)
            locked = True
        except:
            locked = False
        lua.luaL_unref(L, lua.LUA_REGISTRYINDEX, self._ref)
        if locked:
            unlock_runtime(self._runtime)
        # undo additional INCREF at instantiation time
        cpython.ref.Py_DECREF(self._runtime)

    cdef inline int push_lua_object(self) except -1:
        cdef lua_State* L = self._state
        lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, self._ref)
        if lua.lua_isnil(L, -1):
            lua.lua_pop(L, 1)
            raise LuaError("lost reference")

    def __call__(self, *args):
        assert self._runtime is not None
        cdef lua_State* L = self._state
        lock_runtime(self._runtime)
        try:
            lua.lua_settop(L, 0)
            self.push_lua_object()
            return call_lua(self._runtime, L, args)
        finally:
            unlock_runtime(self._runtime)

    def __len__(self):
        assert self._runtime is not None
        cdef lua_State* L = self._state
        lock_runtime(self._runtime)
        try:
            self.push_lua_object()
            return lua.lua_objlen(L, -1)
        finally:
            lua.lua_settop(L, 0)
            unlock_runtime(self._runtime)

    def __nonzero__(self):
        return True

    def __iter__(self):
        raise TypeError("iteration is only supported for tables")

    def __repr__(self):
        assert self._runtime is not None
        cdef lua_State* L = self._state
        encoding = self._runtime._encoding.decode('ASCII') if self._runtime._encoding else 'UTF-8'
        lock_runtime(self._runtime)
        try:
            self.push_lua_object()
            return lua_object_repr(L, encoding)
        finally:
            lua.lua_pop(L, 1)
            unlock_runtime(self._runtime)

    def __str__(self):
        assert self._runtime is not None
        cdef lua_State* L = self._state
        cdef unicode py_string = None
        cdef const_char_ptr s
        cdef size_t size
        encoding = self._runtime._encoding.decode('ASCII') if self._runtime._encoding else 'UTF-8'
        lock_runtime(self._runtime)
        try:
            self.push_lua_object()
            # lookup and call "__tostring" metatable method manually to catch any errors
            if lua.lua_getmetatable(L, -1):
                lua.lua_pushlstring(L, "__tostring", 10)
                lua.lua_rawget(L, -2)
                if not lua.lua_isnil(L, -1) and lua.lua_pcall(L, 1, 1, 0) == 0:
                    s = lua.lua_tolstring(L, -1, &size)
                    if s:
                        try:
                            py_string = s[:size].decode(encoding)
                        except UnicodeDecodeError:
                            # safe 'decode'
                            py_string = s[:size].decode('ISO-8859-1')
            if py_string is None:
                lua.lua_settop(L, 1)
                py_string = lua_object_repr(L, encoding)
        finally:
            lua.lua_settop(L, 0)
            unlock_runtime(self._runtime)
        return py_string

    def __getattr__(self, name):
        assert self._runtime is not None
        cdef lua_State* L = self._state
        if isinstance(name, unicode):
            if (<unicode>name).startswith(u'__') and (<unicode>name).endswith(u'__'):
                return object.__getattr__(self, name)
            name = (<unicode>name).encode(self._runtime._source_encoding)
        elif isinstance(name, bytes) and (<bytes>name).startswith(b'__') and (<bytes>name).endswith(b'__'):
            return object.__getattr__(self, name)
        lock_runtime(self._runtime)
        try:
            self.push_lua_object()
            if lua.lua_isfunction(L, -1):
                lua.lua_pop(L, 1)
                raise TypeError("item/attribute access not supported on functions")
            py_to_lua(self._runtime, L, name, 1)
            lua.lua_gettable(L, -2)
            return py_from_lua(self._runtime, L, -1)
        finally:
            lua.lua_settop(L, 0)
            unlock_runtime(self._runtime)

    def __setattr__(self, name, value):
        assert self._runtime is not None
        cdef lua_State* L = self._state
        if isinstance(name, unicode):
            if (<unicode>name).startswith(u'__') and (<unicode>name).endswith(u'__'):
                object.__setattr__(self, name, value)
            name = (<unicode>name).encode(self._runtime._source_encoding)
        elif isinstance(name, bytes) and (<bytes>name).startswith(b'__') and (<bytes>name).endswith(b'__'):
            object.__setattr__(self, name, value)
        lock_runtime(self._runtime)
        try:
            self.push_lua_object()
            if not lua.lua_istable(L, -1):
                lua.lua_pop(L, -1)
                raise TypeError("Lua object is not a table")
            try:
                py_to_lua(self._runtime, L, name, 1)
                py_to_lua(self._runtime, L, value, 1)
                lua.lua_settable(L, -3)
            finally:
                lua.lua_settop(L, 0)
        finally:
            unlock_runtime(self._runtime)

    def __getitem__(self, index_or_name):
        return self.__getattr__(index_or_name)

    def __setitem__(self, index_or_name, value):
        self.__setattr__(index_or_name, value)


cdef _LuaObject new_lua_object(LuaRuntime runtime, lua_State* L, int n):
    cdef _LuaObject obj = _LuaObject.__new__(_LuaObject)
    init_lua_object(obj, runtime, L, n)
    return obj

cdef void init_lua_object(_LuaObject obj, LuaRuntime runtime, lua_State* L, int n):
    # additional INCREF to keep runtime from disappearing in GC runs
    cpython.ref.Py_INCREF(runtime)
    obj._runtime = runtime
    obj._state = L
    lua.lua_pushvalue(L, n)
    obj._ref = lua.luaL_ref(L, lua.LUA_REGISTRYINDEX)

cdef object lua_object_repr(lua_State* L, encoding):
    cdef bytes py_bytes
    lua_type = lua.lua_type(L, -1)
    if lua_type in (lua.LUA_TTABLE, lua.LUA_TFUNCTION):
        ptr = <void*>lua.lua_topointer(L, -1)
    elif lua_type in (lua.LUA_TUSERDATA, lua.LUA_TLIGHTUSERDATA):
        ptr = <void*>lua.lua_touserdata(L, -1)
    elif lua_type == lua.LUA_TTHREAD:
        ptr = <void*>lua.lua_tothread(L, -1)
    if ptr:
        py_bytes = cpython.bytes.PyBytes_FromFormat(
            "<Lua %s at %p>", lua.lua_typename(L, lua_type), ptr)
    else:
        py_bytes = cpython.bytes.PyBytes_FromFormat(
            "<Lua %s>", lua.lua_typename(L, lua_type))
    try:
        return py_bytes.decode(encoding)
    except UnicodeDecodeError:
        # safe 'decode'
        return py_bytes.decode('ISO-8859-1')


cdef class _LuaTable(_LuaObject):
    def __iter__(self):
        return _LuaIter(self, KEYS)

    def keys(self):
        """Returns an iterator over the keys of a table that this
        object represents.  Same as iter(obj).
        """
        return _LuaIter(self, KEYS)

    def values(self):
        """Returns an iterator over the values of a table that this
        object represents.
        """
        return _LuaIter(self, VALUES)

    def items(self):
        """Returns an iterator over the key-value pairs of a table
        that this object represents.
        """
        return _LuaIter(self, ITEMS)

cdef _LuaTable new_lua_table(LuaRuntime runtime, lua_State* L, int n):
    cdef _LuaTable obj = _LuaTable.__new__(_LuaTable)
    init_lua_object(obj, runtime, L, n)
    return obj


cdef class _LuaFunction(_LuaObject):
    """A Lua function (which may become a coroutine).
    """
    def coroutine(self, *args):
        """Create a Lua coroutine from a Lua function and call it with
        the passed parameters to start it up.
        """
        assert self._runtime is not None
        cdef lua_State* L = self._state
        cdef lua_State* co
        cdef _LuaThread thread
        lock_runtime(self._runtime)
        try:
            self.push_lua_object()
            if not lua.lua_isfunction(L, -1) or lua.lua_iscfunction(L, -1):
                raise TypeError("Lua object is not a function")
            # create thread stack and push the function on it
            co = lua.lua_newthread(L)
            lua.lua_pushvalue(L, 1)
            lua.lua_xmove(L, co, 1)
            # create the coroutine object and initialise it
            assert lua.lua_isthread(L, -1)
            thread = new_lua_thread(self._runtime, L, -1)
            thread._arguments = args # always a tuple, not None !
            return thread
        finally:
            lua.lua_settop(L, 0)
            unlock_runtime(self._runtime)

cdef _LuaFunction new_lua_function(LuaRuntime runtime, lua_State* L, int n):
    cdef _LuaFunction obj = _LuaFunction.__new__(_LuaFunction)
    init_lua_object(obj, runtime, L, n)
    return obj


cdef class _LuaCoroutineFunction(_LuaFunction):
    """A function that returns a new coroutine when called.
    """
    def __call__(self, *args):
        return self.coroutine(*args)

cdef _LuaCoroutineFunction new_lua_coroutine_function(LuaRuntime runtime, lua_State* L, int n):
    cdef _LuaCoroutineFunction obj = _LuaCoroutineFunction.__new__(_LuaCoroutineFunction)
    init_lua_object(obj, runtime, L, n)
    return obj


cdef class _LuaThread(_LuaObject):
    """A Lua thread (coroutine).
    """
    cdef lua_State* _co_state
    cdef tuple _arguments
    def __iter__(self):
        return self

    def __next__(self):
        assert self._runtime is not None
        cdef tuple args = self._arguments
        if args is not None:
            self._arguments = None
        return resume_lua_thread(self, args)

    def send(self, value):
        """Send a value into the coroutine.  If the value is a tuple,
        send the unpacked elements.
        """
        if value is not None:
            if self._arguments is not None:
                raise TypeError("can't send non-None value to a just-started generator")
            if not isinstance(value, tuple):
                value = (value,)
        elif self._arguments is not None:
            value = self._arguments
            self._arguments = None
        return resume_lua_thread(self, <tuple>value)

    def __bool__(self):
        cdef lua.lua_Debug dummy
        assert self._runtime is not None
        cdef int status = lua.lua_status(self._co_state)
        if status == lua.LUA_YIELD:
            return True
        if status == 0:
            # copied from Lua code: check for frames
            if lua.lua_getstack(self._co_state, 0, &dummy) > 0:
                return True # currently running
            elif lua.lua_gettop(self._co_state) > 0:
                return True # not started yet
        return False

cdef _LuaThread new_lua_thread(LuaRuntime runtime, lua_State* L, int n):
    cdef _LuaThread obj = _LuaThread.__new__(_LuaThread)
    init_lua_object(obj, runtime, L, n)
    obj._co_state = lua.lua_tothread(L, n)
    return obj


cdef _LuaObject new_lua_thread_or_function(LuaRuntime runtime, lua_State* L, int n):
    # this is special - we replace a new (unstarted) thread by its
    # underlying function to better follow Python's own generator
    # protocol
    cdef lua_State* co = lua.lua_tothread(L, n)
    assert co is not NULL
    if lua.lua_status(co) == 0 and lua.lua_gettop(co) == 1:
        # not started yet => get the function and return that
        lua.lua_pushvalue(co, 1)
        lua.lua_xmove(co, L, 1)
        try:
            return new_lua_coroutine_function(runtime, L, -1)
        finally:
            lua.lua_pop(L, 1)
    else:
        # already started => wrap the thread
        return new_lua_thread(runtime, L, n)


cdef object resume_lua_thread(_LuaThread thread, tuple args):
    cdef lua_State* co = thread._co_state
    cdef int result, i, nargs = 0
    lock_runtime(thread._runtime)
    try:
        if lua.lua_status(co) == 0 and lua.lua_gettop(co) == 0:
            # already terminated
            raise StopIteration
        if args:
            nargs = len(args)
            push_lua_arguments(thread._runtime, co, args, 0)
        with nogil:
            result = lua.lua_resume(co, nargs)
        if result != lua.LUA_YIELD:
            if result == 0:
                # terminated
                if lua.lua_gettop(co) == 0:
                    # no values left to return
                    raise StopIteration
            else:
                raise_lua_error(thread._runtime, co, result)
        return unpack_lua_results(thread._runtime, co)
    finally:
        lua.lua_settop(co, 0)
        unlock_runtime(thread._runtime)


cdef enum:
    KEYS = 1
    VALUES = 2
    ITEMS = 3

cdef class _LuaIter:
    cdef LuaRuntime _runtime
    cdef _LuaObject _obj
    cdef lua_State* _state
    cdef int _refiter
    cdef char _what

    def __cinit__(self, _LuaObject obj not None, int what):
        assert obj._runtime is not None
        self._runtime = obj._runtime
        # additional INCREF to keep object from disappearing in GC runs
        cpython.ref.Py_INCREF(obj)

        self._obj = obj
        self._state = obj._state
        self._refiter = 0
        self._what = what

    def __dealloc__(self):
        if self._runtime is None:
            return
        cdef lua_State* L = self._state
        if self._refiter:
            try:
                lock_runtime(self._runtime)
                locked = True
            except:
                locked = False
            lua.luaL_unref(L, lua.LUA_REGISTRYINDEX, self._refiter)
            if locked:
                unlock_runtime(self._runtime)
        # undo additional INCREF at instantiation time
        cpython.ref.Py_DECREF(self._obj)

    def __repr__(self):
        return u"LuaIter(%r)" % (self._obj)

    def __iter__(self):
        return self

    def __next__(self):
        if self._obj is None:
            raise StopIteration
        cdef lua_State* L = self._obj._state
        lock_runtime(self._runtime)
        try:
            if self._obj is None:
                raise StopIteration
            # iterable object
            lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, self._obj._ref)
            if not lua.lua_istable(L, -1):
                if lua.lua_isnil(L, -1):
                    lua.lua_pop(L, 1)
                    raise LuaError("lost reference")
                raise TypeError(cpython.bytes.PyBytes_FromFormat(
                    "cannot iterate over non-table (found Lua %s)",
                    lua.lua_typename(L, lua.lua_type(L, -1))))
            if not self._refiter:
                # initial key
                lua.lua_pushnil(L)
            else:
                # last key
                lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, self._refiter)
            if lua.lua_next(L, -2):
                try:
                    if self._what == KEYS:
                        retval = py_from_lua(self._runtime, L, -2)
                    elif self._what == VALUES:
                        retval = py_from_lua(self._runtime, L, -1)
                    else: # ITEMS
                        retval = (py_from_lua(self._runtime, L, -2), py_from_lua(self._runtime, L, -1))
                finally:
                    # pop value
                    lua.lua_pop(L, 1)
                    # pop and store key
                    if not self._refiter:
                        self._refiter = lua.luaL_ref(L, lua.LUA_REGISTRYINDEX)
                    else:
                        lua.lua_rawseti(L, lua.LUA_REGISTRYINDEX, self._refiter)
                return retval
            # iteration done, clean up
            if self._refiter:
                lua.luaL_unref(L, lua.LUA_REGISTRYINDEX, self._refiter)
                self._refiter = 0
            self._obj = None
        finally:
            lua.lua_settop(L, 0)
            unlock_runtime(self._runtime)
        raise StopIteration

# type conversions and protocol adaptations

cdef int py_asfunc_call(lua_State *L) nogil:
    if lua.lua_gettop(L) == 1 and lua.lua_islightuserdata(L, 1) \
       and lua.lua_topointer(L, 1) == <void*>unpack_wrapped_pyfunction:
        # special case: unwrap_lua_object() calls this to find out the Python object
        lua.lua_pushvalue(L, lua.lua_upvalueindex(1))
        return 1
    lua.lua_pushvalue(L, lua.lua_upvalueindex(1))
    lua.lua_insert(L, 1)
    return py_object_call(L)

cdef py_object* unpack_wrapped_pyfunction(lua_State* L, int n) nogil:
    cdef lua.lua_CFunction cfunction = lua.lua_tocfunction(L, n)
    if cfunction is <lua.lua_CFunction>py_asfunc_call:
        lua.lua_pushvalue(L, n)
        lua.lua_pushlightuserdata(L, <void*>unpack_wrapped_pyfunction)
        if lua.lua_pcall(L, 1, 1, 0) == 0:
            return <py_object*> lua.luaL_checkudata(L, -1, POBJECT) # doesn't return on error!
    return NULL

cdef class _PyProtocolWrapper:
    cdef object _obj
    cdef int _type_flags
    def __cinit__(self):
        self._type_flags = 0
    def __init__(self):
        raise TypeError("Type cannot be instantiated from Python")

def as_attrgetter(obj):
    cdef _PyProtocolWrapper wrap = _PyProtocolWrapper.__new__(_PyProtocolWrapper)
    wrap._obj = obj
    wrap._type_flags = 0
    return wrap

def as_itemgetter(obj):
    cdef _PyProtocolWrapper wrap = _PyProtocolWrapper.__new__(_PyProtocolWrapper)
    wrap._obj = obj
    wrap._type_flags = OBJ_AS_INDEX
    return wrap

cdef object py_from_lua(LuaRuntime runtime, lua_State *L, int n):
    cdef size_t size
    cdef const_char_ptr s
    cdef lua.lua_Number number
    cdef py_object* py_obj
    cdef int lua_type = lua.lua_type(L, n)

    if lua_type == lua.LUA_TNIL:
        return None
    elif lua_type == lua.LUA_TNUMBER:
        number = lua.lua_tonumber(L, n)
        if number != <long>number:
            return <double>number
        else:
            return <long>number
    elif lua_type == lua.LUA_TSTRING:
        s = lua.lua_tolstring(L, n, &size)
        if runtime._encoding is not None:
            return s[:size].decode(runtime._encoding)
        else:
            return s[:size]
    elif lua_type == lua.LUA_TBOOLEAN:
        return lua.lua_toboolean(L, n)
    elif lua_type == lua.LUA_TUSERDATA:
        py_obj = <py_object*>lua.luaL_checkudata(L, n, POBJECT) # FIXME: doesn't return on error!
        if py_obj:
            return <object>py_obj.obj
    elif lua_type == lua.LUA_TTABLE:
        return new_lua_table(runtime, L, n)
    elif lua_type == lua.LUA_TTHREAD:
        return new_lua_thread_or_function(runtime, L, n)
    elif lua_type == lua.LUA_TFUNCTION:
        py_obj = unpack_wrapped_pyfunction(L, n)
        if py_obj:
            return <object>py_obj.obj
        return new_lua_function(runtime, L, n)
    return new_lua_object(runtime, L, n)

cdef int py_to_lua(LuaRuntime runtime, lua_State *L, object o, bint withnone) except -1:
    cdef int pushed_values_count = 0
    cdef int type_flags = 0

    if o is None:
        if withnone:
            lua.lua_pushlstring(L, "Py_None", 7)
            lua.lua_rawget(L, lua.LUA_REGISTRYINDEX)
            if lua.lua_isnil(L, -1):
                lua.lua_pop(L, 1)
                return 0
            pushed_values_count = 1
        else:
            # Not really needed, but this way we may check for errors
            # with pushed_values_count == 0.
            lua.lua_pushnil(L)
            pushed_values_count = 1
    elif type(o) is bool:
        lua.lua_pushboolean(L, <bint>o)
        pushed_values_count = 1
    elif type(o) is float:
        lua.lua_pushnumber(L, <lua.lua_Number>cpython.float.PyFloat_AS_DOUBLE(o))
        pushed_values_count = 1
    elif isinstance(o, long):
        lua.lua_pushnumber(L, <lua.lua_Number>cpython.long.PyLong_AsDouble(o))
        pushed_values_count = 1
    elif PY_MAJOR_VERSION < 3 and isinstance(o, int):
        lua.lua_pushnumber(L, <lua.lua_Number><long>o)
        pushed_values_count = 1
    elif isinstance(o, bytes):
        lua.lua_pushlstring(L, <char*>(<bytes>o), len(<bytes>o))
        pushed_values_count = 1
    elif isinstance(o, unicode) and runtime._encoding is not None:
        pushed_values_count = push_encoded_unicode_string(runtime, L, <unicode>o)
    elif isinstance(o, _LuaObject):
        if (<_LuaObject>o)._runtime is not runtime:
            raise LuaError("cannot mix objects from different Lua runtimes")
        lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, (<_LuaObject>o)._ref)
        pushed_values_count = 1
    elif isinstance(o, float):
        lua.lua_pushnumber(L, <lua.lua_Number><double>o)
        pushed_values_count = 1
    else:
        if isinstance(o, _PyProtocolWrapper):
            type_flags = (<_PyProtocolWrapper>o)._type_flags
            o = (<_PyProtocolWrapper>o)._obj
        else:
            # prefer __getitem__ over __getattr__ by default
            type_flags = OBJ_AS_INDEX if hasattr(o, '__getitem__') else 0
        pushed_values_count = py_to_lua_custom(runtime, L, o, type_flags)
    return pushed_values_count

cdef int push_encoded_unicode_string(LuaRuntime runtime, lua_State *L, unicode ustring) except -1:
    cdef bytes bytes_string = ustring.encode(runtime._encoding)
    lua.lua_pushlstring(L, <char*>bytes_string, len(bytes_string))
    return 1

cdef bint py_to_lua_custom(LuaRuntime runtime, lua_State *L, object o, int type_flags):
    cdef py_object *py_obj = <py_object*> lua.lua_newuserdata(L, sizeof(py_object))
    if not py_obj:
        return 0 # values pushed
    cpython.ref.Py_INCREF(o)
    py_obj.obj = <PyObject*>o
    py_obj.runtime = <PyObject*>runtime
    py_obj.type_flags = type_flags
    lua.luaL_getmetatable(L, POBJECT)
    lua.lua_setmetatable(L, -2)
    return 1 # values pushed

# error handling

cdef int raise_lua_error(LuaRuntime runtime, lua_State* L, int result) except -1:
    if result == 0:
        return 0
    elif result == lua.LUA_ERRMEM:
        cpython.exc.PyErr_NoMemory()
    else:
        raise LuaError( build_lua_error_message(runtime, L, None, -1) )

cdef build_lua_error_message(LuaRuntime runtime, lua_State* L, unicode err_message, int n):
    cdef size_t size
    cdef const_char_ptr s = lua.lua_tolstring(L, n, &size)
    if runtime._encoding is not None:
        try:
            py_ustring = s[:size].decode(runtime._encoding)
        except UnicodeDecodeError:
            py_ustring = s[:size].decode('ISO-8859-1') # safe 'fake' decoding
    else:
        py_ustring = s[:size].decode('ISO-8859-1')
    if err_message is None:
        return py_ustring
    else:
        return err_message % py_ustring

# calling into Lua

cdef run_lua(LuaRuntime runtime, bytes lua_code):
    # locks the runtime
    cdef lua_State* L = runtime._state
    cdef bint result
    lock_runtime(runtime)
    try:
        if lua.luaL_loadbuffer(L, lua_code, len(lua_code), '<python>'):
            raise LuaSyntaxError(build_lua_error_message(
                runtime, L, u"error loading code: %s", -1))
        return execute_lua_call(runtime, L, 0)
    finally:
        # resetting the stack is required in case of a syntax error
        # above, so we repeat it here even if execute_lua_call() also
        # does it
        lua.lua_settop(L, 0)
        unlock_runtime(runtime)

cdef call_lua(LuaRuntime runtime, lua_State *L, tuple args):
    # does not lock the runtime!
    push_lua_arguments(runtime, L, args, 0)
    return execute_lua_call(runtime, L, len(args))

cdef object execute_lua_call(LuaRuntime runtime, lua_State *L, Py_ssize_t nargs):
    cdef int result_status
    try:
        # call into Lua
        with nogil:
            result_status = lua.lua_pcall(L, nargs, lua.LUA_MULTRET, 0)
        runtime.reraise_on_exception()
        if result_status:
            raise_lua_error(runtime, L, result_status)
        return unpack_lua_results(runtime, L)
    finally:
        lua.lua_settop(L, 0)

cdef int push_lua_arguments(LuaRuntime runtime, lua_State *L, tuple args, int withnone) except -1:
    cdef int i
    if args:
        for i, arg in enumerate(args):
            if not py_to_lua(runtime, L, arg, withnone):
                lua.lua_settop(L, 0)
                raise TypeError("failed to convert argument at index %d" % i)
    return 0

cdef inline object unpack_lua_results(LuaRuntime runtime, lua_State *L):
    cdef int nargs = lua.lua_gettop(L)
    if nargs == 1:
        return py_from_lua(runtime, L, 1)
    if nargs == 0:
        return None
    return unpack_multiple_lua_results(runtime, L, nargs)

cdef tuple unpack_multiple_lua_results(LuaRuntime runtime, lua_State *L, int nargs):
    cdef tuple args = cpython.tuple.PyTuple_New(nargs)
    cdef int i
    for i in range(nargs):
        arg = py_from_lua(runtime, L, i+1)
        cpython.ref.Py_INCREF(arg)
        cpython.tuple.PyTuple_SET_ITEM(args, i, arg)
    return args


################################################################################
# Python support in Lua

## The rules:
##
## Each of the following blocks of functions represents the view on a
## specific Python feature from Lua code.  As they are called from
## Lua, the entry points are 'nogil' functions that do not hold the
## GIL.  They do the basic error checking and argument unpacking and
## then hand over to a 'with gil' function that acquires the GIL on
## entry and holds it during its lifetime.  This function does the
## actual mapping of the Python feature or object to Lua.
##
## Lua's C level error handling is different from that of Python.  It
## uses long jumps instead of returning from an error function.  The
## places where this can happen are marked with a comment.  Note that
## this only never happen inside of a 'nogil' function, as a long jump
## out of a function that handles Python objects would kill their
## reference counting.


# ref-counting support for Python objects

cdef void decref_with_gil(py_object *py_obj) with gil:
    cpython.ref.Py_XDECREF(py_obj.obj)

cdef int py_object_gc(lua_State* L) nogil:
    if not lua.lua_isuserdata(L, 1):
        return 0
    cdef py_object* py_obj = <py_object*> lua.luaL_checkudata(L, 1, POBJECT) # doesn't return on error!
    if py_obj is not NULL and py_obj.obj is not NULL:
        decref_with_gil(py_obj)
    return 0

# calling Python objects

cdef bint call_python(LuaRuntime runtime, lua_State *L, py_object* py_obj) except -1:
    cdef int i, nargs = lua.lua_gettop(L) - 1
    cdef bint ret = 0

    if not py_obj:
        raise TypeError("not a python object")

    cdef tuple args = cpython.tuple.PyTuple_New(nargs)
    for i in range(nargs):
        arg = py_from_lua(runtime, L, i+2)
        cpython.ref.Py_INCREF(arg)
        cpython.tuple.PyTuple_SET_ITEM(args, i, arg)

    return py_to_lua(runtime, L, (<object>py_obj.obj)(*args), 0)

cdef int py_call_with_gil(lua_State* L, py_object *py_obj) with gil:
    cdef LuaRuntime runtime = None
    try:
        runtime = <LuaRuntime?>py_obj.runtime
        return call_python(runtime, L, py_obj)
    except:
        try: runtime.store_raised_exception()
        except: pass
        return -1

cdef int py_object_call(lua_State* L) nogil:
    cdef py_object* py_obj = unwrap_lua_object(L, 1) # may not return on error!
    if not py_obj:
        return lua.luaL_argerror(L, 1, "not a python object")  # never returns!

    result = py_call_with_gil(L, py_obj)
    if result < 0:
        return lua.luaL_error(L, 'error during Python call')  # never returns!
    return result

# str() support for Python objects

cdef int py_str_with_gil(lua_State* L, py_object* py_obj) with gil:
    cdef LuaRuntime runtime
    try:
        runtime = <LuaRuntime?>py_obj.runtime
        s = str(<object>py_obj.obj)
        if isinstance(s, unicode):
            s = (<unicode>s).encode(runtime._encoding)
        else:
            assert isinstance(s, bytes)
        lua.lua_pushlstring(L, <bytes>s, len(<bytes>s))
        return 1 # returning 1 value
    except:
        try: runtime.store_raised_exception()
        except: pass
        return -1

cdef int py_object_str(lua_State* L) nogil:
    cdef py_object* py_obj = unwrap_lua_object(L, 1) # may not return on error!
    if not py_obj:
        return lua.luaL_argerror(L, 1, "not a python object")   # never returns!
    result = py_str_with_gil(L, py_obj)
    if result < 0:
        return lua.luaL_error(L, 'error during Python str() call')  # never returns!
    return result

# item access for Python objects

cdef int getitem_for_lua(LuaRuntime runtime, lua_State* L, py_object* py_obj, int key_n) except -1:
    return py_to_lua(runtime, L,
                     (<object>py_obj.obj)[ py_from_lua(runtime, L, key_n) ], 1)

cdef int setitem_for_lua(LuaRuntime runtime, lua_State* L, py_object* py_obj, int key_n, int value_n) except -1:
    (<object>py_obj.obj)[ py_from_lua(runtime, L, key_n) ] = py_from_lua(runtime, L, value_n)
    return 0

cdef int getattr_for_lua(LuaRuntime runtime, lua_State* L, py_object* py_obj, int key_n) except -1:
    return py_to_lua(runtime, L,
                     getattr(<object>py_obj.obj, py_from_lua(runtime, L, key_n)), 1)

cdef int setattr_for_lua(LuaRuntime runtime, lua_State* L, py_object* py_obj, int key_n, int value_n) except -1:
    setattr(<object>py_obj.obj, py_from_lua(runtime, L, key_n), py_from_lua(runtime, L, value_n))
    return 0


cdef int py_object_getindex_with_gil(lua_State* L, py_object* py_obj) with gil:
    cdef LuaRuntime runtime
    try:
        runtime = <LuaRuntime?>py_obj.runtime
        if py_obj.type_flags & OBJ_AS_INDEX:
            return getitem_for_lua(runtime, L, py_obj, 2)
        else:
            return getattr_for_lua(runtime, L, py_obj, 2)
    except:
        try: runtime.store_raised_exception()
        except: pass
        return -1

cdef int py_object_getindex(lua_State* L) nogil:
    cdef py_object* py_obj = unwrap_lua_object(L, 1) # may not return on error!
    if not py_obj:
        return lua.luaL_argerror(L, 1, "not a python object")   # never returns!
    result = py_object_getindex_with_gil(L, py_obj)
    if result < 0:
        return lua.luaL_error(L, 'error during Python str() call')  # never returns!
    return result


cdef int py_object_setindex_with_gil(lua_State* L, py_object* py_obj) with gil:
    cdef LuaRuntime runtime
    try:
        runtime = <LuaRuntime?>py_obj.runtime
        if py_obj.type_flags & OBJ_AS_INDEX:
            return setitem_for_lua(runtime, L, py_obj, 2, 3)
        else:
            return setattr_for_lua(runtime, L, py_obj, 2, 3)
    except:
        try: runtime.store_raised_exception()
        except: pass
        return -1

cdef int py_object_setindex(lua_State* L) nogil:
    cdef py_object* py_obj = unwrap_lua_object(L, 1) # may not return on error!
    if not py_obj:
        return lua.luaL_argerror(L, 1, "not a python object")   # never returns!
    result = py_object_setindex_with_gil(L, py_obj)
    if result < 0:
        return lua.luaL_error(L, 'error during Python str() call')  # never returns!
    return result

# special methods for Lua wrapped Python objects

cdef lua.luaL_Reg py_object_lib[6]
py_object_lib[0] = lua.luaL_Reg(name = "__call",     func = <lua.lua_CFunction> py_object_call)
py_object_lib[1] = lua.luaL_Reg(name = "__index",    func = <lua.lua_CFunction> py_object_getindex)
py_object_lib[2] = lua.luaL_Reg(name = "__newindex", func = <lua.lua_CFunction> py_object_setindex)
py_object_lib[3] = lua.luaL_Reg(name = "__tostring", func = <lua.lua_CFunction> py_object_str)
py_object_lib[4] = lua.luaL_Reg(name = "__gc",       func = <lua.lua_CFunction> py_object_gc)
py_object_lib[5] = lua.luaL_Reg(name = NULL, func = NULL)

## # Python helper functions for Lua

cdef inline py_object* unpack_single_python_argument_or_jump(lua_State* L) nogil:
    if lua.lua_gettop(L) > 1:
        lua.luaL_argerror(L, 2, "invalid arguments")   # never returns!
    cdef py_object* py_obj = unwrap_lua_object(L, 1)
    if not py_obj:
        lua.luaL_argerror(L, 1, "not a python object")   # never returns!
    return py_obj

cdef py_object* unwrap_lua_object(lua_State* L, int n) nogil:
    if lua.lua_isuserdata(L, n):
        return <py_object*> lua.luaL_checkudata(L, n, POBJECT) # doesn't return on error!
    else:
        return unpack_wrapped_pyfunction(L, n)

cdef py_object* unwrap_lua_object_from_cclosure(lua_State* L, int n) nogil:
    cdef py_object* userdata = <py_object*> lua.lua_touserdata(L, lua.lua_upvalueindex(n))
    if userdata:
        return userdata
    else:
        return unpack_wrapped_pyfunction(L, lua.lua_upvalueindex(n))

cdef int py_wrap_object_protocol_with_gil(lua_State* L, py_object* py_obj, int type_flags) with gil:
    cdef LuaRuntime runtime
    try:
        runtime = <LuaRuntime?>py_obj.runtime
        return py_to_lua_custom(runtime, L, <object>py_obj.obj, type_flags)
    except:
        try: runtime.store_raised_exception()
        except: pass
        return -1

cdef int py_wrap_object_protocol(lua_State* L, int type_flags) nogil:
    cdef py_object* py_obj = unpack_single_python_argument_or_jump(L) # never returns on error!
    result = py_wrap_object_protocol_with_gil(L, py_obj, type_flags)
    if result < 0:
        return lua.luaL_error(L, 'error during type adaptation')  # never returns!
    return result

cdef int py_as_attrgetter(lua_State* L) nogil:
    return py_wrap_object_protocol(L, 0)

cdef int py_as_itemgetter(lua_State* L) nogil:
    return py_wrap_object_protocol(L, OBJ_AS_INDEX)

cdef int py_as_function(lua_State* L) nogil:
    cdef py_object* py_obj = unpack_single_python_argument_or_jump(L) # never returns on error!
    lua.lua_pushcclosure(L, <lua.lua_CFunction>py_asfunc_call, 1)
    return 1

# iteration support for Python objects in Lua

cdef int py_iter(lua_State* L) nogil:
    cdef py_object* py_obj = unpack_single_python_argument_or_jump(L) # never returns on error!
    result = py_iter_with_gil(L, py_obj, 0)
    if result < 0:
        return lua.luaL_error(L, 'error creating an iterator')  # never returns!
    return result

cdef int py_iterex(lua_State* L) nogil:
    cdef py_object* py_obj = unpack_single_python_argument_or_jump(L) # never returns on error!
    result = py_iter_with_gil(L, py_obj, OBJ_UNPACK_TUPLE)
    if result < 0:
        return lua.luaL_error(L, 'error creating an iterator')  # never returns!
    return result

cdef int py_enumerate(lua_State* L) nogil:
    if lua.lua_gettop(L) > 2:
        lua.luaL_argerror(L, 3, "invalid arguments")   # never returns!
    cdef py_object* py_obj = unwrap_lua_object(L, 1)
    if not py_obj:
        lua.luaL_argerror(L, 1, "not a python object")   # never returns!
    cdef double start = lua.lua_tonumber(L, -1) if lua.lua_gettop(L) == 2 else 0.0
    result = py_enumerate_with_gil(L, py_obj, start)
    if result < 0:
        return lua.luaL_error(L, 'error creating an iterator with enumerate()')  # never returns!
    return result


cdef int py_enumerate_with_gil(lua_State* L, py_object* py_obj, double start) with gil:
    cdef LuaRuntime runtime
    try:
        runtime = <LuaRuntime?>py_obj.runtime
        obj = iter(<object>py_obj.obj)
        return py_push_iterator(runtime, L, obj, OBJ_ENUMERATOR, start - 1.0)
    except:
        try: runtime.store_raised_exception()
        except: pass
        return -1

cdef int py_iter_with_gil(lua_State* L, py_object* py_obj, int type_flags) with gil:
    cdef LuaRuntime runtime
    try:
        runtime = <LuaRuntime?>py_obj.runtime
        obj = iter(<object>py_obj.obj)
        return py_push_iterator(runtime, L, obj, type_flags, 0.0)
    except:
        try: runtime.store_raised_exception()
        except: pass
        return -1

cdef int py_push_iterator(LuaRuntime runtime, lua_State* L, iterator, int type_flags, double initial_value):
    # push the wrapped iterator object into the C closure
    if py_to_lua_custom(runtime, L, iterator, type_flags) < 1:
        return -1
    lua.lua_pushcclosure(L, <lua.lua_CFunction>py_iter_next, 1)
    # Lua needs three values: iterator C function + state + last iter value
    lua.lua_pushnil(L)
    if (type_flags & OBJ_ENUMERATOR):
        lua.lua_pushnumber(L, initial_value)
    else:
        lua.lua_pushnil(L)
    return 3

cdef int py_iter_next(lua_State* L) nogil:
    # first value in the C closure: the Python iterator object
    cdef py_object* py_obj = unwrap_lua_object_from_cclosure(L, 1)
    if not py_obj:
        return lua.luaL_argerror(L, 1, "not a python object")   # never returns!
    result = py_iter_next_with_gil(L, py_obj)
    if result < 0:
        return lua.luaL_error(L, 'error while calling next(iterator)')  # never returns!
    return result

cdef int py_iter_next_with_gil(lua_State* L, py_object* py_iter) with gil:
    cdef LuaRuntime runtime
    try:
        runtime = <LuaRuntime?>py_iter.runtime
        if PY_VERSION_HEX >= 0x02060000:
            obj = next(<object>py_iter.obj)
        else:
            obj = (<object>py_iter.obj).next()
        if (py_iter.type_flags & OBJ_UNPACK_TUPLE) and isinstance(obj, tuple):
            # special case: when the iterable returns a tuple, unpack it
            push_lua_arguments(runtime, L, <tuple>obj, 1)
            return len(<tuple>obj)
        elif (py_iter.type_flags & OBJ_ENUMERATOR):
            lua.lua_pushnumber(L, lua.lua_tonumber(L, -1) + 1.0)
        result = py_to_lua(runtime, L, obj, 1)
        if result < 1:
            return -1
        if (py_iter.type_flags & OBJ_ENUMERATOR):
            result += 1
        return result
    except StopIteration:
        lua.lua_pushnil(L)
        return 1
    except:
        try: runtime.store_raised_exception()
        except: pass
        return -1

# 'python' module functions in Lua

cdef lua.luaL_Reg py_lib[7]
py_lib[0] = lua.luaL_Reg(name = "as_attrgetter", func = <lua.lua_CFunction> py_as_attrgetter)
py_lib[1] = lua.luaL_Reg(name = "as_itemgetter", func = <lua.lua_CFunction> py_as_itemgetter)
py_lib[2] = lua.luaL_Reg(name = "as_function", func = <lua.lua_CFunction> py_as_function)
py_lib[3] = lua.luaL_Reg(name = "iter", func = <lua.lua_CFunction> py_iter)
py_lib[4] = lua.luaL_Reg(name = "iterex", func = <lua.lua_CFunction> py_iterex)
py_lib[5] = lua.luaL_Reg(name = "enumerate", func = <lua.lua_CFunction> py_enumerate)
py_lib[6] = lua.luaL_Reg(name = NULL, func = NULL)
