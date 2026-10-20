/* The Python C API as the extension module sees it: the limited API of
 * Python 3.10 (abi3), so one build works with every later version. */
#define Py_LIMITED_API 0x030A0000
#define PY_SSIZE_T_CLEAN
#include <Python.h>
