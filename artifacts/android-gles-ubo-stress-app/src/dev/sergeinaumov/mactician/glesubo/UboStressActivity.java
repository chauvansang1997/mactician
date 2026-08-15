package dev.sergeinaumov.mactician.glesubo;

import android.app.Activity;
import android.content.Intent;
import android.opengl.GLES20;
import android.opengl.GLES30;
import android.opengl.GLSurfaceView;
import android.os.Bundle;
import android.os.SystemClock;
import android.util.Log;

import java.io.BufferedReader;
import java.io.FileReader;
import java.io.IOException;
import java.nio.Buffer;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.util.Arrays;
import java.util.Locale;

import javax.microedition.khronos.egl.EGLConfig;
import javax.microedition.khronos.opengles.GL10;

/**
 * Auth-independent UBO update microbenchmark for the same guest ANGLE -> Vulkan
 * path used by TFT. Results rank implementation ideas; they are not TFT FPS.
 */
public final class UboStressActivity extends Activity implements GLSurfaceView.Renderer {
    private static final String TAG = "MacticianGLESUbo";
    private static final int TARGET_SIZE = 512;
    private static final int UBO_BYTES = 32;
    private static final String SINGLE_SUBDATA = "single_subdata";
    private static final String POOLED_SUBDATA = "pooled_subdata";
    private static final String MAP_INVALIDATE = "map_invalidate";
    private static final String POOLED_MAP_ONCE = "pooled_map_once";

    private static final String VERTEX_SHADER =
            "#version 300 es\n"
            + "layout(location=0) in vec2 position;\n"
            + "layout(std140) uniform PerDraw { vec4 transform; vec4 tint; };\n"
            + "out vec4 vertexTint;\n"
            + "void main() {\n"
            + "  gl_Position = vec4(position * transform.zw + transform.xy, 0.0, 1.0);\n"
            + "  vertexTint = tint;\n"
            + "}\n";
    private static final String FRAGMENT_SHADER =
            "#version 300 es\n"
            + "precision mediump float;\n"
            + "in vec4 vertexTint;\n"
            + "layout(location=0) out vec4 color;\n"
            + "void main() { color = vertexTint; }\n";

    private String runId;
    private String mode;
    private int rounds;
    private int frames;
    private int drawsPerFrame;
    private int warmupRounds;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        Intent intent = getIntent();
        runId = safeRunId(intent.getStringExtra("run_id"));
        mode = safeMode(intent.getStringExtra("mode"));
        rounds = boundedExtra(intent, "rounds", 12, 2, 30);
        frames = boundedExtra(intent, "frames", 120, 1, 2000);
        drawsPerFrame = boundedExtra(intent, "draws_per_frame", 256, 1, 2048);
        warmupRounds = boundedExtra(intent, "warmup_rounds", 4, 1, rounds - 1);

        GLSurfaceView surface = new GLSurfaceView(this);
        surface.setEGLContextClientVersion(3);
        surface.setPreserveEGLContextOnPause(false);
        surface.setRenderer(this);
        surface.setRenderMode(GLSurfaceView.RENDERMODE_WHEN_DIRTY);
        setContentView(surface);
    }

    private static int boundedExtra(Intent intent, String name, int fallback,
            int minimum, int maximum) {
        int value = intent.getIntExtra(name, fallback);
        if (value < minimum || value > maximum) {
            throw new IllegalArgumentException(name + " must be from " + minimum + " through " + maximum);
        }
        return value;
    }

    private static String safeRunId(String value) {
        if (value == null || !value.matches("[A-Za-z0-9._-]{1,80}")) {
            throw new IllegalArgumentException("run_id is required and must be safe for JSON/logcat");
        }
        return value;
    }

    private static String safeMode(String value) {
        if (!SINGLE_SUBDATA.equals(value) && !POOLED_SUBDATA.equals(value)
                && !MAP_INVALIDATE.equals(value) && !POOLED_MAP_ONCE.equals(value)) {
            throw new IllegalArgumentException("unsupported UBO mode: " + value);
        }
        return value;
    }

    private static String jsonEscape(String value) {
        return value.replace("\\", "\\\\").replace("\"", "\\\"");
    }

    @Override
    public void onSurfaceCreated(GL10 ignored, EGLConfig config) {
        try {
            runStress();
        } catch (Throwable failure) {
            Log.e(TAG, String.format(Locale.US,
                    "{\"kind\":\"failure\",\"run_id\":\"%s\",\"mode\":\"%s\",\"message\":\"%s\"}",
                    jsonEscape(runId), jsonEscape(mode), jsonEscape(String.valueOf(failure))));
        } finally {
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    finishAndRemoveTask();
                }
            });
        }
    }

    private void runStress() {
        int program = createProgram(VERTEX_SHADER, FRAGMENT_SHADER);
        int[] vertexArray = new int[1];
        int[] vertexBuffer = new int[1];
        int[] uniformBuffer = new int[1];
        int[] framebuffer = new int[1];
        int[] texture = new int[1];
        GLES30.glGenVertexArrays(1, vertexArray, 0);
        GLES30.glGenBuffers(1, vertexBuffer, 0);
        GLES30.glGenBuffers(1, uniformBuffer, 0);
        GLES30.glGenFramebuffers(1, framebuffer, 0);
        GLES30.glGenTextures(1, texture, 0);
        if (vertexArray[0] == 0 || vertexBuffer[0] == 0 || uniformBuffer[0] == 0
                || framebuffer[0] == 0 || texture[0] == 0) {
            throw new IllegalStateException("GLES object allocation returned zero");
        }

        int[] alignmentValue = new int[1];
        GLES30.glGetIntegerv(GLES30.GL_UNIFORM_BUFFER_OFFSET_ALIGNMENT, alignmentValue, 0);
        int alignment = Math.max(1, alignmentValue[0]);
        int stride = ((UBO_BYTES + alignment - 1) / alignment) * alignment;
        boolean pooled = POOLED_SUBDATA.equals(mode) || POOLED_MAP_ONCE.equals(mode);
        int bufferBytes = pooled ? Math.multiplyExact(stride, drawsPerFrame) : UBO_BYTES;
        FloatBuffer perDraw = ByteBuffer.allocateDirect(UBO_BYTES)
                .order(ByteOrder.nativeOrder()).asFloatBuffer();

        GLES30.glBindVertexArray(vertexArray[0]);
        FloatBuffer triangle = directFloats(new float[]{
                -0.45f, -0.35f, 0.45f, -0.35f, 0.0f, 0.55f});
        GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, vertexBuffer[0]);
        GLES30.glBufferData(GLES30.GL_ARRAY_BUFFER, triangle.capacity() * 4,
                triangle, GLES30.GL_STATIC_DRAW);
        GLES30.glEnableVertexAttribArray(0);
        GLES30.glVertexAttribPointer(0, 2, GLES30.GL_FLOAT, false, 8, 0);

        GLES30.glBindBuffer(GLES30.GL_UNIFORM_BUFFER, uniformBuffer[0]);
        GLES30.glBufferData(GLES30.GL_UNIFORM_BUFFER, bufferBytes, null, GLES30.GL_STREAM_DRAW);
        int blockIndex = GLES30.glGetUniformBlockIndex(program, "PerDraw");
        if (blockIndex == GLES30.GL_INVALID_INDEX) {
            throw new IllegalStateException("PerDraw uniform block was optimized away");
        }
        int[] blockBytes = new int[1];
        GLES30.glGetActiveUniformBlockiv(program, blockIndex,
                GLES30.GL_UNIFORM_BLOCK_DATA_SIZE, blockBytes, 0);
        if (blockBytes[0] != UBO_BYTES) {
            throw new IllegalStateException("unexpected PerDraw block size: " + blockBytes[0]);
        }
        GLES30.glUniformBlockBinding(program, blockIndex, 0);

        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, texture[0]);
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_NEAREST);
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_NEAREST);
        GLES30.glTexImage2D(GLES30.GL_TEXTURE_2D, 0, GLES30.GL_RGBA8,
                TARGET_SIZE, TARGET_SIZE, 0, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, null);
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, framebuffer[0]);
        GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0,
                GLES30.GL_TEXTURE_2D, texture[0], 0);
        if (GLES30.glCheckFramebufferStatus(GLES30.GL_FRAMEBUFFER)
                != GLES30.GL_FRAMEBUFFER_COMPLETE) {
            throw new IllegalStateException("offscreen framebuffer is incomplete");
        }
        checkNoError("setup");

        String maps = readProcessMaps();
        Log.i(TAG, String.format(Locale.US,
                "{\"kind\":\"attestation\",\"run_id\":\"%s\",\"mode\":\"%s\",\"renderer\":\"%s\",\"version\":\"%s\",\"guest_angle_mapped\":%s,\"gfxstream_gles_encoder_mapped\":%s,\"ranchu_vulkan_mapped\":%s,\"ubo_alignment\":%d,\"ubo_stride\":%d,\"ubo_bytes\":%d}",
                jsonEscape(runId), jsonEscape(mode),
                jsonEscape(GLES20.glGetString(GLES20.GL_RENDERER)),
                jsonEscape(GLES20.glGetString(GLES20.GL_VERSION)),
                maps.contains("libGLESv2_angle.so"), maps.contains("libGLESv2_enc.so"),
                maps.contains("vulkan.ranchu.so"), alignment, stride, UBO_BYTES));

        double[] measuredNS = new double[rounds - warmupRounds];
        double[] measuredFPS = new double[rounds - warmupRounds];
        int glErrorRounds = 0;
        try {
            GLES30.glUseProgram(program);
            GLES20.glViewport(0, 0, TARGET_SIZE, TARGET_SIZE);
            for (int round = 0; round < rounds; round++) {
                long startedNS = SystemClock.elapsedRealtimeNanos();
                for (int frame = 0; frame < frames; frame++) {
                    GLES20.glClearColor(0.01f, 0.015f, 0.02f, 1.0f);
                    GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
                    GLES30.glBindBuffer(GLES30.GL_UNIFORM_BUFFER, uniformBuffer[0]);
                    if (pooled) {
                        GLES30.glBufferData(GLES30.GL_UNIFORM_BUFFER, bufferBytes,
                                null, GLES30.GL_STREAM_DRAW);
                    }
                    if (POOLED_MAP_ONCE.equals(mode)) {
                        Buffer mapped = GLES30.glMapBufferRange(GLES30.GL_UNIFORM_BUFFER, 0,
                                bufferBytes, GLES30.GL_MAP_WRITE_BIT
                                        | GLES30.GL_MAP_INVALIDATE_BUFFER_BIT);
                        if (!(mapped instanceof ByteBuffer)) {
                            throw new IllegalStateException("pooled map returned no ByteBuffer");
                        }
                        FloatBuffer mappedFloats = ((ByteBuffer) mapped)
                                .order(ByteOrder.nativeOrder()).asFloatBuffer();
                        for (int draw = 0; draw < drawsPerFrame; draw++) {
                            writePerDraw(mappedFloats, stride * draw / 4, draw, frame, round);
                        }
                        if (!GLES30.glUnmapBuffer(GLES30.GL_UNIFORM_BUFFER)) {
                            throw new IllegalStateException("pooled UBO unmap failed");
                        }
                    }

                    for (int draw = 0; draw < drawsPerFrame; draw++) {
                        if (SINGLE_SUBDATA.equals(mode) || POOLED_SUBDATA.equals(mode)) {
                            writePerDraw(perDraw, 0, draw, frame, round);
                            perDraw.position(0);
                            int offset = POOLED_SUBDATA.equals(mode) ? stride * draw : 0;
                            GLES30.glBufferSubData(GLES30.GL_UNIFORM_BUFFER,
                                    offset, UBO_BYTES, perDraw);
                        } else if (MAP_INVALIDATE.equals(mode)) {
                            Buffer mapped = GLES30.glMapBufferRange(GLES30.GL_UNIFORM_BUFFER, 0,
                                    UBO_BYTES, GLES30.GL_MAP_WRITE_BIT
                                            | GLES30.GL_MAP_INVALIDATE_BUFFER_BIT);
                            if (!(mapped instanceof ByteBuffer)) {
                                throw new IllegalStateException("per-draw map returned no ByteBuffer");
                            }
                            FloatBuffer mappedFloats = ((ByteBuffer) mapped)
                                    .order(ByteOrder.nativeOrder()).asFloatBuffer();
                            writePerDraw(mappedFloats, 0, draw, frame, round);
                            if (!GLES30.glUnmapBuffer(GLES30.GL_UNIFORM_BUFFER)) {
                                throw new IllegalStateException("per-draw UBO unmap failed");
                            }
                        }

                        if (pooled) {
                            GLES30.glBindBufferRange(GLES30.GL_UNIFORM_BUFFER, 0,
                                    uniformBuffer[0], stride * draw, UBO_BYTES);
                        } else {
                            GLES30.glBindBufferBase(GLES30.GL_UNIFORM_BUFFER, 0, uniformBuffer[0]);
                        }
                        GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3);
                    }
                    GLES20.glFinish();
                }
                long elapsedNS = SystemClock.elapsedRealtimeNanos() - startedNS;
                int glError = GLES20.glGetError();
                long totalDrawCalls = (long) frames * drawsPerFrame;
                double nsPerDraw = (double) elapsedNS / totalDrawCalls;
                double framesPerSecond = frames / (elapsedNS / 1_000_000_000.0);
                Log.i(TAG, String.format(Locale.US,
                        "{\"kind\":\"ubo_stress_round\",\"run_id\":\"%s\",\"mode\":\"%s\",\"round\":%d,\"warmup\":%s,\"frames\":%d,\"draws_per_frame\":%d,\"elapsed_ns\":%d,\"ns_per_draw\":%.3f,\"frames_per_second\":%.3f,\"gl_error\":%d}",
                        jsonEscape(runId), jsonEscape(mode), round, round < warmupRounds,
                        frames, drawsPerFrame, elapsedNS, nsPerDraw, framesPerSecond, glError));
                if (round >= warmupRounds) {
                    int index = round - warmupRounds;
                    measuredNS[index] = nsPerDraw;
                    measuredFPS[index] = framesPerSecond;
                    if (glError != GLES20.GL_NO_ERROR) {
                        glErrorRounds++;
                    }
                }
            }
        } finally {
            GLES30.glDeleteFramebuffers(1, framebuffer, 0);
            GLES30.glDeleteTextures(1, texture, 0);
            GLES30.glDeleteBuffers(1, uniformBuffer, 0);
            GLES30.glDeleteBuffers(1, vertexBuffer, 0);
            GLES30.glDeleteVertexArrays(1, vertexArray, 0);
            GLES30.glDeleteProgram(program);
        }

        Arrays.sort(measuredNS);
        Arrays.sort(measuredFPS);
        Log.i(TAG, String.format(Locale.US,
                "{\"kind\":\"ubo_stress_summary\",\"run_id\":\"%s\",\"mode\":\"%s\",\"measured_rounds\":%d,\"median_ns_per_draw\":%.3f,\"p95_ns_per_draw\":%.3f,\"median_frames_per_second\":%.3f,\"gl_error_rounds\":%d}",
                jsonEscape(runId), jsonEscape(mode), measuredNS.length,
                percentile(measuredNS, 0.5), percentile(measuredNS, 0.95),
                percentile(measuredFPS, 0.5), glErrorRounds));
    }

    private static void writePerDraw(FloatBuffer target, int base, int draw, int frame, int round) {
        float angle = (float) ((draw * 0.61803398875 + frame * 0.013) * Math.PI * 2.0);
        float ring = 0.05f + 0.75f * ((draw % 31) / 30.0f);
        float scale = 0.012f + 0.016f * ((draw % 7) / 6.0f);
        target.put(base, (float) Math.cos(angle) * ring);
        target.put(base + 1, (float) Math.sin(angle) * ring);
        target.put(base + 2, scale);
        target.put(base + 3, scale);
        target.put(base + 4, ((draw * 17 + round) & 255) / 255.0f);
        target.put(base + 5, ((draw * 29 + frame) & 255) / 255.0f);
        target.put(base + 6, ((draw * 43 + round + frame) & 255) / 255.0f);
        target.put(base + 7, 0.85f);
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

    private static FloatBuffer directFloats(float[] values) {
        FloatBuffer result = ByteBuffer.allocateDirect(values.length * 4)
                .order(ByteOrder.nativeOrder()).asFloatBuffer();
        result.put(values).position(0);
        return result;
    }

    private static int createProgram(String vertexSource, String fragmentSource) {
        int vertex = compileShader(GLES30.GL_VERTEX_SHADER, vertexSource);
        int fragment = compileShader(GLES30.GL_FRAGMENT_SHADER, fragmentSource);
        int program = GLES30.glCreateProgram();
        GLES30.glAttachShader(program, vertex);
        GLES30.glAttachShader(program, fragment);
        GLES30.glLinkProgram(program);
        int[] linked = new int[1];
        GLES30.glGetProgramiv(program, GLES30.GL_LINK_STATUS, linked, 0);
        String log = GLES30.glGetProgramInfoLog(program);
        GLES30.glDeleteShader(vertex);
        GLES30.glDeleteShader(fragment);
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
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
    }
}
