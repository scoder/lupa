
import unittest
import lupy

class TestLuaRuntime(unittest.TestCase):

    def setUp(self):
        self.lua = lupy.LuaRuntime()
    
    def test_eval(self):
        self.assertEqual(2, self.lua.eval('1+1'))

    def test_run(self):
        self.assertEqual(2, self.lua.run('return 1+1'))

    def test_function(self):
        function = self.lua.eval('function() return 1+1 end')
        self.assertNotEqual(None, function)
        self.assertEqual(2, function())


if __name__ == '__main__':
    import unittest
    unittest.main()
