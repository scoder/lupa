# cython: embedsignature=True, binding=True, language_level=3str

"""
A fast Python wrapper around Lua and LuaJIT2.
"""

from __future__ import absolute_import

cimport cython

from libc.string cimport strlen, strchr
from libc.stdlib cimport malloc, free, realloc
from libc.stdio cimport fprintf, stderr, fflush
from . cimport luaapi as lua
from .luaapi cimport lua_State

cimport cpython.ref
cimport cpython.tuple
cimport cpython.float
cimport cpython.long
from cpython.ref cimport PyObject
from cpython.method cimport (
    PyMethod_Check, PyMethod_GET_SELF, PyMethod_GET_FUNCTION)
from cpython.bytes cimport PyBytes_FromFormat

#from libc.stdint cimport uintptr_t
cdef extern from "stdint.h":
    ctypedef size_t uintptr_t
    cdef const Py_ssize_t PY_SSIZE_T_MAX
    cdef const char CHAR_MIN, CHAR_MAX
    cdef const short SHRT_MIN, SHRT_MAX
    cdef const int INT_MIN, INT_MAX
    cdef const long LONG_MIN, LONG_MAX
    cdef const long long PY_LLONG_MIN, PY_LLONG_MAX

cdef object exc_info
from sys import exc_info

cdef object Mapping
cdef object Sequence
from collections.abc import Mapping, Sequence

cdef object wraps
from functools import wraps


__all__ = ['LUA_VERSION', 'LUA_MAXINTEGER', 'LUA_MININTEGER',
            'LuaRuntime', 'LuaError', 'LuaSyntaxError', 'LuaMemoryError',
           'as_itemgetter', 'as_attrgetter', 'lua_type',
           'unpacks_lua_table', 'unpacks_lua_table_method']

cdef object builtins
try:
    import __builtin__ as builtins
except ImportError:
    import builtins

DEF POBJECT = b"POBJECT" # as used by LunaticPython
DEF LUPAOFH = b"LUPA_NUMBER_OVERFLOW_CALLBACK_FUNCTION"
DEF PYREFST = b"LUPA_PYTHON_REFERENCES_TABLE"

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


cdef int _LUA_VERSION = lua.read_lua_version(NULL)
LUA_VERSION = (_LUA_VERSION // 100, _LUA_VERSION % 100)


if lua.LUA_MAXINTEGER > 0:
    LUA_MININTEGER, LUA_MAXINTEGER = (lua.LUA_MININTEGER, lua.LUA_MAXINTEGER)
elif sizeof(lua.lua_Integer) >= sizeof(long long):  # probably not larger
    LUA_MININTEGER, LUA_MAXINTEGER = (PY_LLONG_MIN, PY_LLONG_MAX)
elif sizeof(lua.lua_Integer) >= sizeof(long):
    LUA_MININTEGER, LUA_MAXINTEGER = (LONG_MIN, LONG_MAX)
elif sizeof(lua.lua_Integer) >= sizeof(int):
    LUA_MININTEGER, LUA_MAXINTEGER = (INT_MIN, INT_MAX)
elif sizeof(lua.lua_Integer) >= sizeof(short):
    LUA_MININTEGER, LUA_MAXINTEGER = (SHRT_MIN, SHRT_MAX)
else:  # probably not smaller
    LUA_MININTEGER, LUA_MAXINTEGER = (CHAR_MIN, CHAR_MAX)


cdef struct MemoryStatus:
    size_t used
    size_t base_usage
    size_t limit


class LuaError(Exception):
    """Base class for errors in the Lua runtime.
    """


class LuaSyntaxError(LuaError):
    """Syntax error in Lua code.
    """


class LuaMemoryError(LuaError, MemoryError):
    """Memory error in Lua code.
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
    assert lua_object._runtime._state is not NULL
    lock_runtime(lua_object._runtime)
    L = lua_object._state
    old_top = lua.lua_gettop(L)
    cdef const char* lua_type_name
    try:
        check_lua_stack(L, 1)
        lua_object.push_lua_object(L)
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
            return lua_type_name.decode('ascii')
    finally:
        lua.lua_settop(L, old_top)
        unlock_runtime(lua_object._runtime)

cdef inline int _len_as_int(Py_ssize_t obj) except -1:
    if obj > <Py_ssize_t>INT_MAX:
        raise OverflowError
    return <int>obj

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

    * ``overflow_handler``: function for handling Python integers overflowing
      Lua integers. Must have the signature ``func(obj)``. If provided, the
      function will be called when a Python integer (possibly of arbitrary
      precision type) is too large to fit in a fixed-precision Lua integer.
      Normally, it should return the now well-behaved object that can be
      converted/wrapped to a Lua type. If the object cannot be precisely
      represented in Lua, it should raise an ``OverflowError``.

    * ``max_memory``: max memory usage this LuaRuntime can use in bytes.
      If max_memory is None, the default lua allocator is used and calls to
      ``set_max_memory(limit)`` will fail with a ``LuaMemoryError``.
      Note: Not supported on 64bit LuaJIT.
      (default: None, i.e. no limitation. New in Lupa 2.0)

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
    cdef list _pending_unrefs
    cdef bytes _encoding
    cdef bytes _source_encoding
    cdef object _attribute_filter
    cdef object _attribute_getter
    cdef object _attribute_setter
    cdef bint _unpack_returned_tuples
    cdef MemoryStatus _memory_status

    def __cinit__(self, encoding='UTF-8', source_encoding=None,
                  attribute_filter=None, attribute_handlers=None,
                  bint register_eval=True, bint unpack_returned_tuples=False,
                  bint register_builtins=True, overflow_handler=None,
                  max_memory=None):
        cdef lua_State* L

        if max_memory is None:
            L = lua.luaL_newstate()
            self._memory_status.limit = <size_t> -1
        else:
            L = lua.lua_newstate(<lua.lua_Alloc>&_lua_alloc_restricted, <void*>&self._memory_status)
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

        lua.lua_atpanic(L, &_lua_panic)
        lua.luaL_openlibs(L)
        self.init_python_lib(register_eval, register_builtins)

        self.set_overflow_handler(overflow_handler)

        # lupa init done, set real limit
        if max_memory is not None:
            self._memory_status.base_usage = self._memory_status.used
            if max_memory > 0:
                self._memory_status.limit =  self._memory_status.base_usage + <size_t>max_memory
                # Prevent accidental (or deliberate) usage of our special value.
                if self._memory_status.limit == <size_t> -1:
                    self._memory_status.limit -= 1

    @cython.final
    cdef void add_pending_unref(self, int ref) noexcept:
        pyval: object = ref
        if self._pending_unrefs is None:
            self._pending_unrefs = [pyval]
        else:
            self._pending_unrefs.append(pyval)

    @cython.final
    cdef int clean_up_pending_unrefs(self) except -1:
        if self._pending_unrefs is None or self._state is NULL:
            return 0

        pending_unrefs = self._pending_unrefs
        self._pending_unrefs = None

        cdef int ref
        L = self._state
        for ref in pending_unrefs:
            lua.luaL_unref(L, lua.LUA_REGISTRYINDEX, ref)
        return 0

    def __dealloc__(self):
        if self._state is not NULL:
            lua.lua_close(self._state)
            self._state = NULL

    def get_max_memory(self, total=False):
        """
        Maximum memory allowed to be used by this LuaRuntime.
        0 indicates no limit meanwhile None indicates that the default lua
        allocator is being used and ``set_max_memory()`` cannot be used.

        If ``total`` is True, the base memory used by the lua runtime
        will be included in the limit.
        """
        if self._memory_status.limit == <size_t> -1:
            return None
        elif total:
            return self._memory_status.limit
        return self._memory_status.limit - self._memory_status.base_usage

    def get_memory_used(self, total=False):
        """
        Memory currently in use.
        This is None if the default lua allocator is used and 0 if
        ``max_memory`` is 0.

        If ``total`` is True, the base memory used by the lua runtime
        will be included.
        """
        if self._memory_status.limit == <size_t> -1:
            return None
        elif total:
            return self._memory_status.used
        return self._memory_status.used - self._memory_status.base_usage

    @property
    def lua_version(self):
        """
        The Lua runtime/language version as tuple, e.g. (5, 3) for Lua 5.3.
        """
        assert self._state is not NULL
        cdef int version = lua.read_lua_version(self._state)
        return (version // 100, version % 100)

    @property
    def lua_implementation(self):
        """
        The Lua implementation version string, e.g. "Lua 5.3" or "LuaJIT 2.0.1".
        May execute Lua code.
        """
        return self.eval(
            "(function () "
            "    if type(jit) == 'table' then return jit.version else return _VERSION end "
            "end)()"
        )

    @cython.final
    cdef int reraise_on_exception(self) except -1:
        if self._raised_exception is not None:
            exception = self._raised_exception
            self._raised_exception = None
            raise exception[0], exception[1], exception[2]
        return 0

    @cython.final
    cdef int store_raised_exception(self, lua_State* L, bytes lua_error_msg) except -1:
        try:
            self._raised_exception = tuple(exc_info())
            py_to_lua(self, L, self._raised_exception[1])
        except:
            lua.lua_pushlstring(L, lua_error_msg, len(lua_error_msg))
            raise
        return 0

    @cython.final
    cdef bytes _source_encode(self, string):
        if isinstance(string, unicode):
            return (<unicode>string).encode(self._source_encoding)
        elif isinstance(string, bytes):
            return <bytes> string
        elif isinstance(string, bytearray):
            return bytes(string)

        raise TypeError(f"Expected string, got {type(string)}")

    def eval(self, lua_code, *args, name=None, mode=None):
        """Evaluate a Lua expression passed in a string.

        The 'name' argument can be used to override the name printed in error messages.

        The 'mode' argument specifies the input type.  By default, both source code and
        pre-compiled byte code is allowed (mode='bt').  It can be restricted to source
        code with mode='t' and to byte code with mode='b'.  This has no effect on Lua 5.1.
        """
        assert self._state is not NULL
        name_b = self._source_encode(name) if name is not None else None
        mode_b = _asciiOrNone(mode)
        return run_lua(self, b'return ' + self._source_encode(lua_code), name_b, mode_b, args)

    def execute(self, lua_code, *args, name=None, mode=None):
        """Execute a Lua program passed in a string.

        The 'name' argument can be used to override the name printed in error messages.

        The 'mode' argument specifies the input type.  By default, both source code and
        pre-compiled byte code is allowed (mode='bt').  It can be restricted to source
        code with mode='t' and to byte code with mode='b'.  This has no effect on Lua 5.1.
        """
        assert self._state is not NULL
        name_b = self._source_encode(name) if name is not None else None
        mode_b = _asciiOrNone(mode)
        return run_lua(self, self._source_encode(lua_code), name_b, mode_b, args)

    def compile(self, lua_code, name=None, mode=None):
        """Compile a Lua program into a callable Lua function.

        The 'name' argument can be used to override the name printed in error messages.

        The 'mode' argument specifies the input type.  By default, both source code and
        pre-compiled byte code is allowed (mode='bt').  It can be restricted to source
        code with mode='t' and to byte code with mode='b'.  This has no effect on Lua 5.1.
        """
        assert self._state is not NULL
        cdef const char * c_name = b'<python>'
        cdef const char * c_mode = NULL

        lua_code_bytes = self._source_encode(lua_code)
        if name is not None:
            name_b = self._source_encode(name)
            c_name = name_b
        if mode is not None:
            mode_b = _asciiOrNone(mode)
            c_mode = mode_b

        L = self._state
        lock_runtime(self)
        old_top = lua.lua_gettop(L)
        cdef size_t size
        cdef const char *err
        try:
            check_lua_stack(L, 1)
            status = lua.luaL_loadbufferx(L, lua_code_bytes, len(lua_code_bytes), c_name, c_mode)
            if status == 0:
                return py_from_lua(self, L, -1)
            else:
                err = lua.lua_tolstring(L, -1, &size)
                if self._encoding is None:
                    error = err[:size]  # bytes
                    is_memory_error = b"not enough memory" in error
                else:
                    error = err[:size].decode(self._encoding)
                    is_memory_error = u"not enough memory" in error
                if is_memory_error:
                    raise LuaMemoryError(error)
                raise LuaSyntaxError(error)
        finally:
            lua.lua_settop(L, old_top)
            unlock_runtime(self)

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
            check_lua_stack(L, 1)
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
            check_lua_stack(L, 1)
            lua.lua_pushglobaltable(L)
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

    def table_from(self, *args, bint recursive=False):
        """Create a new table from Python mapping or iterable.

        table_from() accepts either a dict/mapping or an iterable with items.
        Items from dicts are set as key-value pairs; items from iterables
        are placed in the table in order.

        Nested mappings / iterables are passed to Lua as userdata
        (wrapped Python objects) by default.  If `recursive` is True,
        they are converted to Lua tables recursively, handling loops
        and duplicates via identity de-duplication.
        """
        assert self._state is not NULL
        cdef lua_State *L = self._state
        lock_runtime(self)
        try:
            return py_to_lua_table(self, L, args, recursive=recursive)
        finally:
            unlock_runtime(self)

    def nogc(self):
        """
        Return a context manager that temporarily disables the Lua garbage collector.
        """
        return _LuaNoGC(self)

    def gccollect(self):
        """
        Run a full pass of the Lua garbage collector.
        """
        assert self._state is not NULL
        cdef lua_State *L = self._state
        lock_runtime(self)
        # Pass third argument for compatibility with Lua 5.[123].
        lua.lua_gc(L, lua.LUA_GCCOLLECT, <int> 0)
        unlock_runtime(self)

    def set_max_memory(self, size_t max_memory, total=False):
        """Set maximum allowed memory for this LuaRuntime.

        If `max_memory` is 0, there will be no limit.
        If ``total`` is True, the base memory used by the LuaRuntime itself
        will be included in the memory limit.

        If max_memory was set to None during creation, this will raise a
        RuntimeError.
        """
        cdef size_t used
        if self._memory_status.limit == <size_t> -1:
            raise RuntimeError("max_memory must be set on LuaRuntime creation")
        elif max_memory == 0:
            self._memory_status.limit = 0
        elif total:
            self._memory_status.limit = max_memory
        else:
            self._memory_status.limit = self._memory_status.base_usage + max_memory
            # Prevent accidental (or deliberate) usage of our special value.
            if self._memory_status.limit == <size_t> -1:
                self._memory_status.limit -= 1

    def set_overflow_handler(self, overflow_handler):
        """Set the overflow handler function that is called on failures to pass large numbers to Lua.
        """
        assert self._state is not NULL
        cdef lua_State *L = self._state
        if overflow_handler is not None and not callable(overflow_handler):
            raise ValueError("overflow_handler must be callable")
        lock_runtime(self)
        old_top = lua.lua_gettop(L)
        try:
            check_lua_stack(L, 2)
            lua.lua_pushlstring(L, LUPAOFH, len(LUPAOFH)) # key
            if not py_to_lua(self, L, overflow_handler):  # key value
                raise LuaError("failed to convert overflow_handler")
            lua.lua_rawset(L, lua.LUA_REGISTRYINDEX)      #
        finally:
            lua.lua_settop(L, old_top)
            unlock_runtime(self)

    @cython.final
    cdef int register_py_object(self, bytes cname, bytes pyname, object obj) except -1:
        """Register Python object 'obj' in the registry with cname and
        in the library on top of the stack with pyname
        Preconditions:
            runtime must be locked
        """
        cdef lua_State *L = self._state
        old_top = lua.lua_gettop(L)
        try:
            check_lua_stack(L, 4)                       # tbl
            lua.lua_pushlstring(L, cname, len(cname))   # tbl cname
            py_to_lua_custom(self, L, obj, 0)           # tbl cname obj
            lua.lua_pushlstring(L, pyname, len(pyname)) # tbl cname obj pyname
            lua.lua_pushvalue(L, -2)                    # tbl cname obj pyname obj
            lua.lua_rawset(L, -5)                       # tbl cname obj
            lua.lua_rawset(L, lua.LUA_REGISTRYINDEX)    # tbl
            return 0
        finally:
            lua.lua_settop(L, old_top)

    @cython.final
    cdef int init_python_lib(self, bint register_eval, bint register_builtins) except -1:
        cdef lua_State *L = self._state

        # create 'python' lib
        luaL_openlib(L, "python", py_lib, 0)       # lib
        lua.lua_pushlightuserdata(L, <void*>self)  # lib udata
        lua.lua_pushcclosure(L, py_args, 1)        # lib function
        lua.lua_setfield(L, -2, "args")            # lib

        # register our own object metatable
        lua.luaL_newmetatable(L, POBJECT)          # lib metatbl
        luaL_openlib(L, NULL, py_object_lib, 0)
        lua.lua_pop(L, 1)                          # lib

        # create and store the python references table
        lua.lua_newtable(L)                                  # lib tbl
        lua.lua_createtable(L, 0, 1)                         # lib tbl metatbl
        lua.lua_pushlstring(L, "v", 1)                       # lib tbl metatbl "v"
        lua.lua_setfield(L, -2, "__mode")                    # lib tbl metatbl
        lua.lua_setmetatable(L, -2)                          # lib tbl
        lua.lua_setfield(L, lua.LUA_REGISTRYINDEX, PYREFST)  # lib

        # register global names in the module
        self.register_py_object(b'Py_None',  b'none', None)
        if register_eval:
            self.register_py_object(b'eval',     b'eval', eval)
        if register_builtins:
            self.register_py_object(b'builtins', b'builtins', builtins)

        # pop 'python' lib
        lua.lua_pop(L, 1)

        return 0  # nothing left to return on the stack


@cython.internal
cdef class _LuaNoGC:
    """
    A context manager that temporarily disables the Lua garbage collector.
    """
    cdef LuaRuntime _runtime

    def __cinit__(self, LuaRuntime runtime not None):
        self._runtime = runtime

    def __enter__(self):
        if self._runtime is None:
            return  # e.g. system teardown
        assert self._runtime._state is not NULL
        cdef lua_State *L = self._runtime._state
        lock_runtime(self._runtime)
        # Pass third argument for compatibility with Lua 5.[123].
        lua.lua_gc(L, lua.LUA_GCSTOP, <int> 0)
        unlock_runtime(self._runtime)

    def __exit__(self, *exc):
        if self._runtime is None:
            return  # e.g. system teardown
        assert self._runtime._state is not NULL
        cdef lua_State *L = self._runtime._state
        lock_runtime(self._runtime)
        # Pass third argument for compatibility with Lua 5.[123].
        lua.lua_gc(L, lua.LUA_GCRESTART, <int> 0)
        unlock_runtime(self._runtime)


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


cdef int check_lua_stack(lua_State* L, int extra) except -1:
    """Wrapper around lua_checkstack.
    On failure, a MemoryError is raised.
    """
    assert extra >= 0
    if not lua.lua_checkstack(L, extra):
        raise LuaMemoryError
    return 0


cdef int get_object_length_from_lua(lua_State* L) noexcept nogil:
    cdef size_t length = lua.lua_objlen(L, lua.lua_upvalueindex(1))
    lua.lua_pushlightuserdata(L, <void*>length)
    return 1


cdef Py_ssize_t get_object_length(LuaRuntime runtime, lua_State* L, int index) except -1:
    """Obtains the length of the object at the given valid index.
    Preconditions:
        runtime must be locked
        index must be valid
    Exceptions:
        LuaError if Lua raises an error
        OverflowError if length doesn't fit in a Py_ssize_t
    """
    cdef int result
    cdef size_t length
    check_lua_stack(L, 1)
    lua.lua_pushvalue(L, index)                             # value
    lua.lua_pushcclosure(L, get_object_length_from_lua, 1)  # closure
    result = lua.lua_pcall(L, 0, 1, 0)
    if result:                                              # err
        raise_lua_error(runtime, L, result)                 #
    length = <size_t>lua.lua_touserdata(L, -1)              # length
    lua.lua_pop(L, 1)                                       #
    if length > <size_t> PY_SSIZE_T_MAX:
        raise OverflowError(f"Size too large to represent: {length}")
    return <Py_ssize_t>length


cdef tuple unpack_lua_table(LuaRuntime runtime, lua_State* L):
    """Unpacks the table at the top of the stack into a tuple of positional arguments
    and a dictionary of keyword arguments.
    Preconditions:
        runtime must be locked
    """
    assert runtime is not None
    cdef tuple args
    cdef dict kwargs = {}
    cdef bytes source_encoding = runtime._source_encoding
    cdef int old_top
    cdef Py_ssize_t index, length
    check_lua_stack(L, 2)
    old_top = lua.lua_gettop(L)
    try:
        length = get_object_length(runtime, L, -1)
        args = cpython.tuple.PyTuple_New(length)
        lua.lua_pushnil(L)            # nil (first key)
        while lua.lua_next(L, -2):    # key value
            key = py_from_lua(runtime, L, -2)
            value = py_from_lua(runtime, L, -1)
            if isinstance(key, int) and not isinstance(key, bool):
                index = <Py_ssize_t>key
                if index < 1 or index > length:
                    raise IndexError("table index out of range")
                cpython.ref.Py_INCREF(value)
                cpython.tuple.PyTuple_SET_ITEM(args, index-1, value)
            elif isinstance(key, bytes):
                kwargs[(<bytes>key).decode(source_encoding)] = value
            elif isinstance(key, unicode):
                kwargs[key] = value
            else:
                raise TypeError("table key is neither an integer nor a string")
            lua.lua_pop(L, 1)         # key
    finally:
        lua.lua_settop(L, old_top)
    return args, kwargs


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

    cdef _LuaTable table = <_LuaTable>arg
    assert table._runtime is not None
    assert table._runtime._state is not NULL
    cdef LuaRuntime runtime = table._runtime
    cdef lua_State* L = table._state
    lock_runtime(runtime)
    old_top = lua.lua_gettop(L)
    try:
        check_lua_stack(L, 1)
        table.push_lua_object(L)
        return unpack_lua_table(runtime, L)
    finally:
        lua.lua_settop(L, old_top)
        unlock_runtime(runtime)


################################################################################
# fast, re-entrant runtime locking

cdef inline bint lock_runtime(LuaRuntime runtime, bint blocking=True) noexcept with gil:
    return lock_lock(runtime._lock, pythread.PyThread_get_thread_ident(), blocking=blocking)

cdef inline void unlock_runtime(LuaRuntime runtime) noexcept nogil:
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

    def __cinit__(self):
        self._ref = lua.LUA_NOREF

    def __init__(self):
        raise TypeError("Type cannot be instantiated manually")

    def __dealloc__(self):
        if self._runtime is None:
            return
        runtime = self._runtime
        self._runtime = None
        ref = self._ref
        if ref == lua.LUA_NOREF:
            return
        self._ref = lua.LUA_NOREF
        cdef lua_State* L = self._state
        if L is not NULL:
            locked = lock_runtime(runtime, blocking=False)
            if locked:
                lua.luaL_unref(L, lua.LUA_REGISTRYINDEX, ref)
                runtime.clean_up_pending_unrefs()  # just in case
                unlock_runtime(runtime)
                return
        runtime.add_pending_unref(ref)

    @cython.final
    cdef inline int push_lua_object(self, lua_State* L) except -1:
        """Pushes Lua object onto the stack
        Preconditions:
            1 extra slot in the Lua stack
            LuaRuntime is locked
        Postconditions:
            Lua object (not nil) is pushed onto of the stack
        """
        if self._ref == lua.LUA_NOREF:
            raise LuaError("lost reference")
        lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, self._ref)
        if lua.lua_isnil(L, -1):
            lua.lua_pop(L, 1)
            raise LuaError("lost reference")
        return 1

    def __call__(self, *args):
        assert self._runtime is not None
        cdef lua_State* L = self._state
        if not lock_runtime(self._runtime):
            raise RuntimeError("failed to acquire thread lock")
        try:
            lua.lua_settop(L, 0)
            self.push_lua_object(L)
            return call_lua(self._runtime, L, args)
        finally:
            lua.lua_settop(L, 0)
            unlock_runtime(self._runtime)

    def __len__(self):
        return self._len()

    @cython.final
    cdef Py_ssize_t _len(self) except -1:
        assert self._runtime is not None
        cdef lua_State* L = self._state
        lock_runtime(self._runtime)
        old_top = lua.lua_gettop(L)
        try:
            check_lua_stack(L, 1)
            self.push_lua_object(L)
            return get_object_length(self._runtime, L, -1)
        finally:
            lua.lua_settop(L, old_top)
            unlock_runtime(self._runtime)

    def __nonzero__(self):
        return True

    def __iter__(self):
        # if not provided, iteration will try item access and call into Lua
        raise TypeError("iteration is only supported for tables")

    def __repr__(self):
        assert self._runtime is not None
        cdef lua_State* L = self._state
        cdef bytes encoding = self._runtime._encoding or b'UTF-8'
        lock_runtime(self._runtime)
        old_top = lua.lua_gettop(L)
        try:
            check_lua_stack(L, 1)
            self.push_lua_object(L)
            return lua_object_repr(L, encoding)
        finally:
            lua.lua_settop(L, old_top)
            unlock_runtime(self._runtime)

    def __str__(self):
        assert self._runtime is not None
        cdef lua_State* L = self._state
        cdef const char *string
        cdef size_t size = 0
        cdef bytes encoding = self._runtime._encoding or b'UTF-8'
        lock_runtime(self._runtime)
        old_top = lua.lua_gettop(L)
        try:
            check_lua_stack(L, 2)
            self.push_lua_object(L)                         # obj
            if lua.luaL_getmetafield(L, -1, "__tostring"):  # obj tostr
                lua.lua_insert(L, -2)                       # tostr obj
                status = lua.lua_pcall(L, 1, 1, 0)
                if status == 0:                             # str
                    string = lua.lua_tolstring(L, -1, &size)
                    if string is NULL:
                        raise TypeError("__tostring returned non-string object")
                    try:
                        return string[:size].decode(encoding)
                    except UnicodeDecodeError:
                        return string[:size].decode('ISO-8859-1')
                else:
                    raise_lua_error(self._runtime, L, status)
            else:
                return lua_object_repr(L, encoding)
        finally:
            lua.lua_settop(L, old_top)
            unlock_runtime(self._runtime)

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
        assert self._runtime is not None
        cdef lua_State* L = self._state
        lock_runtime(self._runtime)
        old_top = lua.lua_gettop(L)
        try:
            check_lua_stack(L, 3)
            lua.lua_pushcfunction(L, get_from_lua_table)                               # func
            self.push_lua_object(L)                                                    # func obj
            lua_type = lua.lua_type(L, -1)
            if lua_type == lua.LUA_TFUNCTION or lua_type == lua.LUA_TTHREAD:
                raise (AttributeError if is_attr_access else TypeError)(
                    "item/attribute access not supported on functions")
            # table[nil] fails, so map None -> python.none for Lua tables
            py_to_lua(self._runtime, L, name, wrap_none=(lua_type == lua.LUA_TTABLE))  # func obj key
            return execute_lua_call(self._runtime, L, 2)                               # obj[key]
        finally:
            lua.lua_settop(L, old_top)                                                 #
            unlock_runtime(self._runtime)


cdef _LuaObject new_lua_object(LuaRuntime runtime, lua_State* L, int n):
    cdef _LuaObject obj = _LuaObject.__new__(_LuaObject)
    init_lua_object(obj, runtime, L, n)
    return obj

cdef void init_lua_object(_LuaObject obj, LuaRuntime runtime, lua_State* L, int n) noexcept:
    obj._runtime = runtime
    obj._state = L
    lua.lua_pushvalue(L, n)
    obj._ref = lua.luaL_ref(L, lua.LUA_REGISTRYINDEX)

cdef object lua_object_repr(lua_State* L, bytes encoding):
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
        assert self._runtime is not None
        cdef lua_State* L = self._state
        lock_runtime(self._runtime)
        old_top = lua.lua_gettop(L)
        try:
            check_lua_stack(L, 3)
            self.push_lua_object(L)
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
        assert self._runtime is not None
        cdef lua_State* L = self._state
        lock_runtime(self._runtime)
        old_top = lua.lua_gettop(L)
        try:
            check_lua_stack(L, 3)
            self.push_lua_object(L)
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
            check_lua_stack(L, 3)
            self.push_lua_object(L)
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
    cdef lua_State* L = thread._state
    cdef int status, i, nargs = 0, nres = 0
    assert thread._runtime is not None
    lock_runtime(thread._runtime)
    old_top = lua.lua_gettop(L)
    try:
        check_lua_stack(L, 1)
        if lua.lua_status(co) == 0 and lua.lua_gettop(co) == 0:
            # already terminated
            raise StopIteration
        if args:
            nargs = _len_as_int(len(args))
            push_lua_arguments(thread._runtime, co, args)
        with nogil:
            status = lua.lua_resume(co, L, nargs, &nres)
        if status != lua.LUA_YIELD:
            if status == 0:
                # terminated
                if nres == 0:
                    # no values left to return
                    raise StopIteration
            else:
                raise_lua_error(thread._runtime, co, status)

        # Move yielded values to the main state before unpacking.
        # This is what Lua's internal auxresume function is doing;
        # it affects wrapped Lua functions returned to Python.
        lua.lua_xmove(co, L, nres)
        return unpack_lua_results(thread._runtime, L)
    finally:
        # FIXME: check that coroutine state is OK in case of errors?
        lua.lua_settop(L, old_top)
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
        self._refiter = lua.LUA_REFNIL
        self._what = what

    def __dealloc__(self):
        if self._runtime is None:
            return
        runtime = self._runtime
        self._runtime = None
        ref = self._refiter
        if ref == lua.LUA_NOREF:
            return
        self._refiter = lua.LUA_NOREF
        cdef lua_State* L = self._state
        if L is not NULL:
            locked = lock_runtime(runtime, blocking=False)
            if locked:
                lua.luaL_unref(L, lua.LUA_REGISTRYINDEX, ref)
                runtime.clean_up_pending_unrefs()  # just in case
                unlock_runtime(runtime)
                return
        runtime.add_pending_unref(ref)

    def __repr__(self):
        return u"LuaIter(%r)" % (self._obj)

    def __iter__(self):
        return self

    def __next__(self):
        if self._obj is None:
            raise StopIteration
        cdef lua_State* L = self._obj._state
        assert self._runtime is not None
        lock_runtime(self._runtime)
        old_top = lua.lua_gettop(L)
        try:
            check_lua_stack(L, 3)
            if self._obj is None:
                raise StopIteration
            # iterable object
            self._obj.push_lua_object(L)
            if not lua.lua_istable(L, -1):
                raise TypeError("cannot iterate over non-table (found %r)" % self._obj)
            if self._refiter == lua.LUA_NOREF:
                # no key
                raise StopIteration
            elif self._refiter == lua.LUA_REFNIL:
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
                    if self._refiter == lua.LUA_REFNIL:
                        self._refiter = lua.luaL_ref(L, lua.LUA_REGISTRYINDEX)
                    else:
                        lua.lua_rawseti(L, lua.LUA_REGISTRYINDEX, self._refiter)
                return retval
            # iteration done, clean up
            if self._refiter != lua.LUA_REFNIL:
                lua.luaL_unref(L, lua.LUA_REGISTRYINDEX, self._refiter)
                self._refiter = lua.LUA_NOREF
            self._obj = None
        finally:
            lua.lua_settop(L, old_top)
            unlock_runtime(self._runtime)
        raise StopIteration

# type conversions and protocol adaptations

cdef int py_asfunc_call(lua_State *L) noexcept nogil:
    if (lua.lua_gettop(L) == 1 and lua.lua_islightuserdata(L, 1)
            and lua.lua_topointer(L, 1) == <void*>unpack_wrapped_pyfunction):
        # special case: unpack_python_argument_or_jump() calls this to find out the Python object
        lua.lua_pushvalue(L, lua.lua_upvalueindex(1))
        return 1
    lua.lua_pushvalue(L, lua.lua_upvalueindex(1))
    lua.lua_insert(L, 1)
    return py_object_call(L)

cdef py_object* unpack_wrapped_pyfunction(lua_State* L, int n) noexcept nogil:
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
    """Convert a Lua object to a Python object by either mapping, wrapping or unwrapping it.
    Preconditions:
        Index n is valid
    """
    cdef size_t size = 0
    cdef const char *s
    cdef lua.lua_Number number
    cdef lua.lua_Integer integer
    cdef py_object* py_obj
    cdef int lua_type = lua.lua_type(L, n)

    if lua_type == lua.LUA_TNIL:
        return None
    elif lua_type == lua.LUA_TNUMBER:
        if lua.LUA_VERSION_NUM >= 503:
            if lua.lua_isinteger(L, n):
                return lua.lua_tointeger(L, n)
            else:
                return lua.lua_tonumber(L, n)
        else:
            number = lua.lua_tonumber(L, n)
            integer = <lua.lua_Integer>number
            if number == integer:
                return integer
            else:
                return number
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
            if not py_obj.obj:
                raise ReferenceError("deleted python object")
            return <object>py_obj.obj
    elif lua_type == lua.LUA_TTABLE:
        return new_lua_table(runtime, L, n)
    elif lua_type == lua.LUA_TTHREAD:
        return new_lua_thread_or_function(runtime, L, n)
    elif lua_type == lua.LUA_TFUNCTION:
        py_obj = unpack_wrapped_pyfunction(L, n)
        if py_obj:
            if not py_obj.obj:
                raise ReferenceError("deleted python object")
            return <object>py_obj.obj
        return new_lua_function(runtime, L, n)
    return new_lua_object(runtime, L, n)

cdef py_object* unpack_userdata(lua_State *L, int n) noexcept nogil:
    """
    Like luaL_checkudata(), unpacks a userdata object and validates that
    it's a wrapped Python object.  Returns NULL on failure.
    """
    if not lua.lua_checkstack(L, 2):
        return NULL
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
         return _len_as_int(len(<tuple>o))
     check_lua_stack(L, 1)
     return py_to_lua(runtime, L, o)

cdef int py_to_lua_handle_overflow(LuaRuntime runtime, lua_State *L, object o) except -1:
    """Converts Python object to Lua via overflow handler
    Preconditions:
        Lua runtime is locked
    Postconditions:
        Returns 0 if cannot convert Python object to Lua (handler not registered or failed)
        Returns 1 if the Python object was converted successfully and pushed onto the stack
    """
    check_lua_stack(L, 2)
    old_top = lua.lua_gettop(L)
    try:
        lua.lua_pushlstring(L, LUPAOFH, len(LUPAOFH))
        lua.lua_rawget(L, lua.LUA_REGISTRYINDEX)
        if lua.lua_isnil(L, -1):
            lua.lua_pop(L, 1)
            return 0
        py_to_lua_custom(runtime, L, o, 0)
        if lua.lua_pcall(L, 1, 1, 0):
            lua.lua_pop(L, 1)
            return 0
        return 1
    except:
        lua.lua_settop(L, old_top)
        raise

cdef int py_to_lua(LuaRuntime runtime, lua_State *L, object o, bint wrap_none=False, bint recursive=False, dict mapped_tables=None) except -1:
    """Converts Python object to Lua
    Preconditions:
        1 extra slot in the Lua stack
        runtime is locked
    Postconditions:
        Returns 0 if cannot convert Python object to Lua
        Returns 1 if the Python object was converted successfully and pushed onto the stack
    """
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
    elif isinstance(o, int):
        try:
            lua.lua_pushinteger(L, <lua.lua_Integer>o)
            pushed_values_count = 1
        except OverflowError:
            pushed_values_count = py_to_lua_handle_overflow(runtime, L, o)
            if pushed_values_count <= 0:
                raise
    elif isinstance(o, bytes):
        lua.lua_pushlstring(L, <char*>(<bytes>o), len(<bytes>o))
        pushed_values_count = 1
    elif isinstance(o, unicode) and runtime._encoding is not None:
        pushed_values_count = push_encoded_unicode_string(runtime, L, <unicode>o)
    elif isinstance(o, _LuaObject):
        if (<_LuaObject>o)._runtime is not runtime:
            raise LuaError("cannot mix objects from different Lua runtimes")
        (<_LuaObject>o).push_lua_object(L)
        pushed_values_count = 1
    elif isinstance(o, float):
        lua.lua_pushnumber(L, <lua.lua_Number><double>o)
        pushed_values_count = 1
    elif isinstance(o, _PyProtocolWrapper):
        type_flags = (<_PyProtocolWrapper> o)._type_flags
        o = (<_PyProtocolWrapper> o)._obj
        pushed_values_count = py_to_lua_custom(runtime, L, o, type_flags)
    elif recursive and isinstance(o, (list, dict, Sequence, Mapping)):
        if mapped_tables is None:
            mapped_tables = {}
        table = py_to_lua_table(runtime, L, (o,), recursive=recursive, mapped_tables=mapped_tables)
        (<_LuaObject> table).push_lua_object(L)
        pushed_values_count = 1
    else:
        # prefer __getitem__ over __getattr__ by default
        type_flags = OBJ_AS_INDEX if hasattr(o, '__getitem__') else 0
        pushed_values_count = py_to_lua_custom(runtime, L, o, type_flags)
    return pushed_values_count


cdef int push_encoded_unicode_string(LuaRuntime runtime, lua_State *L, unicode ustring) except -1:
    cdef bytes bytes_string = ustring.encode(runtime._encoding)
    lua.lua_pushlstring(L, <char*>bytes_string, len(bytes_string))
    return 1


cdef inline tuple build_pyref_key(PyObject* o, int type_flags):
    return (<object><uintptr_t>o, <object>type_flags)


cdef bint py_to_lua_custom(LuaRuntime runtime, lua_State *L, object o, int type_flags) except -1:
    """Wrap Python object into a Lua userdatum with certain type flags
    Preconditions:
        LuaRuntime is locked
    Postconditions:
        Pushes wrapped Python object and returns 1
    """
    cdef py_object* py_obj
    refkey = build_pyref_key(<PyObject*>o, type_flags)
    cdef _PyReference pyref
    check_lua_stack(L, 3)
    old_top = lua.lua_gettop(L)
    try:
        # check if Python object is already referenced in Lua
        lua.lua_getfield(L, lua.LUA_REGISTRYINDEX, PYREFST)  # tbl
        if refkey in runtime._pyrefs_in_lua:
            pyref = <_PyReference>runtime._pyrefs_in_lua[refkey]
            lua.lua_rawgeti(L, -1, pyref._ref)              # tbl udata
            py_obj = <py_object*>lua.lua_touserdata(L, -1)
            if py_obj:
                lua.lua_remove(L, -2)                       # udata
                return 1  # values pushed
            lua.lua_pop(L, 1)                               # tbl

        # create new wrapper for Python object
        py_obj = <py_object*>lua.lua_newuserdata(L, sizeof(py_object))
        py_obj.obj = <PyObject*>o            # tbl udata
        py_obj.runtime = <PyObject*>runtime
        py_obj.type_flags = type_flags
        lua.luaL_getmetatable(L, POBJECT)    # tbl udata metatbl
        lua.lua_setmetatable(L, -2)          # tbl udata
        lua.lua_pushvalue(L, -1)             # tbl udata udata
        pyref = _PyReference.__new__(_PyReference)
        pyref._ref = lua.luaL_ref(L, -3)     # tbl udata
        pyref._obj = o
        lua.lua_remove(L, -2)                # udata

        # originally, we just used:
        #cpython.ref.Py_INCREF(o)
        # now, we store an owned reference in "runtime._pyrefs_in_lua" to keep it visible to Python
        # and a borrowed reference in "py_obj.obj" for access from Lua
        runtime._pyrefs_in_lua[refkey] = pyref
    except:
        lua.lua_settop(L, old_top)
        raise

    return 1  # values pushed


cdef _LuaTable py_to_lua_table(LuaRuntime runtime, lua_State* L, tuple items, bint recursive=False, dict mapped_tables=None):
    """
    Create a new Lua table and add different kinds of values from the sequence 'items' to it.

    Dicts, Mappings and Lua tables are unpacked into key-value pairs.
    Everything else is considered a sequence of plain values that get appended to the table.
    """
    cdef int i = 1
    check_lua_stack(L, 5)
    old_top = lua.lua_gettop(L)
    lua.lua_newtable(L)
    # FIXME: handle allocation errors
    cdef int lua_table_ref = lua.lua_gettop(L)  # the index of the lua table which we are filling
    if recursive and mapped_tables is None:
        mapped_tables = {}
    try:
        for obj in items:
            if recursive:
                if id(obj) not in mapped_tables:
                    # this object is never seen before, we should cache it
                    mapped_tables[id(obj)] = lua_table_ref
                else:
                    # this object has been cached, just get the corresponding lua table's index
                    idx = mapped_tables[id(obj)]
                    return new_lua_table(runtime, L, <int>idx)
            if isinstance(obj, dict):
                for key, value in (<dict>obj).items():
                    py_to_lua(runtime, L, key, wrap_none=True, recursive=recursive, mapped_tables=mapped_tables)
                    py_to_lua(runtime, L, value, wrap_none=False, recursive=recursive, mapped_tables=mapped_tables)
                    lua.lua_rawset(L, -3)

            elif isinstance(obj, _LuaTable):
                # Stack:                               # tbl
                (<_LuaObject> obj).push_lua_object(L)  # tbl, obj
                lua.lua_pushnil(L)            # tbl, obj, nil       // iterate over obj (-2)
                while lua.lua_next(L, -2):    # tbl, obj, k, v
                    lua.lua_pushvalue(L, -2)  # tbl, obj, k, v, k   // copy key (because
                    lua.lua_insert(L, -2)     # tbl, obj, k, k, v   // lua_next needs a key for iteration)
                    lua.lua_settable(L, -5)   # tbl, obj, k         // tbl[k] = v
                lua.lua_pop(L, 1)             # tbl                 // remove obj from stack

            elif isinstance(obj, Mapping):
                for key in obj:
                    value = obj[key]
                    py_to_lua(runtime, L, key, wrap_none=True, recursive=recursive, mapped_tables=mapped_tables)
                    py_to_lua(runtime, L, value, wrap_none=False, recursive=recursive, mapped_tables=mapped_tables)
                    lua.lua_rawset(L, -3)

            else:
                for arg in obj:
                    py_to_lua(runtime, L, arg, wrap_none=False, recursive=recursive, mapped_tables=mapped_tables)
                    lua.lua_rawseti(L, -2, i)
                    i += 1

        return new_lua_table(runtime, L, -1)
    finally:
        lua.lua_settop(L, old_top)


cdef inline int _isascii(unsigned char* s) noexcept:
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
        raise LuaMemoryError()
    else:
        error_message = build_lua_error_message(runtime, L)
        if u"not enough memory" in error_message:
            raise LuaMemoryError(error_message)
        raise LuaError(error_message)


cdef bint _looks_like_traceback_line(unicode line) except -1:
    # Lua tracebacks look like this (using tabs as indentation):
    # stack traceback:
    #    [C]: in function 'error'
    #    [string "<python>"]:1: in main chunk
    cdef Py_UCS4 ch
    cdef bint indentation_seen = False
    for ch in line:
        if ch.isspace():
            indentation_seen = True
        else:
            return indentation_seen and ch == u"["
    return False


cdef unicode _reorder_lua_stack_trace(unicode error_message):
    # Lua tracebacks look like this (using tabs as indentation):
    # stack traceback:
    #    [C]: in function 'error'
    #    [string "<python>"]:1: in main chunk
    cdef Py_ssize_t i, traceback_start = 0
    lines = []
    for i, line in enumerate(error_message.splitlines(), 1):
        if traceback_start > 0 and _looks_like_traceback_line(line):
            lines.insert(traceback_start, line)
        else:
            traceback_start = i if line == u"stack traceback:" else 0
            lines.append(line)

    if traceback_start > 0 and len(lines) > traceback_start + 1:
        error_message = u"\n".join(lines)
    return error_message


cdef build_lua_error_message(LuaRuntime runtime, lua_State* L, int stack_index=-1):
    """Removes the string at the given stack index ``n`` to build an error message.
    """
    cdef size_t size = 0
    cdef const char *s = lua.lua_tolstring(L, stack_index, &size)
    if runtime._encoding is not None:
        try:
            py_ustring = s[:size].decode(runtime._encoding)
        except UnicodeDecodeError:
            py_ustring = s[:size].decode('ISO-8859-1') # safe 'fake' decoding
    else:
        py_ustring = s[:size].decode('ISO-8859-1')
    lua.lua_remove(L, stack_index)

    if u"stack traceback:" in py_ustring:
        py_ustring = _reorder_lua_stack_trace(py_ustring)

    return py_ustring


# calling into Lua

cdef run_lua(LuaRuntime runtime, bytes lua_code, bytes name, bytes mode, tuple args):
    """Run Lua code with arguments"""
    cdef lua_State* L = runtime._state
    cdef const char* c_name = b'<python>'
    cdef const char* c_mode = NULL
    if name is not None:
        c_name = name
    if mode is not None:
        c_mode = mode

    lock_runtime(runtime)
    old_top = lua.lua_gettop(L)
    try:
        check_lua_stack(L, 1)
        if lua.luaL_loadbufferx(L, lua_code, len(lua_code), c_name, c_mode):
            error = build_lua_error_message(runtime, L)
            if error.startswith("not enough memory"):
                raise LuaMemoryError(error)
            raise LuaSyntaxError(u"error loading code: " + error)
        return call_lua(runtime, L, args)
    finally:
        lua.lua_settop(L, old_top)
        unlock_runtime(runtime)

cdef call_lua(LuaRuntime runtime, lua_State *L, tuple args):
    """Call function on top of the stack with args
    Preconditions:
        Function is on top of the stack
        LuaRuntime must be locked
    Postconditions:
        Pops function from the stack and pushes results
    """
    push_lua_arguments(runtime, L, args)
    return execute_lua_call(runtime, L, len(args))

cdef object execute_lua_call(LuaRuntime runtime, lua_State *L, Py_ssize_t nargs):
    cdef int result_status
    cdef object result
    # call into Lua
    cdef bint has_lua_traceback_func = False
    with nogil:
        lua.lua_getglobal(L, "debug")
        if not lua.lua_istable(L, -1):
            lua.lua_pop(L, 1)
        else:
            lua.lua_getfield(L, -1, "traceback")
            if not lua.lua_isfunction(L, -1):
                lua.lua_pop(L, 2)
            else:
                lua.lua_replace(L, -2)
                lua.lua_insert(L, 1)
                has_lua_traceback_func = True
        result_status = lua.lua_pcall(L, <int>nargs, lua.LUA_MULTRET, has_lua_traceback_func)
        if has_lua_traceback_func:
            lua.lua_remove(L, 1)
    runtime.clean_up_pending_unrefs()
    results = unpack_lua_results(runtime, L)
    if result_status:
        if isinstance(results, BaseException):
            runtime.reraise_on_exception()
        raise_lua_error(runtime, L, result_status)
    return results

cdef int push_lua_arguments(LuaRuntime runtime, lua_State *L,
                            tuple args, bint first_may_be_nil=True) except -1:
    """Push Python objects in tuple into Lua stack
    Preconditions:
        LuaRuntime is locked
    Postconditions:
        Pushes each value of the Python tuple into the Lua stack
        Returns number of pushed values
    """
    cdef int i, n
    cdef Py_ssize_t nargs
    cdef bint wrap_none = not first_may_be_nil
    if args:
        nargs = len(args)
        if nargs > INT_MAX:
            raise OverflowError("tuple too large to unpack")
        n = <int>nargs
        check_lua_stack(L, n)
        old_top = lua.lua_gettop(L)
        try:
            for i, arg in enumerate(args):
                if not py_to_lua(runtime, L, arg, wrap_none=wrap_none):
                    raise TypeError("failed to convert argument at index %d" % i)
                wrap_none = False
            return n
        except:
            lua.lua_settop(L, old_top)
            raise
    else:
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


# bounded memory allocation

cdef void* _lua_alloc_restricted(void* ud, void* ptr, size_t old_size, size_t new_size) noexcept nogil:
    # adapted from https://stackoverflow.com/a/9672205
    # print(<size_t>ud, <size_t>ptr, old_size, new_size)
    cdef MemoryStatus* memory_status = <MemoryStatus*>ud
    # print("  ", memory_status.used, memory_status.base_usage, memory_status.limit)

    if ptr is NULL:
        # <http://www.lua.org/manual/5.2/manual.html#lua_Alloc>:
        # When ptr is NULL, old_size encodes the kind of object that Lua is allocating.
        # Since we don’t care about that, just mark it as 0.
        old_size = 0

    cdef void* new_ptr
    if new_size == 0:
        free(ptr)
        memory_status.used -= old_size  # add deallocated old size to available memory
        return NULL
    elif new_size == old_size:
        return ptr

    if memory_status.limit > 0 and new_size > old_size and memory_status.limit <= memory_status.used + new_size - old_size:  # reached the limit
        # print("REACHED LIMIT")
        return NULL
    # print("  realloc()...")
    new_ptr = realloc(ptr, new_size)
    # print("  ", memory_status.used, new_size - old_size, memory_status.used + new_size - old_size)
    if new_ptr is not NULL:
        memory_status.used += new_size - old_size
    return new_ptr

cdef int _lua_panic(lua_State *L) noexcept nogil:
    cdef const char* msg = lua.lua_tostring(L, -1)
    if msg == NULL:
        msg = "error object is not a string"
    cdef char* message = "PANIC: unprotected error in call to Lua API (%s)\n"
    fprintf(stderr, message, msg)
    fflush(stderr)
    return 0  # return to Lua to abort


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

@cython.final
@cython.internal
@cython.freelist(8)
cdef class _PyReference:
    cdef object _obj
    cdef int _ref


cdef int py_object_gc_with_gil(py_object *py_obj, lua_State* L) noexcept with gil:
    cdef _PyReference pyref
    # originally, we just used:
    #cpython.ref.Py_XDECREF(py_obj.obj)
    # now, we keep Python object references in Lua visible to Python in a dict
    runtime = <LuaRuntime>py_obj.runtime
    try:
        refkey = build_pyref_key(py_obj.obj, py_obj.type_flags)
        pyref = <_PyReference>runtime._pyrefs_in_lua.pop(refkey)
    except (TypeError, KeyError):
        return 0  # runtime was already cleared during GC, nothing left to do
    except:
        try: runtime.store_raised_exception(L, b'error while cleaning up a Python object')
        finally: return -1
    else:
        lua.lua_getfield(L, lua.LUA_REGISTRYINDEX, PYREFST)  # tbl
        lua.luaL_unref(L, -1, pyref._ref)                    # tbl
        return 0
    finally:
        py_obj.obj = NULL

cdef int py_object_gc(lua_State* L) noexcept nogil:
    if not lua.lua_isuserdata(L, 1):
        return 0
    py_obj = unpack_userdata(L, 1)
    if py_obj is not NULL and py_obj.obj is not NULL:
        if py_object_gc_with_gil(py_obj, L):
            return lua.lua_error(L)  # never returns!
    return 0

# calling Python objects

cdef bint call_python(LuaRuntime runtime, lua_State *L, py_object* py_obj) except -1:
    # Callers must assure that py_obj.obj is not NULL, i.e. it points to a valid Python object.
    cdef int i, nargs = lua.lua_gettop(L) - 1
    cdef tuple args
    cdef dict kwargs

    f = <object>py_obj.obj

    if nargs == 0:
        lua.lua_settop(L, 0)  # FIXME
        result = f()
    else:
        args = ()
        kwargs = {}

        for i in range(nargs):
            arg = py_from_lua(runtime, L, i+2)
            if isinstance(arg, _PyArguments):
                args += (<_PyArguments>arg).args
                kwargs = dict(**kwargs, **(<_PyArguments>arg).kwargs)
            else:
                args += (arg, )

        if args and PyMethod_Check(f) and (<PyObject*>args[0]) is PyMethod_GET_SELF(f):
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

        lua.lua_settop(L, 0)  # FIXME
        result = f(*args, **kwargs)

    runtime.clean_up_pending_unrefs()
    return py_function_result_to_lua(runtime, L, result)

cdef int py_call_with_gil(lua_State* L, py_object *py_obj) noexcept with gil:
    cdef LuaRuntime runtime = None
    cdef lua_State* stored_state = NULL

    try:
        runtime = <LuaRuntime?>py_obj.runtime
        if runtime._state is not L:
            stored_state = runtime._state
            runtime._state = L
        return call_python(runtime, L, py_obj)
    except:
        try: runtime.store_raised_exception(L, b'error during Python call')
        finally: return -1
    finally:
        if stored_state is not NULL:
            runtime._state = stored_state

cdef int py_object_call(lua_State* L) noexcept nogil:
    cdef py_object* py_obj = unpack_python_argument_or_jump(L, 1) # may not return on error!
    result = py_call_with_gil(L, py_obj)
    if result < 0:
        return lua.lua_error(L)  # never returns!
    return result

# str() support for Python objects

cdef int py_str_with_gil(lua_State* L, py_object* py_obj) noexcept with gil:
    cdef LuaRuntime runtime
    try:
        runtime = <LuaRuntime?>py_obj.runtime
        s = str(<object>py_obj.obj)
        if isinstance(s, unicode):
            if runtime._encoding is None:
                s = (<unicode>s).encode('UTF-8')
            else:
                s = (<unicode>s).encode(runtime._encoding)
        else:
            assert isinstance(s, bytes)
        lua.lua_pushlstring(L, <bytes>s, len(<bytes>s))
        return 1 # returning 1 value
    except:
        try: runtime.store_raised_exception(L, b'error during Python str() call')
        finally: return -1

cdef int py_object_str(lua_State* L) noexcept nogil:
    cdef py_object* py_obj = unpack_python_argument_or_jump(L, 1) # may not return on error!
    result = py_str_with_gil(L, py_obj)
    if result < 0:
        return lua.lua_error(L)  # never returns!
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
    if isinstance(attr_name, bytes):
        attr_name = (<bytes>attr_name).decode(runtime._source_encoding)
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
        if isinstance(attr_name, bytes):
            attr_name = (<bytes>attr_name).decode(runtime._source_encoding)
        setattr(obj, attr_name, attr_value)
    return 0


cdef int py_object_getindex_with_gil(lua_State* L, py_object* py_obj) noexcept with gil:
    cdef LuaRuntime runtime
    try:
        runtime = <LuaRuntime?>py_obj.runtime
        if (py_obj.type_flags & OBJ_AS_INDEX) and not runtime._attribute_getter:
            return getitem_for_lua(runtime, L, py_obj, 2)
        else:
            return getattr_for_lua(runtime, L, py_obj, 2)
    except:
        try: runtime.store_raised_exception(L, b'error reading Python attribute/item')
        finally: return -1

cdef int py_object_getindex(lua_State* L) noexcept nogil:
    cdef py_object* py_obj = unpack_python_argument_or_jump(L, 1) # may not return on error!
    result = py_object_getindex_with_gil(L, py_obj)
    if result < 0:
        return lua.lua_error(L)  # never returns!
    return result


cdef int py_object_setindex_with_gil(lua_State* L, py_object* py_obj) noexcept with gil:
    cdef LuaRuntime runtime
    try:
        runtime = <LuaRuntime?>py_obj.runtime
        if (py_obj.type_flags & OBJ_AS_INDEX) and not runtime._attribute_setter:
            return setitem_for_lua(runtime, L, py_obj, 2, 3)
        else:
            return setattr_for_lua(runtime, L, py_obj, 2, 3)
    except:
        try: runtime.store_raised_exception(L, b'error writing Python attribute/item')
        finally: return -1

cdef int py_object_setindex(lua_State* L) noexcept nogil:
    cdef py_object* py_obj = unpack_python_argument_or_jump(L, 1) # may not return on error!
    result = py_object_setindex_with_gil(L, py_obj)
    if result < 0:
        return lua.lua_error(L)  # never returns!
    return result

# special methods for Lua wrapped Python objects

cdef lua.luaL_Reg *py_object_lib = [
    lua.luaL_Reg(name = "__call",     func = <lua.lua_CFunction> py_object_call),
    lua.luaL_Reg(name = "__index",    func = <lua.lua_CFunction> py_object_getindex),
    lua.luaL_Reg(name = "__newindex", func = <lua.lua_CFunction> py_object_setindex),
    lua.luaL_Reg(name = "__tostring", func = <lua.lua_CFunction> py_object_str),
    lua.luaL_Reg(name = "__gc",       func = <lua.lua_CFunction> py_object_gc),
    lua.luaL_Reg(name = NULL, func = NULL),
]

## # Python helper functions for Lua

cdef inline py_object* unpack_single_python_argument_or_jump(lua_State* L) noexcept nogil:
    if lua.lua_gettop(L) > 1:
        lua.luaL_argerror(L, 2, "invalid arguments")   # never returns!
    return unpack_python_argument_or_jump(L, 1)

cdef inline py_object* unpack_python_argument_or_jump(lua_State* L, int n) noexcept nogil:
    cdef py_object* py_obj

    if lua.lua_isuserdata(L, n):
        py_obj = unpack_userdata(L, n)
    else:
        py_obj = unpack_wrapped_pyfunction(L, n)

    if not py_obj:
        lua.luaL_argerror(L, n, "not a python object")   # never returns!
    if not py_obj.obj:
        lua.luaL_argerror(L, n, "deleted python object") # never returns!

    return py_obj

cdef int py_wrap_object_protocol_with_gil(lua_State* L, py_object* py_obj, int type_flags) noexcept with gil:
    cdef LuaRuntime runtime
    try:
        runtime = <LuaRuntime?>py_obj.runtime
        return py_to_lua_custom(runtime, L, <object>py_obj.obj, type_flags)
    except:
        try: runtime.store_raised_exception(L, b'error during type adaptation')
        finally: return -1

cdef int py_wrap_object_protocol(lua_State* L, int type_flags) noexcept nogil:
    cdef py_object* py_obj = unpack_single_python_argument_or_jump(L) # never returns on error!
    result = py_wrap_object_protocol_with_gil(L, py_obj, type_flags)
    if result < 0:
        return lua.lua_error(L)  # never returns!
    return result

cdef int py_as_attrgetter(lua_State* L) noexcept nogil:
    return py_wrap_object_protocol(L, 0)

cdef int py_as_itemgetter(lua_State* L) noexcept nogil:
    return py_wrap_object_protocol(L, OBJ_AS_INDEX)

cdef int py_as_function(lua_State* L) noexcept nogil:
    cdef py_object* py_obj = unpack_single_python_argument_or_jump(L) # never returns on error!
    lua.lua_pushcclosure(L, <lua.lua_CFunction>py_asfunc_call, 1)
    return 1

# iteration support for Python objects in Lua

cdef int py_iter(lua_State* L) noexcept nogil:
    cdef py_object* py_obj = unpack_single_python_argument_or_jump(L) # never returns on error!
    result = py_iter_with_gil(L, py_obj, 0)
    if result < 0:
        return lua.lua_error(L)  # never returns!
    return result

cdef int py_iterex(lua_State* L) noexcept nogil:
    cdef py_object* py_obj = unpack_single_python_argument_or_jump(L) # never returns on error!
    result = py_iter_with_gil(L, py_obj, OBJ_UNPACK_TUPLE)
    if result < 0:
        return lua.lua_error(L)  # never returns!
    return result

cdef int convert_to_lua_Integer(lua_State* L, int idx, lua.lua_Integer* integer) noexcept nogil:
    cdef int isnum
    cdef lua.lua_Integer temp
    temp = lua.lua_tointegerx(L, idx, &isnum)
    if isnum:
        integer[0] = temp
        return 0
    else:
        lua.lua_pushfstring(L, "Could not convert %s to string", lua.luaL_typename(L, idx))
        return -1

cdef int py_enumerate(lua_State* L) noexcept nogil:
    if lua.lua_gettop(L) > 2:
        lua.luaL_argerror(L, 3, "invalid arguments")   # never returns!
    cdef py_object* py_obj = unpack_python_argument_or_jump(L, 1)
    cdef lua.lua_Integer start
    if lua.lua_gettop(L) == 2:
        if convert_to_lua_Integer(L, -1, &start) < 0:
            return lua.lua_error(L)  # never returns
    else:
        start = 0
    result = py_enumerate_with_gil(L, py_obj, start)
    if result < 0:
        return lua.lua_error(L)  # never returns!
    return result


cdef int py_enumerate_with_gil(lua_State* L, py_object* py_obj, lua.lua_Integer start) noexcept with gil:
    cdef LuaRuntime runtime
    try:
        runtime = <LuaRuntime?>py_obj.runtime
        obj = iter(<object>py_obj.obj)
        return py_push_iterator(runtime, L, obj, OBJ_ENUMERATOR, start - 1)
    except:
        try: runtime.store_raised_exception(L, b'error creating an iterator with enumerate()')
        finally: return -1

cdef int py_iter_with_gil(lua_State* L, py_object* py_obj, int type_flags) noexcept with gil:
    cdef LuaRuntime runtime
    try:
        runtime = <LuaRuntime?>py_obj.runtime
        obj = iter(<object>py_obj.obj)
        return py_push_iterator(runtime, L, obj, type_flags, 0)
    except:
        try: runtime.store_raised_exception(L, b'error creating an iterator')
        finally: return -1

cdef int py_push_iterator(LuaRuntime runtime, lua_State* L, iterator, int type_flags,
                          lua.lua_Integer initial_value) except -2:
    """Pushes iterator function, invariant state variable and control variable
    Preconditions:
        3 extra slots in the Lua stack
        LuaRuntime is locked
    Postconditions:
        Pushes py_iter_next, iterator and the control variable
        Returns the number of pushed values
    """
    # push the iterator function
    lua.lua_pushcfunction(L, <lua.lua_CFunction>py_iter_next)
    # push the wrapped iterator object as for-loop state object
    if runtime._unpack_returned_tuples:
        type_flags |= OBJ_UNPACK_TUPLE
    py_to_lua_custom(runtime, L, iterator, type_flags)
    # push either enumerator index or nil as control variable value
    if type_flags & OBJ_ENUMERATOR:
        lua.lua_pushinteger(L, initial_value)
    else:
        lua.lua_pushnil(L)
    return 3

cdef int py_iter_next(lua_State* L) noexcept nogil:
    # first value in the C closure: the Python iterator object
    cdef py_object* py_obj = unpack_python_argument_or_jump(L, 1) # may not return on error!
    result = py_iter_next_with_gil(L, py_obj)
    if result < 0:
        return lua.lua_error(L)  # never returns!
    return result

cdef int py_iter_next_with_gil(lua_State* L, py_object* py_iter) noexcept with gil:
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
            lua.lua_pushinteger(L, lua.lua_tointeger(L, -1) + 1)
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
        try: runtime.store_raised_exception(L, b'error while calling next(iterator)')
        finally: return -1

# support for calling Python objects in Lua with Python-like arguments

cdef class _PyArguments:
    cdef tuple args
    cdef dict kwargs

cdef int py_args_with_gil(PyObject* runtime_obj, lua_State* L) noexcept with gil:
    cdef _PyArguments pyargs
    cdef LuaRuntime runtime
    try:
        runtime = <LuaRuntime?>runtime_obj
        pyargs = _PyArguments.__new__(_PyArguments)
        pyargs.args, pyargs.kwargs = unpack_lua_table(runtime, L)
        return py_to_lua_custom(runtime, L, pyargs, 0)
    except:
        try: runtime.store_raised_exception(L, b'error while calling python.args()')
        finally: return -1

cdef int py_args(lua_State* L) noexcept nogil:
    cdef PyObject* runtime
    runtime = <PyObject*>lua.lua_touserdata(L, lua.lua_upvalueindex(1))
    if not runtime:
        return lua.luaL_error(L, "missing runtime")
    lua.luaL_checktype(L, 1, lua.LUA_TTABLE)
    result = py_args_with_gil(runtime, L)
    if result < 0:
        return lua.lua_error(L) # never returns!
    return result

# overflow handler setter

cdef int py_set_overflow_handler(lua_State* L) noexcept nogil:
    if (not lua.lua_isnil(L, 1)
            and not lua.lua_isfunction(L, 1)
            and not unpack_python_argument_or_jump(L, 1)):
        return lua.luaL_argerror(L, 1, "expected nil, a Lua function or a callable Python object")
                                                         # hdl [...]
    lua.lua_settop(L, 1)                                 # hdl
    lua.lua_setfield(L, lua.LUA_REGISTRYINDEX, LUPAOFH)  #
    return 0

# 'python' module functions in Lua

cdef lua.luaL_Reg *py_lib = [
    lua.luaL_Reg(name = "as_attrgetter",        func = <lua.lua_CFunction> py_as_attrgetter),
    lua.luaL_Reg(name = "as_itemgetter",        func = <lua.lua_CFunction> py_as_itemgetter),
    lua.luaL_Reg(name = "as_function",          func = <lua.lua_CFunction> py_as_function),
    lua.luaL_Reg(name = "iter",                 func = <lua.lua_CFunction> py_iter),
    lua.luaL_Reg(name = "iterex",               func = <lua.lua_CFunction> py_iterex),
    lua.luaL_Reg(name = "enumerate",            func = <lua.lua_CFunction> py_enumerate),
    lua.luaL_Reg(name = "set_overflow_handler", func = <lua.lua_CFunction> py_set_overflow_handler),
    lua.luaL_Reg(name = NULL, func = NULL),
]

# Setup helpers for library tables (removed from C-API in Lua 5.3).

cdef void luaL_setfuncs(lua_State *L, const lua.luaL_Reg *l, int nup) noexcept:
    cdef int i
    lua.luaL_checkstack(L, nup, "too many upvalues")
    while l.name != NULL:
        for i in range(nup):
            lua.lua_pushvalue(L, -nup)
        lua.lua_pushcclosure(L, l.func, nup)
        lua.lua_setfield(L, -(nup + 2), l.name)
        l += 1
    lua.lua_pop(L, nup)


cdef int libsize(const lua.luaL_Reg *l) noexcept:
    cdef int size = 0
    while l and l.name:
        l += 1
        size += 1
    return size


cdef const char *luaL_findtable(lua_State *L, int idx,
                                const char *fname, int size_hint) noexcept:
    cdef const char *end
    if idx:
        lua.lua_pushvalue(L, idx)

    while True:
        end = strchr(fname, '.')
        if end == NULL:
            end = fname + strlen(fname)
        lua.lua_pushlstring(L, fname, end - fname)
        lua.lua_rawget(L, -2)
        if lua.lua_type(L, -1) == lua.LUA_TNIL:
            lua.lua_pop(L, 1)
            lua.lua_createtable(L, 0, (1 if end[0] == '.' else size_hint))
            lua.lua_pushlstring(L, fname, end - fname)
            lua.lua_pushvalue(L, -2)
            lua.lua_settable(L, -4)
        elif not lua.lua_istable(L, -1):
            lua.lua_pop(L, 2)
            return fname
        lua.lua_remove(L, -2)
        fname = end + 1
        if end[0] != '.':
            break
    return NULL


cdef void luaL_pushmodule(lua_State *L, const char *modname, int size_hint) noexcept:
    # XXX: "_LOADED" is the value of LUA_LOADED_TABLE,
    # but it's absent in lua51
    luaL_findtable(L, lua.LUA_REGISTRYINDEX, "_LOADED", 1)
    lua.lua_getfield(L, -1, modname)
    if lua.lua_type(L, -1) != lua.LUA_TTABLE:
        lua.lua_pop(L, 1)
        lua.lua_getglobal(L, '_G')
        if luaL_findtable(L, 0, modname, size_hint) != NULL:
            lua.luaL_error(L, "name conflict for module '%s'", modname)
        lua.lua_pushvalue(L, -1)
        lua.lua_setfield(L, -3, modname)
    lua.lua_remove(L, -2)


cdef void luaL_openlib(lua_State *L, const char *libname,
                       const lua.luaL_Reg *l, int nup) noexcept:
    if libname:
        luaL_pushmodule(L, libname, libsize(l))
        lua.lua_insert(L, -(nup + 1))
    if l:
        luaL_setfuncs(L, l, nup)
    else:
        lua.lua_pop(L, nup)

# internal Lua functions meant to be called in protected mode

cdef int get_from_lua_table(lua_State* L) noexcept nogil:
    """Equivalent to the following Lua function:
    function(t, k) return t[k] end
    """
                            # tbl key [...]
    lua.lua_settop(L, 2)    # tbl key
    lua.lua_gettable(L, 1)  # tbl tbl[key]
    return 1
