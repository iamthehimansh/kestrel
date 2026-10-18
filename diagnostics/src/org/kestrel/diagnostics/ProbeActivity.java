package org.kestrel.diagnostics;

import android.app.Activity;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.opengl.EGL14;
import android.opengl.EGLConfig;
import android.opengl.EGLContext;
import android.opengl.EGLDisplay;
import android.opengl.EGLSurface;
import android.opengl.GLES20;
import android.os.Bundle;
import android.os.Build;
import android.os.SystemClock;
import android.view.Choreographer;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;

public final class ProbeActivity extends Activity implements Choreographer.FrameCallback {
    private final ArrayList<Double> intervals = new ArrayList<>();
    private final ArrayList<Double> dispatchAges = new ArrayList<>();
    private final JSONArray touches = new JSONArray();
    private JSONObject report;
    private ProbeView view;
    private long started, previous;
    private int duration;
    private boolean finished;
    private String graphics;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        duration = Math.max(5, Math.min(60, getIntent().getIntExtra("duration_seconds", 20)));
        report = new JSONObject();
        try {
            report.put("schema", 1);
            report.put("status", "running");
            report.put("sdk", Build.VERSION.SDK_INT);
            report.put("release", Build.VERSION.RELEASE);
            report.put("model", Build.MODEL);
            report.put("manufacturer", Build.MANUFACTURER);
            report.put("abis", new JSONArray(Build.SUPPORTED_ABIS));
            report.put("duration_seconds", duration);
            report.put("display_hz", getWindowManager().getDefaultDisplay().getRefreshRate());
            report.put("gles", inspectGLES());
            report.put("limits", "Callback intervals are UI scheduling, not presented game FPS. Touch delivery age is guest event-to-handler time, not host-to-photon latency. Workload is 128 animated Canvas circles; GLES is a capability probe only.");
        } catch (Exception e) { throw new IllegalStateException(e); }
        view = new ProbeView();
        setContentView(view);
        started = SystemClock.elapsedRealtimeNanos();
        Choreographer.getInstance().postFrameCallback(this);
    }

    private JSONObject inspectGLES() throws Exception {
        JSONObject gl = new JSONObject();
        EGLDisplay display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY);
        EGLContext context = EGL14.EGL_NO_CONTEXT;
        EGLSurface surface = EGL14.EGL_NO_SURFACE;
        try {
            int[] version = new int[2];
            if (!EGL14.eglInitialize(display, version, 0, version, 1)) throw new Exception("eglInitialize failed");
            EGLConfig[] configs = new EGLConfig[1];
            int[] count = new int[1];
            int[] config = {EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_NONE};
            if (!EGL14.eglChooseConfig(display, config, 0, configs, 0, 1, count, 0) || count[0] == 0)
                throw new Exception("No ES2 pbuffer config");
            context = EGL14.eglCreateContext(display, configs[0], EGL14.EGL_NO_CONTEXT,
                new int[]{EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE}, 0);
            surface = EGL14.eglCreatePbufferSurface(display, configs[0],
                new int[]{EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE}, 0);
            if (!EGL14.eglMakeCurrent(display, surface, surface, context)) throw new Exception("eglMakeCurrent failed");
            gl.put("vendor", GLES20.glGetString(GLES20.GL_VENDOR));
            gl.put("renderer", GLES20.glGetString(GLES20.GL_RENDERER));
            gl.put("version", GLES20.glGetString(GLES20.GL_VERSION));
            gl.put("extensions", GLES20.glGetString(GLES20.GL_EXTENSIONS));
            int[] max = new int[1];
            GLES20.glGetIntegerv(GLES20.GL_MAX_TEXTURE_SIZE, max, 0);
            gl.put("max_texture_size", max[0]);
            graphics = gl.optString("renderer");
        } catch (Exception e) {
            gl.put("error", e.toString());
            graphics = "GLES probe failed";
        } finally {
            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT);
            if (surface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, surface);
            if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context);
            EGL14.eglTerminate(display);
        }
        return gl;
    }

    @Override public void doFrame(long frameTimeNanos) {
        if (finished) return;
        long now = SystemClock.elapsedRealtimeNanos();
        if (previous != 0 && now - started > 2_000_000_000L)
            intervals.add((frameTimeNanos - previous) / 1_000_000.0);
        previous = frameTimeNanos;
        if (now - started >= duration * 1_000_000_000L) {
            finishProbe("completed");
        } else {
            view.invalidate();
            Choreographer.getInstance().postFrameCallback(this);
        }
    }

    private JSONObject summary(ArrayList<Double> samples) throws Exception {
        JSONObject result = new JSONObject();
        result.put("count", samples.size());
        if (samples.isEmpty()) return result;
        ArrayList<Double> sorted = new ArrayList<>(samples);
        Collections.sort(sorted);
        result.put("min_ms", sorted.get(0));
        result.put("median_ms", sorted.get(sorted.size()/2));
        result.put("p95_ms", sorted.get(Math.max(0, (int)Math.ceil(sorted.size()*0.95)-1)));
        result.put("max_ms", sorted.get(sorted.size()-1));
        return result;
    }

    private void finishProbe(String status) {
        if (finished) return;
        finished = true;
        Choreographer.getInstance().removeFrameCallback(this);
        try {
            report.put("status", status);
            report.put("callback_intervals", summary(intervals));
            report.put("callback_intervals_ms", new JSONArray(intervals));
            report.put("touch_delivery_ages", summary(dispatchAges));
            report.put("touches", touches);
            report.put("canvas_draws", view.draws);
            report.put("width", view.getWidth());
            report.put("height", view.getHeight());
            try (FileOutputStream output = openFileOutput("report.json", MODE_PRIVATE)) {
                output.write(report.toString(2).getBytes(StandardCharsets.UTF_8));
            }
        } catch (Exception e) { android.util.Log.e("KestrelProbe", "Report failed", e); }
        view.invalidate();
    }

    @Override protected void onPause() {
        finishProbe("interrupted");
        super.onPause();
    }

    private final class ProbeView extends View {
        final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        int draws;
        ProbeView() { super(ProbeActivity.this); }
        @Override protected void onDraw(Canvas canvas) {
            draws++;
            canvas.drawColor(Color.rgb(20, 26, 36));
            float elapsed = (SystemClock.elapsedRealtimeNanos()-started)/1_000_000_000f;
            for (int i=0; i<128; i++) {
                paint.setColor(Color.HSVToColor(new float[]{i*360f/128, 0.65f, 0.9f}));
                float x = (float)((0.5+0.45*Math.sin(elapsed+i*0.31))*getWidth());
                float y = (float)((0.5+0.38*Math.cos(elapsed*0.7+i*0.23))*getHeight());
                canvas.drawCircle(x, y, 8+ i%12, paint);
            }
            paint.setColor(Color.WHITE);
            paint.setTextSize(24);
            canvas.drawText("Kestrel Diagnostics: " + (finished ? "finished" : (int)elapsed+" / "+duration+" s"), 24, 40, paint);
            canvas.drawText("UI callback probe, not game FPS. Touches: " + touches.length(), 24, 74, paint);
            canvas.drawText(graphics == null ? "" : graphics, 24, 108, paint);
        }
        @Override public boolean onTouchEvent(MotionEvent event) {
            if (finished) return true;
            if (touches.length() >= 2048) return true;
            try {
                long age = SystemClock.uptimeMillis()-event.getEventTime();
                dispatchAges.add((double)age);
                JSONObject touch = new JSONObject();
                touch.put("action", event.getActionMasked());
                touch.put("pointer_count", event.getPointerCount());
                touch.put("x", event.getX());
                touch.put("y", event.getY());
                touch.put("raw_x", event.getRawX());
                touch.put("raw_y", event.getRawY());
                touch.put("delivery_age_ms", age);
                touches.put(touch);
            } catch (Exception e) { throw new IllegalStateException(e); }
            return true;
        }
    }
}
