Lupa change log
===============

Upcoming release
----------------

* The runtime version of the Lua library as a tuple (e.g. ``(5,3)``)
  is provided via ``lupa.LUA_VERSION`` and ``LuaRuntime.lua_version``.

* The Lua implementation name and version string is provided as
  ``LuaRuntime.lua_implementation``.


1.9 (2019-12-21)
----------------

* Build against Lua 5.3 if available.

* Use Lua 5.3.5 in binary wheels and as bundled Lua.

* GH#129: Fix Lua module loading in Python 3.x.

* GH#126: Fix build on Linux systems that install Lua as "lua52" package.

* Built with Cython 0.29.14 for better Py3.8 compatibility.


1.8 (2019-02-01)
----------------

* GH#107: Fix a deprecated import in Py3.

* Built with Cython 0.29.3 for better Py3.7 compatibility.


1.7 (2018-08-06)
----------------

* GH#103: Provide wheels for MS Windows and fix MSVC build on Py2.7.


1.6 (2017-12-15)
----------------

* GH#95: Improved compatibility with Lua 5.3.
  (patch by TitanSnow)


1.5 (2017-09-16)
----------------

* GH#93: New method ``LuaRuntime.compile()`` to compile Lua code
  without executing it.
  (patch by TitanSnow)

* GH#91: Lua 5.3 is bundled in the source distribution to simplify
  one-shot installs.
  (patch by TitanSnow)

* GH#87: Lua stack trace is included in output in debug mode.
  (patch by aaiyer)

* GH#78: Allow Lua code to intercept Python exceptions.
  (patch by Sergey Dobrov)

* Built with Cython 0.26.1.


1.4 (2016-12-10)
----------------

* GH#82: Lua coroutines were using the wrong runtime state
  (patch by Sergey Dobrov)

* GH#81: copy locally provided Lua DLL into installed package on Windows
  (patch by Gareth Coles)

* built with Cython 0.25.2


1.3 (2016-04-12)
----------------

* GH#70: ``eval()`` and ``execute()`` accept optional positional arguments
  (patch by John Vandenberg)

* GH#65: calling ``str()`` on a Python object from Lua could fail if the
  ``LuaRuntime`` is set up without auto-encoding (patch by Mikhail Korobov)

* GH#63: attribute/keyword names were not properly encoded if the
  ``LuaRuntime`` is set up without auto-encoding (patch by Mikhail Korobov)

* built with Cython 0.24


1.2 (2015-10-10)
----------------

* callbacks returned from Lua coroutines were incorrectly mixing
  coroutine state with global Lua state (patch by Mikhail Korobov)

* availability of ``python.builtins`` in Lua can be disabled via
  ``LuaRuntime`` option.

* built with Cython 0.23.4


1.1 (2014-11-21)
----------------

* new module function ``lupa.lua_type()`` that returns the Lua type of
  a wrapped object as string, or ``None`` for normal Python objects

* new helper method ``LuaRuntime.table_from(...)`` that creates a Lua
  table from one or more Python mappings and/or sequences

* new ``lupa.unpacks_lua_table`` and ``lupa.unpacks_lua_table_method``
  decorators to allow calling Python functions from Lua using named
  arguments

* fix a hang on shutdown where the LuaRuntime failed to deallocate due
  to reference cycles

* Lupa now plays more nicely with other Lua extensions that create
  userdata objects


1.0.1 (2014-10-11)
------------------

* fix a crash when requesting attributes of wrapped Lua coroutine objects

* looking up attributes on Lua objects that do not support it now always
  raises an AttributeError instead of sometimes raising a TypeError depending
  on the attribute name


1.0 (2014-09-28)
----------------

* NOTE: this release includes the major backwards incompatible changes listed
  below.  It is believed that they simplify the interaction between Python code
  and Lua code by more strongly following idiomatic Lua on the Lua side.

  * Instead of passing a wrapped ``python.none`` object into Lua, ``None``
    return values are now mapped to ``nil``, making them more straight forward
    to handle in Lua code.  This makes the behaviour more consistent, as it
    was previously somewhat arbitrary where ``none`` could appear and where a
    ``nil`` value was used.  The only remaining exception is during iteration,
    where the first returned value must not be ``nil`` in Lua, or otherwise
    the loop terminates prematurely.  To prevent this, any ``None`` value
    that the iterator returns, or any first item in exploded tuples that is
    ``None``, is still mapped to ``python.none``. Any further values
    returned in the same iteration will be mapped to ``nil`` if they are
    ``None``, not to ``none``.  This means that only the first argument
    needs to be manually checked for this special case.  For the
    ``enumerate()`` iterator, the counter is never ``None`` and thus the
    following unpacked items will never be mapped to ``python.none``.

  * When ``unpack_returned_tuples=True``, iteration now also unpacks tuple
    values, including ``enumerate()`` iteration, which yields a flat sequence
    of counter and unpacked values.

  * When calling bound Python methods from Lua as "obj:meth()", Lupa now
    prevents Python from prepending the self argument a second time, so that
    the Python method is now called as "obj.meth()".  Previously, it was called
    as "obj.meth(obj)".  Note that this can be undesired when the object itself
    is explicitly passed as first argument from Lua, e.g. when calling
    "func(obj)" where "func" is "obj.meth", but these constellations should be
    rare.  As a work-around for this case, user code can wrap the bound method
    in another function so that the final call comes from Python.

* garbage collection works for reference cycles that span both runtimes,
  Python and Lua

* calling from Python into Lua and back into Python did not clean up the
  Lua call arguments before the innermost call, so that they could leak
  into the nested Python call or its return arguments

* support for Lua 5.2 (in addition to Lua 5.1 and LuaJIT 2.0)

* Lua tables support Python's "del" statement for item deletion
  (patch by Jason Fried)

* Attribute lookup can use a more fine-grained control mechanism by
  implementing explicit getter and setter functions for a LuaRuntime
  (``attribute_handlers`` argument).  Patch by Brian Moe.

* item assignments/lookups on Lua objects from Python no longer
  special case double underscore names (as opposed to attribute lookups)


0.21 (2014-02-12)
-----------------

* some garbage collection issues were cleaned up using new Cython features

* new ``LuaRuntime`` option ``unpack_returned_tuples`` which automatically
  unpacks tuples returned from Python functions into separate Lua objects
  (instead of returning a single Python tuple object)

* some internal wrapper classes were removed from the module API

* Windows build fixes

* Py3.x build fixes

* support for building with Lua 5.1 instead of LuaJIT (setup.py --no-luajit)

* no longer uses Cython by default when building from released sources (pass
  ``--with-cython`` to explicitly request a rebuild)

* requires Cython 0.20+ when building from unreleased sources

* built with Cython 0.20.1


0.20 (2011-05-22)
-----------------

* fix "deallocating None" crash while iterating over Lua tables in
  Python code

* support for filtering attribute access to Python objects for Lua
  code

* fix: setting source encoding for Lua code was broken


0.19 (2011-03-06)
-----------------

* fix serious resource leak when creating multiple LuaRuntime instances

* portability fix for binary module importing


0.18 (2010-11-06)
-----------------

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
-----------------

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
-----------------

* dropped ``python.as_function()`` helper function for Lua as all
  Python objects are callable from Lua now (potentially raising a
  ``TypeError`` at call time if they are not callable)

* fix regression in 0.13 and later where ordinary Lua functions failed
  to print due to an accidentally used meta table

* fix crash when calling ``str()`` on wrapped Lua objects without
  metatable


0.15 (2010-09-02)
-----------------

* support for loading binary Lua modules on systems that support it


0.14 (2010-08-31)
-----------------

* relicensed to the MIT license used by LuaJIT2 to simplify licensing
  considerations


0.13.1 (2010-08-30)
-------------------

* fix Cython generated C file using Cython 0.13


0.13 (2010-08-29)
-----------------

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
-----------------

* fix Lua stack leak during table iteration

* fix lost Lua object reference after iteration


0.11 (2010-08-07)
-----------------

* error reporting on Lua syntax errors failed to clean up the stack so
  that errors could leak into the next Lua run

* Lua error messages were not properly decoded


0.10 (2010-07-27)
-----------------

* much faster locking of the LuaRuntime, especially in the single
  threaded case (see
  http://code.activestate.com/recipes/577336-fast-re-entrant-optimistic-lock-implemented-in-cyt/)

* fixed several error handling problems when executing Python code
  inside of Lua


0.9 (2010-07-23)
----------------

* fixed Python special double-underscore method access on LuaObject
  instances

* Lua coroutine support through dedicated wrapper classes, including
  Python iteration support.  In Python space, Lua coroutines behave
  exactly like Python generators.


0.8 (2010-07-21)
----------------

* support for returning multiple values from Lua evaluation

* ``repr()`` support for Lua objects

* ``LuaRuntime.table()`` method for creating Lua tables from Python
  space

* encoding fix for ``str(LuaObject)``


0.7 (2010-07-18)
----------------

* ``LuaRuntime.require()`` and ``LuaRuntime.globals()`` methods

* renamed ``LuaRuntime.run()`` to ``LuaRuntime.execute()``

* support for ``len()``, ``setattr()`` and subscripting of Lua objects

* provide all built-in Lua libraries in ``LuaRuntime``, including
  support for library loading

* fixed a thread locking issue

* fix passing Lua objects back into the runtime from Python space


0.6 (2010-07-18)
----------------

* Python iteration support for Lua objects (e.g. tables)

* threading fixes

* fix compile warnings


0.5 (2010-07-14)
----------------

* explicit encoding options per LuaRuntime instance to decode/encode
  strings and Lua code


0.4 (2010-07-14)
----------------

* attribute read access on Lua objects, e.g. to read Lua table values
  from Python

* str() on Lua objects

* include .hg repository in source downloads

* added missing files to source distribution


0.3 (2010-07-13)
----------------

* fix several threading issues

* safely free the GIL when calling into Lua


0.2 (2010-07-13)
----------------

* propagate Python exceptions through Lua calls


0.1 (2010-07-12)
----------------

* first public release
