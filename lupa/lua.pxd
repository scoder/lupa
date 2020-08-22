
cdef extern from *:
    ctypedef struct va_list

cdef extern from *: # "luaconf.h"
    # Various tunables.
    enum:
        LUAI_MAXSTACK   # 65500	/* Max. # of stack slots for a thread (<64K). */
        LUAI_MAXCSTACK  # 8000	/* Max. # of stack slots for a C func (<10K). */
        LUAI_GCPAUSE    # 200	/* Pause GC until memory is at 200%. */
        LUAI_GCMUL      # 200	/* Run GC at 200% of allocation speed. */
        LUA_MAXCAPTURES # 32	/* Max. pattern captures. */

        LUA_IDSIZE      # 60     /* Size of lua_Debug.short_src. */
        LUAL_BUFFERSIZE # BUFSIZ /* Size of lauxlib and io.* buffers. */

################################################################################
# lua.h
################################################################################

cdef extern from "lua.h" nogil:
    char* LUA_VERSION
    char* LUA_RELEASE
    int LUA_VERSION_NUM
    char* LUA_COPYRIGHT
    char* LUA_AUTHORS

    char* LUA_SIGNATURE
    int LUA_MULTRET

    int LUA_REGISTRYINDEX
    int LUA_ENVIRONINDEX
    int LUA_GLOBALSINDEX
    int lua_upvalueindex(int i)

    enum:
        # thread status; 0 is OK
        LUA_YIELD      # 1
        LUA_ERRRUN     # 2
        LUA_ERRSYNTAX  # 3
        LUA_ERRMEM     # 4
        LUA_ERRERR     # 5

    ctypedef struct lua_State

    ctypedef int (*lua_CFunction) (lua_State *L)

    ctypedef char * (*lua_Reader) (lua_State *L, void *ud, size_t *sz)

    ctypedef int (*lua_Writer) (lua_State *L, void* p, size_t sz, void* ud)

    ctypedef void * (*lua_Alloc) (void *ud, void *ptr, size_t osize, size_t nsize)

    enum:
        LUA_TNONE             # -1

        LUA_TNIL              # 0
        LUA_TBOOLEAN          # 1
        LUA_TLIGHTUSERDATA    # 2
        LUA_TNUMBER           # 3
        LUA_TSTRING           # 4
        LUA_TTABLE            # 5
        LUA_TFUNCTION         # 6
        LUA_TUSERDATA         # 7
        LUA_TTHREAD           # 8

    int LUA_MINSTACK  # minimum Lua stack available to a C function

    ctypedef float lua_Number  # type of numbers in Lua
    ctypedef int lua_Integer   # type for integer functions

    lua_State *lua_newstate (lua_Alloc f, void *ud)
    void       lua_close (lua_State *L)
    lua_State *lua_newthread (lua_State *L)
    const lua_Number *lua_version(lua_State *L)

    lua_CFunction lua_atpanic (lua_State *L, lua_CFunction panicf)

    # basic stack manipulation
    int   lua_gettop (lua_State *L)
    void  lua_settop (lua_State *L, int idx)
    void  lua_pushvalue (lua_State *L, int idx)
    void  lua_remove (lua_State *L, int idx)
    void  lua_insert (lua_State *L, int idx)
    void  lua_replace (lua_State *L, int idx)
    int   lua_checkstack (lua_State *L, int sz)

    void  lua_xmove (lua_State *_from, lua_State *to, int n)

    # access functions (stack -> C)
    int             lua_isnumber (lua_State *L, int idx)
    int             lua_isstring (lua_State *L, int idx)
    int             lua_iscfunction (lua_State *L, int idx)
    int             lua_isuserdata (lua_State *L, int idx)
    int             lua_type (lua_State *L, int idx)
    char           *lua_typename (lua_State *L, int tp)

    int             lua_equal (lua_State *L, int idx1, int idx2)
    int             lua_rawequal (lua_State *L, int idx1, int idx2)
    int             lua_lessthan (lua_State *L, int idx1, int idx2)

    lua_Number      lua_tonumber (lua_State *L, int idx)
    lua_Integer     lua_tointeger (lua_State *L, int idx)
    bint            lua_toboolean (lua_State *L, int idx)
    char           *lua_tolstring (lua_State *L, int idx, size_t *len)
    size_t          lua_objlen (lua_State *L, int idx)
    lua_CFunction   lua_tocfunction (lua_State *L, int idx)
    void           *lua_touserdata (lua_State *L, int idx)
    lua_State      *lua_tothread (lua_State *L, int idx)
    void           *lua_topointer (lua_State *L, int idx)

    # push functions (C -> stack)
    void  lua_pushnil (lua_State *L)
    void  lua_pushnumber (lua_State *L, lua_Number n)
    void  lua_pushinteger (lua_State *L, lua_Integer n)
    void  lua_pushlstring (lua_State *L, char *s, size_t l)
    void  lua_pushstring (lua_State *L, char *s)
    char *lua_pushvfstring (lua_State *L, char *fmt, va_list argp)
    char *lua_pushfstring (lua_State *L, char *fmt, ...)
    void  lua_pushcclosure (lua_State *L, lua_CFunction fn, int n)
    void  lua_pushboolean (lua_State *L, bint b)
    void  lua_pushlightuserdata (lua_State *L, void *p)
    int   lua_pushthread (lua_State *L)

    # get functions (Lua -> stack)
    void  lua_gettable (lua_State *L, int idx)
    void  lua_getfield (lua_State *L, int idx, char *k)
    void  lua_rawget (lua_State *L, int idx)
    void  lua_rawgeti (lua_State *L, int idx, int n)
    void  lua_createtable (lua_State *L, int narr, int nrec)
    void *lua_newuserdata (lua_State *L, size_t sz)
    int   lua_getmetatable (lua_State *L, int objindex)
    void  lua_getfenv (lua_State *L, int idx)

    # set functions (stack -> Lua)
    void  lua_settable (lua_State *L, int idx)
    void  lua_setfield (lua_State *L, int idx, char *k)
    void  lua_rawset (lua_State *L, int idx)
    void  lua_rawseti (lua_State *L, int idx, int n)
    int   lua_setmetatable (lua_State *L, int objindex)
    int   lua_setfenv (lua_State *L, int idx)

    # `load' and `call' functions (load and run Lua code)
    void  lua_call (lua_State *L, int nargs, int nresults)
    int   lua_pcall (lua_State *L, int nargs, int nresults, int errfunc)
    int   lua_cpcall (lua_State *L, lua_CFunction func, void *ud)
    int   lua_load (lua_State *L, lua_Reader reader, void *dt,
                                       char *chunkname)

    int   lua_dump (lua_State *L, lua_Writer writer, void *data)

    # coroutine functions
    int  lua_yield (lua_State *L, int nresults)
    int  lua_resume "__lupa_lua_resume" (lua_State *L, lua_State *from_, int narg, int *nresults)
    int  lua_status (lua_State *L)

    # garbage-collection function and options
    enum:
        LUA_GCSTOP           # 0
        LUA_GCRESTART        # 1
        LUA_GCCOLLECT        # 2
        LUA_GCCOUNT          # 3
        LUA_GCCOUNTB         # 4
        LUA_GCSTEP           # 5
        LUA_GCSETPAUSE       # 6
        LUA_GCSETSTEPMUL     # 7

    int lua_gc (lua_State *L, int what, int data)

    # miscellaneous functions
    int   lua_error (lua_State *L)
    int   lua_next (lua_State *L, int idx)
    void  lua_concat (lua_State *L, int n)
    lua_Alloc lua_getallocf (lua_State *L, void **ud)
    void lua_setallocf (lua_State *L, lua_Alloc f, void *ud)

    # ===============================================================
    # some useful macros
    # ===============================================================

    void lua_pop(lua_State *L, int n)    # lua_settop(L, -(n)-1)
    void lua_newtable(lua_State *L)      # lua_createtable(L, 0, 0)
    void  lua_register(lua_State *L, char* n, lua_CFunction f) # (lua_pushcfunction(L, (f)), lua_setglobal(L, (n)))
    void lua_pushcfunction(lua_State *L, lua_CFunction fn) # lua_pushcclosure(L, (f), 0)
    size_t lua_strlen(lua_State *L, int i) # lua_objlen(L, (i))

    bint lua_isfunction(lua_State *L, int n)      # (lua_type(L, (n)) == LUA_TFUNCTION)
    bint lua_istable(lua_State *L, int n)         # (lua_type(L, (n)) == LUA_TTABLE)
    bint lua_islightuserdata(lua_State *L, int n) # (lua_type(L, (n)) == LUA_TLIGHTUSERDATA)
    bint lua_isnil(lua_State *L, int n)           # (lua_type(L, (n)) == LUA_TNIL)
    bint lua_isboolean(lua_State *L, int n)       # (lua_type(L, (n)) == LUA_TBOOLEAN)
    bint lua_isthread(lua_State *L, int n)        # (lua_type(L, (n)) == LUA_TTHREAD)
    bint lua_isnone(lua_State *L,int n)           # (lua_type(L, (n)) == LUA_TNONE)
    bint lua_isnoneornil(lua_State *L, int n)     # (lua_type(L, (n)) <= 0)

    void lua_pushliteral(lua_State *L, char* s)   # lua_pushlstring(L, "" s, (sizeof(s)/sizeof(char))-1)

    void lua_setglobal(lua_State *L, char* s)     # lua_setfield(L, LUA_GLOBALSINDEX, (s))
    void lua_getglobal(lua_State *L, char* s)     # lua_getfield(L, LUA_GLOBALSINDEX, (s))

    char* lua_tostring(lua_State *L, int i)       # lua_tolstring(L, (i), NULL)


    # compatibility macros and functions
    lua_State* luaL_newstate()
    void lua_getregistry(lua_State *L) # lua_pushvalue(L, LUA_REGISTRYINDEX)
    int lua_getgccount(lua_State *L)

    # define lua_Chunkreader		lua_Reader
    # define lua_Chunkwriter		lua_Writer

    # hack
    void lua_setlevel(lua_State *_from, lua_State *to)


    # =======================================================================
    # Debug API
    # =======================================================================

    # Event codes
    enum:
        LUA_HOOKCALL    # 0
        LUA_HOOKRET     # 1
        LUA_HOOKLINE    # 2
        LUA_HOOKCOUNT   # 3
        LUA_HOOKTAILRET # 4


    # Event masks
    enum:
        LUA_MASKCALL    # (1 << LUA_HOOKCALL)
        LUA_MASKRET     # (1 << LUA_HOOKRET)
        LUA_MASKLINE    # (1 << LUA_HOOKLINE)
        LUA_MASKCOUNT   # (1 << LUA_HOOKCOUNT)

    ctypedef struct lua_Debug  # activation record


    # Functions to be called by the debuger in specific events
    ctypedef void (*lua_Hook) (lua_State *L, lua_Debug *ar)

    int lua_getstack (lua_State *L, int level, lua_Debug *ar)
    int lua_getinfo (lua_State *L, char *what, lua_Debug *ar)
    char *lua_getlocal (lua_State *L, lua_Debug *ar, int n)
    char *lua_setlocal (lua_State *L, lua_Debug *ar, int n)
    char *lua_getupvalue (lua_State *L, int funcindex, int n)
    char *lua_setupvalue (lua_State *L, int funcindex, int n)

    int lua_sethook (lua_State *L, lua_Hook func, int mask, int count)
    lua_Hook lua_gethook (lua_State *L)
    int lua_gethookmask (lua_State *L)
    int lua_gethookcount (lua_State *L)

    ctypedef struct lua_Debug:
        int event
        char *name #         (n) */
        char *namewhat #         (n) `global', `local', `field', `method' */
        char *what #         (S) `Lua', `C', `main', `tail' */
        char *source #         (S) */
        int currentline #         (l) */
        int nups #         (u) number of upvalues */
        int linedefined #         (S) */
        int lastlinedefined #         (S) */
        char short_src[LUA_IDSIZE] #          (S) */
        # private part
        int i_ci               #           active function */


################################################################################
# lauxlib.h
################################################################################

cdef extern from "lauxlib.h" nogil:
    size_t luaL_getn(lua_State *L, int i)       #      ((int)lua_objlen(L, i))
    #void luaL_setn(lua_State *L, int i, int j)  #      ((void)0)  /* no op! */

    # extra error code for `luaL_load'
    enum:
        LUA_ERRFILE #     (LUA_ERRERR+1)

    ctypedef struct luaL_Reg:
        char *name
        lua_CFunction func

    void luaL_register (lua_State *L, char *libname, luaL_Reg *l)
    void luaL_setfuncs (lua_State *L, luaL_Reg *l, int nup)  # 5.2+
    int luaL_getmetafield (lua_State *L, int obj, char *e)
    int luaL_callmeta (lua_State *L, int obj, char *e)
    int luaL_typerror (lua_State *L, int narg, char *tname)
    int luaL_argerror (lua_State *L, int numarg, char *extramsg)
    char *luaL_checklstring (lua_State *L, int numArg, size_t *l)
    char *luaL_optlstring (lua_State *L, int numArg, char *default, size_t *l)
    lua_Number luaL_checknumber (lua_State *L, int numArg)
    lua_Number luaL_optnumber (lua_State *L, int nArg, lua_Number default)

    lua_Integer luaL_checkinteger (lua_State *L, int numArg)
    lua_Integer luaL_optinteger (lua_State *L, int nArg, lua_Integer default)

    void luaL_checkstack (lua_State *L, int sz, char *msg)
    void luaL_checktype (lua_State *L, int narg, int t)
    void luaL_checkany (lua_State *L, int narg)

    int   luaL_newmetatable (lua_State *L, char *tname)
    void *luaL_checkudata (lua_State *L, int ud, char *tname)

    void luaL_where (lua_State *L, int lvl)
    int luaL_error (lua_State *L, char *fmt, ...)

    int luaL_checkoption (lua_State *L, int narg, char *default, char *lst[])

    int luaL_ref (lua_State *L, int t)
    void luaL_unref (lua_State *L, int t, int ref)

    int luaL_loadfile (lua_State *L, char *filename)
    int luaL_loadbuffer (lua_State *L, char *buff, size_t sz, char *name)
    int luaL_loadstring (lua_State *L, char *s)

    lua_State *luaL_newstate ()


    char *luaL_gsub (lua_State *L, char *s, char *p, char *r)


    # ===============================================================
    # some useful macros
    # ===============================================================

    int luaL_argcheck(lua_State *L, bint cond, int numarg, char *extramsg)  # ((void)((cond) || luaL_argerror(L, (numarg), (extramsg))))
    char* luaL_checkstring(lua_State *L, int n)         # (luaL_checklstring(L, (n), NULL))
    char* luaL_optstring(lua_State *L, int n, char* d)  # (luaL_optlstring(L, (n), (d), NULL))
    int luaL_checkint(lua_State *L, int n)              # ((int)luaL_checkinteger(L, (n)))
    int luaL_optint(lua_State *L, int n, lua_Integer d) # ((int)luaL_optinteger(L, (n), (d)))
    long luaL_checklong(lua_State *L, int n)            # ((long)luaL_checkinteger(L, (n)))
    long luaL_optlong(lua_State *L, int n, lua_Integer d) # ((long)luaL_optinteger(L, (n), (d)))
    char* luaL_typename (lua_State *L, int i)           # lua_typename(L, lua_type(L,(i)))
    int luaL_dofile(lua_State *L, char* fn)             # (luaL_loadfile(L, fn) || lua_pcall(L, 0, LUA_MULTRET, 0))
    int luaL_dostring(lua_State *L, char* s)            # (luaL_loadstring(L, s) || lua_pcall(L, 0, LUA_MULTRET, 0))

    void luaL_getmetatable(lua_State *L, char* n)       # (lua_getfield(L, LUA_REGISTRYINDEX, (n)))

    #define luaL_opt(L,f,n,d)	(lua_isnoneornil(L,(n)) ? (d) : f(L,(n)))


    # =======================================================
    # Generic Buffer manipulation
    # =======================================================

'''
typedef struct luaL_Buffer {
  char *p;			/* current position in buffer */
  int lvl;  /* number of strings in the stack (level) */
  lua_State *L;
  char buffer[LUAL_BUFFERSIZE];
} luaL_Buffer;

#define luaL_addchar(B,c) \
  ((void)((B)->p < ((B)->buffer+LUAL_BUFFERSIZE) || luaL_prepbuffer(B)), \
   (*(B)->p++ = (char)(c)))

/* compatibility only */
#define luaL_putchar(B,c)	luaL_addchar(B,c)

#define luaL_addsize(B,n)	((B)->p += (n))

    void (luaL_buffinit) (lua_State *L, luaL_Buffer *B);
    char *(luaL_prepbuffer) (luaL_Buffer *B);
    void (luaL_addlstring) (luaL_Buffer *B, const char *s, size_t l);
    void (luaL_addstring) (luaL_Buffer *B, const char *s);
    void (luaL_addvalue) (luaL_Buffer *B);
    void (luaL_pushresult) (luaL_Buffer *B);


/* }====================================================== */


/* compatibility with ref system */

/* pre-defined references */
#define LUA_NOREF       (-2)
#define LUA_REFNIL      (-1)

#define lua_ref(L,lock) ((lock) ? luaL_ref(L, LUA_REGISTRYINDEX) : \
      (lua_pushstring(L, "unlocked references are obsolete"), lua_error(L), 0))

#define lua_unref(L,ref)        luaL_unref(L, LUA_REGISTRYINDEX, (ref))

#define lua_getref(L,ref)       lua_rawgeti(L, LUA_REGISTRYINDEX, (ref))


#define luaL_reg	luaL_Reg

#endif
'''

cdef extern from "lualib.h":
    char* LUA_COLIBNAME   # "coroutine"
    char* LUA_MATHLIBNAME # "math"
    char* LUA_STRLIBNAME  # "string"
    char* LUA_TABLIBNAME  # "table"
    char* LUA_IOLIBNAME   # "io"
    char* LUA_OSLIBNAME   # "os"
    char* LUA_LOADLIBNAME # "package"
    char* LUA_DBLIBNAME   # "debug"
    char* LUA_BITLIBNAME  # "bit"
    char* LUA_JITLIBNAME  # "jit"

    int luaopen_base(lua_State *L)
    int luaopen_math(lua_State *L)
    int luaopen_string(lua_State *L)
    int luaopen_table(lua_State *L)
    int luaopen_io(lua_State *L)
    int luaopen_os(lua_State *L)
    int luaopen_package(lua_State *L)
    int luaopen_debug(lua_State *L)
    int luaopen_bit(lua_State *L)
    int luaopen_jit(lua_State *L)

    void luaL_openlibs(lua_State *L)


cdef extern from *:
    # Compatibility definitions for Lupa.
    """
    #if LUA_VERSION_NUM >= 504
    #define __lupa_lua_resume lua_resume
    #else
    LUA_API int __lupa_lua_resume (lua_State *L, lua_State *from, int nargs, int* nresults) {
    #if LUA_VERSION_NUM >= 502
        int status = lua_resume(L, from, nargs);
    #else
        int status = lua_resume(L, nargs);
    #endif
        *nresults = lua_gettop(L);
        return status;
    }
    #endif

    #if LUA_VERSION_NUM >= 502
    #define lua_objlen(L, i) lua_rawlen(L, (i))
    #endif

    #if LUA_VERSION_NUM >= 504
    #define read_lua_version(L)  ((int) lua_version(L))
    #elif LUA_VERSION_NUM >= 502
    #define read_lua_version(L)  ((int) *lua_version(L))
    #elif LUA_VERSION_NUM >= 501
    #define read_lua_version(L)  ((int) LUA_VERSION_NUM)
    #else
    #error Lupa requires at least Lua 5.1 or LuaJIT 2.x
    #endif
    """
    int read_lua_version(lua_State *L)
