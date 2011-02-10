Installing lupa
================

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
