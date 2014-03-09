import unittest
import doctest
import os

import lupa


def suite():
    test_dir = os.path.abspath(os.path.dirname(__file__))

    tests = []
    for filename in os.listdir(test_dir):
        if filename.endswith('.py') and not filename.startswith('_'):
            tests.append('lupa.tests.'  + filename[:-3])

    suite = unittest.defaultTestLoader.loadTestsFromNames(tests)
    suite.addTest(doctest.DocTestSuite(lupa._lupa))
    suite.addTest(doctest.DocFileSuite('../../README.rst'))
    return suite


if __name__ == '__main__':
    unittest.TextTestRunner(verbosity=2).run(suite())
