Lupa
=====

Lupa integrates the LuaJIT2 runtime into CPython.  It is a partial
rewrite of LunaticPython_ in Cython_.  Note that it is currently
lacking some features and a lot of testing compared to LunaticPython,
so it does yet make for a production-ready Lua integration.

.. _LunaticPython: http://labix.org/lunatic-python
.. _Cython: http://cython.org


Examples
---------

::
      >>> from lupa import LuaRuntime
      >>> lua = LuaRuntime()

      >>> lua.eval('1+1')
      2

      >>> lua_func = lua.eval('function(f, n) return f(n) end')

      >>> def py_add1(n): return n+1
      >>> lua_func(py_add1, 2)
      3


Advantages over LunaticPython
------------------------------

* separate Lua runtime states through a ``LuaRuntime`` class

* frees the GIL and supports threading in separate runtimes when
  calling into Lua

* supports Python 2.x and 3.x, potentially starting with Python 2.3
  (currently untested)

* written for LuaJIT2, as opposed to the Lua interpreter (tested with
  LuaJIT 2.0.0-beta4)

* much easier to hack on and extend as it is written in Cython, not C


Why use it?
------------

It complements Python very well.  Lua is a language as dynamic as
Python, but LuaJIT compiles it to very fast machine code, sometimes
`faster than many other compiled languages`_.  The language runtime is
extremely small and carefully designed for embedding.  The complete
binary module of Lupa, including a statically linked LuaJIT2 runtime,
is only some 400KB on a 64 bit machine.

.. _`faster than many other compiled languages`: http://shootout.alioth.debian.org/u64/performance.php?test=mandelbrot

However, Lua code is harder to write than Python code as the language
lacks most of the batteries that Python includes.  Writing large
programs in Lua is rather futile, but it provides a perfect backup
language when raw speed is more important than simplicity.

Lupa is a very fast and thin wrapper around LuaJIT.  It makes it easy
to write dynamic Lua code that accompanies dynamic Python code by
switching between the two languages at runtime, based on the tradeoff
between simplicity and speed.
