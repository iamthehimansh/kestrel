package org.kestrel.glesprobe;

import android.app.Activity;
import android.os.Bundle;
import android.os.Build;
import android.os.SystemClock;
import android.opengl.GLES20;
import android.opengl.GLSurfaceView;
import android.view.View;
import android.view.WindowManager;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.FileOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import javax.microedition.khronos.egl.EGLConfig;
import javax.microedition.khronos.opengles.GL10;

/** Fixed-size offscreen GLES workload; glFinish time includes guest/host submission and waiting. */
public final class GLESActivity extends Activity {
    private GLSurfaceView surface;
    private Workload workload;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        getWindow().getDecorView().setSystemUiVisibility(
            View.SYSTEM_UI_FLAG_FULLSCREEN | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION |
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY | View.SYSTEM_UI_FLAG_LAYOUT_STABLE |
            View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION);
        surface = new GLSurfaceView(this);
        surface.setEGLContextClientVersion(2);
        surface.setEGLConfigChooser(8, 8, 8, 8, 0, 0);
        workload = new Workload(Math.max(8, Math.min(30,
            getIntent().getIntExtra("duration_seconds", 20))));
        surface.setRenderer(workload);
        setContentView(surface);
    }

    @Override protected void onPause() {
        surface.queueEvent(() -> workload.finish("interrupted", null));
        surface.onPause();
        super.onPause();
    }

    @Override protected void onResume() {
        super.onResume();
        surface.onResume();
    }

    private final class Workload implements GLSurfaceView.Renderer {
        private static final int WIDTH = 1280, HEIGHT = 720, PASSES = 4, ITERATIONS = 24;
        private final int duration;
        private final ArrayList<Double> completedDraws = new ArrayList<>();
        private final ArrayList<Double> frameStarts = new ArrayList<>();
        private final JSONObject report = new JSONObject();
        private FloatBuffer quad;
        private int renderProgram, displayProgram, texture, framebuffer, surfaceWidth, surfaceHeight;
        private long started, previous;
        private int frames, contexts;
        private boolean finished;
        private static final String VERTEX =
            "attribute vec2 a; varying vec2 uv; void main(){uv=a*0.5+0.5;gl_Position=vec4(a,0.0,1.0);}";
        private static final String FRAGMENT =
            "precision highp float; varying vec2 uv; uniform float phase;" +
            "void main(){vec2 q=uv*3.0;float v=phase;" +
            "for(int i=0;i<24;i++){v=sin(q.x+v)*cos(q.y-v);q+=vec2(v*0.025,0.017);}" +
            "gl_FragColor=vec4(0.5+0.45*sin(v+phase),uv.y,0.5+0.45*cos(v-phase),1.0);}";
        private static final String DISPLAY =
            "precision mediump float; varying vec2 uv; uniform sampler2D image;" +
            "void main(){gl_FragColor=texture2D(image,uv);}";

        Workload(int seconds) { duration = seconds; }

        private void check(String where) {
            int error = GLES20.glGetError();
            if (error != GLES20.GL_NO_ERROR) throw new IllegalStateException(where + ": GL error " + error);
        }

        private int shader(int type, String source) {
            int id = GLES20.glCreateShader(type);
            GLES20.glShaderSource(id, source);
            GLES20.glCompileShader(id);
            int[] ok = new int[1];
            GLES20.glGetShaderiv(id, GLES20.GL_COMPILE_STATUS, ok, 0);
            if (ok[0] == 0) throw new IllegalStateException(GLES20.glGetShaderInfoLog(id));
            return id;
        }

        private int program(String fragment) {
            int vs = shader(GLES20.GL_VERTEX_SHADER, VERTEX);
            int fs = shader(GLES20.GL_FRAGMENT_SHADER, fragment);
            int id = GLES20.glCreateProgram();
            GLES20.glAttachShader(id, vs);
            GLES20.glAttachShader(id, fs);
            GLES20.glBindAttribLocation(id, 0, "a");
            GLES20.glLinkProgram(id);
            int[] ok = new int[1];
            GLES20.glGetProgramiv(id, GLES20.GL_LINK_STATUS, ok, 0);
            if (ok[0] == 0) throw new IllegalStateException(GLES20.glGetProgramInfoLog(id));
            GLES20.glDeleteShader(vs);
            GLES20.glDeleteShader(fs);
            return id;
        }

        @Override public void onSurfaceCreated(GL10 ignored, EGLConfig config) {
            try {
                if (++contexts != 1) throw new IllegalStateException("Context recreated; sample invalid");
                report.put("schema", 1);
                report.put("workload", "gles-fixed-fbo-v1");
                report.put("width", WIDTH);
                report.put("height", HEIGHT);
                report.put("passes", PASSES);
                report.put("shader_iterations", ITERATIONS);
                report.put("duration_seconds", duration);
                report.put("sdk", Build.VERSION.SDK_INT);
                report.put("renderer", GLES20.glGetString(GLES20.GL_RENDERER));
                report.put("vendor", GLES20.glGetString(GLES20.GL_VENDOR));
                report.put("gl_version", GLES20.glGetString(GLES20.GL_VERSION));
                report.put("limits", "CPU-observed glFinish completion includes transport, queueing and GPU execution; not GPU-only time. Frame-start intervals include swap/pacing; not presented FPS. Fixed FBO workload, not a game benchmark.");
                long compileStart = SystemClock.elapsedRealtimeNanos();
                renderProgram = program(FRAGMENT);
                displayProgram = program(DISPLAY);
                report.put("compile_link_ms", (SystemClock.elapsedRealtimeNanos()-compileStart)/1e6);
                quad = ByteBuffer.allocateDirect(8*4).order(ByteOrder.nativeOrder()).asFloatBuffer();
                quad.put(new float[]{-1,-1,1,-1,-1,1,1,1}).position(0);
                int[] ids = new int[1];
                GLES20.glGenTextures(1, ids, 0); texture = ids[0];
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texture);
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR);
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR);
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE);
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE);
                GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, WIDTH, HEIGHT, 0,
                    GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null);
                GLES20.glGenFramebuffers(1, ids, 0); framebuffer = ids[0];
                GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, framebuffer);
                GLES20.glFramebufferTexture2D(GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0,
                    GLES20.GL_TEXTURE_2D, texture, 0);
                if (GLES20.glCheckFramebufferStatus(GLES20.GL_FRAMEBUFFER) != GLES20.GL_FRAMEBUFFER_COMPLETE)
                    throw new IllegalStateException("Incomplete framebuffer");
                GLES20.glViewport(0, 0, WIDTH, HEIGHT);
                GLES20.glClearColor(0.25f, 0.5f, 0.75f, 1);
                GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
                ByteBuffer pixel = ByteBuffer.allocateDirect(4);
                GLES20.glReadPixels(0, 0, 1, 1, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, pixel);
                int[] expected = {64,128,191,255};
                JSONArray actual = new JSONArray();
                for (int i=0;i<4;i++) {
                    int value = pixel.get(i) & 255;
                    actual.put(value);
                    if (Math.abs(value-expected[i]) > 2) throw new IllegalStateException("Calibration readback mismatch");
                }
                report.put("calibration_rgba", actual);
                check("setup/readback");
                GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0);
                started = SystemClock.elapsedRealtimeNanos();
            } catch (Exception e) { finish("failed", e.toString()); }
        }

        @Override public void onSurfaceChanged(GL10 ignored, int width, int height) {
            surfaceWidth = width; surfaceHeight = height;
        }

        private void drawQuad() {
            quad.position(0);
            GLES20.glEnableVertexAttribArray(0);
            GLES20.glVertexAttribPointer(0, 2, GLES20.GL_FLOAT, false, 0, quad);
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);
        }

        @Override public void onDrawFrame(GL10 ignored) {
            if (finished) return;
            try {
                long begin = SystemClock.elapsedRealtimeNanos();
                boolean measured = begin-started > 2_000_000_000L;
                if (previous != 0 && measured) frameStarts.add((begin-previous)/1e6);
                previous = begin;
                GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, framebuffer);
                GLES20.glViewport(0, 0, WIDTH, HEIGHT);
                GLES20.glUseProgram(renderProgram);
                int phase = GLES20.glGetUniformLocation(renderProgram, "phase");
                for (int i=0;i<PASSES;i++) {
                    GLES20.glUniform1f(phase, (frames % 360)*0.01f + i*0.25f);
                    drawQuad();
                }
                GLES20.glFinish();
                long done = SystemClock.elapsedRealtimeNanos();
                if (measured) completedDraws.add((done-begin)/1e6);
                check("workload");
                GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0);
                GLES20.glViewport(0, 0, surfaceWidth, surfaceHeight);
                GLES20.glUseProgram(displayProgram);
                GLES20.glActiveTexture(GLES20.GL_TEXTURE0);
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texture);
                GLES20.glUniform1i(GLES20.glGetUniformLocation(displayProgram, "image"), 0);
                drawQuad();
                check("display");
                frames++;
                if (done-started >= duration*1_000_000_000L) {
                    GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, framebuffer);
                    ByteBuffer pixels = ByteBuffer.allocateDirect(4);
                    JSONArray colors = new JSONArray();
                    for (int y : new int[]{HEIGHT/4, HEIGHT/2, HEIGHT*3/4}) {
                        GLES20.glReadPixels(WIDTH/2, y, 1, 1, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, pixels);
                        JSONArray rgba = new JSONArray();
                        for (int i=0;i<4;i++) rgba.put(pixels.get(i)&255);
                        int green = pixels.get(1)&255;
                        int expectedGreen = Math.round(255f*(y+0.5f)/HEIGHT);
                        if (Math.abs(green-expectedGreen)>3 || (pixels.get(3)&255)!=255)
                            throw new IllegalStateException("Workload pixel validation failed");
                        colors.put(rgba);
                    }
                    report.put("workload_readback_rgba", colors);
                    check("final readback");
                    GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0);
                    finish("completed", null);
                }
            } catch (Exception e) { finish("failed", e.toString()); }
        }

        private JSONObject stats(ArrayList<Double> values) throws Exception {
            JSONObject out = new JSONObject(); out.put("count", values.size());
            if (values.isEmpty()) return out;
            ArrayList<Double> sorted = new ArrayList<>(values); Collections.sort(sorted);
            out.put("median_ms", sorted.get(sorted.size()/2));
            out.put("p95_ms", sorted.get((int)Math.ceil(sorted.size()*0.95)-1));
            out.put("max_ms", sorted.get(sorted.size()-1));
            return out;
        }

        private void finish(String status, String error) {
            if (finished) return;
            finished = true;
            try {
                report.put("status", status);
                if (error != null) report.put("error", error);
                report.put("surface_width", surfaceWidth);
                report.put("surface_height", surfaceHeight);
                report.put("frames", frames);
                report.put("completed_draw", stats(completedDraws));
                report.put("frame_start_intervals", stats(frameStarts));
                report.put("completed_draw_ms", new JSONArray(completedDraws));
                report.put("frame_start_intervals_ms", new JSONArray(frameStarts));
                try (FileOutputStream file = openFileOutput("report.json", MODE_PRIVATE)) {
                    file.write(report.toString(2).getBytes(StandardCharsets.UTF_8));
                }
            } catch (Exception e) { android.util.Log.e("KestrelGLES", "Report failed", e); }
            surface.setRenderMode(GLSurfaceView.RENDERMODE_WHEN_DIRTY);
        }
    }
}
