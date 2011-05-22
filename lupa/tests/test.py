# -*- coding: utf-8 -*-

try:
    from thread import start_new_thread, get_ident
except ImportError:
    # Python 3?
    from _thread import start_new_thread, get_ident
import threading
import unittest
import time
import sys
import gc

import lupa

IS_PYTHON3 = sys.version_info[0] >= 3

try:
    _next = next
except NameError:
    def _next(o):
        return o.next()

unicode_type = type(IS_PYTHON3 and 'abc' or 'abc'.decode('ASCII'))

def _wait():
    # A crude wait/yield function not relying on synchronization primitives.
    time.sleep(0.01)

class SetupLuaRuntimeMixin(object):

    def setUp(self):
        self.lua = lupa.LuaRuntime()

    def tearDown(self):
        self.lua = None
        gc.collect()

class TestLuaRuntimeRefcounting(unittest.TestCase):
    def test_runtime_cleanup(self):
        lua = lupa.LuaRuntime()
        lua_table = lua.eval('{1,2,3,4}')
        del lua
        self.assertEqual(1, lua_table[1])
        del lua_table

class TestLuaRuntime(SetupLuaRuntimeMixin, unittest.TestCase):
    def test_eval(self):
        self.assertEqual(2, self.lua.eval('1+1'))

    def test_eval_multi(self):
        self.assertEqual((1,2,3), self.lua.eval('1,2,3'))

    def test_eval_error(self):
        self.assertRaises(lupa.LuaError, self.lua.eval, '<INVALIDCODE>')

    def test_eval_error_cleanup(self):
        self.assertEqual(2, self.lua.eval('1+1'))
        self.assertRaises(lupa.LuaError, self.lua.eval, '<INVALIDCODE>')
        self.assertEqual(2, self.lua.eval('1+1'))
        self.assertRaises(lupa.LuaError, self.lua.eval, '<INVALIDCODE>')
        self.assertEqual(2, self.lua.eval('1+1'))
        self.assertEqual(2, self.lua.eval('1+1'))

    def test_eval_error_message_decoding(self):
        error = None
        try:
            self.lua.eval('-üUNKNOWNöVALUEä')
        except lupa.LuaError:
            error = (IS_PYTHON3 and '%s' or '%s'.decode('ASCII')) % sys.exc_info()[1]
        else:
            self.fail('expected error not raised')
        expected_message = '[string "<python>"]:1: attempt to perform arithmetic on global \'üUNKNOWNöVALUEä\' (a nil value)'
        if not IS_PYTHON3:
            expected_message = expected_message.decode('UTF-8')
        self.assertEqual(expected_message, error)

    def test_execute(self):
        self.assertEqual(2, self.lua.execute('return 1+1'))

    def test_execute_function(self):
        self.assertEqual(3, self.lua.execute('f = function(i) return i+1 end; return f(2)'))

    def test_execute_tostring_function(self):
        self.assertEqual('function', self.lua.execute('f = function(i) return i+1 end; return tostring(f)')[:8])

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
        fac = self.lua.execute('''\
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
        calc = self.lua.execute(func_code)
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

        calc = self.lua.execute(func_code)

        self.assertNotEqual(None, calc)
        self.assertEqual(12,     calc(pycallback, 3))
        self.assertEqual(1342,   calc(pycallback, 10))
        self.assertEqual(185925, calc(pycallback, 20))

    def test_none(self):
        function = self.lua.eval('function() return python.none end')
        self.assertEqual(None, function())

    def test_pybuiltins(self):
        function = self.lua.eval('function() return python.builtins end')
        try:
            import __builtin__ as builtins
        except ImportError:
            import builtins
        self.assertEqual(builtins, function())

    def test_call_none(self):
        self.assertRaises(TypeError, self.lua.eval, 'python.none()')

    def test_call_non_callable(self):
        func = self.lua.eval('function(x) CALLED = 99; return x() end')
        self.assertRaises(TypeError, func, object())
        self.assertEqual(99, self.lua.eval('CALLED'))

    def test_call_str(self):
        self.assertEqual("test-None", self.lua.eval('"test-" .. tostring(python.none)'))

    def test_call_str_py(self):
        function = self.lua.eval('function(x) return "test-" .. tostring(x) end')
        self.assertEqual("test-nil", function(None))
        self.assertEqual("test-1", function(1))

    def test_call_str_class(self):
        called = [False]
        class test(object):
            def __str__(self):
                called[0] = True
                return 'STR!!'

        function = self.lua.eval('function(x) return "test-" .. tostring(x) end')
        self.assertEqual("test-STR!!", function(test()))
        self.assertEqual(True, called[0])

    def test_eval(self):
        function = self.lua.eval('function() return python.eval end')
        self.assertEqual(2, eval('1+1'))
        self.assertEqual(2, self.lua.eval('python.eval("1+1")'))

    def test_len_table_array(self):
        table = self.lua.eval('{1,2,3,4,5}')
        self.assertEqual(5, len(table))

    def test_len_table_dict(self):
        table = self.lua.eval('{a=1, b=2, c=3}')
        self.assertEqual(0, len(table)) # as returned by Lua's "#" operator

    def test_len_table(self):
        table = self.lua.eval('{1,2,3,4, a=1, b=2, c=3}')
        self.assertEqual(4, len(table)) # as returned by Lua's "#" operator

    def test_iter_table(self):
        table = self.lua.eval('{2,3,4,5,6}')
        self.assertEqual([1,2,3,4,5], list(table))

    def test_iter_table_repeat(self):
        table = self.lua.eval('{2,3,4,5,6}')
        self.assertEqual([1,2,3,4,5], list(table)) # 1
        self.assertEqual([1,2,3,4,5], list(table)) # 2
        self.assertEqual([1,2,3,4,5], list(table)) # 3

    def test_iter_array_table_values(self):
        table = self.lua.eval('{2,3,4,5,6}')
        self.assertEqual([2,3,4,5,6], list(table.values()))

    def test_iter_array_table_repeat(self):
        table = self.lua.eval('{2,3,4,5,6}')
        self.assertEqual([2,3,4,5,6], list(table.values())) # 1
        self.assertEqual([2,3,4,5,6], list(table.values())) # 2
        self.assertEqual([2,3,4,5,6], list(table.values())) # 3

    def test_iter_multiple_tables(self):
        count = 10
        table_values = [ self.lua.eval('{%s}' % ','.join(map(str, range(2,count+2)))).values()
                         for _ in range(4) ]

        # round robin
        l = [ [] for _ in range(count) ]
        for sublist in l:
            for table in table_values:
                sublist.append(_next(table))

        self.assertEqual([[i]*len(table_values) for i in range(2,count+2)], l)

    def test_iter_table_repeat(self):
        count = 10
        table_values = [ self.lua.eval('{%s}' % ','.join(map(str, range(2,count+2)))).values()
                         for _ in range(4) ]

        # one table after the other
        l = [ [] for _ in range(count) ]
        for table in table_values:
            for sublist in l:
                sublist.append(_next(table))

        self.assertEqual([[i]*len(table_values) for i in range(2,count+2)], l)

    def test_iter_table_refcounting(self):
        lua_func = self.lua.eval('''
            function ()
              local t = {}
              t.foo = 'bar'
              t.hello = 'world'
              return t
            end
        ''')
        table = lua_func()
        for _ in range(10000):
            list(table.items())

    def test_iter_table_mapping(self):
        keys = list('abcdefg')
        table = self.lua.eval('{%s}' % ','.join(['%s=%d' % (c,i) for i,c in enumerate(keys)]))
        l = list(table)
        l.sort()
        self.assertEqual(keys, l)

    def test_iter_table_mapping_int_keys(self):
        table = self.lua.eval('{%s}' % ','.join(['[%d]=%d' % (i,-i) for i in range(10) ]))
        l = list(table)
        l.sort()
        self.assertEqual(list(range(10)), l)

    def test_iter_table_keys(self):
        keys = list('abcdefg')
        table = self.lua.eval('{%s}' % ','.join(['%s=%d' % (c,i) for i,c in enumerate(keys)]))
        l = list(table.keys())
        l.sort()
        self.assertEqual(keys, l)

    def test_iter_table_keys_int_keys(self):
        table = self.lua.eval('{%s}' % ','.join(['[%d]=%d' % (i,-i) for i in range(10) ]))
        l = list(table.keys())
        l.sort()
        self.assertEqual(list(range(10)), l)

    def test_iter_table_values(self):
        keys = list('abcdefg')
        table = self.lua.eval('{%s}' % ','.join(['%s=%d' % (c,i) for i,c in enumerate(keys)]))
        l = list(table.values())
        l.sort()
        self.assertEqual(list(range(len(keys))), l)

    def test_iter_table_values_int_keys(self):
        table = self.lua.eval('{%s}' % ','.join(['[%d]=%d' % (i,-i) for i in range(10) ]))
        l = list(table.values())
        l.sort()
        self.assertEqual(list(range(-9,1)), l)

    def test_iter_table_items(self):
        keys = list('abcdefg')
        table = self.lua.eval('{%s}' % ','.join(['%s=%d' % (c,i) for i,c in enumerate(keys)]))
        l = list(table.items())
        l.sort()
        self.assertEqual(list(zip(keys,range(len(keys)))), l)

    def test_iter_table_items_int_keys(self):
        table = self.lua.eval('{%s}' % ','.join(['[%d]=%d' % (i,-i) for i in range(10) ]))
        l = list(table.items())
        l.sort()
        self.assertEqual(list(zip(range(10), range(0,-10,-1))), l)

    def test_iter_table_values_mixed(self):
        keys = list('abcdefg')
        table = self.lua.eval('{98, 99; %s}' % ','.join(['%s=%d' % (c,i) for i,c in enumerate(keys)]))
        l = list(table.values())
        l.sort()
        self.assertEqual(list(range(len(keys))) + [98, 99], l)

    def test_error_iter_number(self):
        func = self.lua.eval('1')
        self.assertRaises(TypeError, list, func)

    def test_error_iter_function(self):
        func = self.lua.eval('function() return 1 end')
        self.assertRaises(TypeError, list, func)

    def test_string_values(self):
        function = self.lua.eval('function(s) return s .. "abc" end')
        self.assertEqual('ABCabc', function('ABC'))

    def test_int_values(self):
        function = self.lua.eval('function(i) return i + 5 end')
        self.assertEqual(3+5, function(3))

    def test_long_values(self):
        try:
            _long = long
        except NameError:
            _long = int
        function = self.lua.eval('function(i) return i + 5 end')
        self.assertEqual(3+5, function(_long(3)))

    def test_float_values(self):
        function = self.lua.eval('function(i) return i + 5 end')
        self.assertEqual(float(3)+5, function(float(3)))

    def test_str_function(self):
        func = self.lua.eval('function() return 1 end')
        self.assertEqual('<Lua function at ', str(func)[:17])

    def test_str_table(self):
        table = self.lua.eval('{}')
        self.assertEqual('<Lua table at ', str(table)[:14])

    def test_create_table_args(self):
        table = self.lua.table(1,2,3,4,5,6)
        self.assertEqual(1, table[1])
        self.assertEqual(3, table[3])
        self.assertEqual(6, table[6])

        self.assertEqual(6, len(table))

    def test_create_table_kwargs(self):
        table = self.lua.table(a=1, b=20, c=300)
        self.assertEqual(  1, table['a'])
        self.assertEqual( 20, table['b'])
        self.assertEqual(300, table['c'])

        self.assertEqual(0, len(table))

    def test_create_table_args_kwargs(self):
        table = self.lua.table(1,2,3,4,5,6, a=100, b=200, c=300)
        self.assertEqual(1, table[1])
        self.assertEqual(3, table[3])
        self.assertEqual(6, table[6])

        self.assertEqual(100, table['a'])
        self.assertEqual(200, table['b'])
        self.assertEqual(300, table['c'])

        self.assertEqual(6, len(table))

    def test_getattr(self):
        stringlib = self.lua.eval('string')
        self.assertEqual('abc', stringlib.lower('ABC'))

    def test_getitem(self):
        stringlib = self.lua.eval('string')
        self.assertEqual('abc', stringlib['lower']('ABC'))

    def test_getattr_table(self):
        table = self.lua.eval('{ const={ name="Pi", value=3.1415927 }, const2={ name="light speed", value=3e8 }, val=1 }')
        self.assertEqual(1, table.val)
        self.assertEqual('Pi', table.const.name)
        self.assertEqual('light speed', table.const2.name)
        self.assertEqual(3e8, table.const2.value)

    def test_getitem_table(self):
        table = self.lua.eval('{ const={ name="Pi", value=3.1415927 }, const2={ name="light speed", value=3e8 }, val=1 }')
        self.assertEqual(1, table['val'])
        self.assertEqual('Pi', table['const']['name'])
        self.assertEqual('light speed', table['const2']['name'])
        self.assertEqual(3e8, table['const2']['value'])

    def test_getitem_array(self):
        table = self.lua.eval('{1,2,3,4,5,6,7,8,9}')
        self.assertEqual(1, table[1])
        self.assertEqual(5, table[5])
        self.assertEqual(9, len(table))

    def test_setitem_array(self):
        table = self.lua.eval('{1,2,3,4,5,6,7,8,9}')
        self.assertEqual(1, table[1])
        table[1] = 0
        self.assertEqual(0, table[1])
        self.assertEqual(2, table[2])
        self.assertEqual(9, len(table))

    def test_setattr_table(self):
        table = self.lua.eval('{ const={ name="Pi", value=3.1415927 }, const2={ name="light speed", value=3e8 }, val=1 }')

        self.assertEqual(1, table.val)
        table.val = 2
        self.assertEqual(2, table.val)

        self.assertEqual('Pi', table.const.name)
        table.const.name = 'POW'
        self.assertEqual('POW', table.const.name)

        table_const_name = self.lua.eval('function(t) return t.const.name end')
        self.assertEqual('POW', table_const_name(table))

    def test_setitem_table(self):
        table = self.lua.eval('{ const={ name="Pi", value=3.1415927 }, const2={ name="light speed", value=3e8 }, val=1 }')

        self.assertEqual(1, table.val)
        table['val'] = 2
        self.assertEqual(2, table.val)

        get_val = self.lua.eval('function(t) return t.val end')
        self.assertEqual(2, get_val(table))

        self.assertEqual('Pi', table.const.name)
        table['const']['name'] = 'POW'
        self.assertEqual('POW', table.const.name)

        get_table_const_name = self.lua.eval('function(t) return t.const.name end')
        self.assertEqual('POW', get_table_const_name(table))

    def test_pygetitem(self):
        lua_func = self.lua.eval('function(x) return x.ATTR end')
        self.assertEqual(123, lua_func({'ATTR': 123}))

    def test_pysetitem(self):
        lua_func = self.lua.eval('function(x) x.ATTR = 123 end')
        d = {'ATTR': 321}
        self.assertEqual(321, d['ATTR'])
        lua_func(d)
        self.assertEqual(123, d['ATTR'])

    def test_pygetattr(self):
        lua_func = self.lua.eval('function(x) return x.ATTR end')
        class test(object):
            def __init__(self):
                self.ATTR = 5
        self.assertEqual(test().ATTR, lua_func(test()))

    def test_pysetattr(self):
        lua_func = self.lua.eval('function(x) x.ATTR = 123 end')
        class test(object):
            def __init__(self):
                self.ATTR = 5
        t = test()
        self.assertEqual(5, t.ATTR)
        lua_func(t)
        self.assertEqual(123, t.ATTR)

    def test_pygetattr_function(self):
        lua_func = self.lua.eval('function(x) x.ATTR = 123 end')
        def test(): pass
        lua_func(test)
        self.assertEqual(123, test.ATTR)

    def test_pysetattr_function(self):
        lua_func = self.lua.eval('function(x) x.ATTR = 123 end')
        def test(): pass
        lua_func(test)
        self.assertEqual(123, test.ATTR)

    def test_globals(self):
        lua_globals = self.lua.globals()
        self.assertNotEqual(None, lua_globals.unpack)

    def test_globals_attrs_call(self):
        lua_globals = self.lua.globals()
        self.assertNotEqual(None, lua_globals.string)
        self.assertEqual('test', lua_globals.string.lower("TEST"))

    def test_require(self):
        stringlib = self.lua.require('string')
        self.assertNotEqual(None, stringlib)
        self.assertNotEqual(None, stringlib.char)

    def test_libraries(self):
        libraries = self.lua.eval('{require, table, io, os, math, string, debug, bit, jit}')
        self.assertEqual(9, len(libraries))
        self.assertTrue(None not in libraries)

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

    def test_callable_passthrough(self):
        passthrough = self.lua.eval('function(f) f(); return f end')
        called = [False]
        def test():
            called[0] = True
        self.assertEqual(test, passthrough(test))
        self.assertEqual([True], called)

    def test_reraise(self):
        function = self.lua.eval('function(f) return f() + 5 end')
        def test():
            raise ValueError("huhu")
        self.assertRaises(ValueError, function, test)

    def test_attribute_filter(self):
        def attr_filter(obj, name, setting):
            if isinstance(name, unicode_type):
                if not name.startswith('_'):
                    return name + '1'
            raise AttributeError('denied')

        lua = lupa.LuaRuntime(attribute_filter=attr_filter)
        function = lua.eval('function(obj) return obj.__name__ end')
        class X(object):
            a = 0
            a1 = 1
            _a = 2
            __a = 3
        x = X()

        function = self.lua.eval('function(obj) return obj.a end')
        self.assertEquals(function(x), 0)
        function = lua.eval('function(obj) return obj.a end')
        self.assertEquals(function(x), 1)

        function = self.lua.eval('function(obj) return obj.__class__ end')
        self.assertEquals(function(x), X)
        function = lua.eval('function(obj) return obj.__class__ end')
        self.assertRaises(AttributeError, function, x)

        function = self.lua.eval('function(obj) return obj._a end')
        self.assertEquals(function(x), 2)
        function = lua.eval('function(obj) return obj._a end')
        self.assertRaises(AttributeError, function, x)

        function = self.lua.eval('function(obj) return obj._X__a end')
        self.assertEquals(function(x), 3)
        function = lua.eval('function(obj) return obj._X__a end')
        self.assertRaises(AttributeError, function, x)

        function = self.lua.eval('function(obj) return obj.a end')
        self.assertEquals(function(x), 0)
        function = lua.eval('function(obj) return obj.a end')
        self.assertEquals(function(x), 1)


class TestPythonObjectsInLua(SetupLuaRuntimeMixin, unittest.TestCase):
    def test_explicit_python_function(self):
        lua_func = self.lua.eval('function(func) return table.foreach({ab="cd"}, python.as_function(func)) end')
        def join(*args):
            return '-'.join(args)
        self.assertEqual('ab-cd', lua_func(join))

    def test_type_conversion(self):
        lua_type = self.lua.eval('type')
        self.assertEqual('number', lua_type(1))
        self.assertEqual('string', lua_type("test"))

    def test_pyobject_wrapping_callable(self):
        lua_type = self.lua.eval('type')
        lua_get_call = self.lua.eval('function(obj) return getmetatable(obj).__call end')
        class Callable(object):
            def __call__(self): pass
            def __getitem__(self, item): pass

        self.assertEqual('userdata', lua_type(Callable()))
        self.assertNotEqual(None, lua_get_call(Callable()))

    def test_pyobject_wrapping_getitem(self):
        lua_type = self.lua.eval('type')
        lua_get_index = self.lua.eval('function(obj) return getmetatable(obj).__index end')
        class GetItem(object):
            def __getitem__(self, item): pass

        self.assertEqual('userdata', lua_type(GetItem()))
        self.assertNotEqual(None, lua_get_index(GetItem()))

    def test_pyobject_wrapping_getattr(self):
        lua_type = self.lua.eval('type')
        lua_get_index = self.lua.eval('function(obj) return getmetatable(obj).__index end')
        class GetAttr(object):
            pass

        self.assertEqual('userdata', lua_type(GetAttr()))
        self.assertNotEqual(None, lua_get_index(GetAttr()))

    def test_pylist(self):
        getitem = self.lua.eval('function(L, i) return L[i] end')
        self.assertEqual(3, getitem([1,2,3], 2))

    def test_python_iter_list(self):
        values = self.lua.eval('''
            function(L)
                local t = {}
                local i = 1
                for value in python.iter(L) do
                    t[i] = value
                    i = i+1
                end
                return t
            end
        ''')
        self.assertEqual([1,2,3], list(values([1,2,3]).values()))

    def test_python_enumerate_list(self):
        values = self.lua.eval('''
            function(L)
                local t = {}
                for index, value in python.enumerate(L) do
                    t[ index+1 ] = value
                end
                return t
            end
        ''')
        self.assertEqual([1,2,3], list(values([1,2,3]).values()))

    def test_python_enumerate_list_start(self):
        values = self.lua.eval('''
            function(L)
                local t = {5,6,7}
                for index, value in python.enumerate(L, 3) do
                    t[ index ] = value
                end
                return t
            end
        ''')
        self.assertEqual([5,6,1,2,3], list(values([1,2,3]).values()))

    def test_python_iter_dict_items(self):
        values = self.lua.eval('''
            function(d)
                local t = {}
                for key, value in python.iterex(d.items()) do
                    t[key] = value
                end
                return t
            end
        ''')
        table = values(lupa.as_attrgetter(dict(a=1, b=2, c=3)))
        self.assertEqual(1, table['a'])
        self.assertEqual(2, table['b'])
        self.assertEqual(3, table['c'])

    def test_python_iter_list_None(self):
        values = self.lua.eval('''
            function(L)
                local t = {}
                local i = 1
                for value in python.iter(L) do
                    t[i] = value
                    i = i + 1
                end
                return t
            end
        ''')
        self.assertEqual([None, None, None], list(values([None, None, None]).values()))


class TestLuaCoroutines(SetupLuaRuntimeMixin, unittest.TestCase):
    def test_coroutine_iter(self):
        lua_code = '''\
            function(N)
                for i=0,N do
                    if i%2 == 0 then coroutine.yield(0) else coroutine.yield(1) end
                end
            end
        '''
        f = self.lua.eval(lua_code)
        gen = f.coroutine(5)
        self.assertEqual([0,1,0,1,0,1], list(gen))

    def test_coroutine_iter_repeat(self):
        lua_code = '''\
            function(N)
                for i=0,N do
                    if i%2 == 0 then coroutine.yield(0) else coroutine.yield(1) end
                end
            end
        '''
        f = self.lua.eval(lua_code)
        gen = f.coroutine(5)
        self.assertEqual([0,1,0,1,0,1], list(gen))

        gen = f.coroutine(5)
        self.assertEqual([0,1,0,1,0,1], list(gen))

        gen = f.coroutine(5)
        self.assertEqual([0,1,0,1,0,1], list(gen))

    def test_coroutine_create_iter(self):
        lua_code = '''\
        coroutine.create(
            function(N)
                for i=0,N do
                    if i%2 == 0 then coroutine.yield(0) else coroutine.yield(1) end
                end
            end
            )
        '''
        co = self.lua.eval(lua_code)
        gen = co(5)
        self.assertEqual([0,1,0,1,0,1], list(gen))

    def test_coroutine_create_iter_repeat(self):
        lua_code = '''\
        coroutine.create(
            function(N)
                for i=0,N do
                    if i%2 == 0 then coroutine.yield(0) else coroutine.yield(1) end
                end
            end
            )
        '''
        co = self.lua.eval(lua_code)

        gen = co(5)
        self.assertEqual([0,1,0,1,0,1], list(gen))

        gen = co(5)
        self.assertEqual([0,1,0,1,0,1], list(gen))

        gen = co(5)
        self.assertEqual([0,1,0,1,0,1], list(gen))

    def test_coroutine_lua_iter(self):
        lua_code = '''\
        co = coroutine.create(
            function(N)
                for i=0,N do
                    if i%2 == 0 then coroutine.yield(0) else coroutine.yield(1) end
                end
            end
            )
        status, first_value = coroutine.resume(co, 5)
        return co, status, first_value
        '''
        gen, status, first_value = self.lua.execute(lua_code)
        self.assertTrue(status)
        self.assertEqual([0,1,0,1,0,1], [first_value] + list(gen))

    def test_coroutine_lua_iter_independent(self):
        lua_code = '''\
            function f(N)
              for i=0,N do
                  coroutine.yield( i%2 )
              end
            end ;
            co1 = coroutine.create(f) ;
            co2 = coroutine.create(f) ;

            status, first_value = coroutine.resume(co2, 5) ;   -- starting!

            return f, co1, co2, status, first_value
        '''
        f, co, lua_gen, status, first_value = self.lua.execute(lua_code)

        # f
        gen = f.coroutine(5)
        self.assertEqual([0,1,0,1,0,1], list(gen))

        # co
        gen = co(5)
        self.assertEqual([0,1,0,1,0,1], list(gen))
        gen = co(5)
        self.assertEqual([0,1,0,1,0,1], list(gen))

        # lua_gen
        self.assertTrue(status)
        self.assertEqual([0,1,0,1,0,1], [first_value] + list(lua_gen))
        self.assertEqual([], list(lua_gen))

    def test_coroutine_iter_pycall(self):
        lua_code = '''\
        coroutine.create(
            function(pyfunc, N)
                for i=0,N do
                    if pyfunc(i) then coroutine.yield(0) else coroutine.yield(1) end
                end
            end
            )
        '''
        co = self.lua.eval(lua_code)

        def pyfunc(i):
            return i%2 == 0
        gen = co(pyfunc, 5)
        self.assertEqual([0,1,0,1,0,1], list(gen))

    def test_coroutine_send(self):
        lua_code = '''\
            function()
                local i = 0
                while coroutine.yield(i) do i = i+1 end
                return i   -- not i+1 !
            end
        '''
        count = self.lua.eval(lua_code).coroutine()
        result = [ count.send(value) for value in ([None]+[True]*9+[False]) ]
        self.assertEqual(list(range(10)) + [9], result)
        self.assertRaises(StopIteration, count.send, True)

    def test_coroutine_send_with_arguments(self):
        lua_code = '''\
            function(N)
                local i = 0
                while coroutine.yield(i) < N do i = i+1 end
                return i   -- not i+1 !
            end
        '''
        count = self.lua.eval(lua_code).coroutine(5)
        result = []
        try:
            for value in ([None]+list(range(10))):
                result.append( count.send(value) )
        except StopIteration:
            pass
        else:
            self.assertTrue(False)
        self.assertEqual(list(range(6)) + [5], result)
        self.assertRaises(StopIteration, count.send, True)

    def test_coroutine_status(self):
        lua_code = '''\
        coroutine.create(
            function(N)
                for i=0,N do
                    if i%2 == 0 then coroutine.yield(0) else coroutine.yield(1) end
                end
            end
            )
        '''
        co = self.lua.eval(lua_code)
        self.assertTrue(bool(co)) # 1
        gen = co(1)
        self.assertTrue(bool(gen)) # 2
        self.assertEqual(0, _next(gen))
        self.assertTrue(bool(gen)) # 3
        self.assertEqual(1, _next(gen))
        self.assertTrue(bool(gen)) # 4
        self.assertRaises(StopIteration, _next, gen)
        self.assertFalse(bool(gen)) # 5
        self.assertRaises(StopIteration, _next, gen)
        self.assertRaises(StopIteration, _next, gen)
        self.assertRaises(StopIteration, _next, gen)

    def test_coroutine_terminate_return(self):
        lua_code = '''\
        coroutine.create(
            function(N)
                for i=0,N do
                    if i%2 == 0 then coroutine.yield(0) else coroutine.yield(1) end
                end
                return 99
            end
            )
        '''
        co = self.lua.eval(lua_code)

        self.assertTrue(bool(co)) # 1
        gen = co(1)
        self.assertTrue(bool(gen)) # 2
        self.assertEqual(0, _next(gen))
        self.assertTrue(bool(gen)) # 3
        self.assertEqual(1, _next(gen))
        self.assertTrue(bool(gen)) # 4
        self.assertEqual(99, _next(gen))
        self.assertFalse(bool(gen)) # 5
        self.assertRaises(StopIteration, _next, gen)
        self.assertRaises(StopIteration, _next, gen)
        self.assertRaises(StopIteration, _next, gen)

    def test_coroutine_while_status(self):
        lua_code = '''\
            function(N)
                for i=0,N-1 do
                    if i%2 == 0 then coroutine.yield(0) else coroutine.yield(1) end
                end
                if N < 0 then return nil end
                if N%2 == 0 then return 0 else return 1 end
            end
        '''
        f = self.lua.eval(lua_code)
        gen = f.coroutine(5)
        result = []
        # note: this only works because the generator returns a result
        # after the last yield - otherwise, it would throw
        # StopIteration in the last call
        while gen:
            result.append(_next(gen))
        self.assertEqual([0,1,0,1,0,1], result)


class TestLuaApplications(unittest.TestCase):
    def tearDown(self):
        gc.collect()

    def test_mandelbrot(self):
        # copied from Computer Language Benchmarks Game
        code = '''\
function(N)
    local char, unpack = string.char, unpack
    local result = ""
    local M, ba, bb, buf = 2/N, 2^(N%8+1)-1, 2^(8-N%8), {}
    for y=0,N-1 do
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

        lua = lupa.LuaRuntime(encoding=None)
        lua_mandelbrot = lua.eval(code)

        image_size = 128
        result_bytes = lua_mandelbrot(image_size)
        self.assertEqual(type(result_bytes), type(''.encode('ASCII')))
        self.assertEqual(image_size*image_size//8, len(result_bytes))

        # if we have PIL, check that it can read the image
        ## try:
        ##     import Image
        ## except ImportError:
        ##     pass
        ## else:
        ##     image = Image.fromstring('1', (image_size, image_size), result_bytes)
        ##     image.show()


class TestLuaRuntimeEncoding(unittest.TestCase):
    def tearDown(self):
        gc.collect()

    test_string = '"abcüöä"'
    if not IS_PYTHON3:
        test_string = test_string.decode('UTF-8')

    def _encoding_test(self, encoding, expected_length):
        lua = lupa.LuaRuntime(encoding)

        self.assertEqual(unicode_type,
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
    def tearDown(self):
        gc.collect()

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


class TestThreading(unittest.TestCase):
    def tearDown(self):
        gc.collect()

    def _run_threads(self, threads, starter=None):
        for thread in threads:
            thread.start()
        if starter is not None:
            time.sleep(0.1) # give some time to start up
            starter.set()
        for thread in threads:
            thread.join()

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
        lua = lupa.LuaRuntime()
        functions = [ lua.execute(func_code) for _ in range(10) ]
        results = [None] * len(functions)

        starter = threading.Event()
        def test(i, func, *args):
            starter.wait()
            results[i] = func(*args)

        threads = [ threading.Thread(target=test, args=(i, func, 25))
                    for i, func in enumerate(functions) ]

        self._run_threads(threads, starter)

        self.assertEqual(1, len(set(results)))
        self.assertEqual(150049, results[0])

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
        functions = [ lua.execute(func_code) for lua in runtimes ]

        results = [None] * len(runtimes)

        def test(i, func, *args):
            results[i] = func(*args)

        threads = [ threading.Thread(target=test, args=(i, func, 20))
                    for i, func in enumerate(functions) ]

        self._run_threads(threads)

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
        functions = [ lua.execute(func_code) for lua in runtimes ]

        results = [None] * len(runtimes)

        def pycallback(i):
            return i**2

        def test(i, func, *args):
            results[i] = func(*args)

        threads = [ threading.Thread(target=test, args=(i, luafunc, pycallback, 20))
                    for i, luafunc in enumerate(functions) ]

        self._run_threads(threads)

        self.assertEqual(1, len(set(results)))
        self.assertEqual(185925, results[0])

    def test_threading_iter(self):
        values = list(range(1,100))
        lua = lupa.LuaRuntime()
        table = lua.eval('{%s}' % ','.join(map(str, values)))
        self.assertEqual(values, list(table))

        lua_iter = iter(table)

        state_lock = threading.Lock()
        running = []
        iterations_done = {}
        def sync(i):
            state_lock.acquire()
            try:
                status = iterations_done[i]
            except KeyError:
                status = iterations_done[i] = [0, threading.Event()]
            status[0] += 1
            state_lock.release()
            event = status[1]
            while status[0] < len(running):
                event.wait(0.1)
            event.set()

        l = []
        start_event = threading.Event()
        def extract(n, append = l.append):
            running.append(n)
            if len(running) < len(threads):
                start_event.wait()
            else:
                start_event.set()
            # all running, let's go
            for i, item in enumerate(lua_iter):
                append(item)
                sync(i)
            running.remove(n)

        threads = [ threading.Thread(target=extract, args=(i,))
                    for i in range(6) ]
        self._run_threads(threads)

        orig = l[:]
        l.sort()
        self.assertEqual(values, l)

    def test_threading_mandelbrot(self):
        # copied from Computer Language Benchmarks Game
        code = '''\
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

        empty_bytes_string = ''.encode('ASCII')

        image_size = 128
        thread_count = 4

        lua_funcs = [ lupa.LuaRuntime(encoding=None).eval(code)
                      for _ in range(thread_count) ]

        results = [None] * thread_count
        def mandelbrot(i, lua_func):
            results[i] = lua_func(image_size, i+1, thread_count)

        threads = [ threading.Thread(target=mandelbrot, args=(i, lua_func))
                    for i, lua_func in enumerate(lua_funcs) ]
        self._run_threads(threads)

        result_bytes = empty_bytes_string.join(results)

        self.assertEqual(type(result_bytes), type(empty_bytes_string))
        self.assertEqual(image_size*image_size//8, len(result_bytes))

        # plausability checks - make sure it's not all white or all black
        self.assertEqual('\0'.encode('ASCII')*(image_size//8//2),
                         result_bytes[:image_size//8//2])
        if IS_PYTHON3:
            self.assertTrue('\xFF'.encode('ISO-8859-1') in result_bytes)
        else:
            self.assertTrue('\xFF' in result_bytes)

        # if we have PIL, check that it can read the image
        ## try:
        ##     import Image
        ## except ImportError:
        ##     pass
        ## else:
        ##     image = Image.fromstring('1', (image_size, image_size), result_bytes)
        ##     image.show()



################################################################################
# tests for the FastRLock implementation

class TestFastRLock(unittest.TestCase):
    """Copied from CPython's test.lock_tests module
    """
    def setUp(self):
        from lupa._lupa import FastRLock
        self.locktype = FastRLock

    def tearDown(self):
        gc.collect()

    class Bunch(object):
        """
        A bunch of threads.
        """
        def __init__(self, f, n, wait_before_exit=False):
            """
            Construct a bunch of `n` threads running the same function `f`.
            If `wait_before_exit` is True, the threads won't terminate until
            do_finish() is called.
            """
            self.f = f
            self.n = n
            self.started = []
            self.finished = []
            self._can_exit = not wait_before_exit
            def task():
                tid = get_ident()
                self.started.append(tid)
                try:
                    f()
                finally:
                    self.finished.append(tid)
                    while not self._can_exit:
                        _wait()
            for i in range(n):
                start_new_thread(task, ())

        def wait_for_started(self):
            while len(self.started) < self.n:
                _wait()

        def wait_for_finished(self):
            while len(self.finished) < self.n:
                _wait()

        def do_finish(self):
            self._can_exit = True


    # the locking tests

    """
    Tests for both recursive and non-recursive locks.
    """

    def test_constructor(self):
        lock = self.locktype()
        del lock

    def test_acquire_destroy(self):
        lock = self.locktype()
        lock.acquire()
        del lock

    def test_acquire_release(self):
        lock = self.locktype()
        lock.acquire()
        lock.release()
        del lock

    def test_try_acquire(self):
        lock = self.locktype()
        self.assertTrue(lock.acquire(False))
        lock.release()

    def test_try_acquire_contended(self):
        lock = self.locktype()
        lock.acquire()
        result = []
        def f():
            result.append(lock.acquire(False))
        self.Bunch(f, 1).wait_for_finished()
        self.assertFalse(result[0])
        lock.release()

    def test_acquire_contended(self):
        lock = self.locktype()
        lock.acquire()
        N = 5
        def f():
            lock.acquire()
            lock.release()

        b = self.Bunch(f, N)
        b.wait_for_started()
        _wait()
        self.assertEqual(len(b.finished), 0)
        lock.release()
        b.wait_for_finished()
        self.assertEqual(len(b.finished), N)

    ## def test_with(self):
    ##     lock = self.locktype()
    ##     def f():
    ##         lock.acquire()
    ##         lock.release()
    ##     def _with(err=None):
    ##         with lock:
    ##             if err is not None:
    ##                 raise err
    ##     _with()
    ##     # Check the lock is unacquired
    ##     self.Bunch(f, 1).wait_for_finished()
    ##     self.assertRaises(TypeError, _with, TypeError)
    ##     # Check the lock is unacquired
    ##     self.Bunch(f, 1).wait_for_finished()

    def test_thread_leak(self):
        # The lock shouldn't leak a Thread instance when used from a foreign
        # (non-threading) thread.
        lock = self.locktype()
        def f():
            lock.acquire()
            lock.release()
        n = len(threading.enumerate())
        # We run many threads in the hope that existing threads ids won't
        # be recycled.
        self.Bunch(f, 15).wait_for_finished()
        self.assertEqual(n, len(threading.enumerate()))

    """
    Tests for non-recursive, weak locks
    (which can be acquired and released from different threads).
    """

    def test_reacquire(self):
        # Lock needs to be released before re-acquiring.
        lock = self.locktype()
        phase = []
        def f():
            lock.acquire()
            phase.append(None)
            lock.acquire()
            phase.append(None)
        start_new_thread(f, ())
        while len(phase) == 0:
            _wait()
        _wait()
        self.assertEqual(len(phase), 1)
        lock.release()
        while len(phase) == 1:
            _wait()
        self.assertEqual(len(phase), 2)

    def test_different_thread(self):
        # Lock can be released from a different thread.
        lock = self.locktype()
        lock.acquire()
        def f():
            lock.release()
        b = self.Bunch(f, 1)
        b.wait_for_finished()
        lock.acquire()
        lock.release()

    """
    Tests for recursive locks.
    """
    def test_reacquire(self):
        lock = self.locktype()
        lock.acquire()
        lock.acquire()
        lock.release()
        lock.acquire()
        lock.release()
        lock.release()

    def test_release_unacquired(self):
        # Cannot release an unacquired lock
        lock = self.locktype()
        self.assertRaises(RuntimeError, lock.release)
        lock.acquire()
        lock.acquire()
        lock.release()
        lock.acquire()
        lock.release()
        lock.release()
        self.assertRaises(RuntimeError, lock.release)

    def test_different_thread(self):
        # Cannot release from a different thread
        lock = self.locktype()
        def f():
            lock.acquire()
        b = self.Bunch(f, 1, True)
        try:
            self.assertRaises(RuntimeError, lock.release)
        finally:
            b.do_finish()

    def test__is_owned(self):
        lock = self.locktype()
        self.assertFalse(lock._is_owned())
        lock.acquire()
        self.assertTrue(lock._is_owned())
        lock.acquire()
        self.assertTrue(lock._is_owned())
        result = []
        def f():
            result.append(lock._is_owned())
        self.Bunch(f, 1).wait_for_finished()
        self.assertFalse(result[0])
        lock.release()
        self.assertTrue(lock._is_owned())
        lock.release()
        self.assertFalse(lock._is_owned())



if __name__ == '__main__':
    import os
    import unittest
    import doctest
    suite = unittest.TestSuite()
    suite.addTest(doctest.DocTestSuite(lupa._lupa))
    suite.addTest(unittest.defaultTestLoader.loadTestsFromName('__main__'))
    suite.addTest(doctest.DocFileSuite('../../README.rst'))
    runner = unittest.TextTestRunner(verbosity=2)
    if not runner.run(suite).wasSuccessful():
        sys.exit(1)
