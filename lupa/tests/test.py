# -*- coding: utf-8 -*-

import gc
import operator
import os.path
import sys
import threading
import time
import unittest

import lupa
import lupa.tests
from lupa.tests import LupaTestCase

try:
    import platform
    IS_PYPY = platform.python_implementation() == 'PyPy'
except (ImportError, AttributeError):
    IS_PYPY = False

not_in_pypy = unittest.skipIf(IS_PYPY, "test not run in PyPy")

try:
    _next = next
except NameError:
    def _next(o):
        return o.next()


class SetupLuaRuntimeMixin:
    lua_runtime_kwargs = {}

    def setUp(self):
        self.lua = self.lupa.LuaRuntime(**self.lua_runtime_kwargs)

    def tearDown(self):
        self.lua = None
        gc.collect()


class TestLuaRuntimeRefcounting(LupaTestCase):
    def _run_gc_test(self, run_test, off_by_one=False):
        gc.collect()
        old_count = len(gc.get_objects())
        i = None
        for i in range(100):
            run_test()
        del i
        gc.collect()

        new_count = len(gc.get_objects())
        if off_by_one and old_count == new_count + 1:
            # FIXME: This happens in test_attrgetter_refcycle - need to investigate why!
            self.assertEqual(old_count, new_count + 1)
        elif off_by_one and old_count == new_count + 2 and (
                sys.version_info[:2] == (3,7) or sys.version_info >= (3,11)):
            # FIXME: This happens in test_attrgetter_refcycle - need to investigate why!
            self.assertEqual(old_count, new_count + 2)
        else:
            self.assertEqual(old_count, new_count)

    @not_in_pypy
    def test_runtime_cleanup(self):
        def run_test():
            lua = self.lupa.LuaRuntime()
            lua_table = lua.eval('{1,2,3,4}')
            del lua
            self.assertEqual(1, lua_table[1])

        self._run_gc_test(run_test)

    @not_in_pypy
    def test_pyfunc_refcycle(self):
        def make_refcycle():
            def use_runtime():
                return lua.eval('1+1')

            lua = self.lupa.LuaRuntime()
            lua.globals()['use_runtime'] = use_runtime
            self.assertEqual(2, lua.eval('use_runtime()'))

        self._run_gc_test(make_refcycle)

    @not_in_pypy
    def test_attrgetter_refcycle(self):
        def make_refcycle():
            def get_attr(obj, name):
                lua.eval('1+1')  # create ref-cycle with runtime
                return 23

            lua = self.lupa.LuaRuntime(attribute_handlers=(get_attr, None))
            assert lua.eval('python.eval.huhu') == 23

        # FIXME: find out why we loose one reference here.
        # Seems related to running the test twice in the same Lupa module?
        self._run_gc_test(make_refcycle, off_by_one=True)


class TestLuaRuntime(SetupLuaRuntimeMixin, LupaTestCase):
    def assertLuaResult(self, lua_expression, result):
        self.assertEqual(self.lua.eval(lua_expression), result)

    def test_lua_version(self):
        version = self.lua.lua_version
        self.assertEqual(tuple, type(version))
        self.assertEqual(5, version[0])  # let's assume that Lua 6 will require code/test changes
        self.assertTrue(version[1] >= 1)
        self.assertTrue(version[1] < 10)  # arbitrary boundary
        self.assertEqual(version, self.lupa.LUA_VERSION)  # no distinction currently

    def test_lua_implementation(self):
        lua_implementation = self.lua.lua_implementation
        self.assertTrue(lua_implementation.startswith("Lua"), lua_implementation)
        self.assertTrue(lua_implementation.split()[0] in ("Lua", "LuaJIT"), lua_implementation)

    def test_lua_gccollect(self):
        self.lua.gccollect()

    def test_lua_nogc(self):
        if self.lua.lua_version >= (5,2):
            self.assertTrue(self.lua.eval('collectgarbage("isrunning")'))

        with self.lua.nogc():
            if self.lua.lua_version >= (5,2):
                self.assertFalse(self.lua.eval('collectgarbage("isrunning")'))

        if self.lua.lua_version >= (5,2):
            self.assertTrue(self.lua.eval('collectgarbage("isrunning")'))

    def test_eval(self):
        self.assertEqual(2, self.lua.eval('1+1'))

    def test_eval_multi(self):
        self.assertEqual((1,2,3), self.lua.eval('1,2,3'))

    def test_eval_args(self):
        self.assertEqual(2, self.lua.eval('...', 2))

    def test_eval_args_multi(self):
        self.assertEqual((1, 2, 3), self.lua.eval('...', 1, 2, 3))

    def test_eval_name_mode(self):
        self.assertEqual(2, self.lua.eval('1+1', name='plus', mode='t'))

    def test_eval_mode_error(self):
        if self.lupa.LUA_VERSION < (5, 2):
            raise unittest.SkipTest("needs lua 5.2+")
        self.assertRaises(self.lupa.LuaSyntaxError, self.lua.eval, '1+1', name='plus', mode='b')

    def test_eval_error(self):
        self.assertRaises(self.lupa.LuaError, self.lua.eval, '<INVALIDCODE>')

    def test_eval_error_cleanup(self):
        self.assertEqual(2, self.lua.eval('1+1'))
        self.assertRaises(self.lupa.LuaError, self.lua.eval, '<INVALIDCODE>')
        self.assertEqual(2, self.lua.eval('1+1'))
        self.assertRaises(self.lupa.LuaError, self.lua.eval, '<INVALIDCODE>')
        self.assertEqual(2, self.lua.eval('1+1'))
        self.assertEqual(2, self.lua.eval('1+1'))

    def test_eval_error_message_decoding(self):
        try:
            self.lua.eval('require "UNKNOWNöMODULEäNAME"')
        except self.lupa.LuaError as exc:
            error = str(exc)
        else:
            self.fail('expected error not raised')
        expected_message = 'module \'UNKNOWNöMODULEäNAME\' not found'
        self.assertIn(expected_message, error)

    def test_execute(self):
        self.assertEqual(2, self.lua.execute('return 1+1'))

    def test_execute_mode(self):
        self.assertEqual(2, self.lua.execute('return 1+1', name='return_plus', mode='t'))

    def test_execute_mode_error(self):
        if self.lupa.LUA_VERSION < (5, 2):
            raise unittest.SkipTest("needs lua 5.2+")
        self.assertRaises(self.lupa.LuaSyntaxError, self.lua.execute, 'return 1+1', name='plus', mode='b')

    def test_execute_function(self):
        self.assertEqual(3, self.lua.execute('f = function(i) return i+1 end; return f(2)'))

    def test_execute_tostring_function(self):
        self.assertEqual('function', self.lua.execute('f = function(i) return i+1 end; return tostring(f)')[:8])

    def test_execute_args(self):
        self.assertEqual(2, self.lua.execute('return ...', 2))

    def test_execute_args_multi(self):
        self.assertEqual((1, 2, 3), self.lua.execute('return ...', 1, 2, 3))

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
        import builtins
        self.assertEqual(builtins, function())

    def test_pybuiltins_disabled(self):
        lua = self.lupa.LuaRuntime(register_builtins=False)
        self.assertEqual(True, lua.eval('python.builtins == nil'))

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
        self.assertEqual("test-1.5", function(1.5))

    def test_call_str_class(self):
        called = [False]
        class test:
            def __str__(self):
                called[0] = True
                return 'STR!!'

        function = self.lua.eval('function(x) return "test-" .. tostring(x) end')
        self.assertEqual("test-STR!!", function(test()))
        self.assertEqual(True, called[0])

    def test_python_eval(self):
        eval = self.lua.eval('function() return python.eval end')()
        self.assertEqual(2, eval('1+1'))
        self.assertEqual(2, self.lua.eval('python.eval("1+1")'))

    def test_python_eval_disabled(self):
        lua = self.lupa.LuaRuntime(register_eval=False)
        self.assertEqual(True, lua.eval('python.eval == nil'))

    def test_len_table_array(self):
        table = self.lua.eval('{1,2,3,4,5}')
        self.assertEqual(5, len(table))

    def test_len_table_dict(self):
        table = self.lua.eval('{a=1, b=2, c=3}')
        self.assertEqual(0, len(table)) # as returned by Lua's "#" operator

    def test_table_delattr(self):
        table = self.lua.eval('{a=1, b=2, c=3}')
        self.assertTrue('a' in table)
        del table.a
        self.assertFalse('a' in table)

    def test_table_delitem(self):
        table = self.lua.eval('{a=1, b=2, c=3}')
        self.assertTrue('c' in table)
        del table['c']
        self.assertFalse('c' in table)

    def test_table_delitem_special(self):
        table = self.lua.eval('{a=1, b=2, c=3, __attr__=4}')
        self.assertTrue('__attr__' in table)
        del table['__attr__']
        self.assertFalse('__attr__' in table)

    def test_len_table(self):
        table = self.lua.eval('{1,2,3,4, a=1, b=2, c=3}')
        self.assertEqual(4, len(table))  # as returned by Lua's "#" operator

    def test_iter_table(self):
        table = self.lua.eval('{2,3,4,5,6}')
        self.assertEqual([1,2,3,4,5], list(table))

    def test_iter_table_list_repeat(self):
        table = self.lua.eval('{2,3,4,5,6}')
        self.assertEqual([1,2,3,4,5], list(table))  # 1
        self.assertEqual([1,2,3,4,5], list(table))  # 2
        self.assertEqual([1,2,3,4,5], list(table))  # 3

    def test_iter_array_table_values(self):
        table = self.lua.eval('{2,3,4,5,6}')
        self.assertEqual([2,3,4,5,6], list(table.values()))

    def test_iter_array_table_repeat(self):
        table = self.lua.eval('{2,3,4,5,6}')
        self.assertEqual([2,3,4,5,6], list(table.values()))  # 1
        self.assertEqual([2,3,4,5,6], list(table.values()))  # 2
        self.assertEqual([2,3,4,5,6], list(table.values()))  # 3

    def test_iter_multiple_tables(self):
        count = 10
        table_values = [self.lua.eval('{%s}' % ','.join(map(str, range(2, count+2)))).values()
                        for _ in range(4)]

        # round robin
        l = [[] for _ in range(count)]
        for sublist in l:
            for table in table_values:
                sublist.append(_next(table))

        self.assertEqual([[i]*len(table_values) for i in range(2, count+2)], l)

    def test_iter_table_repeat(self):
        count = 10
        table_values = [self.lua.eval('{%s}' % ','.join(map(str, range(2, count+2)))).values()
                        for _ in range(4)]

        # one table after the other
        l = [[] for _ in range(count)]
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
        table = self.lua.eval('{%s}' % ','.join('%s=%d' % (c, i) for i, c in enumerate(keys)))
        l = list(table)
        l.sort()
        self.assertEqual(keys, l)

    def test_iter_table_mapping_int_keys(self):
        table = self.lua.eval('{%s}' % ','.join('[%d]=%d' % (i, -i) for i in range(10)))
        l = list(table)
        l.sort()
        self.assertEqual(list(range(10)), l)

    def test_iter_table_keys(self):
        keys = list('abcdefg')
        table = self.lua.eval('{%s}' % ','.join('%s=%d' % (c, i) for i, c in enumerate(keys)))
        l = list(table.keys())
        l.sort()
        self.assertEqual(keys, l)

    def test_iter_table_keys_int_keys(self):
        table = self.lua.eval('{%s}' % ','.join('[%d]=%d' % (i, -i) for i in range(10)))
        l = list(table.keys())
        l.sort()
        self.assertEqual(list(range(10)), l)

    def test_iter_table_values(self):
        keys = list('abcdefg')
        table = self.lua.eval('{%s}' % ','.join('%s=%d' % (c, i) for i, c in enumerate(keys)))
        l = list(table.values())
        l.sort()
        self.assertEqual(list(range(len(keys))), l)

    def test_iter_table_values_int_keys(self):
        table = self.lua.eval('{%s}' % ','.join('[%d]=%d' % (i, -i) for i in range(10)))
        l = list(table.values())
        l.sort()
        self.assertEqual(list(range(-9,1)), l)

    def test_iter_table_items(self):
        keys = list('abcdefg')
        table = self.lua.eval('{%s}' % ','.join('%s=%d' % (c, i) for i, c in enumerate(keys)))
        l = list(table.items())
        l.sort()
        self.assertEqual(list(zip(keys,range(len(keys)))), l)

    def test_iter_table_items_int_keys(self):
        table = self.lua.eval('{%s}' % ','.join('[%d]=%d' % (i, -i) for i in range(10)))
        l = list(table.items())
        l.sort()
        self.assertEqual(list(zip(range(10), range(0,-10,-1))), l)

    def test_iter_table_values_mixed(self):
        keys = list('abcdefg')
        table = self.lua.eval('{98, 99; %s}' % ','.join('%s=%d' % (c, i) for i, c in enumerate(keys)))
        l = list(table.values())
        l.sort()
        self.assertEqual(list(range(len(keys))) + [98, 99], l)

    def test_error_iter_number(self):
        func = self.lua.eval('1')
        self.assertRaises(TypeError, list, func)

    def test_error_iter_function(self):
        func = self.lua.eval('function() return 1 end')
        self.assertRaises(TypeError, list, func)

    def test_iter_table_exaust(self):
        table = self.lua.table(1, 2, 3)
        tableiter = iter(table)
        self.assertEqual(next(tableiter), 1)
        self.assertEqual(next(tableiter), 2)
        self.assertEqual(next(tableiter), 3)
        self.assertRaises(StopIteration, next, tableiter)
        self.assertRaises(StopIteration, next, tableiter)
        self.assertRaises(StopIteration, next, tableiter)

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

    def test_table_from_dict(self):
        table = self.lua.table_from({"foo": 1, "bar": 20, "baz": "spam", None: "python.none"})
        self.assertEqual(     1, table['foo'])
        self.assertEqual(    20, table['bar'])
        self.assertEqual("spam", table['baz'])
        self.assertEqual("python.none", table[None])

        self.assertEqual(0, len(table))

    def test_table_from_int_keys(self):
        table = self.lua.table_from({1: 5, 2: 10, "foo": "bar"})
        self.assertEqual(5, table[1])
        self.assertEqual(10, table[2])
        self.assertEqual("bar", table["foo"])

        self.assertEqual(2, len(table))

    # def test_table_from_obj_keys(self):
    #     key = object()
    #     table = self.lua.table_from({key: "foo"})
    #     self.assertEqual("foo", table[key])
    #
    #     self.assertEqual(0, len(table))

    def test_table_from_list(self):
        table = self.lua.table_from([1,2,5,6])
        self.assertEqual(1, table[1])
        self.assertEqual(2, table[2])
        self.assertEqual(5, table[3])
        self.assertEqual(6, table[4])

        self.assertEqual(4, len(table))

    def test_table_from_iterable(self):
        it = (x for x in range(3))
        table = self.lua.table_from(it)
        self.assertEqual(0, table[1])
        self.assertEqual(1, table[2])
        self.assertEqual(2, table[3])

        self.assertEqual(3, len(table))

    def test_table_from_multiple_dicts(self):
        table = self.lua.table_from({"a": 1, "b": 2}, {"c": 3, "b": 4})
        self.assertEqual(1, table["a"])
        self.assertEqual(4, table["b"])
        self.assertEqual(3, table["c"])

        self.assertEqual(0, len(table))

    def test_table_from_dicts_and_lists(self):
        dct, lst = {"a": 1, "b": 2}, ["foo", "bar"]
        for args in [[dct, lst], [lst, dct]]:
            table = self.lua.table_from(*args)
            self.assertEqual(1, table["a"])
            self.assertEqual(2, table["b"])
            self.assertEqual("foo", table[1])
            self.assertEqual("bar", table[2])

            self.assertEqual(2, len(table))

    def test_table_from_multiple_lists(self):
        table = self.lua.table_from(["foo", "bar"], ["egg", "spam"])
        self.assertEqual("foo", table[1])
        self.assertEqual("bar", table[2])
        self.assertEqual("egg", table[3])
        self.assertEqual("spam", table[4])

        self.assertEqual(4, len(table))

    def test_table_from_bad(self):
        self.assertRaises(TypeError, self.lua.table_from, 5)
        self.assertRaises(TypeError, self.lua.table_from, None)
        self.assertRaises(TypeError, self.lua.table_from, {"a": 5}, 123)

    def test_table_from_nested(self):
        table = self.lua.table_from([[3, 3, 3]], recursive=True)
        self.lua.globals()["data"] = table
        self.assertLuaResult("data[1][1]", 3)
        self.assertLuaResult("data[1][2]", 3)
        self.assertLuaResult("data[1][3]", 3)
        self.assertLuaResult("type(data)", "table")
        self.assertLuaResult("type(data[1])", "table")
        self.assertLuaResult("#data", 1)
        self.assertLuaResult("#data[1]", 3)

    def test_table_from_nested2(self):
        table2 = self.lua.table_from([{"a": "foo"}, {"b": 1}], recursive=True)
        self.lua.globals()["data2"] = table2
        self.assertLuaResult("#data2", 2)
        self.assertLuaResult("data2[1]['a']", "foo")
        self.assertLuaResult("data2[2]['b']", 1)

    def test_table_from_table(self):
        table1 = self.lua.eval("{3, 4, foo='bar'}")
        table2 = self.lua.table_from(table1)

        self.assertEqual(3, table2[1])
        self.assertEqual(4, table2[2])
        self.assertEqual("bar", table2["foo"])

        # data should be copied
        table2["foo"] = "spam"
        self.assertEqual("spam", table2["foo"])
        self.assertEqual("bar", table1["foo"])

    def test_table_from_table_iter(self):
        table1 = self.lua.eval("{3, 4, foo='bar'}")
        table2 = self.lua.table_from(table1.keys())

        self.assertEqual(len(table2), 3)
        self.assertEqual(list(table2.keys()), [1, 2, 3])
        self.assertEqual(set(table2.values()), set([1, 2, "foo"]))

    def test_table_from_table_iter_indirect(self):
        table1 = self.lua.eval("{3, 4, foo='bar'}")
        table2 = self.lua.table_from(k for k in table1.keys())

        self.assertEqual(len(table2), 3)
        self.assertEqual(list(table2.keys()), [1, 2, 3])
        self.assertEqual(set(table2.values()), set([1, 2, "foo"]))

    def test_table_from_nested_dict(self):
        data = {"a": {"a": "foo"}, "b": {"b": "bar"}}
        table = self.lua.table_from(data, recursive=True)
        self.assertEqual(table["a"]["a"], "foo")
        self.assertEqual(table["b"]["b"], "bar")
        self.lua.globals()["data"] = table
        self.assertLuaResult("data.a.a", "foo")
        self.assertLuaResult("data.b.b", "bar")
        self.assertLuaResult("type(data.a)", "table")
        self.assertLuaResult("type(data.b)", "table")

    def test_table_from_nested_list(self):
        data = {"a": {"a": "foo"}, "b": [1, 2, 3]}
        table = self.lua.table_from(data, recursive=True)
        self.assertEqual(table["a"]["a"], "foo")
        self.assertEqual(table["b"][1], 1)
        self.assertEqual(table["b"][2], 2)
        self.assertEqual(table["b"][3], 3)
        self.lua.globals()["data"] = table
        self.assertLuaResult("data.a.a", "foo")
        self.assertLuaResult("#data.b", 3)
        self.lua.eval("assert(#data.b==3, 'failed')")
        self.assertLuaResult("type(data.a)", "table")
        self.assertLuaResult("type(data.b)", "table")

    def test_table_from_nested_list_bad(self):
        data = {"a": {"a": "foo"}, "b": [1, 2, 3]}
        table = self.lua.table_from(data) # in this case, lua will get userdata instead of table
        self.assertEqual(table["a"]["a"], "foo")
        self.assertEqual(list(table["b"]), [1, 2, 3])
        self.assertEqual(table["b"][0], 1)
        self.assertEqual(table["b"][1], 2)
        self.assertEqual(table["b"][2], 3)
        self.lua.globals()["data"] = table
        self.assertLuaResult("type(data.a)", "userdata")
        self.assertLuaResult("type(data.b)", "userdata")

    def test_table_from_self_ref_obj(self):
        data = {}
        data["key"] = data
        l = []
        l.append(l)
        data["list"] = l
        table = self.lua.table_from(data, recursive=True)
        self.lua.globals()["data"] = table
        self.assertLuaResult("type(data)", 'table')
        self.assertLuaResult("type(data['key'])",'table')
        self.assertLuaResult("type(data['list'])",'table')
        self.assertLuaResult("data['list']==data['list'][1]", True)
        self.assertLuaResult("type(data['key']['key']['key']['key'])", 'table')
        self.assertLuaResult("type(data['key']['key']['key']['key']['list'])", 'table')

    def test_table_from_nested_datastructures(self):
        from itertools import count
        def make_ds(*children):
            yield list(children)
            yield dict(zip(count(), children))
            yield {chr(ord('A') + i): child for i, child in enumerate(children)}

        elements = [1, 2, 'x', 'y']
        for ds1 in make_ds(*elements):
            for ds2 in make_ds(ds1):
                for ds3 in make_ds(ds1, elements, ds2):
                    for ds in make_ds(ds1, ds2, ds3):
                        with self.subTest(ds=ds):
                            table = self.lua.table_from(ds)
                            # we don't translate transitively, so apply arbitrary test operation
                            self.assertTrue(list(table))

    # FIXME: it segfaults
    # def test_table_from_generator_calling_lua_functions(self):
    #     func = self.lua.eval("function (obj) return obj end")
    #     table = self.lua.table_from(func(obj) for obj in ["foo", "bar"])
    #
    #     self.assertEqual(len(table), 2)
    #     self.assertEqual(set(table.values()), set(["foo", "bar"]))

    def test_table_contains(self):
        table = self.lua.eval("{foo=5}")
        self.assertTrue("foo" in table)
        self.assertFalse("bar" in table)
        self.assertFalse(5 in table)

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

    def test_setitem_array_none(self):
        table = self.lua.eval('{1,2}')
        get_none = self.lua.eval('function(t) return t[python.none] end')
        self.assertEqual(2, len(table))
        self.assertEqual(None, table[None])
        self.assertEqual(None, get_none(table))
        table[None] = 123
        self.assertEqual(123, table[None])
        self.assertEqual(123, get_none(table))
        self.assertEqual(2, len(table))

    def test_setitem_array_none_initial(self):
        table = self.lua.eval('{1,python.none,3}')
        get_none = self.lua.eval('function(t) return t[python.none] end')
        self.assertEqual(3, len(table))
        self.assertEqual(None, table[None])
        self.assertEqual(None, get_none(table))
        table[None] = 123
        self.assertEqual(123, table[None])
        self.assertEqual(123, get_none(table))
        self.assertEqual(3, len(table))

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
        class test:
            def __init__(self):
                self.ATTR = 5
        self.assertEqual(test().ATTR, lua_func(test()))

    def test_pysetattr(self):
        lua_func = self.lua.eval('function(x) x.ATTR = 123 end')
        class test:
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
        self.assertNotEqual(None, lua_globals.table)

    def test_globals_attrs_call(self):
        lua_globals = self.lua.globals()
        self.assertNotEqual(None, lua_globals.string)
        self.assertEqual('test', lua_globals.string.lower("TEST"))

    def test_require(self):
        stringlib = self.lua.require('string')
        self.assertNotEqual(None, stringlib)
        self.assertNotEqual(None, stringlib.char)

    def test_libraries(self):
        libraries = self.lua.eval('{require, table, io, os, math, string, debug}')
        self.assertEqual(7, len(libraries))
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

    def test_reraise_pcall(self):
        exception = Exception('test')
        def py_function():
            raise exception
        function = self.lua.eval(
            'function(p) local r, err = pcall(p); return r, err end'
        )
        self.assertEqual(
            function(py_function),
            (False, exception)
        )

    def test_lua_error_after_intercepted_python_exception(self):
        function = self.lua.eval('''
            function(p)
                pcall(p)
                print(a.b);
            end
        ''')
        self.assertRaises(
            self.lupa.LuaError,
            function,
            lambda: 5/0,
        )

    def test_attribute_filter(self):
        def attr_filter(obj, name, setting):
            if isinstance(name, str):
                if not name.startswith('_'):
                    return name + '1'
            raise AttributeError('denied')

        lua = self.lupa.LuaRuntime(attribute_filter=attr_filter)
        function = lua.eval('function(obj) return obj.__name__ end')
        class X:
            a = 0
            a1 = 1
            _a = 2
            __a = 3
        x = X()

        function = self.lua.eval('function(obj) return obj.a end')
        self.assertEqual(function(x), 0)
        function = lua.eval('function(obj) return obj.a end')
        self.assertEqual(function(x), 1)

        function = self.lua.eval('function(obj) return obj.__class__ end')
        self.assertEqual(function(x), X)
        function = lua.eval('function(obj) return obj.__class__ end')
        self.assertRaises(AttributeError, function, x)

        function = self.lua.eval('function(obj) return obj._a end')
        self.assertEqual(function(x), 2)
        function = lua.eval('function(obj) return obj._a end')
        self.assertRaises(AttributeError, function, x)

        function = self.lua.eval('function(obj) return obj._X__a end')
        self.assertEqual(function(x), 3)
        function = lua.eval('function(obj) return obj._X__a end')
        self.assertRaises(AttributeError, function, x)

        function = self.lua.eval('function(obj) return obj.a end')
        self.assertEqual(function(x), 0)
        function = lua.eval('function(obj) return obj.a end')
        self.assertEqual(function(x), 1)

    def test_lua_type(self):
        x = self.lua.eval('{}')
        self.assertEqual('table', self.lupa.lua_type(x))

        x = self.lua.eval('function() return 1 end')
        self.assertEqual('function', self.lupa.lua_type(x))

        x = self.lua.eval('function() coroutine.yield(1) end')
        self.assertEqual('function', self.lupa.lua_type(x))
        self.assertEqual('thread', self.lupa.lua_type(x.coroutine()))

        self.assertEqual(None, self.lupa.lua_type(1))
        self.assertEqual(None, self.lupa.lua_type(1.1))
        self.assertEqual(None, self.lupa.lua_type('abc'))
        self.assertEqual(None, self.lupa.lua_type({}))
        self.assertEqual(None, self.lupa.lua_type([]))
        self.assertEqual(None, self.lupa.lua_type(self.lupa))
        self.assertEqual(None, self.lupa.lua_type(self.lupa.lua_type))

    def test_call_from_coroutine(self):
        lua = self.lua
        def f(*args, **kwargs):
            return lua.eval('tostring(...)', args)

        create_thread = lua.eval('''
        function(func)
           local thread = coroutine.create(function()
               coroutine.yield(func());
           end);
           return thread;
        end''')
        t = create_thread(f)()
        self.assertEqual(lua.eval('coroutine.resume(...)', t), (True, '()'))

    def test_call_from_coroutine2(self):
        lua = self.lua
        def f(*args, **kwargs):
            return lua.eval('tostring(...)', args)

        t = lua.eval('''
           function(f)
             coroutine.yield(f());
           end
        ''').coroutine(f)
        self.assertEqual(lua.eval('coroutine.resume(...)', t, f), (True, '()'))

    def test_compile(self):
        lua_func = self.lua.compile('return 1 + 2')
        self.assertEqual(lua_func(), 3)
        lua_func = self.lua.compile('return 3 + 2', mode='t')
        self.assertEqual(lua_func(), 5)
        lua_func = self.lua.compile('return 1 + 3', name='huhu')
        self.assertEqual(lua_func(), 4)
        lua_func = self.lua.compile('return 2 + 3', name='huhu', mode='t')
        self.assertEqual(lua_func(), 5)
        self.assertRaises(self.lupa.LuaSyntaxError, self.lua.compile, 'function awd()')


class TestAttributesNoAutoEncoding(SetupLuaRuntimeMixin, LupaTestCase):
    lua_runtime_kwargs = {'encoding': None}

    def test_pygetitem(self):
        lua_func = self.lua.eval('function(x) return x.ATTR end')
        self.assertEqual(123, lua_func({b'ATTR': 123}))

    def test_pysetitem(self):
        lua_func = self.lua.eval('function(x) x.ATTR = 123 end')
        d = {b'ATTR': 321}
        self.assertEqual(321, d[b'ATTR'])
        lua_func(d)
        self.assertEqual(123, d[b'ATTR'])

    def test_pygetattr(self):
        lua_func = self.lua.eval('function(x) return x.ATTR end')
        class test:
            def __init__(self):
                self.ATTR = 5
        self.assertEqual(test().ATTR, lua_func(test()))

    def test_pysetattr(self):
        lua_func = self.lua.eval('function(x) x.ATTR = 123 end')
        class test:
            def __init__(self):
                self.ATTR = 5
        t = test()
        self.assertEqual(5, t.ATTR)
        lua_func(t)
        self.assertEqual(123, t.ATTR)


class TestStrNoAutoEncoding(SetupLuaRuntimeMixin, LupaTestCase):
    lua_runtime_kwargs = {'encoding': None}

    def test_call_str(self):
        self.assertEqual(b"test-None", self.lua.eval('"test-" .. tostring(python.none)'))

    def test_call_str_py(self):
        function = self.lua.eval('function(x) return "test-" .. tostring(x) end')
        self.assertEqual(b"test-nil", function(None))
        self.assertEqual(b"test-1.5", function(1.5))

    def test_call_str_class(self):
        called = [False]
        class test:
            def __str__(self):
                called[0] = True
                return 'STR!!'

        function = self.lua.eval('function(x) return "test-" .. tostring(x) end')
        self.assertEqual(b"test-STR!!", function(test()))
        self.assertEqual(True, called[0])


class TestAttributeHandlers(LupaTestCase):
    def setUp(self):
        self.lua = self.lupa.LuaRuntime()
        self.lua_handling = self.lupa.LuaRuntime(attribute_handlers=(self.attr_getter, self.attr_setter))

        self.x, self.y = self.X(), self.Y()
        self.d = {'a': "aval", "b": "bval", "c": "cval"}

    def tearDown(self):
        self.lua = None
        gc.collect()

    class X:
        a = 0
        a1 = 1
        _a = 2
        __a = 3

    class Y:
        a = 0
        a1 = 1
        _a = 2
        __a = 3

    def attr_getter(self, obj, name):
        if not isinstance(name, str):
            raise AttributeError('bad type for attr_name')
        if isinstance(obj, self.X):
            if not name.startswith('_'):
                value = getattr(obj, name, None)
                if value is not None:
                    return value + 10
                return None
            else:
                return "forbidden"
        elif isinstance(obj, dict):
            if name == "c":
                name = "b"
            return obj.get(name, None)
        return None

    def attr_setter(self, obj, name, value):
        if isinstance(obj, self.Y):
            return  # class Y is read only.
        if isinstance(obj, self.X):
            if name.startswith('_'):
                return
            if hasattr(obj, name):
                setattr(obj, name, value)
        elif isinstance(obj, dict):
            if 'forbid_new' in obj and name not in obj:
                return
            obj[name] = value

    def test_legal_arguments(self):
        self.lupa.LuaRuntime(attribute_filter=None)
        self.lupa.LuaRuntime(attribute_filter=len)
        self.lupa.LuaRuntime(attribute_handlers=None)
        self.lupa.LuaRuntime(attribute_handlers=())
        self.lupa.LuaRuntime(attribute_handlers=[len, bool])
        self.lupa.LuaRuntime(attribute_handlers=iter([len, bool]))
        self.lupa.LuaRuntime(attribute_handlers=(None, None))
        self.lupa.LuaRuntime(attribute_handlers=iter([None, None]))

    def test_illegal_arguments(self):
        self.assertRaises(
            ValueError, self.lupa.LuaRuntime, attribute_filter=123)
        self.assertRaises(
            ValueError, self.lupa.LuaRuntime, attribute_handlers=(1, 2, 3, 4))
        self.assertRaises(
            ValueError, self.lupa.LuaRuntime, attribute_handlers=(1,))
        self.assertRaises(
            ValueError, self.lupa.LuaRuntime, attribute_handlers=(1, 2))
        self.assertRaises(
            ValueError, self.lupa.LuaRuntime, attribute_handlers=(1, len))
        self.assertRaises(
            ValueError, self.lupa.LuaRuntime, attribute_handlers=(len, 2))
        self.assertRaises(
            ValueError, self.lupa.LuaRuntime, attribute_handlers=(len, bool), attribute_filter=bool)

    def test_attribute_setter_normal(self):
        function = self.lua_handling.eval("function (obj) obj.a = 100 end")
        function(self.x)
        self.assertEqual(self.x.a, 100)

    def test_attribute_setter_forbid_underscore(self):
        function = self.lua_handling.eval("function (obj) obj._a = 100 end")
        function(self.x)
        self.assertEqual(self.x._a, 2)

    def test_attribute_setter_readonly_object(self):
        function = self.lua_handling.eval("function (obj) obj.a1 = 100 end")
        function(self.y)
        self.assertEqual(self.y.a1, 1)

    def test_attribute_setter_dict_create(self):
        function = self.lua_handling.eval("function (obj) obj['x'] = 'new' end")
        function(self.d)
        self.assertEqual(self.d.get('x'), 'new')

    def test_attribute_setter_forbidden_dict_create(self):
        self.d['forbid_new'] = True
        function = self.lua_handling.eval("function (obj) obj['x'] = 'new' end")
        function(self.d)
        self.assertEqual(self.d.get('x'), None)

    def test_attribute_setter_dict_update(self):
        function = self.lua_handling.eval("function (obj) obj['a'] = 'new' end")
        function(self.d)
        self.assertEqual(self.d['a'], 'new')

    def test_attribute_setter_forbidden_dict_update(self):
        self.d['forbid_new'] = True
        function = self.lua_handling.eval("function (obj) obj['a'] = 'new' end")
        function(self.d)
        self.assertEqual(self.d['a'], 'new')

    def test_attribute_getter_forbid_double_underscores(self):
        function = self.lua_handling.eval('function(obj) return obj.__name__ end')
        self.assertEqual(function(self.x), "forbidden")

        function = self.lua.eval('function(obj) return obj.__class__ end')
        self.assertEqual(function(self.x), self.X)
        function = self.lua_handling.eval('function(obj) return obj.__class__ end')
        self.assertEqual(function(self.x), "forbidden")

        function = self.lua.eval('function(obj) return obj._X__a end')
        self.assertEqual(function(self.x), 3)
        function = self.lua_handling.eval('function(obj) return obj._X__a end')
        self.assertEqual(function(self.x), "forbidden")

    def test_attribute_getter_mess_with_underscores(self):
        function = self.lua.eval('function(obj) return obj._a end')
        self.assertEqual(function(self.x), 2)
        function = self.lua_handling.eval('function(obj) return obj._a end')
        self.assertEqual(function(self.x), "forbidden")

    def test_attribute_getter_replace_values(self):
        function = self.lua.eval('function(obj) return obj.a end')
        self.assertEqual(function(self.x), 0)
        function = self.lua_handling.eval('function(obj) return obj.a end')
        self.assertEqual(function(self.x), 10)

        function = self.lua.eval('function(obj) return obj.a end')
        self.assertEqual(function(self.x), 0)
        function = self.lua_handling.eval('function(obj) return obj.a end')
        self.assertEqual(function(self.x), 10)

    def test_attribute_getter_lenient_retrieval(self):
        function = self.lua.eval('function(obj) return obj.bad_attr end')
        self.assertRaises(AttributeError, function, self.y)
        function = self.lua_handling.eval('function(obj) return obj.bad_attr end')
        self.assertEqual(function(self.y), None)

    def test_attribute_getter_normal_dict_retrieval(self):
        function = self.lua.eval('function(obj) return obj.a end')
        self.assertEqual(function(self.d), "aval")
        function = self.lua_handling.eval('function(obj) return obj.a end')
        self.assertEqual(function(self.d), "aval")

    def test_attribute_getter_modify_dict_retrival(self):
        function = self.lua.eval('function(obj) return obj.c end')
        self.assertEqual(function(self.d), "cval")
        function = self.lua_handling.eval('function(obj) return obj.c end')
        self.assertEqual(function(self.d), "bval")

    def test_attribute_getter_lenient_dict_retrival(self):
        function = self.lua.eval('function(obj) return obj.g end')
        self.assertRaises(KeyError, function, self.d)
        function = self.lua_handling.eval('function(obj) return obj.g end')
        self.assertEqual(function(self.d), None)


class TestPythonObjectsInLua(SetupLuaRuntimeMixin, LupaTestCase):
    def test_explicit_python_function(self):
        lua_func = self.lua.eval(
            'function(func)'
            ' t = {1, 5, 2, 4, 3};'
            ' table.sort(t, python.as_function(func));'
            ' return t end')

        def compare(a, b):
            return a < b
        self.assertEqual([1, 2, 3, 4, 5], list(lua_func(compare)))

    def test_type_conversion(self):
        lua_type = self.lua.eval('type')
        self.assertEqual('number', lua_type(1))
        self.assertEqual('string', lua_type("test"))

    def test_pyobject_wrapping_callable(self):
        lua_type = self.lua.eval('type')
        lua_get_call = self.lua.eval('function(obj) return getmetatable(obj).__call end')

        class Callable:
            def __call__(self): pass
            def __getitem__(self, item): pass

        self.assertEqual('userdata', lua_type(Callable()))
        self.assertNotEqual(None, lua_get_call(Callable()))

    def test_pyobject_wrapping_getitem(self):
        lua_type = self.lua.eval('type')
        lua_get_index = self.lua.eval('function(obj) return getmetatable(obj).__index end')

        class GetItem:
            def __getitem__(self, item): pass

        self.assertEqual('userdata', lua_type(GetItem()))
        self.assertNotEqual(None, lua_get_index(GetItem()))

    def test_pyobject_wrapping_getattr(self):
        lua_type = self.lua.eval('type')
        lua_get_index = self.lua.eval('function(obj) return getmetatable(obj).__index end')

        class GetAttr:
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

    def test_python_enumerate_list_start_invalid(self):
        python_enumerate = self.lua.globals().python.enumerate
        iterator = range(10)
        self.assertRaises(self.lupa.LuaError, python_enumerate, iterator, "abc")
        self.assertRaises(self.lupa.LuaError, python_enumerate, iterator, self.lua.table())
        self.assertRaises(self.lupa.LuaError, python_enumerate, iterator, python_enumerate)

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
        table = values(self.lupa.as_attrgetter(dict(a=1, b=2, c=3)))
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

    def test_python_iter_list_some_None(self):
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
        self.assertEqual([None, 1, None], list(values([None, 1, None]).values()))

    def test_python_iter_iterator(self):
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
        self.assertEqual([3, 2, 1], list(values(reversed([1, 2, 3])).values()))


class TestLuaCoroutines(SetupLuaRuntimeMixin, LupaTestCase):

    @unittest.skipIf(IS_PYPY, "attribute access differs in PyPy")
    def test_coroutine_object(self):
        f = self.lua.eval("function(N) coroutine.yield(N) end")
        gen = f.coroutine(5)
        self.assertRaises(AttributeError, getattr, gen, '__setitem__')
        self.assertRaises(AttributeError, setattr, gen, 'send', 5)
        self.assertRaises(AttributeError, setattr, gen, 'no_such_attribute', 5)
        self.assertRaises(AttributeError, getattr, gen, 'no_such_attribute')
        self.assertRaises(AttributeError, gen.__getattr__, 'no_such_attribute')

        self.assertRaises(self.lupa.LuaError, gen.__call__)
        self.assertTrue(hasattr(gen.send, '__call__'))

        self.assertRaises(TypeError, operator.itemgetter(1), gen)
        self.assertRaises(TypeError, gen.__getitem__, 1)

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
        result = [count.send(value) for value in ([None] + [True] * 9 + [False])]
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
            for value in ([None] + list(range(10))):
                result.append(count.send(value))
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


class TestLuaCoroutinesWithDebugHooks(SetupLuaRuntimeMixin, LupaTestCase):

    def _enable_hook(self):
        self.lua.execute('''
            steps = 0
            debug.sethook(function () steps = steps + 1 end, '', 1)
        ''')

    def test_coroutine_yields_callback_debug_hook(self):
        self.lua.execute('''
            func = function()
                coroutine.yield(function() return 123 end)
            end
        ''')
        def _check():
            coro = self.lua.eval('func').coroutine()
            cb = next(coro)
            self.assertEqual(cb(), 123)

        # yielding a callback should work without a debug hook
        _check()

        # it should keep working after a debug hook is added
        self._enable_hook()
        _check()

    def test_coroutine_yields_callback_debug_hook_nowrap(self):
        resume = self.lua.eval("coroutine.resume")
        self.lua.execute('''
            func = function()
                coroutine.yield(function() return 123 end)
            end
        ''')
        def _check():
            coro = self.lua.eval('func').coroutine()
            ok, cb = resume(coro)
            self.assertEqual(ok, True)
            self.assertEqual(cb(), 123)

        # yielding a callback should work without a debug hook
        _check()

        # it should keep working after a debug hook is added
        self._enable_hook()
        _check()

    def test_coroutine_sets_callback_debug_hook(self):
        self.lua.execute('''
            func = function(dct)
                dct['cb'] = function() return 123 end
                coroutine.yield()
            end
        ''')
        def _check(dct):
            coro = self.lua.eval('func').coroutine(dct)
            next(coro)
            cb = dct['cb']
            self.assertEqual(cb(), 123)

        # sending a callback should work without a debug hook
        _check({})

        # enable debug hook and try again
        self._enable_hook()

        # it works with a Lua table wrapper
        _check(self.lua.table_from({}))

        # FIXME: but it fails with a regular dict
        # _check({})

    def test_coroutine_sets_callback_debug_hook_nowrap(self):
        resume = self.lua.eval("coroutine.resume")
        self.lua.execute('''
            func = function(dct)
                dct['cb'] = function() return 123 end
                coroutine.yield()
            end
        ''')
        def _check():
            dct = {}
            coro = self.lua.eval('func').coroutine()
            resume(coro, dct)  # send initial value
            resume(coro)
            cb = dct['cb']
            self.assertEqual(cb(), 123)

        # sending a callback should work without a debug hook
        _check()

        # enable debug hook and try again
        self._enable_hook()
        _check()


class TestLuaApplications(LupaTestCase):
    def tearDown(self):
        gc.collect()

    def test_mandelbrot(self):
        # copied from Computer Language Benchmarks Game
        code = '''\
function(N)
    local char, unpack = string.char, unpack
    if unpack == nil then unpack = table.unpack end
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

        lua = self.lupa.LuaRuntime(encoding=None)
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


class TestLuaRuntimeEncoding(LupaTestCase):
    def tearDown(self):
        gc.collect()

    test_string = '"abcüöä"'

    def _encoding_test(self, encoding, expected_length):
        lua = self.lupa.LuaRuntime(encoding)

        self.assertEqual(str,
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
        lua = self.lupa.LuaRuntime('UTF-8')
        stringlib = lua.eval('string')
        self.assertEqual('abc', stringlib.lower('ABC'))

    def test_stringlib_no_encoding(self):
        lua = self.lupa.LuaRuntime(encoding=None)
        stringlib = lua.eval('string')
        self.assertEqual('abc'.encode('ASCII'), stringlib.lower('ABC'.encode('ASCII')))


class TestMultipleLuaRuntimes(LupaTestCase):
    def tearDown(self):
        gc.collect()

    def test_multiple_runtimes(self):
        lua1 = self.lupa.LuaRuntime()

        function1 = lua1.eval('function() return 1 end')
        self.assertNotEqual(None, function1)
        self.assertEqual(1, function1())

        lua2 = self.lupa.LuaRuntime()

        function2 = lua2.eval('function() return 1+1 end')
        self.assertNotEqual(None, function2)
        self.assertEqual(1, function1())
        self.assertEqual(2, function2())

        lua3 = self.lupa.LuaRuntime()

        self.assertEqual(1, function1())
        self.assertEqual(2, function2())

        function3 = lua3.eval('function() return 1+1+1 end')
        self.assertNotEqual(None, function3)

        del lua1, lua2, lua3

        self.assertEqual(1, function1())
        self.assertEqual(2, function2())
        self.assertEqual(3, function3())


class TestThreading(LupaTestCase):
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
        lua = self.lupa.LuaRuntime()
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
        runtimes  = [ self.lupa.LuaRuntime() for _ in range(10) ]
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
        runtimes  = [ self.lupa.LuaRuntime() for _ in range(10) ]
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
        lua = self.lupa.LuaRuntime()
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
                if unpack == nil then unpack = table.unpack end
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

        lua_funcs = [ self.lupa.LuaRuntime(encoding=None).eval(code)
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
        self.assertTrue(b'\xFF' in result_bytes)

        # if we have PIL, check that it can read the image
        ## try:
        ##     import Image
        ## except ImportError:
        ##     pass
        ## else:
        ##     image = Image.fromstring('1', (image_size, image_size), result_bytes)
        ##     image.show()

    def test_lua_gc_deadlock(self):
        # Delete a Lua reference from a thread while the LuaRuntime is running.
        lua = self.lupa.LuaRuntime()
        ref = [lua.eval("{}")]

        def trigger_gc(ref):
            del ref[0]

        thread = threading.Thread(target=trigger_gc, args=[ref])

        lua.execute(
            "start, join = ...; start(); join()",
            thread.start,
            thread.join,
        )
        assert not thread.is_alive(), "thread didn't finish - deadlock?"


class TestDontUnpackTuples(LupaTestCase):
    def setUp(self):
        self.lua = self.lupa.LuaRuntime()  # default is unpack_returned_tuples=False

        # Define a Python function which returns a tuple
        # and is accessible from Lua as fun().
        def tuple_fun():
            return "one", "two", "three", "four"
        self.lua.globals()['fun'] = tuple_fun

    def tearDown(self):
        self.lua = None
        gc.collect()

    def test_python_function_tuple(self):
        self.lua.execute("a, b, c = fun()")
        self.assertEqual(("one", "two", "three", "four"), self.lua.eval("a"))
        self.assertEqual(None, self.lua.eval("b"))
        self.assertEqual(None, self.lua.eval("c"))

    def test_python_function_tuple_exact(self):
        self.lua.execute("a = fun()")
        self.assertEqual(("one", "two", "three", "four"), self.lua.eval("a"))


class TestUnpackTuples(LupaTestCase):
    def setUp(self):
        self.lua = self.lupa.LuaRuntime(unpack_returned_tuples=True)

        # Define a Python function which returns a tuple
        # and is accessible from Lua as fun().
        def tuple_fun():
            return "one", "two", "three", "four"
        self.lua.globals()['fun'] = tuple_fun

    def tearDown(self):
        self.lua = None
        gc.collect()

    def test_python_function_tuple_expansion_exact(self):
        self.lua.execute("a, b, c, d = fun()")
        self.assertEqual("one", self.lua.eval("a"))
        self.assertEqual("two", self.lua.eval("b"))
        self.assertEqual("three", self.lua.eval("c"))
        self.assertEqual("four", self.lua.eval("d"))

    def test_python_function_tuple_expansion_extra_args(self):
        self.lua.execute("a, b, c, d, e, f = fun()")
        self.assertTrue(self.lua.eval("a == 'one'"))
        self.assertTrue(self.lua.eval("b == 'two'"))
        self.assertTrue(self.lua.eval("c == 'three'"))
        self.assertTrue(self.lua.eval("d == 'four'"))
        self.assertTrue(self.lua.eval("e == nil"))
        self.assertTrue(self.lua.eval("f == nil"))
        self.assertEqual("one", self.lua.eval("a"))
        self.assertEqual("two", self.lua.eval("b"))
        self.assertEqual("three", self.lua.eval("c"))
        self.assertEqual("four", self.lua.eval("d"))
        self.assertEqual(None, self.lua.eval("e"))
        self.assertEqual(None, self.lua.eval("f"))

    def test_python_function_tuple_expansion_missing_args(self):
        self.lua.execute("a, b = fun()")
        self.assertEqual("one", self.lua.eval("a"))
        self.assertEqual("two", self.lua.eval("b"))

    def test_translate_None(self):
        """Lua does not understand None.  Should (almost) never see it."""
        self.lua.globals()['f'] = lambda: (None, None)

        self.lua.execute("x, y = f()")

        self.assertEqual(None, self.lua.eval("x"))
        self.assertEqual(self.lua.eval("x"), self.lua.eval("y"))
        self.assertEqual(self.lua.eval("x"), self.lua.eval("z"))
        self.assertTrue(self.lua.eval("x == y"))
        self.assertTrue(self.lua.eval("x == z"))
        self.assertTrue(self.lua.eval("x == nil"))
        self.assertTrue(self.lua.eval("nil == z"))

    def test_python_enumerate_list_unpacked(self):
        values = self.lua.eval('''
            function(L)
                local t = {}
                for index, a, b in python.enumerate(L) do
                    assert(a + 30 == b)
                    t[ index+1 ] = a + b
                end
                return t
            end
        ''')
        self.assertEqual([50, 70, 90], list(values(zip([10, 20, 30], [40, 50, 60])).values()))

    def test_python_enumerate_list_unpacked_None(self):
        values = self.lua.eval('''
            function(L)
                local t = {}
                for index, a, b in python.enumerate(L) do
                    assert(a == nil)
                    t[ index+1 ] = b
                end
                return t
            end
        ''')
        self.assertEqual([3, 5], list(values(zip([None, None, None], [3, None, 5])).values()))

    def test_python_enumerate_list_start(self):
        values = self.lua.eval('''
            function(L)
                local t = {5,6,7}
                for index, a, b, c in python.enumerate(L, 3) do
                    assert(c == nil)
                    assert(a + 10 == b)
                    t[ index ] = a + b
                end
                return t
            end
        ''')
        self.assertEqual([5, 6, 30, 50, 70],
                         list(values(zip([10, 20, 30], [20, 30, 40])).values()))


class TestMethodCall(LupaTestCase):
    def setUp(self):

        self.lua = self.lupa.LuaRuntime(unpack_returned_tuples=True)

        class C:
            def __init__(self, x):
                self.x = int(x)

            def getx(self):
                return self.x

            def getx1(self, n):
                return int(n) + self.x

            def setx(self, v):
                self.x = int(v)

            @classmethod
            def classmeth(cls, v):
                return v

            @staticmethod
            def staticmeth(v):
                return v

        class D(C):
            pass

        def f():
            return 100

        def g(n):
            return int(n) + 100

        x = C(1)
        self.lua.globals()['C'] = C
        self.lua.globals()['D'] = D
        self.lua.globals()['x'] = x
        self.lua.globals()['f'] = f
        self.lua.globals()['g'] = g
        self.lua.globals()['d'] = { 'F': f, "G": g }
        self.lua.globals()['bound0'] = x.getx
        self.lua.globals()['bound1'] = x.getx1

    def tearDown(self):
        self.lua = None
        gc.collect()

    def test_method_call_as_method(self):
        self.assertEqual(self.lua.eval("x:getx()"), 1)
        self.assertEqual(self.lua.eval("x:getx1(2)"), 3)
        self.lua.execute("x:setx(4)")
        self.assertEqual(self.lua.eval("x:getx()"), 4)
        self.assertEqual(self.lua.eval("x:getx1(2)"), 6)

    def test_method_call_as_attribute(self):
        self.assertEqual(self.lua.eval("x.getx()"), 1)
        self.assertEqual(self.lua.eval("x.getx1(2)"), 3)
        self.lua.execute("x.setx(4)")
        self.assertEqual(self.lua.eval("x.getx()"), 4)
        self.assertEqual(self.lua.eval("x.getx1(2)"), 6)

    def test_method_call_mixed(self):
        self.assertEqual(self.lua.eval("x.getx()"), 1)
        self.assertEqual(self.lua.eval("x:getx1(2)"), 3)
        self.assertEqual(self.lua.eval("x:getx()"), 1)
        self.assertEqual(self.lua.eval("x.getx1(2)"), 3)

        self.lua.execute("x:setx(4)")
        self.assertEqual(self.lua.eval("x:getx()"), 4)
        self.assertEqual(self.lua.eval("x.getx1(2)"), 6)
        self.assertEqual(self.lua.eval("x.getx()"), 4)
        self.assertEqual(self.lua.eval("x:getx1(2)"), 6)

        self.lua.execute("x.setx(6)")
        self.assertEqual(self.lua.eval("x.getx()"), 6)
        self.assertEqual(self.lua.eval("x:getx()"), 6)
        self.assertEqual(self.lua.eval("x.getx()"), 6)
        self.assertEqual(self.lua.eval("x.getx1(2)"), 8)
        self.assertEqual(self.lua.eval("x:getx1(2)"), 8)

    def test_method_call_function_lookup(self):
        self.assertEqual(self.lua.eval("f()"), 100)
        self.assertEqual(self.lua.eval("g(10)"), 110)
        self.assertEqual(self.lua.eval("d.F()"), 100)
        self.assertEqual(self.lua.eval("d.G(9)"), 109)

    def test_method_call_class_hierarchy(self):
        self.assertEqual(self.lua.eval("C(5).getx()"), 5)
        self.assertEqual(self.lua.eval("D(5).getx()"), 5)

        self.assertEqual(self.lua.eval("C(5):getx()"), 5)
        self.assertEqual(self.lua.eval("D(5):getx()"), 5)

    def test_method_call_class_methods(self):
        # unbound methods
        self.assertEqual(self.lua.eval("C.getx(C(5))"), 5)
        self.assertEqual(self.lua.eval("C.getx(D(5))"), 5)

        # class/static methods
        self.assertEqual(self.lua.eval("C:classmeth(5)"), 5)
        self.assertEqual(self.lua.eval("C.classmeth(5)"), 5)
        self.assertEqual(self.lua.eval("C.staticmeth(5)"), 5)

    def test_method_call_bound(self):
        self.assertEqual(self.lua.eval("bound0()"), 1)
        self.assertEqual(self.lua.eval("bound1(3)"), 4)
        self.assertEqual(self.lua.eval("python.eval('1 .__add__')(1)"), 2)
        self.assertEqual(self.lua.eval("python.eval('1 .__add__')(2)"), 3)

        # the following is an unfortunate side effect of the "self" removal
        # on bound method calls:
        self.assertRaises(TypeError, self.lua.eval, "bound1(x)")


################################################################################
# tests for the lupa.unpacks_lua_table and lupa.unpacks_lua_table_method
# decorators

@lupa.unpacks_lua_table
def func_1(x):
    return ("x=%s" % (x, ))


@lupa.unpacks_lua_table
def func_2(x, y):
    return ("x=%s, y=%s" % (x, y))


@lupa.unpacks_lua_table
def func_3(x, y, z='default'):
    return ("x=%s, y=%s, z=%s" % (x, y, z))


class MyCls_1:
    @lupa.unpacks_lua_table_method
    def meth(self, x):
        return ("x=%s" % (x,))


class MyCls_2:
    @lupa.unpacks_lua_table_method
    def meth(self, x, y):
        return ("x=%s, y=%s" % (x, y))


class MyCls_3:
    @lupa.unpacks_lua_table_method
    def meth(self, x, y, z='default'):
        return ("x=%s, y=%s, z=%s" % (x, y, z))


class KwargsDecoratorTest(SetupLuaRuntimeMixin, LupaTestCase):

    def __init__(self, *args, **kwargs):
        super(KwargsDecoratorTest, self).__init__(*args, **kwargs)
        self.arg1 = func_1
        self.arg2 = func_2
        self.arg3 = func_3

    def assertResult(self, f, call_txt, res_txt):
        lua_func = self.lua.eval("function (f) return f%s end" % call_txt)
        self.assertEqual(lua_func(f), res_txt)

    def assertIncorrect(self, f, call_txt, error=TypeError):
        lua_func = self.lua.eval("function (f) return f%s end" % call_txt)
        self.assertRaises(error, lua_func, f)

    def test_many_args(self):
        self.assertResult(self.arg2, "{x=1, y=2}", "x=1, y=2")
        self.assertResult(self.arg2, "{x=2, y=1}", "x=2, y=1")
        self.assertResult(self.arg2, "{y=1, x=2}", "x=2, y=1")
        self.assertResult(self.arg2, "(1, 2)",     "x=1, y=2")

    def test_single_arg(self):
        self.assertResult(self.arg1, "{x=1}", "x=1")
        self.assertResult(self.arg1, "(1)", "x=1")
        self.assertResult(self.arg1, "(nil)", "x=None")

    def test_defaults(self):
        self.assertResult(self.arg3, "{x=1, y=2}", "x=1, y=2, z=default")
        self.assertResult(self.arg3, "{x=1, y=2, z=3}", "x=1, y=2, z=3")

    def test_defaults_incorrect(self):
        self.assertIncorrect(self.arg3, "{x=1, z=3}")

    def test_kwargs_unknown(self):
        self.assertIncorrect(self.arg2, "{x=1, y=2, z=3}")
        self.assertIncorrect(self.arg2, "{y=2, z=3}")
        self.assertIncorrect(self.arg1, "{x=1, y=2}")

    def test_posargs_bad(self):
        self.assertIncorrect(self.arg1, "(1,2)")
        self.assertIncorrect(self.arg1, "()")

    def test_posargs_kwargs(self):
        self.assertResult(self.arg2, "{5, y=6}", "x=5, y=6")
        self.assertResult(self.arg2, "{y=6, 5}", "x=5, y=6")
        self.assertResult(self.arg2, "{5, [2]=6}", "x=5, y=6")
        self.assertResult(self.arg2, "{[1]=5, [2]=6}", "x=5, y=6")
        self.assertResult(self.arg2, "{[1]=5, y=6}", "x=5, y=6")

        self.assertResult(self.arg3, "{x=5, y=6, z=8}", "x=5, y=6, z=8")
        self.assertResult(self.arg3, "{5, y=6, z=8}", "x=5, y=6, z=8")
        self.assertResult(self.arg3, "{5, y=6}", "x=5, y=6, z=default")
        self.assertResult(self.arg3, "{5, 6}", "x=5, y=6, z=default")
        self.assertResult(self.arg3, "{5, 6, 7}", "x=5, y=6, z=7")
        self.assertResult(self.arg3, "{z=7, 5, 6}", "x=5, y=6, z=7")

    def test_posargs_kwargs_bad(self):
        self.assertIncorrect(self.arg2, "{5, y=6, z=7}")
        self.assertIncorrect(self.arg2, "{5, [3]=6}", error=IndexError)
        self.assertIncorrect(self.arg2, "{x=5, [2]=6}", error=IndexError)

        self.assertIncorrect(self.arg3, "{5, z=7}")
        self.assertIncorrect(self.arg3, "{5}")

    def test_posargs_nil(self):
        self.assertResult(self.arg3, "(5, nil, 6)", "x=5, y=None, z=6")

    def test_posargs_nil_first(self):
        self.assertResult(self.arg3, "(nil, nil, 6)", "x=None, y=None, z=6")

    def test_posargs_nil_last(self):
        self.assertResult(self.arg3, "(5, nil, nil)", "x=5, y=None, z=None")

    def test_posargs_kwargs_python_none_last(self):
        self.assertResult(self.arg3, "{5, python.none, python.none}", "x=5, y=None, z=None")

    def test_posargs_python_none_last(self):
        self.assertResult(self.arg3, "(5, python.none, python.none)", "x=5, y=None, z=None")

    def test_posargs_kwargs_python_none_some(self):
        self.assertResult(self.arg3, "{python.none, y=python.none, z=6}", "x=None, y=None, z=6")

    def test_posargs_kwargs_python_none_all(self):
        self.assertResult(self.arg3, "{x=python.none, y=python.none}", "x=None, y=None, z=default")

    # -------------------------------------------------------------------------
    # The following examples don't work as a Python programmer would expect
    # them to:

    # def test_posargs_kwargs_nil_last(self):
    #     self.assertResult(self.arg3, "{5, nil, nil}", "x=5, y=None, z=None")
    #
    # def test_posargs_kwargs_nil_some(self):
    #     self.assertResult(self.arg3, "{nil, y=nil, z=6}", "x=None, y=None, z=6")
    #
    # def test_posargs_kwargs_nil_all(self):
    #     self.assertResult(self.arg3, "{x=nil, y=nil}", "x=None, y=None, z=default")

    # -------------------------------------------------------------------------
    # These tests pass in Lua 5.2 but fail in LuaJIT:

    # def test_posargs_kwargs_nil(self):
    #     self.assertResult(self.arg3, "{5, nil, 6}", "x=5, y=None, z=6")
    #
    # def test_posargs_kwargs_nil_first(self):
    #     self.assertResult(self.arg3, "{nil, nil, 6}", "x=None, y=None, z=6")



class MethodKwargsDecoratorTest(KwargsDecoratorTest):

    def __init__(self, *args, **kwargs):
        super(MethodKwargsDecoratorTest, self).__init__(*args, **kwargs)
        self.arg1 = MyCls_1()
        self.arg2 = MyCls_2()
        self.arg3 = MyCls_3()

    def assertResult(self, f, call_txt, res_txt):
        lua_func = self.lua.eval("function (obj) return obj:meth%s end" % call_txt)
        self.assertEqual(lua_func(f), res_txt)

    def assertIncorrect(self, f, call_txt, error=TypeError):
        lua_func = self.lua.eval("function (obj) return obj:meth%s end" % call_txt)
        self.assertRaises(error, lua_func, f)


class NoEncodingKwargsDecoratorTest(KwargsDecoratorTest):
    lua_runtime_kwargs = {'encoding': None}


class NoEncodingMethodKwargsDecoratorTest(MethodKwargsDecoratorTest):
    lua_runtime_kwargs = {'encoding': None}


################################################################################
# tests for the FastRLock implementation

from _thread import start_new_thread, get_ident


def _wait():
    # A crude wait/yield function not relying on synchronization primitives.
    time.sleep(0.01)


class TestFastRLock(LupaTestCase):
    """Copied from CPython's test.lock_tests module
    """
    FastRLock = None

    def setUp(self):
        for filename in os.listdir(os.path.dirname(os.path.dirname(__file__))):
            if filename.startswith('lupa_lua'):
                try:
                    module_name = "lupa." + filename.partition('.')[0]
                    self.FastRLock = __import__(module_name, fromlist='FastRLock', level=0).FastRLock
                except ImportError:
                    pass
        if self.FastRLock is None:
            self.skipTest("No FastRLock implementation found")
        self.locktype = self.FastRLock

    def tearDown(self):
        gc.collect()

    class Bunch:
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

    def DISABLED_test_reacquire_non_recursive(self):
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

    def DISABLED_test_different_thread_release_succeeds(self):
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

    def test_different_thread_release_fails(self):
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


################################################################################
# tests for error stacktrace

class TestErrorStackTrace(LupaTestCase):
    def test_stacktrace(self):
        lua = self.lupa.LuaRuntime()
        try:
            lua.execute("error('abc')")
            raise RuntimeError("LuaError was not raised")
        except self.lupa.LuaError as e:
            exc_message = e.args[0]
            self.assertIn("stack traceback:", exc_message)
            self.assertIn("main chunk", exc_message)
            self.assertIn("error", exc_message)  # function name
            # check for reordered stack trace
            msg_lines = exc_message.splitlines()
            self.assertIn("error", msg_lines[-1])  # function name
            self.assertNotIn("main chunk", msg_lines[-1])
            self.assertIn("main chunk", msg_lines[-2])
            self.assertIn("stack traceback:", msg_lines[-3])

    def test_nil_debug(self):
        lua = self.lupa.LuaRuntime()
        try:
            lua.execute("debug = nil")
            lua.execute("error('abc')")
            raise RuntimeError("LuaError was not raised")
        except self.lupa.LuaError as e:
            self.assertNotIn("stack traceback:", e.args[0])

    def test_nil_debug_traceback(self):
        lua = self.lupa.LuaRuntime()
        try:
            lua.execute("debug = nil")
            lua.execute("error('abc')")
            raise RuntimeError("LuaError was not raised")
        except self.lupa.LuaError as e:
            self.assertNotIn("stack traceback:", e.args[0])


################################################################################
# tests for keyword arguments

class PythonArgumentsInLuaTest(SetupLuaRuntimeMixin, LupaTestCase):

    @staticmethod
    def get_args(*args, **kwargs):
        return args

    @staticmethod
    def get_kwargs(*args, **kwargs):
        return kwargs

    @staticmethod
    def get_none(*args, **kwargs):
        return None

    def assertEqualInLua(self, a, b):
        lua_type_a = self.lupa.lua_type(a)
        lua_type_b = self.lupa.lua_type(b)
        if lua_type_a and lua_type_b and lua_type_a == lua_type_b:
            return self.lua.eval('function(a, b) return a == b end')(a, b)
        return self.assertEqual(a, b)

    def assertResult(self, txt, args, kwargs):
        lua_func = self.lua.eval('function (f) return f(%s) end' % txt)

        # FIXME: lupa._LuaObject.__eq__ might make this function simpler

        obtained_args = lua_func(self.get_args)
        self.assertEqual(len(obtained_args), len(args))
        for a, b in zip(obtained_args, args):
            self.assertEqualInLua(a, b)

        obtained_kwargs = lua_func(self.get_kwargs)
        self.assertEqual(len(obtained_kwargs), len(kwargs))
        for key in kwargs:
            self.assertEqualInLua(obtained_kwargs[key], kwargs[key])

    def assertIncorrect(self, txt, error=TypeError, regex=''):
        lua_func = self.lua.eval('function (f) return f(%s) end' % txt)
        self.assertRaisesRegex(error, regex, lua_func, self.get_none)

    def test_no_table(self):
        self.assertIncorrect('python.args()', error=self.lupa.LuaError)

    def test_no_args(self):
        self.assertResult('python.args{}', (), {})

    def test_all_types(self):
        # Positional arguments
        args = self.lua.eval('''
        {
            42,
            false,
            "spam",
            function() end,
            coroutine.create(function() end),
            {1, 2, 3},
            python.none,
        }
        ''')
        self.lua.globals()['args'] = args
        self.assertResult('python.args(args)', tuple(args[i+1] for i in range(len(args))), {})

        # Keyword arguments
        kwargs = self.lua.table()
        self.lua.globals()['kwargs'] = kwargs
        self.lua.execute('''
            for _, v in ipairs(args) do
                kwargs[type(v)] = v
            end
        ''')
        self.assertResult('python.args(kwargs)', (), dict(kwargs.items()))

        # Invalid parameter to python.args
        for objtype in kwargs:
            if objtype != 'table':
                self.assertIncorrect('python.args(kwargs["%s"])' % objtype,
                        error=self.lupa.LuaError, regex="bad argument #1 to 'args'")

        # Invalid table keys
        self.assertIncorrect('python.args{[0] = true}', error=IndexError, regex='table index out of range')
        self.assertIncorrect('python.args{[2] = true}', error=IndexError, regex='table index out of range')
        self.assertIncorrect('python.args{[3.14] = true}', regex='table key is neither an integer nor a string')
        for objtype in kwargs:
            if objtype not in {'number', 'string'}:
                self.assertIncorrect('python.args{[kwargs["%s"]] = true}' % objtype,
                        regex='table key is neither an integer nor a string')

    def test_kwargs_merge(self):
        self.assertResult('python.args{1, a=1}, python.args{2}, python.args{}, python.args{b=2}', (1, 2), dict(a=1, b=2))

    def test_kwargs_merge_conflict(self):
        self.assertIncorrect('python.args{a=1}, python.args{a=2}', regex='multiple values')


class PythonArgumentsInLuaMethodsTest(PythonArgumentsInLuaTest):

    def get_args(self, *args, **kwargs):
        return args

    def get_kwargs(self, *args, **kwargs):
        return kwargs

    def get_none(self, *args, **kwargs):
        return None

    def test_self_arg(self):
        self.lua.globals()['self'] = self
        self.assertResult('python.args{self}', (), {})
        self.assertResult('python.args{self, 1, a=2}', (1, ), dict(a=2))
        self.assertIncorrect('python.args{self=self}', regex='multiple values')
        self.assertIncorrect('python.args{self, self=self}', regex='multiple values')


################################################################################
# tests for table access error

class TestTableAccessError(SetupLuaRuntimeMixin, LupaTestCase):
    def test_error_index_metamethod(self):
        self.lua.execute('''
        t = {}
        called = 0
        setmetatable(t, {__index = function()
            called = called + 1
            error('my error message')
        end})
        ''')
        lua_t = self.lua.eval('t')
        self.assertRaisesRegex(self.lupa.LuaError, 'my error message', lambda t, k: t[k], lua_t, 'k')
        self.assertEqual(self.lua.eval('called'), 1)


################################################################################
# tests for handling overflow

class TestOverflowMixin(SetupLuaRuntimeMixin):
    def setUp(self):
        super(TestOverflowMixin, self).setUp()

        self.maxinteger = self.lupa.LUA_MAXINTEGER  # maximum value for Lua integer
        self.mininteger = self.lupa.LUA_MININTEGER  # minimum value for Lua integer
        self.biginteger = (self.maxinteger + 1) << 1  # value too big to fit in a Lua integer
        self.maxfloat = sys.float_info.max  # maximum value for Python float
        self.bigfloat = int(self.maxfloat) * 2  # value too big to fit in Python float

        assert self.biginteger <= self.maxfloat, "%d can't be cast to float" % self.biginteger

        self.lua_type = self.lua.eval('type')
        self.lua_math_type = self.lua.eval('math.type')

    def tearDown(self):
        self.lua_type = None
        self.lua_math_type = None
        super(TestOverflowMixin, self).tearDown()

    def test_no_overflow(self):
        self.assertMathType(0, 'integer')
        self.assertMathType(10, 'integer')
        self.assertMathType(-10, 'integer')
        self.assertMathType(self.maxinteger, 'integer')
        self.assertMathType(self.mininteger, 'integer')
        self.assertMathType(0.0, 'float')
        self.assertMathType(-0.0, 'float')
        self.assertMathType(10.0, 'float')
        self.assertMathType(-10.0, 'float')
        self.assertMathType(3.14, 'float')
        self.assertMathType(-3.14, 'float')
        self.assertMathType(self.maxfloat, 'float')
        self.assertMathType(-self.maxfloat, 'float')

    def assertMathType(self, number, math_type):
        self.assertEqual(self.lua_type(number), 'number')
        if self.lua_math_type is not None:
            self.assertEqual(self.lua_math_type(number), math_type)


class TestOverflowWithoutHandler(TestOverflowMixin, LupaTestCase):
    lua_runtime_kwargs = dict(overflow_handler=None)

    def test_overflow(self):
        self.assertRaises(OverflowError, self.assertMathType, self.biginteger, 'integer')
        self.assertRaises(OverflowError, self.assertMathType, int(self.maxfloat), 'integer')
        self.assertRaises(OverflowError, self.assertMathType, self.bigfloat, 'integer')


class TestOverflowWithFloatHandler(TestOverflowMixin, LupaTestCase):
    lua_runtime_kwargs = dict(overflow_handler=float)

    def test_overflow(self):
        self.assertMathType(self.biginteger, 'float')
        self.assertMathType(int(self.maxfloat), 'float')
        self.assertRaises(OverflowError, self.assertMathType, self.bigfloat, 'float')


class TestOverflowWithObjectHandler(TestOverflowMixin, LupaTestCase):
    def test_overflow(self):
        self.lua.execute('python.set_overflow_handler(function(o) return o end)')
        self.assertEqual(self.lua.eval('type')(self.biginteger), 'userdata')


class TestFloatOverflowHandlerInLua(TestOverflowMixin, LupaTestCase):
    def test_overflow(self):
        self.lua.execute('python.set_overflow_handler(python.builtins.float)')
        self.assertMathType(self.biginteger, 'float')
        self.assertMathType(int(self.maxfloat), 'float')
        self.assertRaises(OverflowError, self.assertMathType, self.bigfloat, 'float')


class TestBadOverflowHandlerInPython(LupaTestCase):
    def test_error(self):
        self.assertRaises(ValueError, self.lupa.LuaRuntime, overflow_handler=123)


class TestBadOverflowHandlerInLua(SetupLuaRuntimeMixin, LupaTestCase):
    def _test_set_overflow_handler(self, overflow_handler_code):
        self.assertRaises(self.lupa.LuaError, self.lua.execute, 'python.set_overflow_handler(%s)' % overflow_handler_code)

    def test_number(self):
        self._test_set_overflow_handler('123')

    def test_table(self):
        self._test_set_overflow_handler('{}')

    def test_boolean(self):
        self._test_set_overflow_handler('true')
        self._test_set_overflow_handler('false')

    def test_string(self):
        self._test_set_overflow_handler('"abc"')

    def test_thread(self):
        self._test_set_overflow_handler('coroutine.create(function() end)')


class TestOverflowHandlerOverwrite(TestOverflowMixin, LupaTestCase):
    lua_runtime_kwargs = dict(overflow_handler=float)

    def test_overwrite_in_lua(self):
        self.lua.execute('python.set_overflow_handler(nil)')
        self.assertRaises(OverflowError, self.assertMathType, self.biginteger, 'integer')
        self.assertRaises(OverflowError, self.assertMathType, int(self.maxfloat), 'integer')
        self.assertRaises(OverflowError, self.assertMathType, self.bigfloat, 'integer')
        self.lua.set_overflow_handler(float)
        self.assertMathType(self.biginteger, 'float')
        self.assertMathType(int(self.maxfloat), 'float')
        self.assertRaises(OverflowError, self.assertMathType, self.bigfloat, 'float')

    def test_overwrite_in_python(self):
        self.lua.set_overflow_handler(None)
        self.assertRaises(OverflowError, self.assertMathType, self.biginteger, 'integer')
        self.assertRaises(OverflowError, self.assertMathType, int(self.maxfloat), 'integer')
        self.assertRaises(OverflowError, self.assertMathType, self.bigfloat, 'integer')
        self.lua.execute('python.set_overflow_handler(function(o) return python.builtins.float(o) end)')
        self.assertMathType(self.biginteger, 'float')
        self.assertMathType(int(self.maxfloat), 'float')
        self.assertRaises(OverflowError, self.assertMathType, self.bigfloat, 'float')


################################################################################
# tests for missing reference

class TestMissingReference(SetupLuaRuntimeMixin, LupaTestCase):
    def setUp(self):
        super(TestMissingReference, self).setUp()
        self.testmissingref = self.lua.eval('''
        function(obj, f)
            local t
            if newproxy then
                local p = newproxy(true)
                t = getmetatable(p)
                t.obj = obj
                t.__gc = function(p_) t = getmetatable(p_) end
            else
                t = { obj = obj }
                setmetatable(t, {__gc = function(t_) t = t_ end})
            end
            obj = nil
            t = nil
            collectgarbage()
            assert(t ~= nil)
            assert(t.obj ~= nil)
            local ok, ret = pcall(f, t.obj)
            assert(not ok)
            assert(tostring(ret):find("deleted python object"))
        end
        ''')

    def tearDown(self):
        self.testmissingref = None
        super(TestMissingReference, self).tearDown()

    def test_fallbacks(self):
        class X():
            def __call__(self, *args):
                return None

        def assign(var):
            var = None

        self.testmissingref({}, lambda o: str(o))                            # __tostring
        self.testmissingref({}, lambda o: o[1])                              # __index
        self.testmissingref({}, lambda o: self.lupa.as_itemgetter(o)[1])          # __index (itemgetter)
        self.testmissingref({}, lambda o: self.lupa.as_attrgetter(o).items)       # __index (attrgetter)
        self.testmissingref({}, lambda o: assign(o[1]))                      # __newindex
        self.testmissingref({}, lambda o: assign(self.lupa.as_itemgetter(o)[1]))  # __newindex (itemgetter)
        self.testmissingref(X(), lambda o: assign(self.lupa.as_attrgetter(o).a))  # __newindex (attrgetter)
        self.testmissingref(X(), lambda o: o())                              # __call

    def test_functions(self):
        self.testmissingref({}, print)              # reflection
        self.testmissingref({}, iter)               # iteration
        self.testmissingref({}, enumerate)          # enumerate
        self.testmissingref({}, self.lupa.as_itemgetter) # item getter protocol
        self.testmissingref({}, self.lupa.as_attrgetter) # attribute getter protocol


################################################################################
# test Lua object __str__ method

class TestLuaObjectString(SetupLuaRuntimeMixin, LupaTestCase):
    def test_normal_string(self):
        self.assertIn('Lua table', str(self.lua.eval('{}')))
        self.assertIn('Lua function', str(self.lua.eval('print')))
        self.assertIn('Lua thread', str(self.lua.execute('local t = coroutine.create(function() end); coroutine.resume(t); return t')))

    def test_bad_tostring(self):
        self.assertRaisesRegex(TypeError, '__tostring returned non-string object',
                str, self.lua.eval('setmetatable({}, {__tostring = function() end})'))

    def test_tostring_err(self):
        self.assertRaises(self.lupa.LuaError, str, self.lua.eval('setmetatable({}, {__tostring = function() error() end})'))


################################################################################
# test LuaRuntime max_memory

class TestMaxMemory(SetupLuaRuntimeMixin, LupaTestCase):
    lua_runtime_kwargs = {"max_memory": 10000}

    def setUp(self):
        # need to test in here because the creation of the LuaRuntime fails
        if "luajit" in self.lupa.LuaRuntime().lua_implementation.lower():
            return self.skipTest("not supported in LuaJIT")
        return super(TestMaxMemory, self).setUp()

    def test_getters(self):
        self.assertEqual(self.lua.get_memory_used(), 0)
        self.assertGreater(self.lua.get_memory_used(total=True), 0)
        self.assertEqual(self.lua.get_max_memory(), 10000)
        self.assertGreater(self.lua.get_max_memory(total=True), 10000)
        self.lua.set_max_memory(1000000)
        self.assertEqual(self.lua.get_memory_used(), 0)
        self.assertGreater(self.lua.get_memory_used(total=True), 0)
        self.assertEqual(self.lua.get_max_memory(), 1000000)
        self.assertGreater(self.lua.get_max_memory(total=True), 1000000)
        self.lua.set_max_memory(1000000, total=True)
        self.assertEqual(self.lua.get_max_memory(total=True), 1000000)
        self.assertLess(self.lua.get_max_memory(), 1000000)

    def test_not_enough_memory(self):
        self.lua.eval("('a'):rep(50)")
        self.assertRaises(self.lupa.LuaMemoryError, self.lua.eval, "('a'):rep(50000)")

    def test_decrease_memory(self):
        self.lua.set_max_memory(1000000)
        self.lua.execute("a = ('a'):rep(50000)")
        self.lua.set_max_memory(10000)
        self.assertEqual(self.lua.get_max_memory(), 10000)
        self.assertGreaterEqual(self.lua.get_memory_used(), 50000)
        self.assertRaises(self.lupa.LuaMemoryError, self.lua.eval, "('b'):rep(10)")
        del self.lua.globals()["a"]
        if self.lua.lua_version >= (5, 2):
            # Lua 5.1 doesn't free the memory of `a` after deleting it
            self.lua.eval("('b'):rep(10)")

    def test_compile_not_enough_memory(self):
        self.lua.set_max_memory(10)
        self.assertRaises(self.lupa.LuaMemoryError, self.lua.compile, "_G.a = function() return 'test abcdef' end")

    def test_unlimited_memory(self):
        self.lua.set_max_memory(0)
        self.lua.execute("a = ('a'):rep(50000)")


class TestMaxMemoryWithoutSettingIt(SetupLuaRuntimeMixin, LupaTestCase):
    def test_property(self):
        self.assertEqual(self.lua.get_max_memory(), None)

    def test_set_max(self):
        self.assertRaises(RuntimeError, self.lua.set_max_memory, 10000)


################################################################################
# Load tests for different Lua version modules

def load_tests(loader, standard_tests, pattern):
    return lupa.tests.build_suite_for_modules(loader, globals())



if __name__ == '__main__':
    def print_version():
        version = lupa.LuaRuntime().lua_implementation
        print('Running Lupa %s tests against %s.' % (lupa.__version__, version))

    print_version()
    unittest.main()
