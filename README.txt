Lupa
=====

Lupa integrates the LuaJIT2_ runtime into CPython.  It is a partial
rewrite of LunaticPython_ in Cython_.  Note that it is currently
lacking some features and a lot of testing compared to LunaticPython,
so it does not yet make for a production-ready Lua integration.

.. _LuaJIT2: http://luajit.org/
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



Advantages over LunaticPython
------------------------------

* separate Lua runtime states through a ``LuaRuntime`` class

* proper encoding and decoding of strings (configurable, UTF-8 by
  default)

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
