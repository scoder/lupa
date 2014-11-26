# cython: embedsignature=True, binding=True

"""
A fast Python wrapper around Lua and LuaJIT2.
"""

from __future__ import absolute_import

cimport cython

from lupa cimport lua
from .lua cimport lua_State

cimport cpython.ref
cimport cpython.tuple
cimport cpython.float
cimport cpython.long
from cpython.ref cimport PyObject
from cpython.method cimport (
    PyMethod_Check, PyMethod_GET_SELF, PyMethod_GET_FUNCTION)
from cpython.version cimport PY_MAJOR_VERSION
from cpython.bytes cimport PyBytes_FromFormat

from libc.stdint cimport uintptr_t

cdef extern from *:
    ctypedef char* const_char_ptr "const char*"

cdef object exc_info
from sys import exc_info

cdef object Mapping
from collections import Mapping

cdef object wraps
from functools import wraps


__all__ = ['LuaRuntime', 'LuaError', 'LuaSyntaxError',
           'as_itemgetter', 'as_attrgetter', 'lua_type',
           'unpacks_lua_table', 'unpacks_lua_table_method']

cdef object builtins
try:
    import __builtin__ as builtins
except ImportError:
    import builtins

DEF POBJECT = "POBJECT" # as used by LunaticPython


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


class LuaSyntaxError(LuaError):
    """Syntax error in Lua code.
    """


def lua_type(obj):
    """
    Return the Lua type name of a wrapped object as string, as provided
    by Lua's type() function.

    For non-wrapper objects (i.e. normal Python objects), returns None.
    """
    if not isinstance(obj, _LuaObject):
        return None
    lua_object = <_LuaObject>obj
    assert lua_object._runtime is not None
    lock_runtime(lua_object._runtime)
    L = lua_object._state
    old_top = lua.lua_gettop(L)
    cdef const char* lua_type_name
    try:
        lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, lua_object._ref)
        ltype = lua.lua_type(L, -1)
        if ltype == lua.LUA_TTABLE:
            return 'table'
        elif ltype == lua.LUA_TFUNCTION:
            return 'function'
        elif ltype == lua.LUA_TTHREAD:
            return 'thread'
        elif ltype in (lua.LUA_TUSERDATA, lua.LUA_TLIGHTUSERDATA):
            return 'userdata'
        else:
            lua_type_name = lua.lua_typename(L, ltype)
            return lua_type_name.decode('ascii') if PY_MAJOR_VERSION >= 3 else lua_type_name
    finally:
        lua.lua_settop(L, old_top)
        unlock_runtime(lua_object._runtime)


@cython.no_gc_clear
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

    * ``attribute_filter``: filter function for attribute access
      (get/set).  Must have the signature ``func(obj, attr_name,
      is_setting)``, where ``is_setting`` is True when the attribute
      is being set.  If provided, the function will be called for all
      Python object attributes that are being accessed from Lua code.
      Normally, it should return an attribute name that will then be
      used for the lookup.  If it wants to prevent access, it should
      raise an ``AttributeError``.  Note that Lua does not guarantee
      that the names will be strings.  (New in Lupa 0.20)

    * ``attribute_handlers``: like ``attribute_filter`` above, but
      handles the getting/setting itself rather than giving hints
      to the LuaRuntime.  This must be a 2-tuple, ``(getter, setter)``
      where ``getter`` has the signature ``func(obj, attr_name)``
      and either returns the value for ``obj.attr_name`` or raises an
      ``AttributeError``  The function ``setter`` has the signature
      ``func(obj, attr_name, value)`` and may raise an ``AttributeError``.
      The return value of the setter is unused.  (New in Lupa 1.0)

    * ``register_eval``: should Python's ``eval()`` function be available
      to Lua code as ``python.eval()``?  Note that this does not remove it
      from the builtins.  Use an ``attribute_filter`` function for that.
      (default: True)

    * ``register_builtins``: should Python's builtins be available to Lua
      code as ``python.builtins.*``?  Note that this does not prevent access
      to the globals available as special Python function attributes, for
      example.  Use an ``attribute_filter`` function for that.
      (default: True, new in Lupa 1.2)

    * ``unpack_returned_tuples``: should Python tuples be unpacked in Lua?
      If ``py_fun()`` returns ``(1, 2, 3)``, then does ``a, b, c = py_fun()``
      give ``a == 1 and b == 2 and c == 3`` or does it give
      ``a == (1,2,3), b == nil, c == nil``?  ``unpack_returned_tuples=True``
      gives the former.
      (default: False, new in Lupa 0.21)

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
    cdef dict _pyrefs_in_lua
    cdef tuple _raised_exception
    cdef bytes _encoding
    cdef bytes _source_encoding
    cdef object _attribute_filter
    cdef object _attribute_getter
    cdef object _attribute_setter
    cdef bint _unpack_returned_tuples

    def __cinit__(self, encoding='UTF-8', source_encoding=None,
                  attribute_filter=None, attribute_handlers=None,
                  bint register_eval=True, bint unpack_returned_tuples=False,
                  bint register_builtins=True):
        cdef lua_State* L = lua.luaL_newstate()
        if L is NULL:
            raise LuaError("Failed to initialise Lua runtime")
        self._state = L
        self._lock = FastRLock()
        self._pyrefs_in_lua = {}
        self._encoding = _asciiOrNone(encoding)
        self._source_encoding = _asciiOrNone(source_encoding) or self._encoding or b'UTF-8'
        if attribute_filter is not None and not callable(attribute_filter):
            raise ValueError("attribute_filter must be callable")
        self._attribute_filter = attribute_filter
        self._unpack_returned_tuples = unpack_returned_tuples

        if attribute_handlers:
            raise_error = False
            try:
                getter, setter = attribute_handlers
            except (ValueError, TypeError):
                raise_error = True
            else:
                if (getter is not None and not callable(getter) or
                        setter is not None and not callable(setter)):
                    raise_error = True
            if raise_error:
                raise ValueError("attribute_handlers must be a sequence of two callables")
            if attribute_filter and (getter is not None or setter is not None):
                raise ValueError("attribute_filter and attribute_handlers are mutually exclusive")
            self._attribute_getter, self._attribute_setter = getter, setter

        lua.luaL_openlibs(L)
        self.init_python_lib(register_eval, register_builtins)
        lua.lua_settop(L, 0)
        lua.lua_atpanic(L, <lua.lua_CFunction>1)

    def __dealloc__(self):
        if self._state is not NULL:
            lua.lua_close(self._state)
            self._state = NULL

    @cython.final
    cdef int reraise_on_exception(self) except -1:
        if self._raised_exception is not None:
            exception = self._raised_exception
            self._raised_exception = None
            raise exception[0], exception[1], exception[2]
        return 0

    @cython.final
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
        old_top = lua.lua_gettop(L)
        try:
            lua.lua_getglobal(L, 'require')
            if lua.lua_isnil(L, -1):
                raise LuaError("require is not defined")
            return call_lua(self, L, (modulename,))
        finally:
            lua.lua_settop(L, old_top)
            unlock_runtime(self)

    def globals(self):
        """Return the globals defined in this Lua runtime as a Lua
        table.
        """
        assert self._state is not NULL
        cdef lua_State *L = self._state
        lock_runtime(self)
        old_top = lua.lua_gettop(L)
        try:
            lua.lua_getglobal(L, '_G')
            if lua.lua_isnil(L, -1):
                raise LuaError("globals not defined")
            return py_from_lua(self, L, -1)
        finally:
            lua.lua_settop(L, old_top)
            unlock_runtime(self)

    def table(self, *items, **kwargs):
        """Create a new table with the provided items.  Positional
        arguments are placed in the table in order, keyword arguments
        are set as key-value pairs.
        """
        return self.table_from(items, kwargs)

    def table_from(self, *args):
        """Create a new table from Python mapping or iterable.

        table_from() accepts either a dict/mapping or an iterable with items.
        Items from dicts are set as key-value pairs; items from iterables
        are placed in the table in order.

        Nested mappings / iterables are passed to Lua as userdata
        (wrapped Python objects); they are not converted to Lua tables.
        """
        assert self._state is not NULL
        cdef lua_State *L = self._state
        cdef int i = 1
        lock_runtime(self)
        old_top = lua.lua_gettop(L)
        try:
            lua.lua_newtable(L)
            # FIXME: how to check for failure?
            for obj in args:
                if isinstance(obj, dict):
                    for key, value in obj.iteritems():
                        py_to_lua(self, L, key)
                        py_to_lua(self, L, value)
                        lua.lua_rawset(L, -3)

                elif isinstance(obj, _LuaTable):
                    # Stack:                            # tbl
                    (<_LuaObject>obj).push_lua_object() # tbl, obj
                    lua.lua_pushnil(L)                  # tbl, obj, nil       // iterate over obj (-2)
                    while lua.lua_next(L, -2):          # tbl, obj, k, v
                        lua.lua_pushvalue(L, -2)        # tbl, obj, k, v, k   // copy key (because
                        lua.lua_insert(L, -2)           # tbl, obj, k, k, v   // lua_next needs a key for iteration)
                        lua.lua_settable(L, -5)         # tbl, obj, k         // tbl[k] = v
                    lua.lua_pop(L, 1)                   # tbl                 // remove obj from stack

                elif isinstance(obj, Mapping):
                    for key in obj:
                        value = obj[key]
                        py_to_lua(self, L, key)
                        py_to_lua(self, L, value)
                        lua.lua_rawset(L, -3)
                else:
                    for arg in obj:
                        py_to_lua(self, L, arg)
                        lua.lua_rawseti(L, -2, i)
                        i += 1
            return py_from_lua(self, L, -1)
        finally:
            lua.lua_settop(L, old_top)
            unlock_runtime(self)

    @cython.final
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

    @cython.final
    cdef int init_python_lib(self, bint register_eval, bint register_builtins) except -1:
        cdef lua_State *L = self._state

        # create 'python' lib and register our own object metatable
        lua.luaL_openlib(L, "python", py_lib, 0)
        lua.luaL_newmetatable(L, POBJECT)
        lua.luaL_openlib(L, NULL, py_object_lib, 0)
        lua.lua_pop(L, 1)

        # register global names in the module
        self.register_py_object(b'Py_None',  b'none', None)
        if register_eval:
            self.register_py_object(b'eval',     b'eval', eval)
        if register_builtins:
            self.register_py_object(b'builtins', b'builtins', builtins)

        return 0  # nothing left to return on the stack


################################################################################
# decorators for calling Python functions with keyword (named) arguments
# from Lua scripts

def unpacks_lua_table(func):
    """
    A decorator to make the decorated function receive kwargs
    when it is called from Lua with a single Lua table argument.

    Python functions wrapped in this decorator can be called from Lua code
    as ``func(foo, bar)``, ``func{foo=foo, bar=bar}`` and ``func{foo, bar=bar}``.

    See also: http://lua-users.org/wiki/NamedParameters

    WARNING: avoid using this decorator for functions where the
    first argument can be a Lua table.

    WARNING: be careful with ``nil`` values.  Depending on the context,
    passing ``nil`` as a parameter can mean either "omit a parameter"
    or "pass None".  This even depends on the Lua version.  It is
    possible to use ``python.none`` instead of ``nil`` to pass None values
    robustly.
    """
    @wraps(func)
    def wrapper(*args):
        args, kwargs = _fix_args_kwargs(args)
        return func(*args, **kwargs)
    return wrapper


def unpacks_lua_table_method(meth):
    """
    This is :func:`unpacks_lua_table` for methods
    (i.e. it knows about the 'self' argument).
    """
    @wraps(meth)
    def wrapper(self, *args):
        args, kwargs = _fix_args_kwargs(args)
        return meth(self, *args, **kwargs)
    return wrapper


cdef tuple _fix_args_kwargs(tuple args):
    """
    Extract named arguments from args passed to a Python function by Lua
    script. Arguments are processed only if a single argument is passed and
    it is a table.
    """
    if len(args) != 1:
        return args, {}

    arg = args[0]
    if not isinstance(arg, _LuaTable):
        return args, {}

    table = <_LuaTable>arg

    # arguments with keys from 1 to #tbl are passed as positional
    new_args = [
        table._getitem(key, is_attr_access=False)
        for key in range(1, table._len() + 1)
    ]

    # arguments with non-integer keys are passed as named
    new_kwargs = {
        key: value for key, value in _LuaIter(table, ITEMS)
        if not isinstance(key, (int, long))
    }
    return new_args, new_kwargs


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

@cython.internal
@cython.no_gc_clear
@cython.freelist(16)
cdef class _LuaObject:
    """A wrapper around a Lua object such as a table or function.
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

    @cython.final
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
            lua.lua_settop(L, 0)
            unlock_runtime(self._runtime)

    def __len__(self):
        return self._len()

    @cython.final
    cdef size_t _len(self):
        assert self._runtime is not None
        cdef lua_State* L = self._state
        lock_runtime(self._runtime)
        size = 0
        try:
            self.push_lua_object()
            size = lua.lua_objlen(L, -1)
            lua.lua_pop(L, 1)
        finally:
            unlock_runtime(self._runtime)
        return size

    def __nonzero__(self):
        return True

    def __iter__(self):
        # if not provided, iteration will try item access and call into Lua
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
        cdef size_t size = 0
        encoding = self._runtime._encoding.decode('ASCII') if self._runtime._encoding else 'UTF-8'
        lock_runtime(self._runtime)
        old_top = lua.lua_gettop(L)
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
                lua.lua_settop(L, old_top + 1)
                py_string = lua_object_repr(L, encoding)
        finally:
            lua.lua_settop(L, old_top)
            unlock_runtime(self._runtime)
        return py_string

    def __getattr__(self, name):
        assert self._runtime is not None
        if isinstance(name, unicode):
            if (<unicode>name).startswith(u'__') and (<unicode>name).endswith(u'__'):
                return object.__getattr__(self, name)
            name = (<unicode>name).encode(self._runtime._source_encoding)
        elif isinstance(name, bytes):
            if (<bytes>name).startswith(b'__') and (<bytes>name).endswith(b'__'):
                return object.__getattr__(self, name)
        return self._getitem(name, is_attr_access=True)

    def __getitem__(self, index_or_name):
        return self._getitem(index_or_name, is_attr_access=False)

    @cython.final
    cdef _getitem(self, name, bint is_attr_access):
        cdef lua_State* L = self._state
        lock_runtime(self._runtime)
        old_top = lua.lua_gettop(L)
        try:
            self.push_lua_object()
            lua_type = lua.lua_type(L, -1)
            if lua_type == lua.LUA_TFUNCTION or lua_type == lua.LUA_TTHREAD:
                lua.lua_pop(L, 1)
                raise (AttributeError if is_attr_access else TypeError)(
                    "item/attribute access not supported on functions")
            # table[nil] fails, so map None -> python.none for Lua tables
            py_to_lua(self._runtime, L, name, wrap_none=lua_type == lua.LUA_TTABLE)
            lua.lua_gettable(L, -2)
            return py_from_lua(self._runtime, L, -1)
        finally:
            lua.lua_settop(L, old_top)
            unlock_runtime(self._runtime)


cdef _LuaObject new_lua_object(LuaRuntime runtime, lua_State* L, int n):
    cdef _LuaObject obj = _LuaObject.__new__(_LuaObject)
    init_lua_object(obj, runtime, L, n)
    return obj

cdef void init_lua_object(_LuaObject obj, LuaRuntime runtime, lua_State* L, int n):
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
    else:
        ptr = NULL
    if ptr:
        py_bytes = PyBytes_FromFormat(
            "<Lua %s at %p>", lua.lua_typename(L, lua_type), ptr)
    else:
        py_bytes = PyBytes_FromFormat(
            "<Lua %s>", lua.lua_typename(L, lua_type))
    try:
        return py_bytes.decode(encoding)
    except UnicodeDecodeError:
        # safe 'decode'
        return py_bytes.decode('ISO-8859-1')


@cython.final
@cython.internal
@cython.no_gc_clear
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

    def __setattr__(self, name, value):
        assert self._runtime is not None
        if isinstance(name, unicode):
            if (<unicode>name).startswith(u'__') and (<unicode>name).endswith(u'__'):
                object.__setattr__(self, name, value)
                return
            name = (<unicode>name).encode(self._runtime._source_encoding)
        elif isinstance(name, bytes) and (<bytes>name).startswith(b'__') and (<bytes>name).endswith(b'__'):
            object.__setattr__(self, name, value)
            return
        self._setitem(name, value)

    def __setitem__(self, index_or_name, value):
        self._setitem(index_or_name, value)

    @cython.final
    cdef int _setitem(self, name, value) except -1:
        cdef lua_State* L = self._state
        lock_runtime(self._runtime)
        old_top = lua.lua_gettop(L)
        try:
            self.push_lua_object()
            # table[nil] fails, so map None -> python.none for Lua tables
            py_to_lua(self._runtime, L, name, wrap_none=True)
            py_to_lua(self._runtime, L, value)
            lua.lua_settable(L, -3)
        finally:
            lua.lua_settop(L, old_top)
            unlock_runtime(self._runtime)
        return 0

    def __delattr__(self, item):
        assert self._runtime is not None
        if isinstance(item, unicode):
            if (<unicode>item).startswith(u'__') and (<unicode>item).endswith(u'__'):
                object.__delattr__(self, item)
                return
            item = (<unicode>item).encode(self._runtime._source_encoding)
        elif isinstance(item, bytes) and (<bytes>item).startswith(b'__') and (<bytes>item).endswith(b'__'):
            object.__delattr__(self, item)
            return
        self._delitem(item)

    def __delitem__(self, key):
        self._delitem(key)

    @cython.final
    cdef _delitem(self, name):
        cdef lua_State* L = self._state
        lock_runtime(self._runtime)
        old_top = lua.lua_gettop(L)
        try:
            self.push_lua_object()
            py_to_lua(self._runtime, L, name, wrap_none=True)
            lua.lua_pushnil(L)
            lua.lua_settable(L, -3)
        finally:
            lua.lua_settop(L, old_top)
            unlock_runtime(self._runtime)


cdef _LuaTable new_lua_table(LuaRuntime runtime, lua_State* L, int n):
    cdef _LuaTable obj = _LuaTable.__new__(_LuaTable)
    init_lua_object(obj, runtime, L, n)
    return obj


@cython.internal
@cython.no_gc_clear
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
        old_top = lua.lua_gettop(L)
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
            lua.lua_settop(L, old_top)
            unlock_runtime(self._runtime)

cdef _LuaFunction new_lua_function(LuaRuntime runtime, lua_State* L, int n):
    cdef _LuaFunction obj = _LuaFunction.__new__(_LuaFunction)
    init_lua_object(obj, runtime, L, n)
    return obj


@cython.final
@cython.internal
@cython.no_gc_clear
cdef class _LuaCoroutineFunction(_LuaFunction):
    """A function that returns a new coroutine when called.
    """
    def __call__(self, *args):
        return self.coroutine(*args)

cdef _LuaCoroutineFunction new_lua_coroutine_function(LuaRuntime runtime, lua_State* L, int n):
    cdef _LuaCoroutineFunction obj = _LuaCoroutineFunction.__new__(_LuaCoroutineFunction)
    init_lua_object(obj, runtime, L, n)
    return obj


@cython.final
@cython.internal
@cython.no_gc_clear   # FIXME: get rid if this
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
            push_lua_arguments(thread._runtime, co, args)
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
        lua.lua_settop(co, 0)  # FIXME?
        unlock_runtime(thread._runtime)


cdef enum:
    KEYS = 1
    VALUES = 2
    ITEMS = 3


@cython.final
@cython.internal
@cython.no_gc_clear
cdef class _LuaIter:
    cdef LuaRuntime _runtime
    cdef _LuaObject _obj
    cdef lua_State* _state
    cdef int _refiter
    cdef char _what

    def __cinit__(self, _LuaObject obj not None, int what):
        self._state = NULL
        assert obj._runtime is not None
        self._runtime = obj._runtime
        self._obj = obj
        self._state = obj._state
        self._refiter = 0
        self._what = what

    def __dealloc__(self):
        if self._runtime is None:
            return
        cdef lua_State* L = self._state
        if L is not NULL and self._refiter:
            locked = False
            try:
                lock_runtime(self._runtime)
                locked = True
            except:
                pass
            lua.luaL_unref(L, lua.LUA_REGISTRYINDEX, self._refiter)
            if locked:
                unlock_runtime(self._runtime)

    def __repr__(self):
        return u"LuaIter(%r)" % (self._obj)

    def __iter__(self):
        return self

    def __next__(self):
        if self._obj is None:
            raise StopIteration
        cdef lua_State* L = self._obj._state
        lock_runtime(self._runtime)
        old_top = lua.lua_gettop(L)
        try:
            if self._obj is None:
                raise StopIteration
            # iterable object
            lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, self._obj._ref)
            if not lua.lua_istable(L, -1):
                if lua.lua_isnil(L, -1):
                    lua.lua_pop(L, 1)
                    raise LuaError("lost reference")
                raise TypeError("cannot iterate over non-table (found %r)" % self._obj)
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
            lua.lua_settop(L, old_top)
            unlock_runtime(self._runtime)
        raise StopIteration

# type conversions and protocol adaptations

cdef int py_asfunc_call(lua_State *L) nogil:
    if (lua.lua_gettop(L) == 1 and lua.lua_islightuserdata(L, 1)
            and lua.lua_topointer(L, 1) == <void*>unpack_wrapped_pyfunction):
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
            return unpack_userdata(L, -1)
    return NULL


@cython.final
@cython.internal
@cython.freelist(8)
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
    """
    Convert a Lua object to a Python object by either mapping, wrapping
    or unwrapping it.
    """
    cdef size_t size = 0
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
        py_obj = unpack_userdata(L, n)
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

cdef py_object* unpack_userdata(lua_State *L, int n) nogil:
    """
    Like luaL_checkudata(), unpacks a userdata object and validates that
    it's a wrapped Python object.  Returns NULL on failure.
    """
    p = lua.lua_touserdata(L, n)
    if p and lua.lua_getmetatable(L, n):
        # found userdata with metatable - the one we expect?
        lua.luaL_getmetatable(L, POBJECT)
        if lua.lua_rawequal(L, -1, -2):
            lua.lua_pop(L, 2)
            return <py_object*>p
        lua.lua_pop(L, 2)
    return NULL

cdef int py_function_result_to_lua(LuaRuntime runtime, lua_State *L, object o) except -1:
     if runtime._unpack_returned_tuples and isinstance(o, tuple):
         push_lua_arguments(runtime, L, <tuple>o)
         return len(<tuple>o)
     return py_to_lua(runtime, L, o)

cdef int py_to_lua(LuaRuntime runtime, lua_State *L, object o, bint wrap_none=False) except -1:
    cdef int pushed_values_count = 0
    cdef int type_flags = 0

    if o is None:
        if wrap_none:
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
    elif o is True or o is False:
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

    # originally, we just used:
    #cpython.ref.Py_INCREF(o)
    # now, we store an owned reference in "runtime._pyrefs_in_lua" to keep it visible to Python
    # and a borrowed reference in "py_obj.obj" for access from Lua
    obj_id = <object><uintptr_t><PyObject*>(o)
    if obj_id in runtime._pyrefs_in_lua:
        runtime._pyrefs_in_lua[obj_id].append(o)
    else:
        runtime._pyrefs_in_lua[obj_id] = [o]

    py_obj.obj = <PyObject*>o
    py_obj.runtime = <PyObject*>runtime
    py_obj.type_flags = type_flags
    lua.luaL_getmetatable(L, POBJECT)
    lua.lua_setmetatable(L, -2)
    return 1 # values pushed


cdef inline int _isascii(unsigned char* s):
    cdef unsigned char c = 0
    while s[0]:
        c |= s[0]
        s += 1
    return c & 0x80 == 0


cdef bytes _asciiOrNone(s):
    if s is None:
        return s
    elif isinstance(s, unicode):
        return (<unicode>s).encode('ascii')
    elif isinstance(s, bytearray):
        s = bytes(s)
    elif not isinstance(s, bytes):
        raise ValueError("expected string, got %s" % type(s))
    if not _isascii(<bytes>s):
        raise ValueError("byte string input has unknown encoding, only ASCII is allowed")
    return <bytes>s


# error handling

cdef int raise_lua_error(LuaRuntime runtime, lua_State* L, int result) except -1:
    if result == 0:
        return 0
    elif result == lua.LUA_ERRMEM:
        raise MemoryError()
    else:
        raise LuaError( build_lua_error_message(runtime, L, None, -1) )

cdef build_lua_error_message(LuaRuntime runtime, lua_State* L, unicode err_message, int n):
    cdef size_t size = 0
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
    old_top = lua.lua_gettop(L)
    try:
        if lua.luaL_loadbuffer(L, lua_code, len(lua_code), '<python>'):
            raise LuaSyntaxError(build_lua_error_message(
                runtime, L, u"error loading code: %s", -1))
        return execute_lua_call(runtime, L, 0)
    finally:
        lua.lua_settop(L, old_top)
        unlock_runtime(runtime)

cdef call_lua(LuaRuntime runtime, lua_State *L, tuple args):
    # does not lock the runtime!
    # does not clean up the stack!
    push_lua_arguments(runtime, L, args)
    return execute_lua_call(runtime, L, len(args))

cdef object execute_lua_call(LuaRuntime runtime, lua_State *L, Py_ssize_t nargs):
    cdef int result_status
    # call into Lua
    with nogil:
        result_status = lua.lua_pcall(L, nargs, lua.LUA_MULTRET, 0)
    runtime.reraise_on_exception()
    if result_status:
        raise_lua_error(runtime, L, result_status)
    return unpack_lua_results(runtime, L)

cdef int push_lua_arguments(LuaRuntime runtime, lua_State *L,
                            tuple args, bint first_may_be_nil=True) except -1:
    cdef int i
    if args:
        old_top = lua.lua_gettop(L)
        for i, arg in enumerate(args):
            if not py_to_lua(runtime, L, arg, wrap_none=not first_may_be_nil):
                lua.lua_settop(L, old_top)
                raise TypeError("failed to convert argument at index %d" % i)
            first_may_be_nil = True
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

cdef int decref_with_gil(py_object *py_obj) with gil:
    # originally, we just used:
    #cpython.ref.Py_XDECREF(py_obj.obj)
    # now, we keep Python object references in Lua visible to Python in a dict of lists:
    runtime = <LuaRuntime>py_obj.runtime
    try:
        obj_id = <object><uintptr_t>py_obj.obj
        try:
            refs = <list>runtime._pyrefs_in_lua[obj_id]
        except (TypeError, KeyError):
            return 0  # runtime was already cleared during GC, nothing left to do
        if len(refs) == 1:
            del runtime._pyrefs_in_lua[obj_id]
        else:
            refs.pop()  # any, really
        return 0
    except:
        try: runtime.store_raised_exception()
        finally: return -1

cdef int py_object_gc(lua_State* L) nogil:
    if not lua.lua_isuserdata(L, 1):
        return 0
    py_obj = unpack_userdata(L, 1)
    if py_obj is not NULL and py_obj.obj is not NULL:
        if decref_with_gil(py_obj):
            return lua.luaL_error(L, 'error while cleaning up a Python object')  # never returns!
    return 0

# calling Python objects

cdef bint call_python(LuaRuntime runtime, lua_State *L, py_object* py_obj) except -1:
    cdef int i, nargs = lua.lua_gettop(L) - 1
    cdef tuple args

    if not py_obj:
        raise TypeError("not a python object")

    f = <object>py_obj.obj

    if not nargs:
        lua.lua_settop(L, 0)  # FIXME
        result = f()
    else:
        arg = py_from_lua(runtime, L, 2)

        if PyMethod_Check(f) and (<PyObject*>arg) is PyMethod_GET_SELF(f):
            # Calling a bound method and self is already the first argument.
            # Lua x:m(a, b) => Python as x.m(x, a, b) but should be x.m(a, b)
            #
            # Lua syntax is sensitive to method calls vs function lookups, while
            # Python's syntax is not.  In a way, we are leaking Python semantics
            # into Lua by duplicating the first argument from method calls.
            #
            # The method wrapper would only prepend self to the tuple again,
            # so we just call the underlying function directly instead.
            f = <object>PyMethod_GET_FUNCTION(f)

        args = cpython.tuple.PyTuple_New(nargs)
        cpython.ref.Py_INCREF(arg)
        cpython.tuple.PyTuple_SET_ITEM(args, 0, arg)

        for i in range(1, nargs):
            arg = py_from_lua(runtime, L, i+2)
            cpython.ref.Py_INCREF(arg)
            cpython.tuple.PyTuple_SET_ITEM(args, i, arg)

        lua.lua_settop(L, 0)  # FIXME
        result = f(*args)

    return py_function_result_to_lua(runtime, L, result)

cdef int py_call_with_gil(lua_State* L, py_object *py_obj) with gil:
    cdef LuaRuntime runtime = None
    try:
        runtime = <LuaRuntime?>py_obj.runtime
        return call_python(runtime, L, py_obj)
    except:
        try: runtime.store_raised_exception()
        finally: return -1

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
        finally: return -1

cdef int py_object_str(lua_State* L) nogil:
    cdef py_object* py_obj = unwrap_lua_object(L, 1) # may not return on error!
    if not py_obj:
        return lua.luaL_argerror(L, 1, "not a python object")   # never returns!
    result = py_str_with_gil(L, py_obj)
    if result < 0:
        return lua.luaL_error(L, 'error during Python str() call')  # never returns!
    return result

# item access for Python objects
#
# Behavior is:
#
#   If setting attribute_handlers flag has been set in LuaRuntime object
#   use those handlers.
#
#   Else if wrapped by python.as_attrgetter() or python.as_itemgetter()
#   from the Lua side, user getitem or getattr respsectively.
#
#   Else If object has __getitem__, use that
#
#   Else use getattr()
#
#   Note that when getattr() is used, attribute_filter from LuaRuntime
#   may mediate access.  attribute_filter does not come into play when
#   using the getitem method of access.

cdef int getitem_for_lua(LuaRuntime runtime, lua_State* L, py_object* py_obj, int key_n) except -1:
    return py_to_lua(runtime, L,
                     (<object>py_obj.obj)[ py_from_lua(runtime, L, key_n) ])

cdef int setitem_for_lua(LuaRuntime runtime, lua_State* L, py_object* py_obj, int key_n, int value_n) except -1:
    (<object>py_obj.obj)[ py_from_lua(runtime, L, key_n) ] = py_from_lua(runtime, L, value_n)
    return 0

cdef int getattr_for_lua(LuaRuntime runtime, lua_State* L, py_object* py_obj, int key_n) except -1:
    obj = <object>py_obj.obj
    attr_name = py_from_lua(runtime, L, key_n)
    if runtime._attribute_getter is not None:
        value = runtime._attribute_getter(obj, attr_name)
        return py_to_lua(runtime, L, value)
    if runtime._attribute_filter is not None:
        attr_name = runtime._attribute_filter(obj, attr_name, False)
    return py_to_lua(runtime, L, getattr(obj, attr_name))

cdef int setattr_for_lua(LuaRuntime runtime, lua_State* L, py_object* py_obj, int key_n, int value_n) except -1:
    obj = <object>py_obj.obj
    attr_name = py_from_lua(runtime, L, key_n)
    attr_value = py_from_lua(runtime, L, value_n)
    if runtime._attribute_setter is not None:
        runtime._attribute_setter(obj, attr_name, attr_value)
    else:
        if runtime._attribute_filter is not None:
            attr_name = runtime._attribute_filter(obj, attr_name, True)
        setattr(obj, attr_name, attr_value)
    return 0


cdef int py_object_getindex_with_gil(lua_State* L, py_object* py_obj) with gil:
    cdef LuaRuntime runtime
    try:
        runtime = <LuaRuntime?>py_obj.runtime
        if (py_obj.type_flags & OBJ_AS_INDEX) and not runtime._attribute_getter:
            return getitem_for_lua(runtime, L, py_obj, 2)
        else:
            return getattr_for_lua(runtime, L, py_obj, 2)
    except:
        try: runtime.store_raised_exception()
        finally: return -1

cdef int py_object_getindex(lua_State* L) nogil:
    cdef py_object* py_obj = unwrap_lua_object(L, 1) # may not return on error!
    if not py_obj:
        return lua.luaL_argerror(L, 1, "not a python object")   # never returns!
    result = py_object_getindex_with_gil(L, py_obj)
    if result < 0:
        return lua.luaL_error(L, 'error reading Python attribute/item')  # never returns!
    return result


cdef int py_object_setindex_with_gil(lua_State* L, py_object* py_obj) with gil:
    cdef LuaRuntime runtime
    try:
        runtime = <LuaRuntime?>py_obj.runtime
        if (py_obj.type_flags & OBJ_AS_INDEX) and not runtime._attribute_setter:
            return setitem_for_lua(runtime, L, py_obj, 2, 3)
        else:
            return setattr_for_lua(runtime, L, py_obj, 2, 3)
    except:
        try: runtime.store_raised_exception()
        finally: return -1

cdef int py_object_setindex(lua_State* L) nogil:
    cdef py_object* py_obj = unwrap_lua_object(L, 1) # may not return on error!
    if not py_obj:
        return lua.luaL_argerror(L, 1, "not a python object")   # never returns!
    result = py_object_setindex_with_gil(L, py_obj)
    if result < 0:
        return lua.luaL_error(L, 'error writing Python attribute/item')  # never returns!
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
        return unpack_userdata(L, n)
    else:
        return unpack_wrapped_pyfunction(L, n)

cdef int py_wrap_object_protocol_with_gil(lua_State* L, py_object* py_obj, int type_flags) with gil:
    cdef LuaRuntime runtime
    try:
        runtime = <LuaRuntime?>py_obj.runtime
        return py_to_lua_custom(runtime, L, <object>py_obj.obj, type_flags)
    except:
        try: runtime.store_raised_exception()
        finally: return -1

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
        finally: return -1

cdef int py_iter_with_gil(lua_State* L, py_object* py_obj, int type_flags) with gil:
    cdef LuaRuntime runtime
    try:
        runtime = <LuaRuntime?>py_obj.runtime
        obj = iter(<object>py_obj.obj)
        return py_push_iterator(runtime, L, obj, type_flags, 0.0)
    except:
        try: runtime.store_raised_exception()
        finally: return -1

cdef int py_push_iterator(LuaRuntime runtime, lua_State* L, iterator, int type_flags,
                          lua.lua_Number initial_value):
    # Lua needs three values: iterator C function + state + control variable (last iter) value
    old_top = lua.lua_gettop(L)
    lua.lua_pushcfunction(L, <lua.lua_CFunction>py_iter_next)
    # push the wrapped iterator object as for-loop state object
    if runtime._unpack_returned_tuples:
        type_flags |= OBJ_UNPACK_TUPLE
    if py_to_lua_custom(runtime, L, iterator, type_flags) < 1:
        lua.lua_settop(L, old_top)
        return -1
    # push either enumerator index or nil as control variable value
    if type_flags & OBJ_ENUMERATOR:
        lua.lua_pushnumber(L, initial_value)
    else:
        lua.lua_pushnil(L)
    return 3

cdef int py_iter_next(lua_State* L) nogil:
    # first value in the C closure: the Python iterator object
    cdef py_object* py_obj = unwrap_lua_object(L, 1)
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
        try:
            obj = next(<object>py_iter.obj)
        except StopIteration:
            lua.lua_pushnil(L)
            return 1

        # NOTE: cannot return nil for None as first item
        # as Lua interprets it as end of the iterator
        allow_nil = False
        if py_iter.type_flags & OBJ_ENUMERATOR:
            lua.lua_pushnumber(L, lua.lua_tonumber(L, -1) + 1.0)
            allow_nil = True
        if (py_iter.type_flags & OBJ_UNPACK_TUPLE) and isinstance(obj, tuple):
            # special case: when the iterable returns a tuple, unpack it
            push_lua_arguments(runtime, L, <tuple>obj, first_may_be_nil=allow_nil)
            result = len(<tuple>obj)
        else:
            result = py_to_lua(runtime, L, obj, wrap_none=not allow_nil)
            if result < 1:
                return -1
        if py_iter.type_flags & OBJ_ENUMERATOR:
            result += 1
        return result
    except:
        try: runtime.store_raised_exception()
        finally: return -1

# 'python' module functions in Lua

cdef lua.luaL_Reg py_lib[7]
py_lib[0] = lua.luaL_Reg(name = "as_attrgetter", func = <lua.lua_CFunction> py_as_attrgetter)
py_lib[1] = lua.luaL_Reg(name = "as_itemgetter", func = <lua.lua_CFunction> py_as_itemgetter)
py_lib[2] = lua.luaL_Reg(name = "as_function", func = <lua.lua_CFunction> py_as_function)
py_lib[3] = lua.luaL_Reg(name = "iter", func = <lua.lua_CFunction> py_iter)
py_lib[4] = lua.luaL_Reg(name = "iterex", func = <lua.lua_CFunction> py_iterex)
py_lib[5] = lua.luaL_Reg(name = "enumerate", func = <lua.lua_CFunction> py_enumerate)
py_lib[6] = lua.luaL_Reg(name = NULL, func = NULL)
