# Khronos GL headers

Unmodified copies, so MSVC builds (whose SDK has no `GL/glext.h`) see the same
GL types and enums as MinGW and Linux. Used by `host/render` (slang chain).

| File | Upstream | Commit | License |
| --- | --- | --- | --- |
| `GL/glext.h` | KhronosGroup/OpenGL-Registry `api/GL/glext.h` | 6af574a14089ccfee87efe230ebcdd8742859813 | MIT |
| `KHR/khrplatform.h` | KhronosGroup/EGL-Registry `api/KHR/khrplatform.h` | db3425b8246136faccb5e2782b5694960bd6edf1 | MIT (Khronos) |
