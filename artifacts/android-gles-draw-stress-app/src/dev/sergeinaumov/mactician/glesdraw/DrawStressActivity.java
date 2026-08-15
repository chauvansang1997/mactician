package dev.sergeinaumov.mactician.glesdraw;

import android.app.Activity;
import android.content.Intent;
import android.opengl.GLES20;
import android.opengl.GLES30;
import android.opengl.GLES31;
import android.opengl.GLSurfaceView;
import android.os.Bundle;
import android.os.SystemClock;
import android.util.Log;

import java.io.BufferedReader;
import java.io.FileReader;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.util.Arrays;
import java.util.Locale;

import javax.microedition.khronos.egl.EGLConfig;
import javax.microedition.khronos.opengles.GL10;

public final class DrawStressActivity extends Activity implements GLSurfaceView.Renderer {
    private static final String TAG = "MacticianGLESDraw";
    private static final int TARGET_SIZE = 512;

    private static final String DRAW_VERTEX_SHADER =
            "#version 300 es\n"
            + "layout(location=0) in vec2 position;\n"
            + "layout(std140) uniform PerDraw { vec4 transform; vec4 tint; };\n"
            + "out vec4 vertexTint;\n"
            + "void main() {\n"
            + "  gl_Position = vec4(position * transform.zw + transform.xy, 0.0, 1.0);\n"
            + "  vertexTint = tint;\n"
            + "}\n";
    private static final String DRAW_FRAGMENT_SHADER =
            "#version 300 es\n"
            + "precision mediump float;\n"
            + "in vec4 vertexTint;\n"
            + "layout(location=0) out vec4 color;\n"
            + "void main() { color = vertexTint; }\n";
    private static final String BLIT_VERTEX_SHADER =
            "#version 300 es\n"
            + "layout(location=0) in vec2 position;\n"
            + "out vec2 uv;\n"
            + "void main() {\n"
            + "  gl_Position = vec4(position, 0.0, 1.0);\n"
            + "  uv = position * 0.5 + 0.5;\n"
            + "}\n";
    private static final String BLIT_FRAGMENT_SHADER =
            "#version 300 es\n"
            + "precision mediump float;\n"
            + "uniform sampler2D sourceTexture;\n"
            + "in vec2 uv;\n"
            + "layout(location=0) out vec4 color;\n"
            + "void main() { color = texture(sourceTexture, uv); }\n";

    private GLSurfaceView surface;
    private String runId;
    private int rounds;
    private int frames;
    private int drawsPerFrame;
    private int warmupRounds;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        Intent intent = getIntent();
        runId = sanitizeRunId(intent.getStringExtra("run_id"));
        rounds = boundedExtra(intent, "rounds", 8, 2, 30);
        frames = boundedExtra(intent, "frames", 120, 1, 2000);
        drawsPerFrame = boundedExtra(intent, "draws_per_frame", 256, 1, 2048);
        warmupRounds = boundedExtra(intent, "warmup_rounds", 3, 1, rounds - 1);

        surface = new GLSurfaceView(this);
        surface.setEGLContextClientVersion(3);
        surface.setPreserveEGLContextOnPause(false);
        surface.setRenderer(this);
        surface.setRenderMode(GLSurfaceView.RENDERMODE_WHEN_DIRTY);
        setContentView(surface);
    }

    private static int boundedExtra(Intent intent, String name, int fallback, int minimum, int maximum) {
        int value = intent.getIntExtra(name, fallback);
        if (value < minimum || value > maximum) {
            throw new IllegalArgumentException(name + " must be from " + minimum + " through " + maximum);
        }
        return value;
    }

    private static String sanitizeRunId(String value) {
        if (value == null || !value.matches("[A-Za-z0-9._-]{1,80}")) {
            throw new IllegalArgumentException("run_id is required and must be safe for JSON/logcat");
        }
        return value;
    }

    private static String jsonEscape(String value) {
        return value.replace("\\", "\\\\").replace("\"", "\\\"");
    }

    @Override
    public void onSurfaceCreated(GL10 ignored, EGLConfig config) {
        String renderer = GLES20.glGetString(GLES20.GL_RENDERER);
        String version = GLES20.glGetString(GLES20.GL_VERSION);
        String maps = readProcessMaps();
        Log.i(TAG, String.format(Locale.US,
                "{\"kind\":\"attestation\",\"run_id\":\"%s\",\"renderer\":\"%s\",\"version\":\"%s\",\"guest_angle_mapped\":%s,\"gfxstream_gles_encoder_mapped\":%s,\"ranchu_vulkan_mapped\":%s}",
                jsonEscape(runId), jsonEscape(renderer), jsonEscape(version),
                maps.contains("libGLESv2_angle.so"), maps.contains("libGLESv2_enc.so"),
                maps.contains("vulkan.ranchu.so")));
        try {
            runStress();
        } catch (Throwable failure) {
            Log.e(TAG, String.format(Locale.US,
                    "{\"kind\":\"failure\",\"run_id\":\"%s\",\"message\":\"%s\"}",
                    jsonEscape(runId), jsonEscape(String.valueOf(failure))));
        } finally {
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    finishAndRemoveTask();
                }
            });
        }
    }

    private static String readProcessMaps() {
        StringBuilder result = new StringBuilder();
        try (BufferedReader reader = new BufferedReader(new FileReader("/proc/self/maps"))) {
            String line;
            while ((line = reader.readLine()) != null) {
                result.append(line).append('\n');
            }
            return result.toString();
        } catch (IOException failure) {
            throw new IllegalStateException("could not read /proc/self/maps", failure);
        }
    }

    private void runStress() {
        int drawProgram = createProgram(DRAW_VERTEX_SHADER, DRAW_FRAGMENT_SHADER);
        int blitProgram = createProgram(BLIT_VERTEX_SHADER, BLIT_FRAGMENT_SHADER);
        int[] vertexArrays = new int[1];
        int[] vertexBuffers = new int[2];
        int[] uniformBuffers = new int[1];
        int[] framebuffers = new int[2];
        int[] textures = new int[2];
        GLES30.glGenVertexArrays(1, vertexArrays, 0);
        GLES30.glGenBuffers(2, vertexBuffers, 0);
        GLES30.glGenBuffers(1, uniformBuffers, 0);
        GLES30.glGenFramebuffers(2, framebuffers, 0);
        GLES30.glGenTextures(2, textures, 0);
        if (vertexArrays[0] == 0 || vertexBuffers[0] == 0 || vertexBuffers[1] == 0
                || uniformBuffers[0] == 0 || framebuffers[0] == 0 || framebuffers[1] == 0
                || textures[0] == 0 || textures[1] == 0) {
            throw new IllegalStateException("GLES object allocation returned zero");
        }

        FloatBuffer triangle = directFloats(new float[]{-0.45f, -0.35f, 0.45f, -0.35f, 0.0f, 0.55f});
        FloatBuffer fullscreen = directFloats(new float[]{-1.0f, -1.0f, 3.0f, -1.0f, -1.0f, 3.0f});
        FloatBuffer perDraw = ByteBuffer.allocateDirect(32).order(ByteOrder.nativeOrder()).asFloatBuffer();

        GLES30.glBindVertexArray(vertexArrays[0]);
        uploadVertices(vertexBuffers[0], triangle);
        uploadVertices(vertexBuffers[1], fullscreen);
        GLES30.glBindBuffer(GLES30.GL_UNIFORM_BUFFER, uniformBuffers[0]);
        GLES30.glBufferData(GLES30.GL_UNIFORM_BUFFER, 32, null, GLES30.GL_STREAM_DRAW);
        int blockIndex = GLES30.glGetUniformBlockIndex(drawProgram, "PerDraw");
        if (blockIndex == GLES30.GL_INVALID_INDEX) {
            throw new IllegalStateException("PerDraw uniform block was optimized away");
        }
        GLES30.glUniformBlockBinding(drawProgram, blockIndex, 0);
        GLES30.glBindBufferBase(GLES30.GL_UNIFORM_BUFFER, 0, uniformBuffers[0]);

        for (int index = 0; index < 2; index++) {
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, textures[index]);
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR);
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR);
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE);
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE);
            GLES30.glTexImage2D(GLES30.GL_TEXTURE_2D, 0, GLES30.GL_RGBA8, TARGET_SIZE, TARGET_SIZE,
                    0, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, null);
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, framebuffers[index]);
            GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0,
                    GLES30.GL_TEXTURE_2D, textures[index], 0);
            int status = GLES30.glCheckFramebufferStatus(GLES30.GL_FRAMEBUFFER);
            if (status != GLES30.GL_FRAMEBUFFER_COMPLETE) {
                throw new IllegalStateException(String.format(Locale.US,
                        "framebuffer %d incomplete: 0x%x", index, status));
            }
            GLES20.glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
        }
        checkNoError("setup");

        double[] measuredNS = new double[rounds - warmupRounds];
        double[] measuredDrawsPerSecond = new double[rounds - warmupRounds];
        int glErrorRounds = 0;
        try {
            for (int round = 0; round < rounds; round++) {
                long startedNS = SystemClock.elapsedRealtimeNanos();
                int sourceIndex = 0;
                int destinationIndex = 1;
                for (int frame = 0; frame < frames; frame++) {
                    GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, framebuffers[destinationIndex]);
                    GLES20.glViewport(0, 0, TARGET_SIZE, TARGET_SIZE);
                    GLES20.glClearColor(0.01f, 0.015f, 0.02f, 1.0f);
                    GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
                    GLES30.glUseProgram(drawProgram);
                    bindVertices(vertexBuffers[0]);
                    for (int draw = 0; draw < drawsPerFrame; draw++) {
                        float angle = (float) ((draw * 0.61803398875 + frame * 0.013) * Math.PI * 2.0);
                        float ring = 0.05f + 0.75f * ((draw % 31) / 30.0f);
                        float scale = 0.012f + 0.016f * ((draw % 7) / 6.0f);
                        perDraw.put(0, (float) Math.cos(angle) * ring);
                        perDraw.put(1, (float) Math.sin(angle) * ring);
                        perDraw.put(2, scale);
                        perDraw.put(3, scale);
                        perDraw.put(4, ((draw * 17 + round) & 255) / 255.0f);
                        perDraw.put(5, ((draw * 29 + frame) & 255) / 255.0f);
                        perDraw.put(6, ((draw * 43 + round + frame) & 255) / 255.0f);
                        perDraw.put(7, 0.85f);
                        perDraw.position(0);
                        GLES30.glBindBuffer(GLES30.GL_UNIFORM_BUFFER, uniformBuffers[0]);
                        GLES30.glBufferSubData(GLES30.GL_UNIFORM_BUFFER, 0, 32, perDraw);
                        GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3);
                    }
                    GLES31.glMemoryBarrier(GLES31.GL_BUFFER_UPDATE_BARRIER_BIT
                            | GLES31.GL_FRAMEBUFFER_BARRIER_BIT
                            | GLES31.GL_TEXTURE_FETCH_BARRIER_BIT);

                    GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, framebuffers[sourceIndex]);
                    GLES30.glUseProgram(blitProgram);
                    bindVertices(vertexBuffers[1]);
                    GLES30.glActiveTexture(GLES30.GL_TEXTURE0);
                    GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, textures[destinationIndex]);
                    GLES30.glUniform1i(GLES30.glGetUniformLocation(blitProgram, "sourceTexture"), 0);
                    GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3);
                    GLES31.glMemoryBarrier(GLES31.GL_FRAMEBUFFER_BARRIER_BIT
                            | GLES31.GL_TEXTURE_FETCH_BARRIER_BIT);
                    GLES20.glFinish();

                    int next = sourceIndex;
                    sourceIndex = destinationIndex;
                    destinationIndex = next;
                }
                long elapsedNS = SystemClock.elapsedRealtimeNanos() - startedNS;
                int glError = GLES20.glGetError();
                long totalDrawCalls = (long) frames * (drawsPerFrame + 1L);
                double nsPerDraw = (double) elapsedNS / totalDrawCalls;
                double drawsPerSecond = totalDrawCalls / (elapsedNS / 1_000_000_000.0);
                double framesPerSecond = frames / (elapsedNS / 1_000_000_000.0);
                Log.i(TAG, String.format(Locale.US,
                        "{\"kind\":\"draw_stress_round\",\"run_id\":\"%s\",\"round\":%d,\"warmup\":%s,\"frames\":%d,\"draws_per_frame\":%d,\"total_draw_calls\":%d,\"elapsed_ns\":%d,\"ns_per_draw\":%.3f,\"draws_per_second\":%.3f,\"frames_per_second\":%.3f,\"gl_error\":%d}",
                        jsonEscape(runId), round, round < warmupRounds, frames, drawsPerFrame,
                        totalDrawCalls, elapsedNS, nsPerDraw, drawsPerSecond, framesPerSecond, glError));
                if (round >= warmupRounds) {
                    int measuredIndex = round - warmupRounds;
                    measuredNS[measuredIndex] = nsPerDraw;
                    measuredDrawsPerSecond[measuredIndex] = drawsPerSecond;
                    if (glError != GLES20.GL_NO_ERROR) {
                        glErrorRounds++;
                    }
                }
            }
        } finally {
            GLES30.glDeleteFramebuffers(2, framebuffers, 0);
            GLES30.glDeleteTextures(2, textures, 0);
            GLES30.glDeleteBuffers(1, uniformBuffers, 0);
            GLES30.glDeleteBuffers(2, vertexBuffers, 0);
            GLES30.glDeleteVertexArrays(1, vertexArrays, 0);
            GLES30.glDeleteProgram(drawProgram);
            GLES30.glDeleteProgram(blitProgram);
        }

        Arrays.sort(measuredNS);
        Arrays.sort(measuredDrawsPerSecond);
        Log.i(TAG, String.format(Locale.US,
                "{\"kind\":\"draw_stress_summary\",\"run_id\":\"%s\",\"measured_rounds\":%d,\"median_ns_per_draw\":%.3f,\"p95_ns_per_draw\":%.3f,\"median_draws_per_second\":%.3f,\"gl_error_rounds\":%d}",
                jsonEscape(runId), measuredNS.length, percentile(measuredNS, 0.5),
                percentile(measuredNS, 0.95), percentile(measuredDrawsPerSecond, 0.5), glErrorRounds));
    }

    private static FloatBuffer directFloats(float[] values) {
        FloatBuffer result = ByteBuffer.allocateDirect(values.length * 4)
                .order(ByteOrder.nativeOrder()).asFloatBuffer();
        result.put(values).position(0);
        return result;
    }

    private static void uploadVertices(int buffer, FloatBuffer vertices) {
        GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, buffer);
        GLES30.glBufferData(GLES30.GL_ARRAY_BUFFER, vertices.capacity() * 4, vertices, GLES30.GL_STATIC_DRAW);
    }

    private static void bindVertices(int buffer) {
        GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, buffer);
        GLES30.glEnableVertexAttribArray(0);
        GLES30.glVertexAttribPointer(0, 2, GLES30.GL_FLOAT, false, 8, 0);
    }

    private static int createProgram(String vertexSource, String fragmentSource) {
        int vertexShader = compileShader(GLES30.GL_VERTEX_SHADER, vertexSource);
        int fragmentShader = compileShader(GLES30.GL_FRAGMENT_SHADER, fragmentSource);
        int program = GLES30.glCreateProgram();
        GLES30.glAttachShader(program, vertexShader);
        GLES30.glAttachShader(program, fragmentShader);
        GLES30.glLinkProgram(program);
        int[] linked = new int[1];
        GLES30.glGetProgramiv(program, GLES30.GL_LINK_STATUS, linked, 0);
        String log = GLES30.glGetProgramInfoLog(program);
        GLES30.glDeleteShader(vertexShader);
        GLES30.glDeleteShader(fragmentShader);
        if (linked[0] == 0) {
            GLES30.glDeleteProgram(program);
            throw new IllegalStateException("program link failed: " + log);
        }
        return program;
    }

    private static int compileShader(int type, String source) {
        int shader = GLES30.glCreateShader(type);
        GLES30.glShaderSource(shader, source);
        GLES30.glCompileShader(shader);
        int[] compiled = new int[1];
        GLES30.glGetShaderiv(shader, GLES30.GL_COMPILE_STATUS, compiled, 0);
        if (compiled[0] == 0) {
            String log = GLES30.glGetShaderInfoLog(shader);
            GLES30.glDeleteShader(shader);
            throw new IllegalStateException("shader compile failed: " + log);
        }
        return shader;
    }

    private static void checkNoError(String stage) {
        int error = GLES20.glGetError();
        if (error != GLES20.GL_NO_ERROR) {
            throw new IllegalStateException(String.format(Locale.US,
                    "%s GLES error 0x%x", stage, error));
        }
    }

    private static double percentile(double[] sorted, double fraction) {
        double position = (sorted.length - 1) * fraction;
        int lower = (int) Math.floor(position);
        int upper = (int) Math.ceil(position);
        if (lower == upper) {
            return sorted[lower];
        }
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - lower);
    }

    @Override
    public void onSurfaceChanged(GL10 ignored, int width, int height) {
        GLES20.glViewport(0, 0, width, height);
    }

    @Override
    public void onDrawFrame(GL10 ignored) {
        GLES20.glClearColor(0.02f, 0.02f, 0.02f, 1.0f);
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
    }
}
