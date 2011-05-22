Lupa change log
================

0.20 (2011-05-22)
------------------

* fix "deallocating None" crash while iterating over Lua tables in
  Python code

* support for filtering attribute access to Python objects for Lua
  code

* fix: setting source encoding for Lua code was broken


0.19 (2011-03-06)
------------------

* fix serious resource leak when creating multiple LuaRuntime instances

* portability fix for binary module importing


0.18 (2010-11-06)
------------------

* fix iteration by returning ``Py_None`` object for ``None`` instead
  of ``nil``, which would terminate the iteration

* when converting Python values to Lua, represent ``None`` as a
  ``Py_None`` object in places where ``nil`` has a special meaning,
  but leave it as ``nil`` where it doesn't hurt

* support for counter start value in ``python.enumerate()``

* native implementation for ``python.enumerate()`` that is several
  times faster

* much faster Lua iteration over Python objects


0.17 (2010-11-05)
------------------

* new helper function ``python.enumerate()`` in Lua that returns a Lua
  iterator for a Python object and adds the 0-based index to each
  item.

* new helper function ``python.iterex()`` in Lua that returns a Lua
  iterator for a Python object and unpacks any tuples that the
  iterator yields.

* new helper function ``python.iter()`` in Lua that returns a Lua
  iterator for a Python object.

* reestablished the ``python.as_function()`` helper function for Lua
  code as it can be needed in cases where Lua cannot determine how to
  run a Python function.


0.16 (2010-09-03)
------------------

* dropped ``python.as_function()`` helper function for Lua as all
  Python objects are callable from Lua now (potentially raising a
  ``TypeError`` at call time if they are not callable)

* fix regression in 0.13 and later where ordinary Lua functions failed
  to print due to an accidentally used meta table

* fix crash when calling ``str()`` on wrapped Lua objects without
  metatable


0.15 (2010-09-02)
------------------

* support for loading binary Lua modules on systems that support it


0.14 (2010-08-31)
------------------

* relicensed to the MIT license used by LuaJIT2 to simplify licensing
  considerations


0.13.1 (2010-08-30)
--------------------

* fix Cython generated C file using Cython 0.13


0.13 (2010-08-29)
------------------

* fixed undefined behaviour on ``str(lua_object)`` when the object's
  ``__tostring()`` meta method fails

* removed redundant "error:" prefix from ``LuaError`` messages

* access to Python's ``python.builtins`` from Lua code

* more generic wrapping rules for Python objects based on supported
  protocols (callable, getitem, getattr)

* new helper functions ``as_attrgetter()`` and ``as_itemgetter()`` to
  specify the Python object protocol used by Lua indexing when
  wrapping Python objects in Python code

* new helper functions ``python.as_attrgetter()``,
  ``python.as_itemgetter()`` and ``python.as_function()`` to specify
  the Python object protocol used by Lua indexing of Python objects in
  Lua code

* item and attribute access for Python objects from Lua code


0.12 (2010-08-16)
------------------

* fix Lua stack leak during table iteration

* fix lost Lua object reference after iteration


0.11 (2010-08-07)
------------------

* error reporting on Lua syntax errors failed to clean up the stack so
  that errors could leak into the next Lua run

* Lua error messages were not properly decoded


0.10 (2010-07-27)
------------------

* much faster locking of the LuaRuntime, especially in the single
  threaded case (see
  http://code.activestate.com/recipes/577336-fast-re-entrant-optimistic-lock-implemented-in-cyt/)

* fixed several error handling problems when executing Python code
  inside of Lua


0.9 (2010-07-23)
-----------------

* fixed Python special double-underscore method access on LuaObject
  instances

* Lua coroutine support through dedicated wrapper classes, including
  Python iteration support.  In Python space, Lua coroutines behave
  exactly like Python generators.


0.8 (2010-07-21)
-----------------

* support for returning multiple values from Lua evaluation

* ``repr()`` support for Lua objects

* ``LuaRuntime.table()`` method for creating Lua tables from Python
  space

* encoding fix for ``str(LuaObject)``


0.7 (2010-07-18)
-----------------

* ``LuaRuntime.require()`` and ``LuaRuntime.globals()`` methods

* renamed ``LuaRuntime.run()`` to ``LuaRuntime.execute()``

* support for ``len()``, ``setattr()`` and subscripting of Lua objects

* provide all built-in Lua libraries in ``LuaRuntime``, including
  support for library loading

* fixed a thread locking issue

* fix passing Lua objects back into the runtime from Python space


0.6 (2010-07-18)
-----------------

* Python iteration support for Lua objects (e.g. tables)

* threading fixes

* fix compile warnings


0.5 (2010-07-14)
-----------------

* explicit encoding options per LuaRuntime instance to decode/encode
  strings and Lua code


0.4 (2010-07-14)
-----------------

* attribute read access on Lua objects, e.g. to read Lua table values
  from Python

* str() on Lua objects

* include .hg repository in source downloads

* added missing files to source distribution


0.3 (2010-07-13)
-----------------

* fix several threading issues

* safely free the GIL when calling into Lua


0.2 (2010-07-13)
-----------------

* propagate Python exceptions through Lua calls


0.1 (2010-07-12)
-----------------

* first public release
