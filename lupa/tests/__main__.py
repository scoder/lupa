if __name__ == '__main__':
    import sys
    import unittest
    from . import suite
    sys.exit(1 if unittest.TextTestRunner(verbosity=2).run(suite()).failures else 0)
