Lupa
=====

Lupa integrates the LuaJIT2_ runtime into CPython.  It is a partial
rewrite of LunaticPython_ in Cython_ with some additional features
such as proper coroutine support.

.. _LuaJIT2: http://luajit.org/
.. _LunaticPython: http://labix.org/lunatic-python
.. _Cython: http://cython.org


Major features
---------------

* separate Lua runtime states through a ``LuaRuntime`` class

* Python coroutine wrapper for Lua coroutines

* proper encoding and decoding of strings (configurable per runtime,
  UTF-8 by default)

* frees the GIL and supports threading in separate runtimes when
  calling into Lua

* supports Python 2.x and 3.x, potentially starting with Python 2.3
  (currently untested)

* written for LuaJIT2, as opposed to the Lua interpreter (tested with
  LuaJIT 2.0.0-beta4)

* easy to hack on and extend as it is written in Cython, not C


Why use it?
------------

It complements Python very well.  Lua is a language as dynamic as
Python, but LuaJIT compiles it to very fast machine code, sometimes
`faster than many other compiled languages`_.  The language runtime is
extremely small and carefully designed for embedding.  The complete
binary module of Lupa, including a statically linked LuaJIT2 runtime,
is only some 500KB on a 64 bit machine.

.. _`faster than many other compiled languages`: http://shootout.alioth.debian.org/u64/performance.php?test=mandelbrot

However, Lua code is harder to write than Python code as the language
lacks most of the batteries that Python includes.  Writing large
programs in Lua is rather futile, but it provides a perfect backup
language when raw speed is more important than simplicity, and
edit-compile-run cycles are too heavy for agile development.

Lupa is a very fast and thin wrapper around LuaJIT.  It makes it easy
to write dynamic Lua code that accompanies dynamic Python code by
switching between the two languages at runtime, based on the tradeoff
between simplicity and speed.


Examples
---------

..
      ## doctest helpers:
      >>> try: _ = sorted
      ... except NameError:
      ...     def sorted(seq):
      ...         l = list(seq)
      ...         l.sort()
      ...         return l

::

      >>> from lupa import LuaRuntime
      >>> lua = LuaRuntime()

      >>> lua.eval('1+1')
      2

      >>> lua_func = lua.eval('function(f, n) return f(n) end')

      >>> def py_add1(n): return n+1
      >>> lua_func(py_add1, 2)
      3


Lua Tables
-----------

Lua tables mimic Python's mapping protocol.  For the special case of
array tables, Lua automatically inserts integer indices as keys into
the table.  Therefore, indexing starts from 1 as in Lua instead of 0
as in Python.  For the same reason, negative indexing does not work.
It is best to think of Lua tables as mappings rather than arrays, even
for plain array tables.

::

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

A lookup of nonexisting keys or indices returns None (actually ``nil``
inside of Lua).  A lookup is therefore more similar to the ``.get()``
method of Python dicts than to a mapping lookup in Python.

::

      >>> table[1000000] is None
      True
      >>> table['no such key'] is None
      True
      >>> mapping['no such key'] is None
      True

Note that ``len()`` does the right thing for array tables but does not
work on mappings::

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
attribute access to table members::

      >>> table = lua.eval('{ a=1, b=2 }')
      >>> table.a, table.b
      (1, 2)
      >>> table.a == table['a']
      True

This enables access to Lua 'methods' that are associated with a table,
as used by the standard library modules::

      >>> string = lua.eval('string')    # get the 'string' library table
      >>> print( string.lower('A') )
      a


Lua Coroutines
---------------

The next is an example of Lua coroutines.  A wrapped Lua coroutine
behaves exactly like a Python coroutine.  It needs to get created at
the beginning, either by using the ``.coroutine()`` method of a
function or by creating it in Lua code.  Then, values can be sent into
it using the ``.send()`` method or it can be iterated over.  Note that
the ``.throw()`` method is not supported, though.

::

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
``.send()`` method::

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

      >>> gen = f.coroutine(4)
      >>> gen.send(None)           # start coroutine

      >>> for i in range(3):
      ...     gen.send(i*2)

      >>> mapping = gen.send(None)   # loop termination signal
      >>> list(mapping.values())
      [0, 2, 4]

It also works to create coroutines in Lua and to pass them back into
Python space::

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
----------

The following example calculates a mandelbrot image in parallel
threads and displays the result in PIL. It is based on a `benchmark
implementation`_ for the `Computer Language Benchmarks Game`_.

.. _`Computer Language Benchmarks Game`: http://shootout.alioth.debian.org/u64/benchmark.php?test=all&lang=luajit&lang2=python3
.. _`benchmark implementation`: http://shootout.alioth.debian.org/u64/program.php?test=mandelbrot&lang=luajit&id=1

::

        lua_code = '''\
            function(N, i, total)
                local char, unpack = string.char, unpack
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

	# use PIL to display the image
	import Image
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
