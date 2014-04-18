/*
 * Compatibility definitions for Lupa.
 */

#if LUA_VERSION_NUM >= 502
#define __lupa_lua_resume(L, nargs)   lua_resume(L, NULL, nargs)
#define lua_objlen(L, i)              lua_rawlen(L, (i))

#else
#if LUA_VERSION_NUM >= 501
#define __lupa_lua_resume(L, nargs)   lua_resume(L, nargs)

#else
#error Lupa requires at least Lua 5.1 or LuaJIT 2.x
#endif
#endif
