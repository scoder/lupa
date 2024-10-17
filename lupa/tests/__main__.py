if __name__ == '__main__':
    import unittest
    from . import suite
    unittest.TextTestRunner(verbosity=2).run(suite())
