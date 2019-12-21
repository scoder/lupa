from __future__ import absolute_import


# We need to enable global symbol visibility for lupa in order to
# support binary module loading in Lua.  If we can enable it here, we
# do it temporarily.

def _try_import_with_global_library_symbols():
    try:
        from os import RTLD_NOW, RTLD_GLOBAL
    except ImportError:
        from DLFCN import RTLD_NOW, RTLD_GLOBAL  # Py2.7
    dlopen_flags = RTLD_NOW | RTLD_GLOBAL

    import sys
    old_flags = sys.getdlopenflags()
    try:
        sys.setdlopenflags(dlopen_flags)
        import lupa._lupa
    finally:
        sys.setdlopenflags(old_flags)

try:
    _try_import_with_global_library_symbols()
except:
    pass

del _try_import_with_global_library_symbols

# the following is all that should stay in the namespace:

from lupa._lupa import *

try:
    from lupa.version import __version__
except ImportError:
    pass
