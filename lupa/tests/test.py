# -*- coding: utf-8 -*-

import threading
import unittest
import sys

import lupa

IS_PYTHON3 = sys.version_info[0] >= 3


class TestLuaRuntime(unittest.TestCase):

    def setUp(self):
        self.lua = lupa.LuaRuntime()

    def tearDown(self):
        self.lua = None


    def test_eval(self):
        self.assertEqual(2, self.lua.eval('1+1'))

    def test_run(self):
        self.assertEqual(2, self.lua.run('return 1+1'))

    def test_function(self):
        function = self.lua.eval('function() return 1+1 end')
        self.assertNotEqual(None, function)
        self.assertEqual(2, function())

    def test_multiple_functions(self):
        function1 = self.lua.eval('function() return 0+1 end')
        function2 = self.lua.eval('function() return 1+1 end')
        self.assertEqual(1, function1())
        self.assertEqual(2, function2())
        function3 = self.lua.eval('function() return 1+2 end')
        self.assertEqual(3, function3())
        self.assertEqual(2, function2())
        self.assertEqual(1, function1())

    def test_recursive_function(self):
        fac = self.lua.run('''\
        function fac(i)
            if i <= 1
                then return 1
                else return i * fac(i-1)
            end
        end
        return fac
        ''')
        self.assertNotEqual(None, fac)
        self.assertEqual(6,       fac(3))
        self.assertEqual(3628800, fac(10))

    def test_double_recursive_function(self):
        func_code = '''\
        function calc(i)
            if i > 2
                then return calc(i-1) + calc(i-2) + 1
                else return 1
            end
        end
        return calc
        '''
        calc = self.lua.run(func_code)
        self.assertNotEqual(None, calc)
        self.assertEqual(3,     calc(3))
        self.assertEqual(109,   calc(10))
        self.assertEqual(13529, calc(20))

    def test_double_recursive_function_pycallback(self):
        func_code = '''\
        function calc(pyfunc, i)
            if i > 2
                then return pyfunc(i) + calc(pyfunc, i-1) + calc(pyfunc, i-2) + 1
                else return 1
            end
        end
        return calc
        '''
        def pycallback(i):
            return i**2

        calc = self.lua.run(func_code)

        self.assertNotEqual(None, calc)
        self.assertEqual(12,     calc(pycallback, 3))
        self.assertEqual(1342,   calc(pycallback, 10))
        self.assertEqual(185925, calc(pycallback, 20))

    def test_none(self):
        function = self.lua.eval('function() return python.none end')
        self.assertEqual(None, function())

    def test_call_none(self):
        self.assertRaises(TypeError, self.lua.eval, 'python.none()')

    def test_call_str(self):
        self.assertEqual("test-None", self.lua.eval('"test-" .. tostring(python.none)'))

    def test_call_str_py(self):
        function = self.lua.eval('function(x) return "test-" .. tostring(x) end')
        self.assertEqual("test-nil", function(None))
        self.assertEqual("test-1", function(1))

    def test_call_str_class(self):
        class test(object):
            def __str__(self):
                return 'STR!!'

        function = self.lua.eval('function(x) return "test-" .. tostring(x) end')
        self.assertEqual("test-STR!!", function(test()))

    def test_eval(self):
        function = self.lua.eval('function() return python.eval end')
        self.assertEqual(2, eval('1+1'))
        self.assertEqual(2, self.lua.eval('python.eval("1+1")'))

    def test_string_values(self):
        function = self.lua.eval('function(s) return s .. "abc" end')
        self.assertEqual('ABCabc', function('ABC'))

    def test_int_values(self):
        function = self.lua.eval('function(i) return i + 5 end')
        self.assertEqual(3+5, function(3))

    def test_str_function(self):
        func = self.lua.eval('function() return 1 end')
        self.assertEqual('<Lua function at ', str(func)[:17])

    def test_str_table(self):
        table = self.lua.eval('{}')
        self.assertEqual('<Lua table at ', str(table)[:14])

    def test_getattr(self):
        stringlib = self.lua.eval('string')
        self.assertEqual('abc', stringlib.lower('ABC'))

    def test_getattr_table(self):
        table = self.lua.eval('{ const={ name="Pi", value=3.1415927 }, const2={ name="light speed", value=3e8 }, val=1 }')
        self.assertEqual(1, table.val)
        self.assertEqual('Pi', table.const.name)
        self.assertEqual('light speed', table.const2.name)
        self.assertEqual(3e8, table.const2.value)

    def test_callable_values(self):
        function = self.lua.eval('function(f) return f() + 5 end')
        def test():
            return 3
        self.assertEqual(3+5, function(test))

    def test_callable_values_pass_through(self):
        function = self.lua.eval('function(f, n) return f(n) + 5 end')
        def test(n):
            return n
        self.assertEqual(2+5, function(test, 2))

    def _test_reraise(self):
        function = self.lua.eval('function(f) return f() + 5 end')
        def test():
            raise ValueError("huhu")
        self.assertRaises(ValueError, function, test)

    def test_sequential_threading(self):
        func_code = '''\
        function calc(i)
            if i > 2
                then return calc(i-1) + calc(i-2) + 1
                else return 1
            end
        end
        return calc
        '''
        functions = [ self.lua.run(func_code) for _ in range(10) ]
        results = [None] * len(functions)

        def test(i, func, *args):
            results[i] = func(*args)

        threads = [ threading.Thread(target=test, args=(i, func, 20))
                    for i, func in enumerate(functions) ]

        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()

        self.assertEqual(1, len(set(results)))
        self.assertEqual(13529, results[0])


class TestLuaRuntimeEncoding(unittest.TestCase):
    unicode_type = type(IS_PYTHON3 and 'abc' or 'abc'.decode('ASCII'))

    test_string = '"abcüöä"'
    if not IS_PYTHON3:
        test_string = test_string.decode('UTF-8')

    def _encoding_test(self, encoding, expected_length):
        lua = lupa.LuaRuntime(encoding)

        self.assertEqual(self.unicode_type,
                         type(lua.eval(self.test_string)))

        self.assertEqual(self.test_string[1:-1],
                         lua.eval(self.test_string))

        self.assertEqual(expected_length,
                         lua.eval('string.len(%s)' % self.test_string))

    def test_utf8(self):
        self._encoding_test('UTF-8', 9)

    def test_latin9(self):
        self._encoding_test('ISO-8859-15', 6)

    def test_stringlib_utf8(self):
        lua = lupa.LuaRuntime('UTF-8')
        stringlib = lua.eval('string')
        self.assertEqual('abc', stringlib.lower('ABC'))

    def test_stringlib_no_encoding(self):
        lua = lupa.LuaRuntime(encoding=None)
        stringlib = lua.eval('string')
        self.assertEqual('abc'.encode('ASCII'), stringlib.lower('ABC'.encode('ASCII')))


class TestMultipleLuaRuntimes(unittest.TestCase):

    def test_multiple_runtimes(self):
        lua1 = lupa.LuaRuntime()

        function1 = lua1.eval('function() return 1 end')
        self.assertNotEqual(None, function1)
        self.assertEqual(1, function1())

        lua2 = lupa.LuaRuntime()

        function2 = lua2.eval('function() return 1+1 end')
        self.assertNotEqual(None, function2)
        self.assertEqual(1, function1())
        self.assertEqual(2, function2())

        lua3 = lupa.LuaRuntime()

        self.assertEqual(1, function1())
        self.assertEqual(2, function2())

        function3 = lua3.eval('function() return 1+1+1 end')
        self.assertNotEqual(None, function3)

        del lua1, lua2, lua3

        self.assertEqual(1, function1())
        self.assertEqual(2, function2())
        self.assertEqual(3, function3())

    def test_threading(self):
        func_code = '''\
        function calc(i)
            if i > 2
                then return calc(i-1) + calc(i-2) + 1
                else return 1
            end
        end
        return calc
        '''
        runtimes  = [ lupa.LuaRuntime() for _ in range(10) ]
        functions = [ lua.run(func_code) for lua in runtimes ]

        results = [None] * len(runtimes)

        def test(i, func, *args):
            results[i] = func(*args)

        threads = [ threading.Thread(target=test, args=(i, func, 20))
                    for i, func in enumerate(functions) ]

        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()

        self.assertEqual(1, len(set(results)))
        self.assertEqual(13529, results[0])

    def test_threading_pycallback(self):
        func_code = '''\
        function calc(pyfunc, i)
            if i > 2
                then return pyfunc(i) + calc(pyfunc, i-1) + calc(pyfunc, i-2) + 1
                else return 1
            end
        end
        return calc
        '''
        runtimes  = [ lupa.LuaRuntime() for _ in range(10) ]
        functions = [ lua.run(func_code) for lua in runtimes ]

        results = [None] * len(runtimes)

        def pycallback(i):
            return i**2

        def test(i, func, *args):
            results[i] = func(*args)

        threads = [ threading.Thread(target=test, args=(i, luafunc, pycallback, 20))
                    for i, luafunc in enumerate(functions) ]

        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()

        self.assertEqual(1, len(set(results)))
        self.assertEqual(185925, results[0])
        

if __name__ == '__main__':
    import unittest
    unittest.main()
