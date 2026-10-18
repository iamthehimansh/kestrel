package org.kestrel.diagnostics;

import android.app.Activity;
import android.os.Bundle;
import android.opengl.EGL14;
import android.opengl.EGLConfig;
import android.opengl.EGLContext;
import android.opengl.EGLDisplay;
import android.opengl.EGLSurface;
import android.opengl.GLES20;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import org.json.JSONObject;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;

/** Isolated driver-error-path probe; never loads or modifies game code. */
public final class EGLSwapActivity extends Activity implements SurfaceHolder.Callback {
    private boolean started;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        SurfaceView surface = new SurfaceView(this);
        surface.getHolder().addCallback(this);
        setContentView(surface);
    }
    @Override public void surfaceCreated(SurfaceHolder holder) {
        if (started) return;
        started = true;
        new Thread(() -> runProbe(holder), "KestrelEGLProbe").start();
    }
    @Override public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {}
    @Override public void surfaceDestroyed(SurfaceHolder holder) {}

    private void report(String stage, boolean result, int error) throws Exception {
        JSONObject value = new JSONObject();
        value.put("stage", stage); value.put("result", result); value.put("egl_error", error);
        try (FileOutputStream out = openFileOutput("egl-swap-report.json", MODE_PRIVATE)) {
            out.write(value.toString().getBytes(StandardCharsets.UTF_8));
            out.getFD().sync();
        }
    }

    private void runProbe(SurfaceHolder holder) {
        EGLDisplay display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY);
        EGLContext context = EGL14.EGL_NO_CONTEXT;
        EGLSurface surface = EGL14.EGL_NO_SURFACE;
        try {
            int[] version = new int[2];
            if (!EGL14.eglInitialize(display, version, 0, version, 1)) throw new IllegalStateException("initialize");
            int[] attributes = { EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT, EGL14.EGL_RED_SIZE, 8,
                EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_NONE };
            EGLConfig[] configs = new EGLConfig[1]; int[] count = new int[1];
            if (!EGL14.eglChooseConfig(display, attributes, 0, configs, 0, 1, count, 0) || count[0] == 0)
                throw new IllegalStateException("config");
            if (getIntent().getBooleanExtra("zero_context_flags", false)) {
                // EGL_CONTEXT_FLAGS_KHR=0 is the ordinary non-debug context request.
                context = EGL14.eglCreateContext(display, configs[0], EGL14.EGL_NO_CONTEXT,
                    new int[] { EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, 0x30FC, 0, EGL14.EGL_NONE }, 0);
                report("zero_context_flags", !context.equals(EGL14.EGL_NO_CONTEXT), EGL14.eglGetError());
                return;
            }
            context = EGL14.eglCreateContext(display, configs[0], EGL14.EGL_NO_CONTEXT,
                new int[] { EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE }, 0);
            surface = EGL14.eglCreateWindowSurface(display, configs[0], holder.getSurface(), new int[] { EGL14.EGL_NONE }, 0);
            if (context.equals(EGL14.EGL_NO_CONTEXT) || surface.equals(EGL14.EGL_NO_SURFACE)
                || !EGL14.eglMakeCurrent(display, surface, surface, context)) throw new IllegalStateException("make current");
            GLES20.glClearColor(0.15f, 0.35f, 0.65f, 1);
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
            boolean first = EGL14.eglSwapBuffers(display, surface);
            int firstError = EGL14.eglGetError();
            report("valid_swap", first, firstError);
            if (!first || firstError != EGL14.EGL_SUCCESS) throw new IllegalStateException("valid swap");
            if (!EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT))
                throw new IllegalStateException("release context");
            report("before_contextless_swap", true, EGL14.eglGetError());
            boolean result = EGL14.eglSwapBuffers(display, surface);
            report("contextless_swap_returned", result, EGL14.eglGetError());
        } catch (Exception failure) {
            try { report("setup_failed", false, EGL14.eglGetError()); } catch (Exception ignored) {}
        } finally {
            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT);
            if (!surface.equals(EGL14.EGL_NO_SURFACE)) EGL14.eglDestroySurface(display, surface);
            if (!context.equals(EGL14.EGL_NO_CONTEXT)) EGL14.eglDestroyContext(display, context);
            EGL14.eglTerminate(display);
        }
    }
}
