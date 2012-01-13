Installing lupa
================

Building with LuaJIT2
---------------------

#) Download and unpack lupa

   http://pypi.python.org/pypi/lupa

#) Download LuaJIT2

   http://luajit.org/download.html

#) Unpack the archive into the lupa base directory, e.g.::

     .../lupa-0.1/LuaJIT-2.0.0-beta4

#) Build LuaJIT::

     cd LuaJIT-2.0.0-beta4
     make
     cd ..

   If you need specific C compiler flags, pass them to ``make`` as follows::

     make CFLAGS="..."

   For trickier target platforms like Windows and MacOS-X, please see
   the official `installation instructions for LuaJIT`_.

#) Build lupa::

     python setup.py build

   Or any other distutils target of your choice, such as ``install``
   or one of the ``bdist`` targets.  See the `distutils
   documentation`_ for help, also the `hints on building extension
   modules`_.

   Note that on 64bit MacOS-X installations, the following additional
   compiler flags are reportedly required due to the embedded LuaJIT::

     -pagezero_size 10000 -image_base 100000000

   You can find additional installation hints for MacOS-X in this
   `somewhat unclear blog post`_, which may or may not tell you at
   which point in the installation process to provide these flags.

.. _`installation instructions for LuaJIT`: http://luajit.org/install.html
.. _`somewhat unclear blog post`: http://t-p-j.blogspot.com/2010/11/lupa-on-os-x-with-macports-python-26.html
.. _`distutils documentation`: http://docs.python.org/install/index.html#install-index
.. _`hints on building extension modules`: http://docs.python.org/install/index.html#building-extensions-tips-and-tricks


Building with Lua 5.1
---------------------

Reportedly, it also works to use Lupa with the standard (non-JIT) Lua
runtime.  To that end, install Lua 5.1 instead of LuaJIT2, including
any development packages (header files etc.).

On systems that use the "pkg-config" configuration mechanism, Lupa's
setup.py will pick up either LuaJIT2 or Lua automatically, with a
preference for LuaJIT2 if it is found.  Pass the "--no-luajit" option
to the setup.py script if you have both installed but do not want to
use LuaJIT2.

On other systems, you may have to supply the build parameters
externally, e.g. using environment variables or by changing the
setup.py script manually.  Pass the "--no-luajit" option to the
setup.py script in order to ignore the failure you get when neither
LuaJIT2 nor Lua are found automatically.

For further information, read this mailing list post:

http://article.gmane.org/gmane.comp.python.lupa.devel/31
