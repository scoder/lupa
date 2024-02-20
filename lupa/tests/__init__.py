from __future__ import absolute_import

import unittest
import doctest
import os
import os.path as os_path
import sys

import lupa


class LupaTestCase(unittest.TestCase):
    """
    Subclasses can use 'self.lupa' to get the test module, which build_suite_for_module() below will vary.
    """
    lupa = lupa

    if sys.version_info < (3, 4):
        from contextlib import contextmanager

        @contextmanager
        def subTest(self, message=None, **parameters):
            """Dummy implementation"""
            yield


def find_lua_modules():
    modules = [lupa]
    imported = set()
    for filename in os.listdir(os.path.dirname(os.path.dirname(__file__))):
        if not filename.startswith('lua'):
            continue
        module_name = "lupa." + filename.partition('.')[0]
        if module_name in imported:
            continue
        try:
            module = __import__(module_name, fromlist='*', level=0)
        except ImportError:
            pass
        else:
            imported.add(module_name)
            modules.append(module)

    return modules


def build_suite_for_modules(loader, test_module_globals):
    suite = unittest.TestSuite()
    all_lua_modules = find_lua_modules()

    for module in all_lua_modules[1:]:
        suite.addTests(doctest.DocTestSuite(module))

    def add_tests(cls):
        tests = loader.loadTestsFromTestCase(cls)
        suite.addTests(tests)

    for name, test_class in test_module_globals.items():
        if (not isinstance(test_class, type) or
                not name.startswith('Test') or
                not issubclass(test_class, unittest.TestCase)):
            continue

        if issubclass(test_class, LupaTestCase):
            prefix = test_class.__name__ + "_"
            qprefix = getattr(test_class, '__qualname__', test_class.__name__) + "_"

            for module in all_lua_modules:
                class TestClass(test_class):
                    lupa = module

                module_name = module.__name__.rpartition('.')[2]
                TestClass.__name__ = prefix + module_name
                TestClass.__qualname__ = qprefix + module_name
                add_tests(TestClass)
        else:
            add_tests(test_class)

    return suite


def suite():
    test_dir = os.path.abspath(os.path.dirname(__file__))

    tests = []
    for filename in os.listdir(test_dir):
        if filename.endswith('.py') and not filename.startswith('_'):
            tests.append('lupa.tests.'  + filename[:-3])

    suite = unittest.defaultTestLoader.loadTestsFromNames(tests)

    # Long version of
    # suite.addTest(doctest.DocFileSuite('../../README.rst'))
    # to remove some platform specific tests.
    readme_filename = 'README.rst'
    readme_file = os_path.join(os_path.dirname(__file__), '..', '..', readme_filename)
    with open(readme_file) as f:
        readme = f.read()
    if sys.platform != 'linux2':
        # Exclude last section, which is Linux specific.
        readme = readme.split('Importing Lua binary modules\n----------------------------\n', 1)[0]

    parser = doctest.DocTestParser()
    test = parser.get_doctest(readme, {'__file__': readme_file}, 'README.rst', readme_file, 0)
    suite.addTest(doctest.DocFileCase(test))

    return suite


if __name__ == '__main__':
    unittest.TextTestRunner(verbosity=2).run(suite())
