from __future__ import absolute_import

import unittest
import doctest
import os
import os.path as os_path
import sys

import lupa


def suite():
    test_dir = os.path.abspath(os.path.dirname(__file__))

    tests = []
    for filename in os.listdir(test_dir):
        if filename.endswith('.py') and not filename.startswith('_'):
            tests.append('lupa.tests.'  + filename[:-3])

    suite = unittest.defaultTestLoader.loadTestsFromNames(tests)
    suite.addTest(doctest.DocTestSuite(lupa._lupa))

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
