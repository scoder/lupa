Lupa
=====

Lupa integrates the LuaJIT2 runtime into CPython.  It is a partial
rewrite of LunaticPython_ in Cython_.  Note that it is currently
lacking many features and a lot of testing compared to LunaticPython,
so if you need a production-ready Lua integration, use that instead.

The advantages over LunaticPython are:

* separate Lua runtime states through a ``LuaRuntime`` class

* frees the GIL and supports threading when calling into Lua

* supports Python 2.x and 3.x, potentially starting with Python 2.3
  (currently untested)

* written for LuaJIT2, as opposed to the Lua interpreter (tested with
  LuaJIT 2.0.0-beta4)

* much easier to hack on and extend as it is written in Cython, not C


.. _LunaticPython: http://labix.org/lunatic-python
.. _Cython: http://cython.org


Example usage::

      >>> from lupa import LuaRuntime
      >>> lua = LuaRuntime()

      >>> lua.eval('1+1')
      2

      >>> def add1(n): return n+1
      >>> func = lua.eval('function(f, n) return f(n) end')
      >>> func(add1, 2)
      3
