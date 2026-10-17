// SPDX-License-Identifier: BSD-2-Clause
/*
 * egl-readback: GPU functional test without a display. Opens the msm render
 * node, creates a surfaceless GLES2 context on GBM, draws a triangle into a
 * texture-backed framebuffer, reads it back and checks the pixels. Then
 * draws FRAMES frames and reports the rate. Fails on a software renderer.
 */
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <fcntl.h>
#include <gbm.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <xf86drm.h>

#define W 256
#define H 256
#define FRAMES 500

static int fail(const char *what)
{
	fprintf(stderr, "egl-readback: FAIL: %s (egl 0x%x gl 0x%x)\n", what,
		eglGetError(), glGetError());
	return 1;
}

static int open_msm_render(void)
{
	for (int i = 128; i < 136; i++) {
		char path[32];
		int fd, msm = 0;
		drmVersionPtr v;

		snprintf(path, sizeof(path), "/dev/dri/renderD%d", i);
		fd = open(path, O_RDWR | O_CLOEXEC);
		if (fd < 0)
			continue;
		v = drmGetVersion(fd);
		if (v) {
			printf("%s: %s %d.%d.%d\n", path, v->name,
			       v->version_major, v->version_minor,
			       v->version_patchlevel);
			msm = !strcmp(v->name, "msm");
			drmFreeVersion(v);
		}
		if (msm)
			return fd;
		close(fd);
	}
	return -1;
}

static GLuint shader(GLenum type, const char *src)
{
	GLuint s = glCreateShader(type);
	GLint ok = 0;

	glShaderSource(s, 1, &src, NULL);
	glCompileShader(s);
	glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
	return ok ? s : 0;
}

static int pixel_is(const unsigned char *px, int x, int y,
		    unsigned char r, unsigned char g, unsigned char b)
{
	const unsigned char *p = px + 4 * (y * W + x);

	printf("pixel (%d,%d) = %u %u %u %u\n", x, y, p[0], p[1], p[2], p[3]);
	return p[0] == r && p[1] == g && p[2] == b && p[3] == 255;
}

int main(void)
{
	static const GLfloat tri[] = { -1, -1, 1, -1, -1, 1 };
	static unsigned char px[W * H * 4];
	const EGLint cfg_attr[] = { EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
				    EGL_NONE };
	const EGLint ctx_attr[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
	struct gbm_device *gbm;
	struct timespec t0, t1;
	const char *renderer;
	EGLDisplay dpy;
	EGLContext ctx;
	EGLConfig cfg;
	EGLint major, minor, n = 0;
	GLuint prog, tex, fbo, vs, fs;
	GLint color;
	double s;
	int fd;

	fd = open_msm_render();
	if (fd < 0)
		return fail("no msm render node");
	gbm = gbm_create_device(fd);
	if (!gbm)
		return fail("gbm_create_device");
	dpy = eglGetPlatformDisplay(EGL_PLATFORM_GBM_KHR, gbm, NULL);
	if (dpy == EGL_NO_DISPLAY || !eglInitialize(dpy, &major, &minor))
		return fail("eglInitialize");
	printf("EGL %d.%d %s\n", major, minor, eglQueryString(dpy, EGL_VENDOR));
	if (!strstr(eglQueryString(dpy, EGL_EXTENSIONS),
		    "EGL_KHR_surfaceless_context"))
		return fail("no EGL_KHR_surfaceless_context");
	if (!eglBindAPI(EGL_OPENGL_ES_API) ||
	    !eglChooseConfig(dpy, cfg_attr, &cfg, 1, &n) || n < 1)
		return fail("eglChooseConfig");
	ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctx_attr);
	if (ctx == EGL_NO_CONTEXT ||
	    !eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx))
		return fail("context");

	renderer = (const char *)glGetString(GL_RENDERER);
	printf("GL_VENDOR %s\nGL_RENDERER %s\nGL_VERSION %s\n",
	       glGetString(GL_VENDOR), renderer, glGetString(GL_VERSION));
	if (!renderer || strstr(renderer, "llvmpipe") ||
	    strstr(renderer, "softpipe"))
		return fail("software renderer");

	glGenTextures(1, &tex);
	glBindTexture(GL_TEXTURE_2D, tex);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, W, H, 0, GL_RGBA,
		     GL_UNSIGNED_BYTE, NULL);
	glGenFramebuffers(1, &fbo);
	glBindFramebuffer(GL_FRAMEBUFFER, fbo);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
			       GL_TEXTURE_2D, tex, 0);
	if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
		return fail("framebuffer incomplete");

	vs = shader(GL_VERTEX_SHADER,
		    "attribute vec2 p;\n"
		    "void main() { gl_Position = vec4(p, 0.0, 1.0); }\n");
	fs = shader(GL_FRAGMENT_SHADER,
		    "precision mediump float;\n"
		    "uniform vec4 c;\n"
		    "void main() { gl_FragColor = c; }\n");
	if (!vs || !fs)
		return fail("shader compile");
	prog = glCreateProgram();
	glAttachShader(prog, vs);
	glAttachShader(prog, fs);
	glBindAttribLocation(prog, 0, "p");
	glLinkProgram(prog);
	glUseProgram(prog);
	color = glGetUniformLocation(prog, "c");
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, tri);
	glEnableVertexAttribArray(0);
	glViewport(0, 0, W, H);

	/* Blue background, red lower-left half. */
	glClearColor(0, 0, 1, 1);
	glClear(GL_COLOR_BUFFER_BIT);
	glUniform4f(color, 1, 0, 0, 1);
	glDrawArrays(GL_TRIANGLES, 0, 3);
	glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, px);
	if (glGetError() != GL_NO_ERROR)
		return fail("draw or readback");
	if (!pixel_is(px, 16, 16, 255, 0, 0) ||
	    !pixel_is(px, W - 16, H - 16, 0, 0, 255))
		return fail("unexpected pixels");

	clock_gettime(CLOCK_MONOTONIC, &t0);
	for (int i = 0; i < FRAMES; i++) {
		glClear(GL_COLOR_BUFFER_BIT);
		glUniform4f(color, (i & 255) / 255.0f, 1, 0, 1);
		glDrawArrays(GL_TRIANGLES, 0, 3);
	}
	glReadPixels(16, 16, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
	clock_gettime(CLOCK_MONOTONIC, &t1);
	s = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
	printf("%d frames in %.3f s (%.0f fps), last pixel %u %u %u\n",
	       FRAMES, s, FRAMES / s, px[0], px[1], px[2]);
	/* mediump is fp16 on Adreno: allow one step of rounding. */
	if (abs(px[0] - ((FRAMES - 1) & 255)) > 1 || px[1] != 255 || px[2] != 0)
		return fail("unexpected pixel after the frame loop");

	printf("egl-readback: PASS\n");
	return 0;
}
