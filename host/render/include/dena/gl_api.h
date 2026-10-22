// Desktop GL entry points for the slang chain, loaded at run time through a
// proc_address callback (WGL or EGL), so nothing links against a GL library.
// Spec: docs/specs/shader-stacks.md
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#endif
#include <GL/gl.h>
#include <GL/glext.h>

#ifndef APIENTRY
#define APIENTRY
#endif

namespace dena {
namespace slang {

using ProcAddress = void *(*)(const char *name);

#define DENA_SLANG_GL(X)                                                                  \
  X(const GLubyte *, GetString, (GLenum))                                                 \
  X(GLenum, GetError, (void))                                                             \
  X(void, GetIntegerv, (GLenum, GLint *))                                                 \
  X(void, GetIntegeri_v, (GLenum, GLuint, GLint *))                                       \
  X(GLboolean, IsEnabled, (GLenum))                                                       \
  X(void, Enable, (GLenum))                                                               \
  X(void, Disable, (GLenum))                                                              \
  X(void, Viewport, (GLint, GLint, GLsizei, GLsizei))                                     \
  X(void, ColorMask, (GLboolean, GLboolean, GLboolean, GLboolean))                        \
  X(void, GetBooleanv, (GLenum, GLboolean *))                                             \
  X(void, GetFloatv, (GLenum, GLfloat *))                                                 \
  X(void, ClearColor, (GLfloat, GLfloat, GLfloat, GLfloat))                               \
  X(void, Clear, (GLbitfield))                                                            \
  X(void, Flush, (void))                                                                  \
  X(void, Finish, (void))                                                                 \
  X(GLuint, CreateShader, (GLenum))                                                       \
  X(void, ShaderSource, (GLuint, GLsizei, const GLchar *const *, const GLint *))          \
  X(void, CompileShader, (GLuint))                                                        \
  X(void, GetShaderiv, (GLuint, GLenum, GLint *))                                         \
  X(void, GetShaderInfoLog, (GLuint, GLsizei, GLsizei *, GLchar *))                       \
  X(void, DeleteShader, (GLuint))                                                         \
  X(GLuint, CreateProgram, (void))                                                        \
  X(void, AttachShader, (GLuint, GLuint))                                                 \
  X(void, LinkProgram, (GLuint))                                                          \
  X(void, GetProgramiv, (GLuint, GLenum, GLint *))                                        \
  X(void, GetProgramInfoLog, (GLuint, GLsizei, GLsizei *, GLchar *))                      \
  X(void, DeleteProgram, (GLuint))                                                        \
  X(void, UseProgram, (GLuint))                                                           \
  X(void, GetActiveUniform, (GLuint, GLuint, GLsizei, GLsizei *, GLint *, GLenum *, GLchar *)) \
  X(GLint, GetUniformLocation, (GLuint, const GLchar *))                                  \
  X(void, Uniform1i, (GLint, GLint))                                                      \
  X(void, GetActiveUniformsiv, (GLuint, GLsizei, const GLuint *, GLenum, GLint *))        \
  X(void, GetActiveUniformBlockiv, (GLuint, GLuint, GLenum, GLint *))                     \
  X(void, GetActiveUniformBlockName, (GLuint, GLuint, GLsizei, GLsizei *, GLchar *))      \
  X(void, UniformBlockBinding, (GLuint, GLuint, GLuint))                                  \
  X(void, GenBuffers, (GLsizei, GLuint *))                                                \
  X(void, DeleteBuffers, (GLsizei, const GLuint *))                                       \
  X(void, BindBuffer, (GLenum, GLuint))                                                   \
  X(void, BindBufferBase, (GLenum, GLuint, GLuint))                                       \
  X(void, BindBufferRange, (GLenum, GLuint, GLuint, GLintptr, GLsizeiptr))                \
  X(void, BufferData, (GLenum, GLsizeiptr, const void *, GLenum))                         \
  X(void, BufferSubData, (GLenum, GLintptr, GLsizeiptr, const void *))                    \
  X(void, GenVertexArrays, (GLsizei, GLuint *))                                           \
  X(void, DeleteVertexArrays, (GLsizei, const GLuint *))                                  \
  X(void, BindVertexArray, (GLuint))                                                      \
  X(void, VertexAttribPointer, (GLuint, GLint, GLenum, GLboolean, GLsizei, const void *)) \
  X(void, EnableVertexAttribArray, (GLuint))                                              \
  X(void, DrawArrays, (GLenum, GLint, GLsizei))                                           \
  X(void, GenTextures, (GLsizei, GLuint *))                                               \
  X(void, DeleteTextures, (GLsizei, const GLuint *))                                      \
  X(void, BindTexture, (GLenum, GLuint))                                                  \
  X(void, ActiveTexture, (GLenum))                                                        \
  X(void, TexStorage2D, (GLenum, GLsizei, GLenum, GLsizei, GLsizei))                      \
  X(void, TexSubImage2D,                                                                  \
    (GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, const void *))        \
  X(void, TexParameteri, (GLenum, GLenum, GLint))                                         \
  X(void, GenerateMipmap, (GLenum))                                                       \
  X(void, PixelStorei, (GLenum, GLint))                                                   \
  X(void, GenSamplers, (GLsizei, GLuint *))                                               \
  X(void, DeleteSamplers, (GLsizei, const GLuint *))                                      \
  X(void, BindSampler, (GLuint, GLuint))                                                  \
  X(void, SamplerParameteri, (GLuint, GLenum, GLint))                                     \
  X(void, SamplerParameterfv, (GLuint, GLenum, const GLfloat *))                          \
  X(void, GenFramebuffers, (GLsizei, GLuint *))                                           \
  X(void, DeleteFramebuffers, (GLsizei, const GLuint *))                                  \
  X(void, BindFramebuffer, (GLenum, GLuint))                                              \
  X(void, FramebufferTexture2D, (GLenum, GLenum, GLenum, GLuint, GLint))                  \
  X(GLenum, CheckFramebufferStatus, (GLenum))                                             \
  X(void, BlitFramebuffer,                                                                \
    (GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLbitfield, GLenum))         \
  X(void, ReadPixels, (GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *))          \
  X(void, GenQueries, (GLsizei, GLuint *))                                                \
  X(void, DeleteQueries, (GLsizei, const GLuint *))                                       \
  X(void, BeginQuery, (GLenum, GLuint))                                                   \
  X(void, EndQuery, (GLenum))                                                             \
  X(void, GetQueryObjectiv, (GLuint, GLenum, GLint *))                                    \
  X(void, GetQueryObjectui64v, (GLuint, GLenum, GLuint64 *))

struct Gl {
#define DENA_SLANG_GL_MEMBER(ret, name, args) ret(APIENTRY *name) args = nullptr;
  DENA_SLANG_GL(DENA_SLANG_GL_MEMBER)
#undef DENA_SLANG_GL_MEMBER

  // Loads every entry point; false (with the first missing name) if any is.
  bool load(ProcAddress proc, const char **missing) {
    bool ok = true;
#define DENA_SLANG_GL_LOAD(ret, name, args)                                           \
  name = reinterpret_cast<ret(APIENTRY *) args>(proc("gl" #name));                    \
  if (!name && ok) {                                                                  \
    ok = false;                                                                       \
    if (missing) *missing = "gl" #name;                                               \
  }
    DENA_SLANG_GL(DENA_SLANG_GL_LOAD)
#undef DENA_SLANG_GL_LOAD
    return ok;
  }
};

}  // namespace slang
}  // namespace dena
