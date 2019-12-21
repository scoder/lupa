Lupa
====

.. image:: logo/logo-220x200.png

Lupa integrates the runtimes of Lua_ or LuaJIT2_ into CPython.
It is a partial rewrite of LunaticPython_ in Cython_ with some
additional features such as proper coroutine support.

.. _Lua: http://lua.org/
.. _LuaJIT2: http://luajit.org/
.. _LunaticPython: http://labix.org/lunatic-python
.. _Cython: http://cython.org

For questions not answered here, please contact the `Lupa mailing list`_.

.. _`Lupa mailing list`: http://www.freelists.org/list/lupa-dev

.. contents:: :local:


Major features
--------------

* separate Lua runtime states through a ``LuaRuntime`` class

* Python coroutine wrapper for Lua coroutines

* iteration support for Python objects in Lua and Lua objects in
  Python

* proper encoding and decoding of strings (configurable per runtime,
  UTF-8 by default)

* frees the GIL and supports threading in separate runtimes when
  calling into Lua

* tested with Python 2.6/3.2 and later

* written for LuaJIT2 (tested with LuaJIT 2.0.2), but also works
  with the normal Lua interpreter (5.1 and 5.2)

* easy to hack on and extend as it is written in Cython, not C


Why the name?
-------------

In Latin, "lupa" is a female wolf, as elegant and wild as it sounds.
If you don't like this kind of straight forward allegory to an
endangered species, you may also happily assume it's just an
amalgamation of the phonetic sounds that start the words "Lua" and
"Python", two from each to keep the balance.


Why use it?
-----------

It complements Python very well.  Lua is a language as dynamic as
Python, but LuaJIT compiles it to very fast machine code, sometimes
faster than many statically compiled languages for computational code.
The language runtime is very small and carefully designed for
embedding.  The complete binary module of Lupa, including a statically
linked LuaJIT2 runtime, only weighs some 700KB on a 64 bit machine.
With standard Lua 5.1, it's less than 400KB.

However, the Lua ecosystem lacks many of the batteries that Python
readily includes, either directly in its standard library or as third
party packages. This makes real-world Lua applications harder to write
than equivalent Python applications. Lua is therefore not commonly
used as primary language for large applications, but it makes for a
fast, high-level and resource-friendly backup language inside of
Python when raw speed is required and the edit-compile-run cycle of
binary extension modules is too heavy and too static for agile
development or hot-deployment.

Lupa is a very fast and thin wrapper around Lua or LuaJIT.  It makes it
easy to write dynamic Lua code that accompanies dynamic Python code by
switching between the two languages at runtime, based on the tradeoff
between simplicity and speed.


Examples
--------

..
      ## doctest helpers:
      >>> try: _ = sorted
      ... except NameError:
      ...     def sorted(seq):
      ...         l = list(seq)
      ...         l.sort()
      ...         return l

.. code:: python

      >>> import lupa
      >>> from lupa import LuaRuntime
      >>> lua = LuaRuntime(unpack_returned_tuples=True)

      >>> lua.eval('1+1')
      2

      >>> lua_func = lua.eval('function(f, n) return f(n) end')

      >>> def py_add1(n): return n+1
      >>> lua_func(py_add1, 2)
      3

      >>> lua.eval('python.eval(" 2 ** 2 ")') == 4
      True
      >>> lua.eval('python.builtins.str(4)') == '4'
      True

The function ``lua_type(obj)`` can be used to find out the type of a
wrapped Lua object in Python code, as provided by Lua's ``type()``
function:

.. code:: python

      >>> lupa.lua_type(lua_func)
      'function'
      >>> lupa.lua_type(lua.eval('{}'))
      'table'

To help in distinguishing between wrapped Lua objects and normal
Python objects, it returns ``None`` for the latter:

.. code:: python

      >>> lupa.lua_type(123) is None
      True
      >>> lupa.lua_type('abc') is None
      True
      >>> lupa.lua_type({}) is None
      True

Note the flag ``unpack_returned_tuples=True`` that is passed to create
the Lua runtime.  It is new in Lupa 0.21 and changes the behaviour of
tuples that get returned by Python functions.  With this flag, they
explode into separate Lua values:

.. code:: python

      >>> lua.execute('a,b,c = python.eval("(1,2)")')
      >>> g = lua.globals()
      >>> g.a
      1
      >>> g.b
      2
      >>> g.c is None
      True

When set to False, functions that return a tuple pass it through to the
Lua code:

.. code:: python

      >>> non_explode_lua = lupa.LuaRuntime(unpack_returned_tuples=False)
      >>> non_explode_lua.execute('a,b,c = python.eval("(1,2)")')
      >>> g = non_explode_lua.globals()
      >>> g.a
      (1, 2)
      >>> g.b is None
      True
      >>> g.c is None
      True

Since the default behaviour (to not explode tuples) might change in a
later version of Lupa, it is best to always pass this flag explicitly.


Python objects in Lua
---------------------

Python objects are either converted when passed into Lua (e.g.
numbers and strings) or passed as wrapped object references.

.. code:: python

      >>> wrapped_type = lua.globals().type     # Lua's own type() function
      >>> wrapped_type(1) == 'number'
      True
      >>> wrapped_type('abc') == 'string'
      True

Wrapped Lua objects get unwrapped when they are passed back into Lua,
and arbitrary Python objects get wrapped in different ways:

.. code:: python

      >>> wrapped_type(wrapped_type) == 'function'  # unwrapped Lua function
      True
      >>> wrapped_type(len) == 'userdata'       # wrapped Python function
      True
      >>> wrapped_type([]) == 'userdata'        # wrapped Python object
      True

Lua supports two main protocols on objects: calling and indexing.  It
does not distinguish between attribute access and item access like
Python does, so the Lua operations ``obj[x]`` and ``obj.x`` both map
to indexing.  To decide which Python protocol to use for Lua wrapped
objects, Lupa employs a simple heuristic.

Pratically all Python objects allow attribute access, so if the object
also has a ``__getitem__`` method, it is preferred when turning it
into an indexable Lua object.  Otherwise, it becomes a simple object
that uses attribute access for indexing from inside Lua.

Obviously, this heuristic will fail to provide the required behaviour
in many cases, e.g. when attribute access is required to an object
that happens to support item access.  To be explicit about the
protocol that should be used, Lupa provides the helper functions
``as_attrgetter()`` and ``as_itemgetter()`` that restrict the view on
an object to a certain protocol, both from Python and from inside
Lua:

.. code:: python

      >>> lua_func = lua.eval('function(obj) return obj["get"] end')
      >>> d = {'get' : 'value'}

      >>> value = lua_func(d)
      >>> value == d['get'] == 'value'
      True

      >>> value = lua_func( lupa.as_itemgetter(d) )
      >>> value == d['get'] == 'value'
      True

      >>> dict_get = lua_func( lupa.as_attrgetter(d) )
      >>> dict_get == d.get
      True
      >>> dict_get('get') == d.get('get') == 'value'
      True

      >>> lua_func = lua.eval(
      ...     'function(obj) return python.as_attrgetter(obj)["get"] end')
      >>> dict_get = lua_func(d)
      >>> dict_get('get') == d.get('get') == 'value'
      True

Note that unlike Lua function objects, callable Python objects support
indexing in Lua:

.. code:: python

      >>> def py_func(): pass
      >>> py_func.ATTR = 2

      >>> lua_func = lua.eval('function(obj) return obj.ATTR end')
      >>> lua_func(py_func)
      2
      >>> lua_func = lua.eval(
      ...     'function(obj) return python.as_attrgetter(obj).ATTR end')
      >>> lua_func(py_func)
      2
      >>> lua_func = lua.eval(
      ...     'function(obj) return python.as_attrgetter(obj)["ATTR"] end')
      >>> lua_func(py_func)
      2


Iteration in Lua
----------------

Iteration over Python objects from Lua's for-loop is fully supported.
However, Python iterables need to be converted using one of the
utility functions which are described here.  This is similar to the
functions like ``pairs()`` in Lua.

To iterate over a plain Python iterable, use the ``python.iter()``
function.  For example, you can manually copy a Python list into a Lua
table like this:

.. code:: python

      >>> lua_copy = lua.eval('''
      ...     function(L)
      ...         local t, i = {}, 1
      ...         for item in python.iter(L) do
      ...             t[i] = item
      ...             i = i + 1
      ...         end
      ...         return t
      ...     end
      ... ''')

      >>> table = lua_copy([1,2,3,4])
      >>> len(table)
      4
      >>> table[1]   # Lua indexing
      1

Python's ``enumerate()`` function is also supported, so the above
could be simplified to:

.. code:: python

      >>> lua_copy = lua.eval('''
      ...     function(L)
      ...         local t = {}
      ...         for index, item in python.enumerate(L) do
      ...             t[ index+1 ] = item
      ...         end
      ...         return t
      ...     end
      ... ''')

      >>> table = lua_copy([1,2,3,4])
      >>> len(table)
      4
      >>> table[1]   # Lua indexing
      1

For iterators that return tuples, such as ``dict.iteritems()``, it is
convenient to use the special ``python.iterex()`` function that
automatically explodes the tuple items into separate Lua arguments:

.. code:: python

      >>> lua_copy = lua.eval('''
      ...     function(d)
      ...         local t = {}
      ...         for key, value in python.iterex(d.items()) do
      ...             t[key] = value
      ...         end
      ...         return t
      ...     end
      ... ''')

      >>> d = dict(a=1, b=2, c=3)
      >>> table = lua_copy( lupa.as_attrgetter(d) )
      >>> table['b']
      2

Note that accessing the ``d.items`` method from Lua requires passing
the dict as ``attrgetter``.  Otherwise, attribute access in Lua would
use the ``getitem`` protocol of Python dicts and look up ``d['items']``
instead.


None vs. nil
------------

While ``None`` in Python and ``nil`` in Lua differ in their semantics, they
usually just mean the same thing: no value.  Lupa therefore tries to map one
directly to the other whenever possible:

.. code:: python

      >>> lua.eval('nil') is None
      True
      >>> is_nil = lua.eval('function(x) return x == nil end')
      >>> is_nil(None)
      True

The only place where this cannot work is during iteration, because Lua
considers a ``nil`` value the termination marker of iterators.  Therefore,
Lupa special cases ``None`` values here and replaces them by a constant
``python.none`` instead of returning ``nil``:

.. code:: python

      >>> _ = lua.require("table")
      >>> func = lua.eval('''
      ...     function(items)
      ...         local t = {}
      ...         for value in python.iter(items) do
      ...             table.insert(t, value == python.none)
      ...         end
      ...         return t
      ...     end
      ... ''')

      >>> items = [1, None ,2]
      >>> list(func(items).values())
      [False, True, False]

Lupa avoids this value escaping whenever it's obviously not necessary.
Thus, when unpacking tuples during iteration, only the first value will
be subject to ``python.none`` replacement, as Lua does not look at the
other items for loop termination anymore.  And on ``enumerate()``
iteration, the first value is known to be always a number and never None,
so no replacement is needed.

.. code:: python

      >>> func = lua.eval('''
      ...     function(items)
      ...         for a, b, c, d in python.iterex(items) do
      ...             return {a == python.none, a == nil,   -->  a == python.none
      ...                     b == python.none, b == nil,   -->  b == nil
      ...                     c == python.none, c == nil,   -->  c == nil
      ...                     d == python.none, d == nil}   -->  d == nil ...
      ...         end
      ...     end
      ... ''')

      >>> items = [(None, None, None, None)]
      >>> list(func(items).values())
      [True, False, False, True, False, True, False, True]

      >>> items = [(None, None)]   # note: no values for c/d => nil in Lua
      >>> list(func(items).values())
      [True, False, False, True, False, True, False, True]


Note that this behaviour changed in Lupa 1.0.  Previously, the ``python.none``
replacement was done in more places, which made it not always very predictable.


Lua Tables
----------

Lua tables mimic Python's mapping protocol.  For the special case of
array tables, Lua automatically inserts integer indices as keys into
the table.  Therefore, indexing starts from 1 as in Lua instead of 0
as in Python.  For the same reason, negative indexing does not work.
It is best to think of Lua tables as mappings rather than arrays, even
for plain array tables.

.. code:: python

      >>> table = lua.eval('{10,20,30,40}')
      >>> table[1]
      10
      >>> table[4]
      40
      >>> list(table)
      [1, 2, 3, 4]
      >>> list(table.values())
      [10, 20, 30, 40]
      >>> len(table)
      4

      >>> mapping = lua.eval('{ [1] = -1 }')
      >>> list(mapping)
      [1]

      >>> mapping = lua.eval('{ [20] = -20; [3] = -3 }')
      >>> mapping[20]
      -20
      >>> mapping[3]
      -3
      >>> sorted(mapping.values())
      [-20, -3]
      >>> sorted(mapping.items())
      [(3, -3), (20, -20)]

      >>> mapping[-3] = 3     # -3 used as key, not index!
      >>> mapping[-3]
      3
      >>> sorted(mapping)
      [-3, 3, 20]
      >>> sorted(mapping.items())
      [(-3, 3), (3, -3), (20, -20)]

To simplify the table creation from Python, the ``LuaRuntime`` comes with
a helper method that creates a Lua table from Python arguments:

.. code:: python

      >>> t = lua.table(1, 2, 3, 4)
      >>> lupa.lua_type(t)
      'table'
      >>> list(t)
      [1, 2, 3, 4]

      >>> t = lua.table(1, 2, 3, 4, a=1, b=2)
      >>> t[3]
      3
      >>> t['b']
      2

A second helper method, ``.table_from()``, is new in Lupa 1.1 and accepts
any number of mappings and sequences/iterables as arguments.  It collects
all values and key-value pairs and builds a single Lua table from them.
Any keys that appear in multiple mappings get overwritten with their last
value (going from left to right).

.. code:: python

      >>> t = lua.table_from([1, 2, 3], {'a': 1, 'b': 2}, (4, 5), {'b': 42})
      >>> t['b']
      42
      >>> t[5]
      5

A lookup of non-existing keys or indices returns None (actually ``nil``
inside of Lua).  A lookup is therefore more similar to the ``.get()``
method of Python dicts than to a mapping lookup in Python.

.. code:: python

      >>> table[1000000] is None
      True
      >>> table['no such key'] is None
      True
      >>> mapping['no such key'] is None
      True

Note that ``len()`` does the right thing for array tables but does not
work on mappings:

.. code:: python

      >>> len(table)
      4
      >>> len(mapping)
      0

This is because ``len()`` is based on the ``#`` (length) operator in
Lua and because of the way Lua defines the length of a table.
Remember that unset table indices always return ``nil``, including
indices outside of the table size.  Thus, Lua basically looks for an
index that returns ``nil`` and returns the index before that.  This
works well for array tables that do not contain ``nil`` values, gives
barely predictable results for tables with 'holes' and does not work
at all for mapping tables.  For tables with both sequential and
mapping content, this ignores the mapping part completely.

Note that it is best not to rely on the behaviour of len() for
mappings.  It might change in a later version of Lupa.

Similar to the table interface provided by Lua, Lupa also supports
attribute access to table members:

.. code:: python

      >>> table = lua.eval('{ a=1, b=2 }')
      >>> table.a, table.b
      (1, 2)
      >>> table.a == table['a']
      True

This enables access to Lua 'methods' that are associated with a table,
as used by the standard library modules:

.. code:: python

      >>> string = lua.eval('string')    # get the 'string' library table
      >>> print( string.lower('A') )
      a


Python Callables
----------------

As discussed earlier, Lupa allows Lua scripts to call Python functions
and methods:

.. code:: python

      >>> def add_one(num):
      ...     return num + 1
      >>> lua_func = lua.eval('function(num, py_func) return py_func(num) end')
      >>> lua_func(48, add_one)
      49

      >>> class MyClass():
      ...     def my_method(self):
      ...         return 345
      >>> obj = MyClass()
      >>> lua_func = lua.eval('function(py_obj) return py_obj:my_method() end')
      >>> lua_func(obj)
      345

Lua doesn't have a dedicated syntax for named arguments, so by default
Python callables can only be called using positional arguments.

A common pattern for implementing named arguments in Lua is passing them
in a table as the first and only function argument.  See
http://lua-users.org/wiki/NamedParameters for more details.  Lupa supports
this pattern by providing two decorators: ``lupa.unpacks_lua_table``
for Python functions and ``lupa.unpacks_lua_table_method`` for methods
of Python objects.

Python functions/methods wrapped in these decorators can be called from
Lua code as ``func(foo, bar)``, ``func{foo=foo, bar=bar}``
or ``func{foo, bar=bar}``.  Example:

.. code:: python

      >>> @lupa.unpacks_lua_table
      ... def add(a, b):
      ...     return a + b
      >>> lua_func = lua.eval('function(a, b, py_func) return py_func{a=a, b=b} end')
      >>> lua_func(5, 6, add)
      11
      >>> lua_func = lua.eval('function(a, b, py_func) return py_func{a, b=b} end')
      >>> lua_func(5, 6, add)
      11

If you do not control the function implementation, you can also just
manually wrap a callable object when passing it into Lupa:

.. code:: python

      >>> import operator
      >>> wrapped_py_add = lupa.unpacks_lua_table(operator.add)

      >>> lua_func = lua.eval('function(a, b, py_func) return py_func{a, b} end')
      >>> lua_func(5, 6, wrapped_py_add)
      11

There are some limitations:

1. Avoid using ``lupa.unpacks_lua_table`` and ``lupa.unpacks_lua_table_method``
   for functions where the first argument can be a Lua table.  In this case
   ``py_func{foo=bar}`` (which is the same as ``py_func({foo=bar})`` in Lua)
   becomes ambiguous: it could mean either "call ``py_func`` with a named
   ``foo`` argument" or "call ``py_func`` with a positional ``{foo=bar}``
   argument".

2. One should be careful with passing ``nil`` values to callables wrapped in
   ``lupa.unpacks_lua_table`` or ``lupa.unpacks_lua_table_method`` decorators.
   Depending on the context, passing ``nil`` as a parameter can mean either
   "omit a parameter" or "pass None".  This even depends on the Lua version.

   It is possible to use ``python.none`` instead of ``nil`` to pass None values
   robustly.  Arguments with ``nil`` values are also fine when standard braces
   ``func(a, b, c)`` syntax is used.

Because of these limitations lupa doesn't enable named arguments for all
Python callables automatically.  Decorators allow to enable named arguments
on a per-callable basis.


Lua Coroutines
--------------

The next is an example of Lua coroutines.  A wrapped Lua coroutine
behaves exactly like a Python coroutine.  It needs to get created at
the beginning, either by using the ``.coroutine()`` method of a
function or by creating it in Lua code.  Then, values can be sent into
it using the ``.send()`` method or it can be iterated over.  Note that
the ``.throw()`` method is not supported, though.

.. code:: python

      >>> lua_code = '''\
      ...     function(N)
      ...         for i=0,N do
      ...             coroutine.yield( i%2 )
      ...         end
      ...     end
      ... '''
      >>> lua = LuaRuntime()
      >>> f = lua.eval(lua_code)

      >>> gen = f.coroutine(4)
      >>> list(enumerate(gen))
      [(0, 0), (1, 1), (2, 0), (3, 1), (4, 0)]

An example where values are passed into the coroutine using its
``.send()`` method:

.. code:: python

      >>> lua_code = '''\
      ...     function()
      ...         local t,i = {},0
      ...         local value = coroutine.yield()
      ...         while value do
      ...             t[i] = value
      ...             i = i + 1
      ...             value = coroutine.yield()
      ...         end
      ...         return t
      ...     end
      ... '''
      >>> f = lua.eval(lua_code)

      >>> co = f.coroutine()   # create coroutine
      >>> co.send(None)        # start coroutine (stops at first yield)

      >>> for i in range(3):
      ...     co.send(i*2)

      >>> mapping = co.send(None)   # loop termination signal
      >>> sorted(mapping.items())
      [(0, 0), (1, 2), (2, 4)]

It also works to create coroutines in Lua and to pass them back into
Python space:

.. code:: python

      >>> lua_code = '''\
      ...   function f(N)
      ...         for i=0,N do
      ...             coroutine.yield( i%2 )
      ...         end
      ...   end ;
      ...   co1 = coroutine.create(f) ;
      ...   co2 = coroutine.create(f) ;
      ...
      ...   status, first_result = coroutine.resume(co2, 2) ;   -- starting!
      ...
      ...   return f, co1, co2, status, first_result
      ... '''

      >>> lua = LuaRuntime()
      >>> f, co, lua_gen, status, first_result = lua.execute(lua_code)

      >>> # a running coroutine:

      >>> status
      True
      >>> first_result
      0
      >>> list(lua_gen)
      [1, 0]
      >>> list(lua_gen)
      []

      >>> # an uninitialised coroutine:

      >>> gen = co(4)
      >>> list(enumerate(gen))
      [(0, 0), (1, 1), (2, 0), (3, 1), (4, 0)]

      >>> gen = co(2)
      >>> list(enumerate(gen))
      [(0, 0), (1, 1), (2, 0)]

      >>> # a plain function:

      >>> gen = f.coroutine(4)
      >>> list(enumerate(gen))
      [(0, 0), (1, 1), (2, 0), (3, 1), (4, 0)]


Threading
---------

The following example calculates a mandelbrot image in parallel
threads and displays the result in PIL. It is based on a `benchmark
implementation`_ for the `Computer Language Benchmarks Game`_.

.. _`Computer Language Benchmarks Game`: http://shootout.alioth.debian.org/u64/benchmark.php?test=all&lang=luajit&lang2=python3
.. _`benchmark implementation`: http://shootout.alioth.debian.org/u64/program.php?test=mandelbrot&lang=luajit&id=1

.. code:: python

    lua_code = '''\
        function(N, i, total)
            local char, unpack = string.char, table.unpack
            local result = ""
            local M, ba, bb, buf = 2/N, 2^(N%8+1)-1, 2^(8-N%8), {}
            local start_line, end_line = N/total * (i-1), N/total * i - 1
            for y=start_line,end_line do
                local Ci, b, p = y*M-1, 1, 0
                for x=0,N-1 do
                    local Cr = x*M-1.5
                    local Zr, Zi, Zrq, Ziq = Cr, Ci, Cr*Cr, Ci*Ci
                    b = b + b
                    for i=1,49 do
                        Zi = Zr*Zi*2 + Ci
                        Zr = Zrq-Ziq + Cr
                        Ziq = Zi*Zi
                        Zrq = Zr*Zr
                        if Zrq+Ziq > 4.0 then b = b + 1; break; end
                    end
                    if b >= 256 then p = p + 1; buf[p] = 511 - b; b = 1; end
                end
                if b ~= 1 then p = p + 1; buf[p] = (ba-b)*bb; end
                result = result .. char(unpack(buf, 1, p))
            end
            return result
        end
    '''

    image_size = 1280   # == 1280 x 1280
    thread_count = 8

    from lupa import LuaRuntime
    lua_funcs = [ LuaRuntime(encoding=None).eval(lua_code)
                  for _ in range(thread_count) ]

    results = [None] * thread_count
    def mandelbrot(i, lua_func):
        results[i] = lua_func(image_size, i+1, thread_count)

    import threading
    threads = [ threading.Thread(target=mandelbrot, args=(i,lua_func))
                for i, lua_func in enumerate(lua_funcs) ]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    result_buffer = b''.join(results)

    # use Pillow to display the image
    from PIL import Image
    image = Image.fromstring('1', (image_size, image_size), result_buffer)
    image.show()

Note how the example creates a separate ``LuaRuntime`` for each thread
to enable parallel execution.  Each ``LuaRuntime`` is protected by a
global lock that prevents concurrent access to it.  The low memory
footprint of Lua makes it reasonable to use multiple runtimes, but
this setup also means that values cannot easily be exchanged between
threads inside of Lua.  They must either get copied through Python
space (passing table references will not work, either) or use some Lua
mechanism for explicit communication, such as a pipe or some kind of
shared memory setup.


Restricting Lua access to Python objects
----------------------------------------

..
        >>> try: unicode = unicode
        ... except NameError: unicode = str

Lupa provides a simple mechanism to control access to Python objects.
Each attribute access can be passed through a filter function as
follows:

.. code:: python

        >>> def filter_attribute_access(obj, attr_name, is_setting):
        ...     if isinstance(attr_name, unicode):
        ...         if not attr_name.startswith('_'):
        ...             return attr_name
        ...     raise AttributeError('access denied')

        >>> lua = lupa.LuaRuntime(
        ...           register_eval=False,
        ...           attribute_filter=filter_attribute_access)
        >>> func = lua.eval('function(x) return x.__class__ end')
        >>> func(lua)
        Traceback (most recent call last):
         ...
        AttributeError: access denied

The ``is_setting`` flag indicates whether the attribute is being read
or set.

Note that the attributes of Python functions provide access to the
current ``globals()`` and therefore to the builtins etc.  If you want
to safely restrict access to a known set of Python objects, it is best
to work with a whitelist of safe attribute names.  One way to do that
could be to use a well selected list of dedicated API objects that you
provide to Lua code, and to only allow Python attribute access to the
set of public attribute/method names of these objects.

Since Lupa 1.0, you can alternatively provide dedicated getter and
setter function implementations for a ``LuaRuntime``:

.. code:: python

        >>> def getter(obj, attr_name):
        ...     if attr_name == 'yes':
        ...         return getattr(obj, attr_name)
        ...     raise AttributeError(
        ...         'not allowed to read attribute "%s"' % attr_name)

        >>> def setter(obj, attr_name, value):
        ...     if attr_name == 'put':
        ...         setattr(obj, attr_name, value)
        ...         return
        ...     raise AttributeError(
        ...         'not allowed to write attribute "%s"' % attr_name)

        >>> class X(object):
        ...     yes = 123
        ...     put = 'abc'
        ...     noway = 2.1

        >>> x = X()

        >>> lua = lupa.LuaRuntime(attribute_handlers=(getter, setter))
        >>> func = lua.eval('function(x) return x.yes end')
        >>> func(x)  # getting 'yes'
        123
        >>> func = lua.eval('function(x) x.put = "ABC"; end')
        >>> func(x)  # setting 'put'
        >>> print(x.put)
        ABC
        >>> func = lua.eval('function(x) x.noway = 42; end')
        >>> func(x)  # setting 'noway'
        Traceback (most recent call last):
         ...
        AttributeError: not allowed to write attribute "noway"


Importing Lua binary modules
----------------------------

**This will usually work as is**, but here are the details, in case
anything goes wrong for you.

To use binary modules in Lua, you need to compile them against the
header files of the LuaJIT sources that you used to build Lupa, but do
not link them against the LuaJIT library.

Furthermore, CPython needs to enable global symbol visibility for
shared libraries before loading the Lupa module.  This can be done by
calling ``sys.setdlopenflags(flag_values)``.  Importing the ``lupa``
module will automatically try to set up the correct ``dlopen`` flags
if it can find the platform specific ``DLFCN`` Python module that
defines the necessary flag constants.  In that case, using binary
modules in Lua should work out of the box.

If this setup fails, however, you have to set the flags manually.
When using the above configuration call, the argument ``flag_values``
must represent the sum of your system's values for ``RTLD_NEW`` and
``RTLD_GLOBAL``.  If ``RTLD_NEW`` is 2 and ``RTLD_GLOBAL`` is 256, you
need to call ``sys.setdlopenflags(258)``.

Assuming that the Lua luaposix_ (``posix``) module is available, the
following should work on a Linux system:

.. code:: python

      >>> import sys
      >>> orig_dlflags = sys.getdlopenflags()
      >>> sys.setdlopenflags(258)
      >>> import lupa
      >>> sys.setdlopenflags(orig_dlflags)

      >>> lua = lupa.LuaRuntime()
      >>> posix_module = lua.require('posix')     # doctest: +SKIP

.. _luaposix: http://git.alpinelinux.org/cgit/luaposix
