Lupy
=====

Lupy integrates the LuaJIT2 runtime into CPython.  It is a partial
rewrite of LunaticPython_ in Cython_.  Note that it is currently
lacking a lot of features and testing compared to LunaticPython, so if
you need a production-ready Lua integration, use that instead.

The advantages over LunaticPython are:

* supports Python 2.x and 3.x, potentially starting with Python 2.3
  (currently untested)

* written for LuaJIT2, as opposed to the Lua interpreter

* written in Cython, as opposed to C


.. _LunaticPython: http://labix.org/lunatic-python
.. _Cython: http://cython.org

